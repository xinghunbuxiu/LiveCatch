//! Expand Douyin share short links to `https://live.douyin.com/{web_rid}`.
//!
//! `platforms-parser` only accepts `live.douyin.com/{web_rid}`. Share cards use
//! `v.douyin.com/...` which 302 to `webcast.amemv.com/.../reflow/{room_id}`.

use anyhow::{anyhow, Context, Result};
use reqwest::header::{ACCEPT, LOCATION, REFERER, USER_AGENT};
use reqwest::redirect::Policy;
use reqwest::Client;
use serde_json::Value;
use url::Url;

const MOBILE_UA: &str = "Mozilla/5.0 (Linux; Android 11; SAMSUNG SM-G973U) \
AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/14.2 Chrome/87.0.4280.141 \
Mobile Safari/537.36";

pub fn looks_like_douyin_short_url(url: &str) -> bool {
    let l = url.trim().to_ascii_lowercase();
    l.contains("v.douyin.com/")
        || l.contains("v.douyin.com?")
        || (l.contains("iesdouyin.com") && l.contains("/share/"))
}

/// If [url] is a Douyin short/share link, expand to `live.douyin.com/{web_rid}`.
pub async fn expand_douyin_input(client: &Client, url: &str) -> Result<String> {
    let url = url.trim();
    if !looks_like_douyin_short_url(url) {
        return Ok(url.to_string());
    }
    expand_douyin_short_url(client, url)
        .await
        .context("展开抖音短链失败")
}

async fn expand_douyin_short_url(client: &Client, url: &str) -> Result<String> {
    let location = fetch_redirect_location(client, url).await?;
    if let Some(web_rid) = live_web_rid_from_location(&location) {
        return Ok(format!("https://live.douyin.com/{web_rid}"));
    }
    let (room_id, sec_user_id) = parse_reflow_redirect(&location)
        .ok_or_else(|| anyhow!("短链未返回直播间 ID / sec_user_id"))?;
    let web_rid = fetch_web_rid(client, &room_id, &sec_user_id).await?;
    Ok(format!("https://live.douyin.com/{web_rid}"))
}

async fn fetch_redirect_location(client: &Client, url: &str) -> Result<String> {
    let resp = client
        .get(url)
        .header(USER_AGENT, MOBILE_UA)
        .header(ACCEPT, "text/html,application/xhtml+xml")
        .send()
        .await
        .context("请求短链")?;
    let status = resp.status();
    let loc = resp
        .headers()
        .get(LOCATION)
        .and_then(|v| v.to_str().ok())
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_owned);
    let Some(loc) = loc else {
        return Err(anyhow!("抖音短链未返回跳转地址 (HTTP {status})"));
    };
    if loc.starts_with("http://") || loc.starts_with("https://") {
        return Ok(loc);
    }
    let base = Url::parse(url).context("parse short url")?;
    Ok(base
        .join(&loc)
        .context("resolve redirect")?
        .to_string())
}

fn live_web_rid_from_location(location: &str) -> Option<String> {
    let lower = location.to_ascii_lowercase();
    let idx = lower.find("live.douyin.com/")?;
    let rest = &location[idx + "live.douyin.com/".len()..];
    let rid = rest
        .split(['?', '#', '/'])
        .next()
        .unwrap_or("")
        .trim();
    if rid.is_empty() {
        None
    } else {
        Some(rid.to_string())
    }
}

/// Returns `(room_id, sec_user_id)` from a reflow Location URL.
pub fn parse_reflow_redirect(location: &str) -> Option<(String, String)> {
    let room_id = reflow_room_id(location)?;
    let sec = sec_user_id_from_query(location)?;
    Some((room_id, sec))
}

fn reflow_room_id(location: &str) -> Option<String> {
    let lower = location.to_ascii_lowercase();
    for marker in ["/reflow/", "/share/live/"] {
        if let Some(idx) = lower.find(marker) {
            let rest = &location[idx + marker.len()..];
            let id: String = rest
                .chars()
                .take_while(|c| c.is_ascii_digit())
                .collect();
            if !id.is_empty() {
                return Some(id);
            }
        }
    }
    None
}

