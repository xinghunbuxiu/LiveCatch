use anyhow::{anyhow, Context, Result};
use platforms_parser::{
    extractor::factory::{ExtractorFactory, ExtractorSelection},
    media::{MediaInfo, StreamInfo},
};
#[cfg(not(target_os = "android"))]
use platforms_parser::extractor::create_client;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{HashMap, HashSet};

#[cfg(target_os = "android")]
mod android_jni;
mod douyin_expand;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct StreamCandidate {
    pub url: String,
    pub format: String,
    pub media_format: String,
    pub quality: String,
    pub bitrate: u64,
    pub codec: String,
    pub fps: f64,
    pub priority: u32,
    pub headers_needed: bool,
    pub audio_only: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ResolvedStream {
    pub platform: String,
    pub site_url: String,
    pub title: String,
    pub artist: String,
    pub is_live: bool,
    pub streams: Vec<StreamCandidate>,
    pub headers: Option<HashMap<String, String>>,
}

#[derive(Debug, Clone, Default)]
pub struct ResolveOptions {
    pub cookies: Option<String>,
    pub extras: Option<Value>,
}

pub async fn resolve(
    url: &str,
    cookies: Option<&str>,
    extras: Option<Value>,
) -> Result<ResolvedStream> {
    resolve_with_options(
        url,
        ResolveOptions {
            cookies: cookies.map(str::to_owned),
            extras,
        },
    )
    .await
}

pub async fn resolve_with_options(
    url: &str,
    options: ResolveOptions,
) -> Result<ResolvedStream> {
    let url = url.trim();
    if url.is_empty() {
        return Err(anyhow!("stream URL is empty"));
    }

    // platforms-parser only matches live.douyin.com/{web_rid}; expand share short links first.
    let url = if douyin_expand::looks_like_douyin_short_url(url) {
        let expand_client = douyin_expand::no_redirect_client()?;
        douyin_expand::expand_douyin_input(&expand_client, url).await?
    } else {
        url.to_string()
    };
    let url = url.as_str();

    #[cfg(target_os = "android")]
    let client = android_http_client().context("build HTTP client")?;
    #[cfg(not(target_os = "android"))]
    let client = create_client(None);

    // First attempt matches strev/desktop defaults (no forced Douyin extras).
    let extras = options.extras;
    let cookies = options.cookies;

    let mut last_err: Option<anyhow::Error> = None;
    for attempt in 0u32..3 {
        if attempt > 0 {
            tokio::time::sleep(std::time::Duration::from_millis(700 * u64::from(attempt)))
                .await;
        }
        let factory = ExtractorFactory::new(client.clone());
        let attempt_extras = if attempt == 0 {
            extras.clone()
        } else if looks_like_douyin(url) {
            // Same extractor; only retry path differs (mobile API + fresh ttwid).
            bump_retry_extras(extras.clone())
        } else {
            extras.clone()
        };
        match try_extract_once(&factory, url, cookies.clone(), attempt_extras).await {
            Ok(resolved) => return Ok(resolved),
            Err(e) => {
                let retryable = is_retryable_extract(&e);
                last_err = Some(e);
                if !retryable {
                    break;
                }
            }
        }
    }

    Err(map_resolve_error(
        last_err.unwrap_or_else(|| anyhow!("extract stream metadata failed")),
    ))
}

async fn try_extract_once(
    factory: &ExtractorFactory,
    url: &str,
    cookies: Option<String>,
    extras: Option<Value>,
) -> Result<ResolvedStream> {
    let extractor = factory
        .create_extractor(url, cookies, extras, ExtractorSelection::Auto)
        .map_err(|e| anyhow!(e.to_string()))
        .context("create stream extractor")?;
    let platform = extractor.get_extractor().platform_name.clone();
    let media = extractor
        .extract()
        .await
        .map_err(|e| anyhow!(e.to_string()))
        .context("extract stream metadata")?;
    Ok(map_media(media, platform))
}

fn looks_like_douyin(url: &str) -> bool {
    let u = url.to_ascii_lowercase();
    u.contains("douyin.com") || u.contains("iesdouyin.com") || u.contains("live.douyin")
}

fn bump_retry_extras(extras: Option<Value>) -> Option<Value> {
    let mut obj = match extras {
        Some(Value::Object(map)) => map,
        _ => serde_json::Map::new(),
    };
    obj.insert("force_mobile_api".into(), Value::Bool(true));
    obj.insert(
        "ttwid_management_mode".into(),
        Value::String("per_extractor".into()),
    );
    obj.remove("ttwid");
    Some(Value::Object(obj))
}

fn is_retryable_extract(err: &anyhow::Error) -> bool {
    let msg = format!("{err:#}").to_ascii_lowercase();
    msg.contains("服务繁忙")
        || msg.contains("繁忙")
        || msg.contains("rate limit")
        || msg.contains("timeout")
        || msg.contains("timed out")
        || msg.contains("connection")
        || msg.contains("temporarily")
}

/// Prefer a short Chinese tip over nested anyhow/extractor English chains.
fn map_resolve_error(err: anyhow::Error) -> anyhow::Error {
    let full = format!("{err:#}");
    if full.contains("服务繁忙") {
        return anyhow!("抖音接口繁忙（请确认直播间正在开播后稍后重试）");
    }
    if full.contains("StreamerNotFound") || full.contains("streamer not found") {
        return anyhow!("未找到该直播间，请检查链接");
    }
    if full.contains("直播已结束") || full.contains("not live") {
        return anyhow!("直播已结束或不在播");
    }
    if full.contains("HTML error page") || full.contains("rate limiting or blocking") {
        return anyhow!("抖音接口拒绝请求，请稍后重试或更换网络");
    }
    if full.contains("Failed to extract ttwid") {
        return anyhow!("获取抖音凭证失败，请检查网络后重试");
    }
    if full.contains("展开抖音短链")
        || full.contains("短链未返回")
        || full.contains("响应中无 web_rid")
    {
        return anyhow!("抖音短链展开失败，请改用 live.douyin.com 直播间号");
    }
    // Keep the cause chain for transport failures (cert/DNS/reset), not just the leaf.
    if full.contains("error sending request")
        || full.contains("connection")
        || full.contains("timed out")
        || full.contains("dns error")
        || full.contains("certificate")
        || full.contains("tls")
    {
        return anyhow!("网络请求失败: {full}");
    }
    // Drop leading "resolve:" / "extract stream metadata:" noise for UI.
    let leaf = full.rsplit(": ").next().unwrap_or(&full).trim();
    if leaf != full {
        anyhow!("{leaf}")
    } else {
        err
    }
}

/// Forked Android Process has no JVM — cannot use rustls-platform-verifier.
/// Mirror strev/platforms-parser feature set (webpki roots + gzip/deflate).
#[cfg(target_os = "android")]
fn android_http_client() -> Result<reqwest::Client> {
    use rustls::ClientConfig;
    use rustls::crypto::aws_lc_rs;
    use std::sync::{Arc, OnceLock};

    static PROVIDER: OnceLock<()> = OnceLock::new();
    PROVIDER.get_or_init(|| {
        let _ = aws_lc_rs::default_provider().install_default();
    });

    let mut roots = rustls::RootCertStore::empty();
    roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    let provider = Arc::new(aws_lc_rs::default_provider());
    let tls = ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .context("TLS protocol versions")?
        .with_root_certificates(roots)
        .with_no_client_auth();

    // no_proxy: Android may inject HTTP(S)_PROXY into the forked Process env;
    // strev/desktop usually hit Douyin directly.
    reqwest::Client::builder()
        .use_preconfigured_tls(tls)
        .timeout(std::time::Duration::from_secs(30))
        .no_proxy()
        .build()
        .context("reqwest client")
}

pub async fn resolve_douyin(
    url: &str,
    cookies: Option<&str>,
    extras: Option<Value>,
) -> Result<ResolvedStream> {
    let result = resolve(url, cookies, extras).await?;
    if is_douyin_platform(&result.platform) || result.site_url.contains("douyin.com") {
        Ok(result)
    } else {
        Err(anyhow!(
            "resolved platform is not Douyin: {}",
            result.platform
        ))
    }
}

pub fn ranked_candidates(streams: &[StreamCandidate]) -> Vec<StreamCandidate> {
    let mut seen = HashSet::new();
    let mut candidates: Vec<_> = streams
        .iter()
        .filter(|s| !s.url.trim().is_empty())
        .filter(|s| seen.insert(s.url.clone()))
        .cloned()
        .collect();
    candidates.sort_by(|a, b| {
        a.audio_only
            .cmp(&b.audio_only)
            .then_with(|| a.priority.cmp(&b.priority))
            .then_with(|| b.bitrate.cmp(&a.bitrate))
            .then_with(|| b.fps.total_cmp(&a.fps))
            .then_with(|| a.quality.cmp(&b.quality))
            .then_with(|| a.url.cmp(&b.url))
    });
    candidates
}

pub fn best_candidate(streams: &[StreamCandidate]) -> Option<StreamCandidate> {
    ranked_candidates(streams).into_iter().next()
}

fn is_douyin_platform(platform: &str) -> bool {
    let p = platform.trim().to_ascii_lowercase();
    p == "douyin" || p.contains("douyin") || p == "tiktok-cn"
}

fn map_media(media: MediaInfo, platform: String) -> ResolvedStream {
    let streams =
        ranked_candidates(&media.streams.into_iter().map(map_stream).collect::<Vec<_>>());
    ResolvedStream {
        platform,
        site_url: media.site_url,
        title: media.title,
        artist: media.artist,
        is_live: media.is_live,
        streams,
        headers: media.headers.map(|h| h.into_iter().collect()),
    }
}

fn map_stream(stream: StreamInfo) -> StreamCandidate {
    StreamCandidate {
        url: stream.url,
        format: stream.stream_format.to_string(),
        media_format: stream.media_format.to_string(),
        quality: stream.quality,
        bitrate: stream.bitrate,
        codec: stream.codec,
        fps: stream.fps,
        priority: stream.priority,
        headers_needed: stream.is_headers_needed,
        audio_only: stream.is_audio_only,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn candidate(
        url: &str,
        priority: u32,
        bitrate: u64,
        fps: f64,
        audio_only: bool,
    ) -> StreamCandidate {
        StreamCandidate {
            url: url.into(),
            format: "flv".into(),
            media_format: "video".into(),
            quality: "1080p".into(),
            bitrate,
            codec: "h264".into(),
            fps,
            priority,
            headers_needed: false,
            audio_only,
        }
    }
    #[test]
    fn douyin_platform_detection_is_stable() {
        assert!(is_douyin_platform("douyin"));
        assert!(is_douyin_platform("DouYin"));
        assert!(is_douyin_platform("douyin-live"));
        assert!(!is_douyin_platform("twitch"));
    }
    #[test]
    fn ranking_deduplicates_and_prefers_video() {
        let input = vec![
            candidate("https://a", 10, 1000, 30.0, false),
            candidate("https://a", 10, 9999, 60.0, false),
            candidate("https://b", 20, 2000, 60.0, false),
            candidate("https://audio", 999, 99999, 60.0, true),
        ];
        let ranked = ranked_candidates(&input);
        assert_eq!(ranked.len(), 3);
        assert_eq!(ranked[0].url, "https://a");
        assert_eq!(ranked[1].url, "https://b");
        assert!(ranked[2].audio_only);
    }
    #[test]
    fn best_candidate_returns_none_for_empty_input() {
        assert!(best_candidate(&[]).is_none());
    }
}
