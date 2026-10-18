//! Douyin web `webcast/room/web/enter` — aligned with streamget / streamget-rs.

use anyhow::{anyhow, Context, Result};
use reqwest::header::{HeaderMap, HeaderValue, COOKIE, REFERER, USER_AGENT};
use reqwest::Client;
use serde_json::Value;

use super::ab_sign::ab_sign;

pub const PC_UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36";

const WEBCAST_ENTER: &str = "https://live.douyin.com/webcast/room/web/enter/";
const TTWID_REGISTER: &str = "https://ttwid.bytedance.com/ttwid/union/register/";

/// Fetch room JSON for `web_rid` (already normalized live.douyin.com id).
pub async fn fetch_web_enter(
    client: &Client,
    web_rid: &str,
    cookies: Option<&str>,
) -> Result<Value> {
    let ttwid_cookie = resolve_ttwid_cookie(client, cookies).await?;
    let mut last_err = None;
    for attempt in 0u32..3 {
        if attempt > 0 {
            tokio::time::sleep(std::time::Duration::from_millis(500 * u64::from(attempt))).await;
        }
        match enter_once(client, web_rid, &ttwid_cookie).await {
            Ok(v) => return Ok(v),
            Err(e) => {
                let msg = format!("{e:#}");
                let retry = msg.contains("繁忙")
                    || msg.contains("服务")
                    || msg.contains("timeout")
                    || msg.contains("连接");
                last_err = Some(e);
                if !retry {
                    break;
                }
            }
        }
    }
    Err(last_err.unwrap_or_else(|| anyhow!("抖音进房失败")))
}

async fn resolve_ttwid_cookie(client: &Client, cookies: Option<&str>) -> Result<String> {
    if let Some(c) = cookies.map(str::trim).filter(|s| !s.is_empty()) {
        if c.contains("ttwid=") {
            return Ok(c.to_string());
        }
        // Keep user cookies and append a fresh ttwid.
        let ttwid = fetch_ttwid(client).await?;
        return Ok(format!("{c}; ttwid={ttwid}"));
    }
    let ttwid = fetch_ttwid(client).await?;
    Ok(format!("ttwid={ttwid}"))
}

async fn fetch_ttwid(client: &Client) -> Result<String> {
    let body = serde_json::json!({
        "region": "cn",
        "aid": 6383,
        "needFid": false,
        "service": "https://www.douyin.com",
        "union": true,
        "fid": ""
    });
    let resp = client
        .post(TTWID_REGISTER)
        .header(USER_AGENT, PC_UA)
        .json(&body)
        .send()
        .await
        .context("请求抖音 ttwid")?
        .error_for_status()
        .context("抖音 ttwid HTTP 错误")?;

    for val in resp.headers().get_all("set-cookie") {
        let Ok(s) = val.to_str() else { continue };
        if let Some(rest) = s.split("ttwid=").nth(1) {
            let v = rest.split(';').next().unwrap_or("").trim();
            if !v.is_empty() {
                return Ok(v.to_string());
            }
        }
    }
    Err(anyhow!("获取抖音凭证失败，请检查网络后重试"))
}

async fn enter_once(client: &Client, web_rid: &str, cookie: &str) -> Result<Value> {
    // Insertion order must match streamget (a_bogus signs the exact query string).
    let params: [(&str, &str); 12] = [
        ("aid", "6383"),
        ("app_name", "douyin_web"),
        ("live_id", "1"),
        ("device_platform", "web"),
        ("language", "zh-CN"),
        ("browser_language", "zh-CN"),
        ("browser_platform", "Win32"),
        ("browser_name", "Chrome"),
        ("browser_version", "116.0.0.0"),
        ("web_rid", web_rid),
        ("is_need_double_stream", "false"),
        ("msToken", ""),
    ];
    let query = serde_urlencoded(&params);
    let a_bogus = ab_sign(&query, PC_UA);
    let api = format!("{WEBCAST_ENTER}?{query}&a_bogus={a_bogus}");

    let mut headers = HeaderMap::new();
    headers.insert(USER_AGENT, HeaderValue::from_static(PC_UA));
    headers.insert(
        REFERER,
        HeaderValue::from_static("https://live.douyin.com/"),
    );
    headers.insert(
        COOKIE,
        HeaderValue::from_str(cookie).context("cookie header")?,
    );

    let text = client
        .get(&api)
        .headers(headers)
        .send()
        .await
        .context("请求抖音进房接口")?
        .error_for_status()
        .context("抖音进房 HTTP 错误")?
        .text()
        .await
        .context("读取抖音进房响应")?;

    if text.trim().is_empty() {
        return Err(anyhow!("抖音接口拒绝请求，请稍后重试或更换网络"));
    }

    let root: Value = serde_json::from_str(&text).context("解析抖音进房 JSON")?;
    let data = root
        .get("data")
        .ok_or_else(|| anyhow!("抖音进房响应缺少 data"))?;

    if data.get("data").map(|v| v.is_null() || v.as_array().is_some_and(|a| a.is_empty())).unwrap_or(true)
    {
        if let Some(prompts) = data.get("prompts").and_then(|v| v.as_str()) {
            if prompts.contains("繁忙") {
                return Err(anyhow!("抖音接口繁忙（请确认直播间正在开播后稍后重试）"));
            }
            return Err(anyhow!("{prompts}"));
        }
        return Err(anyhow!("未找到该直播间，请检查链接"));
    }

    Ok(root)
}

fn serde_urlencoded(params: &[(&str, &str)]) -> String {
    let mut parts = Vec::with_capacity(params.len());
    for (k, v) in params {
        parts.push(format!("{}={}", urlencoding(k), urlencoding(v)));
    }
    parts.join("&")
}

fn urlencoding(s: &str) -> String {
    // Match typical application/x-www-form-urlencoded (space as %20).
    let mut out = String::with_capacity(s.len() * 3);
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char);
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn query_encoding_stable() {
        let p = [("aid", "6383"), ("web_rid", "123")];
        let q = serde_urlencoded(&p);
        assert_eq!(q, "aid=6383&web_rid=123");
        assert!(ab_sign(&q, PC_UA).len() > 10);
    }
}
