//! HTML / deeplink parsing aligned with ihmily/streamget `RedNoteLiveStream`.
//!
//! Re-sync checklist: see `UPSTREAM.md` in this folder.

use anyhow::{anyhow, Result};
use regex::Regex;
use serde_json::Value;
use std::collections::HashMap;
use std::sync::LazyLock;
use url::Url;

use crate::rank::ranked_candidates;
use crate::types::{ResolvedStream, StreamCandidate};

/// streamget: ` window.__INITIAL_STATE__=(.*?) `; live pages often omit spaces.
static INITIAL_STATE_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?s)window\.__INITIAL_STATE__\s*=\s*(.*?)(?:\s*</script>|\s*;\s*(?:\(function|<))")
        .expect("regex")
});

static PROFILE_ID_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)/user/profile/([^/?#]+)").expect("regex")
});

static ANCHOR_NAME_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"@(.*?)的个人主页").expect("regex")
});

pub const MOBILE_UA: &str =
    "ios/7.830 (ios 17.0; ; iPhone 15 (A2846/A3089/A3090/A3092))";

pub fn looks_like_xiaohongshu_host(url: &str) -> bool {
    let l = url.trim().to_ascii_lowercase();
    l.contains("xiaohongshu.com") || l.contains("xhslink.com") || l.contains("xhs.cn")
}

pub fn is_xhs_short_url(url: &str) -> bool {
    url.trim().to_ascii_lowercase().contains("xhslink.com")
}

pub fn user_id_from_url(url: &str) -> Option<String> {
    let url = url.trim();
    if let Some(id) = PROFILE_ID_RE
        .captures(url)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().to_string())
        .filter(|s| !s.is_empty())
    {
        return Some(id);
    }
    query_param(url, "host_id").filter(|s| !s.is_empty())
}

pub fn query_param(url: &str, key: &str) -> Option<String> {
    // Deeplink may be `xhsdiscover://…?flvUrl=…` — Url::parse handles that.
    let parsed = Url::parse(url).ok()?;
    parsed
        .query_pairs()
        .find(|(k, _)| k == key)
        .map(|(_, v)| v.into_owned())
}

/// Build FLV/HLS candidates from page `__INITIAL_STATE__` JSON text.
pub fn resolved_from_html(html: &str, page_url: &str) -> Result<Option<ResolvedStream>> {
    let Some(caps) = INITIAL_STATE_RE.captures(html) else {
        return Ok(None);
    };
    let json_str = caps
        .get(1)
        .map(|m| m.as_str().replace("undefined", "null"))
        .ok_or_else(|| anyhow!("小红书 __INITIAL_STATE__ 为空"))?;
    let json: Value =
        serde_json::from_str(&json_str).map_err(|e| anyhow!("解析小红书 INITIAL_STATE: {e}"))?;
    resolved_from_state(&json, page_url)
}

pub fn resolved_from_state(json: &Value, page_url: &str) -> Result<Option<ResolvedStream>> {
    let Some(stream_data) = json.get("liveStream") else {
        return Ok(None);
    };
    let status = stream_data
        .get("liveStatus")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    if status != "success" {
        return Ok(None);
    }
    let room_info = stream_data
        .pointer("/roomData/roomInfo")
        .ok_or_else(|| anyhow!("小红书缺少 roomInfo"))?;
    let title = room_info
        .get("roomTitle")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    if title.is_empty() || title.contains("回放") {
        return Ok(None);
    }
    let live_link = room_info
        .get("deeplink")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let artist = query_param(live_link, "host_nickname").unwrap_or_default();
    let flv_raw = query_param(live_link, "flvUrl").unwrap_or_default();
    let room_id = room_id_from_flv(&flv_raw).ok_or_else(|| {
        anyhow!("小红书 deeplink 缺少有效 flvUrl（可能已结束）")
    })?;

    let flv_url = format!("http://live-source-play.xhscdn.com/live/{room_id}.flv");
    let m3u8_url = format!("http://live-source-play.xhscdn.com/live/{room_id}.m3u8");

    let streams = ranked_candidates(&[
        StreamCandidate {
            url: flv_url,
            format: "flv".into(),
            media_format: "video".into(),
            quality: "default".into(),
            bitrate: 0,
            codec: "h264".into(),
            fps: 0.0,
            priority: 0,
            headers_needed: true,
            audio_only: false,
        },
        StreamCandidate {
            url: m3u8_url,
            format: "hls".into(),
            media_format: "video".into(),
            quality: "default".into(),
            bitrate: 0,
            codec: "h264".into(),
            fps: 0.0,
            priority: 10,
            headers_needed: true,
            audio_only: false,
        },
    ]);

    Ok(Some(ResolvedStream {
        platform: "xiaohongshu".into(),
        site_url: page_url.to_string(),
        title,
        artist,
        is_live: true,
        streams,
        headers: Some(playback_headers()),
    }))
}

fn room_id_from_flv(flv_url: &str) -> Option<String> {
    let after = flv_url.split("live/").nth(1)?;
    let id = after.split('.').next()?.trim();
    if id.is_empty() {
        None
    } else {
        Some(id.to_string())
    }
}

pub fn playback_headers() -> HashMap<String, String> {
    let mut h = HashMap::new();
    h.insert("User-Agent".into(), MOBILE_UA.into());
    h.insert("Referer".into(), "https://app.xhs.cn/".into());
    h.insert("Accept".into(), "*/*".into());
    h
}

pub fn offline_resolved(page_url: &str, artist: &str) -> ResolvedStream {
    ResolvedStream {
        platform: "xiaohongshu".into(),
        site_url: page_url.to_string(),
        title: String::new(),
        artist: artist.to_string(),
        is_live: false,
        streams: Vec::new(),
        headers: Some(playback_headers()),
    }
}

pub fn scrape_anchor_name(html: &str) -> Option<String> {
    ANCHOR_NAME_RE
        .captures(html)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().trim().to_string())
        .filter(|s| !s.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn room_id_from_cdn_flv() {
        assert_eq!(
            room_id_from_flv("http://cdn/live/abc123.flv?token=1").as_deref(),
            Some("abc123")
        );
    }

    #[test]
    fn live_state_builds_http_candidates() {
        let deeplink = "xhsdiscover://live_audience?flvUrl=http%3A%2F%2Fx%2Flive%2Froom99.flv&host_nickname=%E4%B8%BB%E6%92%AD";
        let state = serde_json::json!({
            "liveStream": {
                "liveStatus": "success",
                "roomData": {
                    "roomInfo": {
                        "roomTitle": "今晚直播",
                        "deeplink": deeplink
                    }
                }
            }
        });
        let r = resolved_from_state(&state, "https://www.xiaohongshu.com/user/profile/u1")
            .unwrap()
            .unwrap();
        assert!(r.is_live);
        assert_eq!(r.artist, "主播");
        assert_eq!(
            r.streams[0].url,
            "http://live-source-play.xhscdn.com/live/room99.flv"
        );
        assert!(r.streams.iter().any(|s| s.format == "hls"));
    }

    #[test]
    fn replay_title_skipped() {
        let state = serde_json::json!({
            "liveStream": {
                "liveStatus": "success",
                "roomData": {
                    "roomInfo": {
                        "roomTitle": "回放：昨晚",
                        "deeplink": "xhsdiscover://x?flvUrl=http://x/live/a.flv"
                    }
                }
            }
        });
        assert!(resolved_from_state(&state, "https://x").unwrap().is_none());
    }
}
