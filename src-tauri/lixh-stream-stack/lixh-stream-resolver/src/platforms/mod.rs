//! Pluggable live-room resolvers (native only — no rust-srec).
//!
//! See [`README.md`](./README.md) for how to add or re-sync a platform.

mod douyin;
mod kuaishou;
mod xiaohongshu;

use anyhow::{anyhow, Result};
use async_trait::async_trait;
use reqwest::Client;
use serde_json::Value;

use crate::types::ResolvedStream;

pub use douyin::DouyinBackend;
pub use kuaishou::KuaishouBackend;
pub use xiaohongshu::XiaohongshuBackend;

/// Inputs shared by every platform backend for one resolve call.
pub struct ResolveCtx<'a> {
    pub url: &'a str,
    pub cookies: Option<&'a str>,
    pub extras: Option<&'a Value>,
    pub client: &'a Client,
}

/// One streaming site.
#[async_trait]
pub trait PlatformBackend: Send + Sync {
    fn id(&self) -> &'static str;
    fn matches(&self, url: &str) -> bool;
    async fn prepare_url(&self, url: &str, _client: &Client) -> Result<String> {
        Ok(url.to_string())
    }
    async fn resolve(&self, ctx: &ResolveCtx<'_>) -> Result<ResolvedStream>;
}

/// Ordered backends. First `matches(url)` wins. Unknown hosts → 暂不支持.
pub fn default_registry() -> Vec<Box<dyn PlatformBackend>> {
    vec![
        Box::new(DouyinBackend),
        Box::new(KuaishouBackend),
        Box::new(XiaohongshuBackend),
    ]
}

pub async fn resolve_with_registry(
    backends: &[Box<dyn PlatformBackend>],
    url: &str,
    cookies: Option<&str>,
    extras: Option<&Value>,
    client: &Client,
) -> Result<ResolvedStream> {
    let url = url.trim();
    if url.is_empty() {
        return Err(anyhow!("stream URL is empty"));
    }

    let backend = backends
        .iter()
        .find(|b| b.matches(url))
        .ok_or_else(|| anyhow!("暂不支持该平台链接"))?;

    let prepared = backend.prepare_url(url, client).await?;
    let ctx = ResolveCtx {
        url: prepared.as_str(),
        cookies,
        extras,
        client,
    };
    backend.resolve(&ctx).await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn registry_order_natives_only() {
        let reg = default_registry();
        assert_eq!(reg[0].id(), "douyin");
        assert_eq!(reg[1].id(), "kuaishou");
        assert_eq!(reg[2].id(), "xiaohongshu");
        assert_eq!(reg.len(), 3);
    }

    #[test]
    fn douyin_claimed() {
        let reg = default_registry();
        let url = "https://live.douyin.com/123";
        assert_eq!(
            reg.iter().find(|b| b.matches(url)).unwrap().id(),
            "douyin"
        );
    }

    #[test]
    fn kuaishou_claimed() {
        let reg = default_registry();
        let url = "https://live.kuaishou.com/u/cym030000";
        assert_eq!(
            reg.iter().find(|b| b.matches(url)).unwrap().id(),
            "kuaishou"
        );
    }

    #[test]
    fn xiaohongshu_claimed() {
        let reg = default_registry();
        let url = "https://www.xiaohongshu.com/user/profile/abc";
        assert_eq!(
            reg.iter().find(|b| b.matches(url)).unwrap().id(),
            "xiaohongshu"
        );
    }

    #[test]
    fn unknown_host_unmatched() {
        let reg = default_registry();
        assert!(reg
            .iter()
            .find(|b| b.matches("https://live.bilibili.com/1"))
            .is_none());
    }
}
