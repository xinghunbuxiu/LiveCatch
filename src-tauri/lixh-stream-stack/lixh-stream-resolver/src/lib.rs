//! LiveCatch room URL → playable stream candidates.
//!
//! Platform logic lives under [`platforms`] (native only). See
//! `platforms/README.md` for adding or re-syncing a site.

mod error;
mod http_client;
mod platforms;
mod rank;
mod types;

#[cfg(target_os = "android")]
mod android_jni;

use anyhow::{anyhow, Context, Result};
use serde_json::Value;

pub use platforms::{
    default_registry, DouyinBackend, KuaishouBackend, PlatformBackend, ResolveCtx,
    XiaohongshuBackend,
};
pub use rank::{best_candidate, ranked_candidates};
pub use types::{ResolveOptions, ResolvedStream, StreamCandidate};

pub async fn resolve(
    url: &str,
    cookies: Option<&str>,
    extras: Option<Value>,
) -> Result<ResolvedStream> {
    resolve_with_options(
        url,
        ResolveOptions {
            cookies: cookies.map(str::to_owned),
            extras,
        },
    )
    .await
}

pub async fn resolve_with_options(
    url: &str,
    options: ResolveOptions,
) -> Result<ResolvedStream> {
    let client = http_client::build_resolve_client().context("build HTTP client")?;
    let backends = default_registry();
    platforms::resolve_with_registry(
        &backends,
        url,
        options.cookies.as_deref(),
        options.extras.as_ref(),
        &client,
    )
    .await
    .map_err(error::map_resolve_error)
}

pub async fn resolve_douyin(
    url: &str,
    cookies: Option<&str>,
    extras: Option<Value>,
) -> Result<ResolvedStream> {
    let result = resolve(url, cookies, extras).await?;
    if is_douyin_platform(&result.platform) || result.site_url.contains("douyin.com") {
        Ok(result)
    } else {
        Err(anyhow!(
            "resolved platform is not Douyin: {}",
            result.platform
        ))
    }
}

fn is_douyin_platform(platform: &str) -> bool {
    let p = platform.trim().to_ascii_lowercase();
    p == "douyin" || p.contains("douyin") || p == "tiktok-cn"
}

#[cfg(test)]
mod tests {
    use super::*;

    fn candidate(
        url: &str,
        priority: u32,
        bitrate: u64,
        fps: f64,
        audio_only: bool,
    ) -> StreamCandidate {
        StreamCandidate {
            url: url.into(),
            format: "flv".into(),
            media_format: "video".into(),
            quality: "1080p".into(),
            bitrate,
            codec: "h264".into(),
            fps,
            priority,
            headers_needed: false,
            audio_only,
        }
    }

    #[test]
    fn douyin_platform_detection_is_stable() {
        assert!(is_douyin_platform("douyin"));
        assert!(is_douyin_platform("DouYin"));
        assert!(is_douyin_platform("douyin-live"));
        assert!(!is_douyin_platform("twitch"));
    }

    #[test]
    fn ranking_deduplicates_and_prefers_video() {
        let input = vec![
            candidate("https://a", 10, 1000, 30.0, false),
            candidate("https://a", 10, 9999, 60.0, false),
            candidate("https://b", 20, 2000, 60.0, false),
            candidate("https://audio", 999, 99999, 60.0, true),
        ];
        let ranked = ranked_candidates(&input);
        assert_eq!(ranked.len(), 3);
        assert_eq!(ranked[0].url, "https://a");
        assert_eq!(ranked[1].url, "https://b");
        assert!(ranked[2].audio_only);
    }

    #[test]
    fn best_candidate_returns_none_for_empty_input() {
        assert!(best_candidate(&[]).is_none());
    }
}
