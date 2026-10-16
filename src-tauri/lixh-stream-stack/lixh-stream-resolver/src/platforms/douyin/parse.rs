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
    if n.contains("ORIGIN") || n.contains("蓝光") || n.contains("原画") {
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

    if flv_map.is_empty() {
        return Err(anyhow!("没有可播放线路（直播可能已结束）"));
    }

    let mut streams: Vec<StreamCandidate> = flv_map
        .into_iter()
        .filter(|(_, u)| !u.trim().is_empty())
        .map(|(quality, url)| {
            let bitrate = quality_bitrate(&quality);
            StreamCandidate {
                url: playback_url(&url),
                format: "flv".into(),
                media_format: "video".into(),
                quality,
                bitrate,
                codec: "h264".into(),
                fps: 0.0,
                priority: bitrate.min(u64::from(u32::MAX)) as u32,
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

fn merge_origin_flv(room: &Value, flv_map: &mut HashMap<String, String>) {
    let Some(stream_data) = room.pointer(
        "/stream_url/live_core_sdk_data/pull_data/stream_data",
    )
    .and_then(|v| v.as_str())
    else {
        return;
    };
    let Ok(parsed) = serde_json::from_str::<Value>(stream_data) else {
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
    fn parses_minimal_live_room() {
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
                                "stream_data": "{\"data\":{\"origin\":{\"main\":{\"flv\":\"https://cdn.example/origin.flv\",\"sdk_params\":\"{\\\"VCodec\\\":\\\"h264\\\"}\"}}}}"
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
        assert!(r.streams.iter().all(|s| s.url.starts_with("http://")));
        // lowest priority/bitrate first
        assert!(r.streams[0].bitrate <= r.streams.last().unwrap().bitrate);
    }
}
