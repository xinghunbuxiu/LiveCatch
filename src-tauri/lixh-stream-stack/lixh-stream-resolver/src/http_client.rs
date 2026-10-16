//! Shared HTTP client for resolve backends (desktop + Android).

use anyhow::{Context, Result};
use reqwest::Client;

/// Build the client used by platform backends (follows redirects).
pub fn build_resolve_client() -> Result<Client> {
    #[cfg(target_os = "android")]
    {
        android_http_client(/* no_redirect */ false)
    }
    #[cfg(not(target_os = "android"))]
    {
        Client::builder()
            .timeout(std::time::Duration::from_secs(30))
            .build()
            .context("reqwest client")
    }
}

/// Client that does **not** follow redirects (short-link `Location` capture).
pub fn build_no_redirect_client() -> Result<Client> {
    #[cfg(target_os = "android")]
    {
        android_http_client(/* no_redirect */ true)
    }
    #[cfg(not(target_os = "android"))]
    {
        use reqwest::redirect::Policy;
        Client::builder()
            .redirect(Policy::none())
            .timeout(std::time::Duration::from_secs(30))
            .build()
            .context("reqwest no-redirect client")
    }
}

/// Forked Android Process has no JVM — cannot use rustls-platform-verifier.
/// Use webpki roots + gzip/deflate (matches Cargo.toml reqwest features).
#[cfg(target_os = "android")]
fn android_http_client(no_redirect: bool) -> Result<Client> {
    use reqwest::redirect::Policy;
    use rustls::crypto::aws_lc_rs;
    use rustls::ClientConfig;
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

    // no_proxy: Android may inject HTTP(S)_PROXY into the forked Process env.
    let mut b = Client::builder()
        .use_preconfigured_tls(tls)
        .timeout(std::time::Duration::from_secs(30))
        .no_proxy();
    if no_redirect {
        b = b.redirect(Policy::none());
    }
    b.build().context("reqwest client")
}
