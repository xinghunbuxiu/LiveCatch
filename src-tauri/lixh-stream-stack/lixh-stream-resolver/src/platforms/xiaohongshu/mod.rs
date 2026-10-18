//! Native Xiaohongshu (小红书 / RedNote) live resolver.
//!
//! Ported from **ihmily/streamget** `RedNoteLiveStream` (see [`UPSTREAM.md`](./UPSTREAM.md)).
//! See [`UPSTREAM.md`](./UPSTREAM.md) and [`../README.md`](../README.md).

mod parse;

use anyhow::{anyhow, Context, Result};
use async_trait::async_trait;
use reqwest::header::{HeaderMap, HeaderValue, COOKIE, LOCATION, REFERER, USER_AGENT};
use reqwest::redirect::Policy;
use reqwest::Client;

use super::{PlatformBackend, ResolveCtx};
use crate::types::ResolvedStream;

pub use parse::{is_xhs_short_url, looks_like_xiaohongshu_host};

/// Stable backend id used in logs / registry.
pub struct XiaohongshuBackend;

#[async_trait]
impl PlatformBackend for XiaohongshuBackend {
    fn id(&self) -> &'static str {
        "xiaohongshu"
    }

    fn matches(&self, url: &str) -> bool {
        looks_like_xiaohongshu_host(url)
    }

    async fn prepare_url(&self, url: &str, _client: &Client) -> Result<String> {
        let url = url.trim();
        if is_xhs_short_url(url) {
            return expand_xhs_short_url(url).await;
        }
        Ok(url.to_string())
    }

    async fn resolve(&self, ctx: &ResolveCtx<'_>) -> Result<ResolvedStream> {
        let page_url = ctx.url.trim();
        let headers = mobile_headers(ctx.cookies);

        let html = ctx
            .client
            .get(page_url)
            .headers(headers.clone())
            .send()
            .await
            .context("请求小红书直播页")?
            .error_for_status()
            .context("小红书直播页 HTTP 错误")?
            .text()
            .await
            .context("读取小红书直播页")?;

        if let Some(live) = parse::resolved_from_html(&html, page_url)? {
            return Ok(live);
        }

        // Offline / not a live page — try profile for display name.
        let mut artist = String::new();
        if let Some(uid) = parse::user_id_from_url(page_url) {
            let profile = format!("https://www.xiaohongshu.com/user/profile/{uid}");
            if let Ok(resp) = ctx.client.get(&profile).headers(headers).send().await {
                if let Ok(body) = resp.text().await {
                    artist = parse::scrape_anchor_name(&body).unwrap_or_default();
                }
            }
        }

        Ok(parse::offline_resolved(page_url, &artist))
    }
}

fn mobile_headers(cookies: Option<&str>) -> HeaderMap {
    let mut h = HeaderMap::new();
    h.insert(USER_AGENT, HeaderValue::from_static(parse::MOBILE_UA));
    h.insert(
        "xy-common-params",
        HeaderValue::from_static("platform=iOS&sid=session.1722166379345546829388"),
    );
    h.insert(REFERER, HeaderValue::from_static("https://app.xhs.cn/"));
    if let Some(c) = cookies.map(str::trim).filter(|s| !s.is_empty()) {
        if let Ok(v) = HeaderValue::from_str(c) {
            h.insert(COOKIE, v);
        }
    }
    h
}

/// Follow Location hop(s) off xhslink.com.
async fn expand_xhs_short_url(url: &str) -> Result<String> {
    let client = Client::builder()
        .redirect(Policy::none())
        .timeout(std::time::Duration::from_secs(20))
        .build()
        .context("小红书短链客户端")?;

    let mut current = url.to_string();
    for _ in 0..8 {
        if !is_xhs_short_url(&current)
            && (current.contains("xiaohongshu.com") || current.contains("xhs.cn"))
        {
            return Ok(current);
        }
        let resp = client
            .get(&current)
            .header(USER_AGENT, parse::MOBILE_UA)
            .header(REFERER, "https://app.xhs.cn/")
            .send()
            .await
            .context("展开小红书短链")?;
        let status = resp.status();
        let loc = resp
            .headers()
            .get(LOCATION)
            .and_then(|v| v.to_str().ok())
            .map(str::to_string);
        if let Some(loc) = loc {
            current = if loc.starts_with("http") {
                loc
            } else {
                let base = reqwest::Url::parse(&current).context("短链 base URL")?;
                base.join(&loc).context("拼接短链 Location")?.to_string()
            };
            continue;
        }
        if status.is_success() {
            return Ok(current);
        }
        return Err(anyhow!(
            "小红书短链展开失败 (HTTP {status})，请改用 xiaohongshu.com 用户页链接"
        ));
    }
    Err(anyhow!(
        "小红书短链未能展开，请改用 www.xiaohongshu.com/user/profile/…"
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_xhs_hosts() {
        assert!(XiaohongshuBackend.matches("https://www.xiaohongshu.com/user/profile/abc"));
        assert!(XiaohongshuBackend.matches("https://xhslink.com/m/xyz"));
        assert!(!XiaohongshuBackend.matches("https://live.douyin.com/1"));
    }
}
