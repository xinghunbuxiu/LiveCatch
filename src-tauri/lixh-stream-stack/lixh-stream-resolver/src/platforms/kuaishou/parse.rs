//! HTML / JSON parsing aligned with ihmily/streamget `KwaiLiveStream`.
//!
//! Re-sync checklist: see `UPSTREAM.md` in this folder.

use anyhow::{anyhow, Context, Result};
use regex::Regex;
use serde_json::Value;
use std::sync::LazyLock;

use crate::rank::ranked_candidates;
use crate::types::{ResolvedStream, StreamCandidate};

// streamget uses a leading space; live HTML is often `<script>window.__INITIAL_STATE__=`.
static INITIAL_STATE_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"\s*window\.__INITIAL_STATE__=(.*?);\(function\(\)\{var s;").expect("regex")
});

/// streamget: `({"liveStream".*?),"gameInfo` then append `}`.
static LIVE_STREAM_FRAGMENT_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r#"(\{"liveStream".*?),"gameInfo"#).expect("regex")
});

/// Canonical room: `live.kuaishou.com/u/{principalId}`.
static ROOM_U_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)(?:https?://)?(?:www\.)?live\.kuaishou\.com/u/([^/?#]+)").expect("regex")
});

/// Profile pages share the same principalId (`/profile/{id}` on live or www).
static PROFILE_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)(?:https?://)?(?:www\.)?(?:live\.)?kuaishou\.com/profile/([^/?#]+)")
        .expect("regex")
});

pub fn looks_like_kuaishou_host(url: &str) -> bool {
    let l = url.trim().to_ascii_lowercase();
    l.contains("kuaishou.com")
        || l.contains("kuaishou.cn")
        || l.contains("chenzhongtech.com")
        || l.contains("kwai.com")
}

/// Claim any 快手 host so unknown paths get a clear tip, not a generic reject.
pub fn looks_like_kuaishou_live_url(url: &str) -> bool {
    looks_like_kuaishou_host(url)
}

pub fn principal_id(url: &str) -> Option<String> {
    let url = url.trim();
    ROOM_U_RE
        .captures(url)
        .or_else(|| PROFILE_RE.captures(url))
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().to_string())
}

pub fn is_kuaishou_short_url(url: &str) -> bool {
    let l = url.trim().to_ascii_lowercase();
    l.contains("v.kuaishou.com")
        || l.contains("v.kuaishou.cn")
        || l.contains("chenzhongtech.com")
}

/// Normalize to `https://live.kuaishou.com/u/{id}` when principal is known.
pub fn canonical_room_url(url: &str) -> Result<String> {
    let id = principal_id(url).ok_or_else(|| {
        anyhow!(
            "无法识别快手直播间，请使用 live.kuaishou.com/u/房间号 或 /profile/房间号"
        )
    })?;
    Ok(format!("https://live.kuaishou.com/u/{id}"))
}

/// Parse room page HTML → [`ResolvedStream`] (may be offline with empty streams).
pub fn resolved_from_html(html: &str, page_url: &str) -> Result<ResolvedStream> {
    let play_list = parse_play_list_json(html)?;
    resolved_from_play_list(&play_list, page_url)
}

fn parse_play_list_json(html: &str) -> Result<Value> {
    let json_str = INITIAL_STATE_RE
        .captures(html)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str())
        .ok_or_else(|| anyhow!("快手页面缺少 __INITIAL_STATE__（可能被风控或改版）"))?;

    let frag = LIVE_STREAM_FRAGMENT_RE
        .captures(json_str)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str())
        .ok_or_else(|| anyhow!("快手页面缺少 liveStream 片段（可能未开播或改版）"))?;

    let play_list: Value = serde_json::from_str(&format!("{frag}}}"))
        .context("解析快手 liveStream JSON 失败")?;
    Ok(play_list)
}

fn resolved_from_play_list(play_list: &Value, page_url: &str) -> Result<ResolvedStream> {
    if play_list.get("errorType").is_some() || play_list.get("liveStream").is_none() {
        let title = play_list
            .pointer("/errorType/title")
            .and_then(|v| v.as_str())
            .unwrap_or("错误");
        let content = play_list
            .pointer("/errorType/content")
            .and_then(|v| v.as_str())
            .unwrap_or("");
        return Err(anyhow!("快手返回错误: {title}{content}"));
    }

    let live_stream = play_list
        .get("liveStream")
        .filter(|v| !v.is_null())
        .ok_or_else(|| anyhow!("快手疑似封禁 IP，请更换网络后重试"))?;

    let artist = play_list
        .pointer("/author/name")
        .or_else(|| live_stream.pointer("/author/name"))
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();

    let title = live_stream
        .get("caption")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();

    let representations = extract_representations(live_stream);
    let is_live = !representations.is_empty();
    let streams = ranked_candidates(
        &representations
            .into_iter()
            .filter_map(|r| representation_to_candidate(&r))
            .collect::<Vec<_>>(),
    );

    Ok(ResolvedStream {
        platform: "kuaishou".into(),
        site_url: page_url.to_string(),
        title,
        artist,
        is_live,
        streams,
        headers: Some(playback_headers()),
    })
}

