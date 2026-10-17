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
use url::Url;

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
    let url = url.trim();
    if let Some(rid) = path_web_rid(url) {
        return Some(rid);
    }
    query_web_rid(url)
}

/// `https://live.douyin.com/{web_rid}` — same path rule as strev `URL_REGEX`.
fn path_web_rid(url: &str) -> Option<String> {
    LIVE_RID_RE
        .captures(url)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().trim_end_matches('/').to_string())
        .filter(|s| is_rid_token(s))
}

/// Homepage / recommend cards: `https://live.douyin.com/?live_web_rid={web_rid}`.
/// strev only reads the path, so these links never yielded a room id.
fn query_web_rid(url: &str) -> Option<String> {
    let parsed = parse_http_url(url)?;
    let host = parsed.host_str()?.to_ascii_lowercase();
    if host != "live.douyin.com" && host != "www.live.douyin.com" {
        return None;
    }
    for key in ["live_web_rid", "web_rid", "webRid"] {
        let Some(value) = parsed
            .query_pairs()
            .find(|(k, _)| k.eq_ignore_ascii_case(key))
            .map(|(_, v)| v.into_owned())
        else {
            continue;
        };
        let rid = value.trim().trim_end_matches('/');
        if is_rid_token(rid) {
            return Some(rid.to_string());
        }
    }
    None
}

fn parse_http_url(raw: &str) -> Option<Url> {
    if let Ok(parsed) = Url::parse(raw) {
        if parsed.scheme() == "http" || parsed.scheme() == "https" {
            return Some(parsed);
        }
    }
    Url::parse(&format!("https://{raw}")).ok()
}

fn is_rid_token(s: &str) -> bool {
    let lower = s.to_ascii_lowercase();
    !s.is_empty()
        && lower != "undefined"
        && lower != "null"
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-' || c == '.')
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
            anyhow!("无效的抖音直播间链接，请使用 live.douyin.com/房间号，或带 live_web_rid 的直播页链接")
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
        assert_eq!(
            web_rid("https://live.douyin.com/?live_web_rid=954193741251").as_deref(),
            Some("954193741251")
        );
        assert_eq!(
            web_rid(
                "https://live.douyin.com/?activity_name=&anchor_id=569990725775929&banner_index=undefined&banner_type=recommend&category_name=all&live_web_rid=591215943970&page_type=live_main_page&user_id=undefined"
            )
            .as_deref(),
            Some("591215943970")
        );
        assert_eq!(
            web_rid("https://live.douyin.com/573716250978?room_id=1").as_deref(),
            Some("573716250978")
        );
        assert_eq!(web_rid("https://live.douyin.com/?live_web_rid=undefined"), None);
    }
}
