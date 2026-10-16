//! Native Kuaishou (快手) live resolver.
//!
//! Ported from **ihmily/streamget** `KwaiLiveStream` (see [`UPSTREAM.md`](./UPSTREAM.md)).
//! See [`UPSTREAM.md`](./UPSTREAM.md) and [`../README.md`](../README.md).

mod parse;

use anyhow::{anyhow, Context, Result};
use async_trait::async_trait;
use reqwest::header::{HeaderMap, HeaderValue, ACCEPT_LANGUAGE, COOKIE, LOCATION, REFERER, USER_AGENT};
use reqwest::redirect::Policy;
use reqwest::Client;
use serde_json::Value;

use super::{PlatformBackend, ResolveCtx};
use crate::types::ResolvedStream;

pub use parse::{looks_like_kuaishou_live_url, principal_id};

/// Stable backend id used in logs / registry.
pub struct KuaishouBackend;

#[async_trait]
impl PlatformBackend for KuaishouBackend {
    fn id(&self) -> &'static str {
        "kuaishou"
    }

    fn matches(&self, url: &str) -> bool {
        // Claim every 快手 host — wrong path gets a clear Chinese tip.
        looks_like_kuaishou_live_url(url)
    }

    async fn prepare_url(&self, url: &str, _client: &Client) -> Result<String> {
        let url = url.trim();
        if parse::principal_id(url).is_some() {
            return parse::canonical_room_url(url);
        }
        if parse::is_kuaishou_short_url(url) {
            let expanded = expand_kuaishou_short_url(url).await?;
            return parse::canonical_room_url(&expanded);
        }
        parse::canonical_room_url(url)
    }

    async fn resolve(&self, ctx: &ResolveCtx<'_>) -> Result<ResolvedStream> {
        let page_url = parse::canonical_room_url(ctx.url)?;
        let headers = pc_headers(ctx.cookies);

        // Optional cookie preflight (streamget / streamget-rs).
        if ctx
            .cookies
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .is_some()
        {
            if let Some((name, living)) = fetch_user_living(ctx.client, &page_url, &headers)
                .await
                .context("快手 userinfo 预检")?
            {
                if !living {
                    return Ok(parse::offline_resolved(&page_url, &name));
                }
            }
        }

        let html = ctx
            .client
            .get(&page_url)
            .headers(headers)
            .send()
            .await
            .context("请求快手直播页")?
            .error_for_status()
            .context("快手直播页 HTTP 错误")?
            .text()
            .await
            .context("读取快手直播页")?;

        parse::resolved_from_html(&html, &page_url)
    }
}

fn pc_headers(cookies: Option<&str>) -> HeaderMap {
    let mut h = HeaderMap::new();
    h.insert(USER_AGENT, HeaderValue::from_static(parse::PC_UA));
    h.insert(
        ACCEPT_LANGUAGE,
        HeaderValue::from_static("zh-CN,zh;q=0.9,en;q=0.8"),
    );
    h.insert(
        REFERER,
        HeaderValue::from_static("https://live.kuaishou.com/"),
    );
    if let Some(c) = cookies.map(str::trim).filter(|s| !s.is_empty()) {
        if let Ok(v) = HeaderValue::from_str(c) {
            h.insert(COOKIE, v);
        }
    }
    h
}

/// Follow Location hop(s) until we see `/u/` or `/profile/`.
async fn expand_kuaishou_short_url(url: &str) -> Result<String> {
    let client = Client::builder()
        .redirect(Policy::none())
        .timeout(std::time::Duration::from_secs(20))
        .build()
        .context("快手短链客户端")?;

    let mut current = url.to_string();
    for _ in 0..8 {
        if parse::principal_id(&current).is_some() {
            return Ok(current);
        }
        let resp = client
            .get(&current)
            .header(USER_AGENT, parse::PC_UA)
            .header(REFERER, "https://live.kuaishou.com/")
            .send()
            .await
            .context("展开快手短链")?;
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
                // Relative Location
                let base = reqwest::Url::parse(&current).context("短链 base URL")?;
                base.join(&loc).context("拼接短链 Location")?.to_string()
            };
            continue;
        }
        if status.is_success() {
            // Body may still embed a room id — last resort scan.
            let body = resp.text().await.unwrap_or_default();
            if let Some(id) = scrape_principal_from_html(&body) {
                return Ok(format!("https://live.kuaishou.com/u/{id}"));
            }
            break;
        }
        return Err(anyhow!(
            "快手短链展开失败 (HTTP {status})，请改用 live.kuaishou.com/u/房间号"
        ));
    }
    Err(anyhow!(
        "快手短链未能解析到直播间，请改用 live.kuaishou.com/u/房间号"
    ))
}

fn scrape_principal_from_html(html: &str) -> Option<String> {
    parse::principal_id(html).or_else(|| {
        // Loose scan inside HTML/JSON blobs.
        let re = regex::Regex::new(r"live\.kuaishou\.com/u/([A-Za-z0-9_-]+)").ok()?;
        re.captures(html)
            .and_then(|c| c.get(1))
            .map(|m| m.as_str().to_string())
    })
}

/// Returns `Some((name, living))` when the API answers; `None` if principal missing.
async fn fetch_user_living(
    client: &Client,
    page_url: &str,
    headers: &HeaderMap,
) -> Result<Option<(String, bool)>> {
    let Some(id) = principal_id(page_url) else {
        return Ok(None);
    };
    let api = format!(
        "https://live.kuaishou.com/live_api/baseuser/userinfo/byid?__NS_hxfalcon=&caver=2&principalId={id}"
    );
    let json: Value = client
        .get(&api)
        .headers(headers.clone())
        .send()
        .await
        .context("请求快手 userinfo")?
        .error_for_status()
        .context("快手 userinfo HTTP 错误")?
        .json()
        .await
        .context("解析快手 userinfo JSON")?;

    let result = json
        .pointer("/data/result")
        .and_then(|v| v.as_i64())
        .unwrap_or(0);
    let user = json
        .pointer("/data/userInfo")
        .ok_or_else(|| anyhow!("快手 userinfo 无 userInfo"))?;
    let name = user
        .get("name")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    if result == 2 && !name.is_empty() {
        return Err(anyhow!("快手账号异常（风控），请更换 cookie 或网络"));
    }
    let living = user
        .get("living")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);
    Ok(Some((name, living)))
}
