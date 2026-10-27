//! Map Douyin web-enter JSON → [`ResolvedStream`].

use anyhow::{anyhow, Result};
use serde_json::Value;
use std::collections::HashMap;

use crate::rank::ranked_candidates;
use crate::types::{ResolvedStream, StreamCandidate};

use super::enter::PC_UA;

/// Android FFmpeg has http only — rewrite pull URLs like Kuaishou.
fn playback_url(url: &str) -> String {
    if let Some(rest) = url.strip_prefix("https://") {
        format!("http://{rest}")
    } else {
        url.to_string()
    }
}

fn quality_bitrate(name: &str) -> u64 {
    let n = name.to_ascii_uppercase();
    // Unsuffixed CDN path (stream-<id>.flv) — same class as peer pull links.
    if n == "DEFAULT" {
        8500
    } else if n.contains("ORIGIN") || n.contains("蓝光") || n.contains("原画") {
        8000
    } else if n.contains("FULL_HD") || n.contains("UH") || n.contains("蓝光") {
        4000
    } else if n.contains("HD") || n.contains("超清") {
        2000
    } else if n.contains("SD") || n.contains("高清") {
        1000
    } else if n.contains("LD") || n.contains("标清") {
        600
    } else {
        1500
    }
}

/// Drop `only_audio=1` so the bare `stream-<id>.flv` path serves A+V (CDN
/// serves audio-only when that flag is present).
fn strip_only_audio_param(url: &str) -> String {
    let Some((base, query)) = url.split_once('?') else {
        return url.to_string();
    };
    let kept: Vec<&str> = query
        .split('&')
        .filter(|p| {
            let key = p.split('=').next().unwrap_or("");
            !key.eq_ignore_ascii_case("only_audio")
        })
        .collect();
    if kept.is_empty() {
        base.to_string()
    } else {
        format!("{base}?{}", kept.join("&"))
    }
}

pub fn resolved_from_enter(root: &Value, site_url: &str) -> Result<ResolvedStream> {
    let data = root
        .get("data")
        .ok_or_else(|| anyhow!("抖音响应缺少 data"))?;
    let room = data
        .pointer("/data/0")
        .ok_or_else(|| anyhow!("未找到该直播间，请检查链接"))?;

    let artist = data
        .pointer("/user/nickname")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let title = room
        .get("title")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();

    let status = room.get("status").and_then(|v| v.as_i64()).unwrap_or(4);
    if status == 4 {
        return Ok(ResolvedStream {
            platform: "douyin".into(),
            site_url: site_url.to_string(),
            title,
            artist,
            is_live: false,
            streams: Vec::new(),
            headers: Some(playback_headers()),
        });
    }
    if status != 2 {
        return Err(anyhow!("直播已结束或不在播"));
    }

    let mut flv_map = extract_flv_map(room)?;
    merge_origin_flv(room, &mut flv_map);
    merge_bare_flv(room, &mut flv_map);

    if flv_map.is_empty() {
        return Err(anyhow!("没有可播放线路（直播可能已结束）"));
    }

    let mut streams: Vec<StreamCandidate> = flv_map
        .into_iter()
        .filter(|(_, u)| !u.trim().is_empty())
        .map(|(quality, url)| {
            let bitrate = quality_bitrate(&quality);
            // Prefer unsuffixed DEFAULT first (matches peer pull links / faster path).
            let priority = if quality.eq_ignore_ascii_case("DEFAULT") {
                0
            } else {
                bitrate.min(u64::from(u32::MAX)) as u32
            };
            StreamCandidate {
                url: playback_url(&url),
                format: "flv".into(),
                media_format: "video".into(),
                quality,
                bitrate,
                codec: "h264".into(),
                fps: 0.0,
                priority,
                headers_needed: true,
                audio_only: url.contains("only_audio=1"),
            }
        })
        .collect();

    streams = ranked_candidates(&streams);
    Ok(ResolvedStream {
        platform: "douyin".into(),
        site_url: site_url.to_string(),
        title,
        artist,
        is_live: true,
        streams,
        headers: Some(playback_headers()),
    })
}

fn extract_flv_map(room: &Value) -> Result<HashMap<String, String>> {
    let stream_url = room
        .get("stream_url")
        .or_else(|| room.get("streamUrl"))
        .ok_or_else(|| anyhow!("没有可播放线路（直播可能已结束）"))?;

    let mut map = HashMap::new();
    if let Some(obj) = stream_url
        .get("flv_pull_url")
        .or_else(|| stream_url.get("flvPullUrl"))
        .and_then(|v| v.as_object())
    {
        for (k, v) in obj {
            if let Some(u) = v.as_str() {
                map.insert(k.clone(), u.to_string());
            }
        }
    }
    Ok(map)
}

