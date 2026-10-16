//! Native Douyin (抖音) live resolver.
//!
//! Web enter + a_bogus from **streamget / streamget-rs** (see [`UPSTREAM.md`](./UPSTREAM.md)).
//! Short-link expand kept from LiveCatch’s existing helper.

mod ab_sign;
mod enter;
mod expand;
mod parse;

use anyhow::{anyhow, Result};
use async_trait::async_trait;
use regex::Regex;
use reqwest::Client;
use std::sync::LazyLock;

use super::{PlatformBackend, ResolveCtx};
use crate::types::ResolvedStream;

pub use expand::{expand_douyin_input, looks_like_douyin_short_url, no_redirect_client};

static LIVE_RID_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)^(?:https?://)?(?:www\.)?live\.douyin\.com/([A-Za-z0-9_\-\.]+)").expect("re")
});

pub struct DouyinBackend;

pub fn looks_like_douyin_url(url: &str) -> bool {
    let l = url.trim().to_ascii_lowercase();
    l.contains("douyin.com")
        || l.contains("iesdouyin.com")
        || l.contains("amemv.com")
        || looks_like_douyin_short_url(url)
}

fn web_rid(url: &str) -> Option<String> {
    LIVE_RID_RE
        .captures(url.trim())
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().trim_end_matches('/').to_string())
        .filter(|s| !s.is_empty())
}

#[async_trait]
impl PlatformBackend for DouyinBackend {
    fn id(&self) -> &'static str {
        "douyin"
    }

    fn matches(&self, url: &str) -> bool {
        looks_like_douyin_url(url)
    }

    async fn prepare_url(&self, url: &str, _client: &Client) -> Result<String> {
        let url = url.trim();
        if looks_like_douyin_short_url(url) {
            let expand_client = no_redirect_client()?;
            return expand_douyin_input(&expand_client, url).await;
        }
        if let Some(rid) = web_rid(url) {
            return Ok(format!("https://live.douyin.com/{rid}"));
        }
        // Claimed host but no rid yet — leave as-is; resolve will error clearly.
        Ok(url.to_string())
    }

    async fn resolve(&self, ctx: &ResolveCtx<'_>) -> Result<ResolvedStream> {
        let rid = web_rid(ctx.url).ok_or_else(|| {
            anyhow!("无效的抖音直播间链接，请使用 live.douyin.com/房间号")
        })?;
        let site = format!("https://live.douyin.com/{rid}");
        let root = enter::fetch_web_enter(ctx.client, &rid, ctx.cookies).await?;
        parse::resolved_from_enter(&root, &site)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_hosts() {
        assert!(looks_like_douyin_url("https://live.douyin.com/123"));
        assert!(looks_like_douyin_url("https://v.douyin.com/AbC/"));
        assert!(!looks_like_douyin_url("https://live.kuaishou.com/u/x"));
    }

    #[test]
    fn extracts_rid() {
        assert_eq!(
            web_rid("https://live.douyin.com/573716250978").as_deref(),
            Some("573716250978")
        );
    }
}