fn sec_user_id_from_query(location: &str) -> Option<String> {
    let url = Url::parse(location).ok()?;
    for key in ["sec_user_id", "sec_uid"] {
        if let Some(v) = url.query_pairs().find(|(k, _)| k == key) {
            let s = v.1.into_owned();
            if !s.is_empty() {
                return Some(s);
            }
        }
    }
    None
}

async fn fetch_web_rid(client: &Client, room_id: &str, sec_user_id: &str) -> Result<String> {
    let mut url = Url::parse("https://webcast.amemv.com/webcast/room/reflow/info/")
        .context("reflow info url")?;
    {
        let mut q = url.query_pairs_mut();
        q.append_pair("type_id", "0");
        q.append_pair("live_id", "1");
        q.append_pair("room_id", room_id);
        q.append_pair("sec_user_id", sec_user_id);
        q.append_pair("app_id", "1128");
    }

    let resp = client
        .get(url)
        .header(USER_AGENT, MOBILE_UA)
        .header(ACCEPT, "application/json")
        .header(REFERER, "https://live.douyin.com/")
        .send()
        .await
        .context("请求 reflow/info")?;
    let status = resp.status();
    let text = resp.text().await.context("读取 reflow/info")?;
    if !status.is_success() {
        return Err(anyhow!("获取直播间号失败 (HTTP {status})"));
    }
    let value: Value = serde_json::from_str(&text).context("解析 reflow/info JSON")?;
    web_rid_from_reflow_json(&value).ok_or_else(|| anyhow!("响应中无 web_rid"))
}

pub fn web_rid_from_reflow_json(value: &Value) -> Option<String> {
    let owner = value.pointer("/data/room/owner")?;
    let rid = owner
        .get("web_rid")
        .or_else(|| owner.get("display_id"))?
        .as_str()
        .map(str::to_owned)
        .or_else(|| {
            owner
                .get("web_rid")
                .or_else(|| owner.get("display_id"))
                .and_then(|v| v.as_u64())
                .map(|n| n.to_string())
        })?;
    let rid = rid.trim();
    if rid.is_empty() {
        None
    } else {
        Some(rid.to_string())
    }
}

/// HTTP client that does **not** follow redirects (needed to read short-link Location).
pub fn no_redirect_client() -> Result<Client> {
    #[cfg(target_os = "android")]
    {
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

        Client::builder()
            .use_preconfigured_tls(tls)
            .redirect(Policy::none())
            .timeout(std::time::Duration::from_secs(30))
            .no_proxy()
            .build()
            .context("reqwest no-redirect client")
    }
    #[cfg(not(target_os = "android"))]
    {
        use platforms_parser::extractor::create_client_builder;
        create_client_builder(None)
            .redirect(Policy::none())
            .build()
            .context("reqwest no-redirect client")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn short_url_detection() {
        assert!(looks_like_douyin_short_url(
            "https://v.douyin.com/CbS4y7rfTQc/"
        ));
        assert!(!looks_like_douyin_short_url(
            "https://live.douyin.com/976204288960"
        ));
    }

    #[test]
    fn parse_reflow_location() {
        let loc = "https://webcast.amemv.com/douyin/webcast/reflow/7695563656410549033?\
sec_user_id=MS4wLjABAAAABo7TOjs0WGkWRxhjBGsb5UXArcfstqkMtBm9WOtF828PzATw8pTfI_GJ-n2_0RS5\
&utm_source=copy";
        let (room, sec) = parse_reflow_redirect(loc).unwrap();
        assert_eq!(room, "7695563656410549033");
        assert_eq!(
            sec,
            "MS4wLjABAAAABo7TOjs0WGkWRxhjBGsb5UXArcfstqkMtBm9WOtF828PzATw8pTfI_GJ-n2_0RS5"
        );
        assert_eq!(
            live_web_rid_from_location(
                "https://live.douyin.com/976204288960?room_id=1"
            )
            .as_deref(),
            Some("976204288960")
        );
    }

    #[test]
    fn parse_web_rid_json() {
        let v = json!({
            "data": {
                "room": {
                    "owner": { "web_rid": "976204288960", "display_id": "1" }
                }
            }
        });
        assert_eq!(
            web_rid_from_reflow_json(&v).as_deref(),
            Some("976204288960")
        );
    }
}