fn extract_representations(live_stream: &Value) -> Vec<Value> {
    let play_urls = match live_stream.get("playUrls") {
        Some(v) if !v.is_null() => v,
        _ => return Vec::new(),
    };

    if let Some(h264) = play_urls.get("h264") {
        return h264
            .pointer("/adaptationSet/representation")
            .and_then(|v| v.as_array())
            .cloned()
            .unwrap_or_default();
    }

    play_urls
        .as_array()
        .and_then(|a| a.first())
        .and_then(|first| first.pointer("/adaptationSet/representation"))
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default()
}

/// LiveCatch Android FFmpeg is built with `--enable-protocol=http` only (no TLS).
/// Kuaishou CDN accepts the same FLV path over plain HTTP.
fn playback_url(url: &str) -> String {
    if let Some(rest) = url.strip_prefix("https://") {
        format!("http://{rest}")
    } else {
        url.to_string()
    }
}

fn representation_to_candidate(item: &Value) -> Option<StreamCandidate> {
    let url = item
        .get("url")
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())?;
    let url = playback_url(url);
    let bitrate = item
        .get("bitrate")
        .and_then(|v| v.as_u64().or_else(|| v.as_f64().map(|f| f as u64)))
        .unwrap_or(0);
    let quality = item
        .get("qualityType")
        .or_else(|| item.get("name"))
        .or_else(|| item.get("quality"))
        .and_then(|v| v.as_str())
        .map(str::to_string)
        .unwrap_or_else(|| {
            if bitrate > 0 {
                format!("{bitrate}kbps")
            } else {
                "default".into()
            }
        });

    Some(StreamCandidate {
        url,
        format: "flv".into(),
        media_format: "video".into(),
        quality,
        bitrate,
        codec: item
            .get("codec")
            .and_then(|v| v.as_str())
            .unwrap_or("h264")
            .to_string(),
        fps: item
            .get("frameRate")
            .or_else(|| item.get("fps"))
            .and_then(|v| v.as_f64())
            .unwrap_or(0.0),
        // Prefer lean rungs first — matches Flutter AbrSupervisor (index 0 = lowest).
        priority: bitrate.min(u64::from(u32::MAX)) as u32,
        headers_needed: true,
        audio_only: false,
    })
}

pub fn playback_headers() -> std::collections::HashMap<String, String> {
    let mut h = std::collections::HashMap::new();
    // Keep headers minimal for FFmpeg avformat (Origin is unnecessary and can confuse some edges).
    h.insert("User-Agent".into(), PC_UA.into());
    h.insert("Referer".into(), "https://live.kuaishou.com/".into());
    h.insert("Accept".into(), "*/*".into());
    h
}

pub const PC_UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36 Edg/145.0.0.0";

pub fn offline_resolved(page_url: &str, artist: &str) -> ResolvedStream {
    ResolvedStream {
        platform: "kuaishou".into(),
        site_url: page_url.to_string(),
        title: String::new(),
        artist: artist.to_string(),
        is_live: false,
        streams: Vec::new(),
        headers: Some(playback_headers()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_common_kuaishou_hosts() {
        assert!(looks_like_kuaishou_live_url(
            "https://live.kuaishou.com/u/cym030000"
        ));
        assert!(looks_like_kuaishou_live_url(
            "https://live.kuaishou.com/profile/cym030000"
        ));
        assert!(looks_like_kuaishou_live_url(
            "https://www.kuaishou.com/profile/cym030000"
        ));
        assert!(looks_like_kuaishou_live_url("https://v.kuaishou.com/AbCd"));
        assert!(!looks_like_kuaishou_live_url("https://live.douyin.com/1"));
    }

    #[test]
    fn extracts_principal_from_u_and_profile() {
        assert_eq!(
            principal_id("https://live.kuaishou.com/u/cym030000").as_deref(),
            Some("cym030000")
        );
        assert_eq!(
            principal_id("https://live.kuaishou.com/profile/cym030000").as_deref(),
            Some("cym030000")
        );
        assert_eq!(
            principal_id("https://www.kuaishou.com/profile/abc?x=1").as_deref(),
            Some("abc")
        );
        assert_eq!(
            canonical_room_url("https://live.kuaishou.com/profile/xyz").unwrap(),
            "https://live.kuaishou.com/u/xyz"
        );
    }

    #[test]
    fn parses_streamget_style_fragment() {
        let html = concat!(
            "<script>window.__INITIAL_STATE__=",
            r#"{"wrap":{"liveStream":{"caption":"标题","playUrls":{"h264":{"adaptationSet":{"representation":[{"url":"https://cdn.example/low.flv","bitrate":1000,"qualityType":"HD"},{"url":"https://cdn.example/hi.flv","bitrate":4000,"qualityType":"BD"}]}}}},"author":{"name":"主播A"},"gameInfo":{}}"#,
            ";(function(){var s;"
        );

        let resolved = resolved_from_html(html, "https://live.kuaishou.com/u/x").unwrap();
        assert!(resolved.is_live);
        assert_eq!(resolved.artist, "主播A");
        // https → http; lower bitrate first (priority == bitrate).
        assert_eq!(resolved.streams[0].url, "http://cdn.example/low.flv");
        assert_eq!(resolved.streams[1].url, "http://cdn.example/hi.flv");
    }

    #[test]
    fn https_flv_rewritten_to_http() {
        assert_eq!(
            playback_url("https://hw-origin.pull.yximgs.com/a.flv"),
            "http://hw-origin.pull.yximgs.com/a.flv"
        );
        assert_eq!(playback_url("http://x/a.flv"), "http://x/a.flv");
    }
}
