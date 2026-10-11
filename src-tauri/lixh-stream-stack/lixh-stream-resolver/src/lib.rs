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
    #[cfg(target_os = "android")]
    let client = android_http_client().context("build HTTP client")?;
    #[cfg(not(target_os = "android"))]
    let client = create_client(None);
    let factory = ExtractorFactory::new(client);
    let extractor = factory
        .create_extractor(
            url,
            options.cookies,
            options.extras,
            ExtractorSelection::Auto,
        )
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

/// Forked Android Process has no JVM — cannot use rustls-platform-verifier.
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

    reqwest::Client::builder()
        .use_preconfigured_tls(tls)
        .timeout(std::time::Duration::from_secs(30))
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