fn parse_stream_data(room: &Value) -> Option<Value> {
    let stream_data = room
        .pointer("/stream_url/live_core_sdk_data/pull_data/stream_data")
        .and_then(|v| v.as_str())?;
    serde_json::from_str(stream_data).ok()
}

fn merge_origin_flv(room: &Value, flv_map: &mut HashMap<String, String>) {
    let Some(parsed) = parse_stream_data(room) else {
        return;
    };
    let Some(main) = parsed.pointer("/data/origin/main") else {
        return;
    };
    let Some(flv) = main.get("flv").and_then(|v| v.as_str()) else {
        return;
    };
    let codec = main
        .get("sdk_params")
        .and_then(|s| {
            if let Some(st) = s.as_str() {
                serde_json::from_str::<Value>(st).ok()
            } else {
                Some(s.clone())
            }
        })
        .and_then(|p| {
            p.get("VCodec")
                .and_then(|v| v.as_str())
                .map(str::to_string)
        })
        .unwrap_or_default();
    let url = if codec.is_empty() {
        flv.to_string()
    } else {
        format!("{flv}&codec={codec}")
    };
    flv_map.entry("ORIGIN".into()).or_insert(url);
}

/// Peer tools often pull the unsuffixed `stream-<id>.flv` path. In web-enter
/// JSON that path lives under `stream_data.data.ao.main.flv` (usually with
/// `only_audio=1`). Strip the flag so the CDN returns the A+V variant.
fn merge_bare_flv(room: &Value, flv_map: &mut HashMap<String, String>) {
    let Some(parsed) = parse_stream_data(room) else {
        return;
    };
    let Some(flv) = parsed
        .pointer("/data/ao/main/flv")
        .and_then(|v| v.as_str())
        .map(str::trim)
        .filter(|s| !s.is_empty())
    else {
        return;
    };
    let url = strip_only_audio_param(flv);
    if url.is_empty() || url.contains("only_audio=") {
        return;
    }
    flv_map.entry("DEFAULT".into()).or_insert(url);
}

pub fn playback_headers() -> HashMap<String, String> {
    let mut h = HashMap::new();
    h.insert("User-Agent".into(), PC_UA.into());
    h.insert("Referer".into(), "https://live.douyin.com/".into());
    h.insert("Accept".into(), "*/*".into());
    h
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn https_rewritten() {
        assert_eq!(
            playback_url("https://pull.example/a.flv"),
            "http://pull.example/a.flv"
        );
    }

    #[test]
    fn strips_only_audio_query() {
        assert_eq!(
            strip_only_audio_param(
                "http://cdn/x.flv?a=1&only_audio=1&b=2"
            ),
            "http://cdn/x.flv?a=1&b=2"
        );
        assert_eq!(
            strip_only_audio_param("http://cdn/x.flv?only_audio=1"),
            "http://cdn/x.flv"
        );
    }

    #[test]
    fn parses_minimal_live_room() {
        let stream_data = serde_json::json!({
            "data": {
                "origin": {
                    "main": {
                        "flv": "https://cdn.example/stream-1_or4.flv",
                        "sdk_params": "{\"VCodec\":\"h264\"}"
                    }
                },
                "ao": {
                    "main": {
                        "flv": "https://cdn.example/stream-1.flv?keeptime=1&only_audio=1&sign=abc"
                    }
                }
            }
        })
        .to_string();
        let root = serde_json::json!({
            "data": {
                "user": {"nickname": "主播"},
                "data": [{
                    "status": 2,
                    "title": "测试",
                    "stream_url": {
                        "flv_pull_url": {
                            "HD1": "https://cdn.example/hd.flv",
                            "SD1": "https://cdn.example/sd.flv"
                        },
                        "live_core_sdk_data": {
                            "pull_data": {
                                "stream_data": stream_data
                            }
                        }
                    }
                }]
            }
        });
        let r = resolved_from_enter(&root, "https://live.douyin.com/1").unwrap();
        assert!(r.is_live);
        assert_eq!(r.artist, "主播");
        assert!(r.streams.iter().any(|s| s.quality == "ORIGIN"));
        let bare = r
            .streams
            .iter()
            .find(|s| s.quality == "DEFAULT")
            .expect("DEFAULT bare flv");
        assert!(bare.url.contains("stream-1.flv"));
        assert!(!bare.url.contains("only_audio"));
        assert!(!bare.audio_only);
        assert_eq!(r.streams[0].quality, "DEFAULT");
        assert!(r.streams.iter().all(|s| s.url.starts_with("http://")));
    }
}
