//! HTTP room resolve service — native platforms only (see `platforms/README.md`).
//!
//! Endpoints:
//!   GET  /health
//!   POST /v1/resolve   JSON body: { "url": "...", "cookies": "..."? }
//!
//! Auth: optional `X-Api-Key` / `Authorization: Bearer …` when `LIXH_RESOLVE_API_KEY` is set.
//! Bind: `LIXH_RESOLVE_BIND` (default `127.0.0.1:9101`).

use anyhow::{anyhow, Context, Result};
use axum::extract::State;
use axum::http::{HeaderMap, StatusCode};
use axum::response::IntoResponse;
use axum::routing::{get, post};
use axum::{Json, Router};
use lixh_stream_resolver::{resolve, ResolvedStream};
use serde::{Deserialize, Serialize};
use std::env;
use std::net::SocketAddr;
use std::sync::Arc;
use tower_http::cors::{Any, CorsLayer};
use tower_http::trace::TraceLayer;
use tracing::{error, info};

#[derive(Clone)]
struct AppState {
    api_key: Option<String>,
    /// RewardPlay entitlement gate. When configured, every resolve must carry a
    /// license code + device id that RewardPlay still reports as active. The
    /// integration token stays server-side: it is never sent to clients.
    license: Option<LicenseGate>,
    /// Per-device request budget so a leaked code cannot be used to scrape.
    rate: RateLimiter,
}

#[derive(Clone)]
struct LicenseGate {
    base_url: String,
    project_code: String,
    integration_token: String,
    /// Skip the network call when a code was verified this recently.
    cache: Arc<std::sync::Mutex<std::collections::HashMap<String, (std::time::Instant, bool)>>>,
}

#[derive(Clone)]
struct RateLimiter {
    per_minute: u32,
    hits: Arc<std::sync::Mutex<std::collections::HashMap<String, (std::time::Instant, u32)>>>,
}

#[derive(Debug, Deserialize)]
struct ResolveRequest {
    url: String,
    #[serde(default)]
    cookies: Option<String>,
    /// License code bound to this device (RewardPlay `authorizationCode`).
    #[serde(default)]
    license_code: Option<String>,
    /// Stable device id the app already uses for licensing.
    #[serde(default)]
    device_id: Option<String>,
}

#[derive(Debug, Serialize)]
struct ErrorBody {
    error: String,
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let bind = env::var("LIXH_RESOLVE_BIND").unwrap_or_else(|_| "127.0.0.1:9101".into());
    let api_key = env::var("LIXH_RESOLVE_API_KEY")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());

    let auth_enabled = api_key.is_some();

    /* RewardPlay gate. Enabled only when all three values are present, so an
     * existing deployment keeps working until the operator opts in. */
    let license = match (
        env::var("LIXH_LICENSE_BASE_URL").ok(),
        env::var("LIXH_LICENSE_PROJECT_CODE").ok(),
        env::var("LIXH_LICENSE_TOKEN").ok(),
    ) {
        (Some(base), Some(project), Some(token))
            if !base.trim().is_empty() && !project.trim().is_empty() && !token.trim().is_empty() =>
        {
            Some(LicenseGate {
                base_url: base.trim().trim_end_matches('/').to_string(),
                project_code: project.trim().to_string(),
                integration_token: token.trim().to_string(),
                cache: Arc::new(std::sync::Mutex::new(std::collections::HashMap::new())),
            })
        }
        _ => None,
    };
    let license_enabled = license.is_some();

    let per_minute = env::var("LIXH_RESOLVE_RATE_PER_MIN")
        .ok()
        .and_then(|v| v.trim().parse::<u32>().ok())
        .unwrap_or(30);
    let rate = RateLimiter {
        per_minute,
        hits: Arc::new(std::sync::Mutex::new(std::collections::HashMap::new())),
    };

    let state = Arc::new(AppState {
        api_key,
        license,
        rate,
    });
    let app = Router::new()
        .route("/health", get(health))
        .route("/v1/resolve", post(resolve_handler))
        .layer(
            CorsLayer::new()
                .allow_origin(Any)
                .allow_methods(Any)
                .allow_headers(Any),
        )
        .layer(TraceLayer::new_for_http())
        .with_state(state);

    let addr: SocketAddr = bind.parse().context("parse LIXH_RESOLVE_BIND")?;
    info!(
        %addr,
        auth_enabled,
        license_enabled,
        rate_per_min = per_minute,
        "lixh_resolve_server listening"
    );
    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .with_context(|| format!("bind {addr}"))?;
    axum::serve(listener, app).await.context("serve")?;
    Ok(())
}

async fn health() -> impl IntoResponse {
    (StatusCode::OK, "ok\n")
}

impl RateLimiter {
    /// Sliding one-minute budget keyed by device (or peer when unlicensed).
    fn allow(&self, key: &str) -> Result<()> {
        if self.per_minute == 0 {
            return Ok(());
        }
        let now = std::time::Instant::now();
        let mut hits = self.hits.lock().expect("rate limiter poisoned");
        // Drop stale keys so the map cannot grow without bound.
        hits.retain(|_, (start, _)| now.duration_since(*start).as_secs() < 120);
        let entry = hits.entry(key.to_string()).or_insert((now, 0));
        if now.duration_since(entry.0).as_secs() >= 60 {
            *entry = (now, 0);
        }
        if entry.1 >= self.per_minute {
            return Err(anyhow!("rate limit exceeded"));
        }
        entry.1 += 1;
        Ok(())
    }
}

/// Marker for RewardPlay transport blips — mapped to HTTP 503, not 403, so the
/// client does not tell the user their licence expired when the check itself failed.
const LICENSE_CHECK_UNAVAILABLE: &str = "license check unavailable";

impl LicenseGate {
    /// Ask RewardPlay whether this code is still active on this device.
    ///
    /// Only "active" counts as success. A code bound to a different device is
    /// rejected here even if it is otherwise valid, which is what stops a
    /// shared code from being used to run the resolver on many machines.
    async fn verify(&self, code: &str, device_id: &str) -> Result<()> {
        let cache_key = format!("{code}\u{1}{device_id}");
        {
            let mut cache = self.cache.lock().expect("license cache poisoned");
            // Drop stale entries so scrapers cannot grow the map without bound.
            cache.retain(|_, (at, _)| at.elapsed().as_secs() < 120);
            if let Some((at, ok)) = cache.get(&cache_key) {
                // Positive hits get 60s grace (below the app's own heartbeat interval).
                // Negatives are not cached — see insert below — so a just-activated
                // code is not stuck for a minute after a failed probe.
                if *ok && at.elapsed().as_secs() < 60 {
                    return Ok(());
                }
            }
        }

        let url = format!("{}/api/open/license/heartbeat", self.base_url);
        let payload = serde_json::json!({
            "projectCode": self.project_code,
            "code": code,
            "deviceId": device_id,
        });
        let resp = match reqwest::Client::new()
            .post(&url)
            .header("Authorization", format!("Bearer {}", self.integration_token))
            .header("Content-Type", "application/json")
            .json(&payload)
            .timeout(std::time::Duration::from_secs(10))
            .send()
            .await
        {
            Ok(r) => r,
            Err(e) => {
                error!(error = %e, "license heartbeat transport");
                return Err(anyhow!(LICENSE_CHECK_UNAVAILABLE));
            }
        };

        let status = resp.status();
        let text = resp.text().await.unwrap_or_default();
        // Upstream 5xx / empty body is a check outage, not proof the licence is dead.
        if status.is_server_error() || (status.is_success() && text.trim().is_empty()) {
            error!(%status, "license heartbeat upstream unavailable");
            return Err(anyhow!(LICENSE_CHECK_UNAVAILABLE));
        }
        let ok = status.is_success() && license_payload_active(&text);

        if ok {
            if let Ok(mut cache) = self.cache.lock() {
                cache.retain(|_, (at, _)| at.elapsed().as_secs() < 120);
                cache.insert(cache_key, (std::time::Instant::now(), true));
            }
            Ok(())
        } else {
            error!(%status, body = %text.chars().take(200).collect::<String>(), "license rejected");
            Err(anyhow!("license not active"))
        }
    }
}

/// `success: true` plus `status: "active"` (or an explicit expiry still ahead).
fn license_payload_active(body: &str) -> bool {
    let Ok(v) = serde_json::from_str::<serde_json::Value>(body) else {
        return false;
    };
    let data = v.get("data").unwrap_or(&v);
    let success = data
        .get("success")
        .and_then(|b| b.as_bool())
        .unwrap_or(false);
    let status_ok = data
        .get("status")
        .and_then(|s| s.as_str())
        .map(|s| s.eq_ignore_ascii_case("active"))
        .unwrap_or(false);
    success && status_ok
}

async fn resolve_handler(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(body): Json<ResolveRequest>,
) -> Result<Json<ResolvedStream>, (StatusCode, Json<ErrorBody>)> {
    if let Err(e) = authorize(&state, &headers) {
        return Err((
            StatusCode::UNAUTHORIZED,
            Json(ErrorBody {
                error: e.to_string(),
            }),
        ));
    }

    let url = body.url.trim();
    if url.is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(ErrorBody {
                error: "url required".into(),
            }),
        ));
    }

    /* Entitlement gate. Checked before any upstream work so an expired or
     * foreign device cannot make the resolver do network traffic. */
    if let Some(gate) = state.license.as_ref() {
        let code = body.license_code.as_deref().map(str::trim).unwrap_or("");
        let device = body.device_id.as_deref().map(str::trim).unwrap_or("");
        if code.is_empty() || device.is_empty() {
            return Err((
                StatusCode::FORBIDDEN,
                Json(ErrorBody {
                    error: "license_code and device_id required".into(),
                }),
            ));
        }
        if let Err(e) = gate.verify(code, device).await {
            let msg = e.to_string();
            let status = if msg.contains(LICENSE_CHECK_UNAVAILABLE) {
                StatusCode::SERVICE_UNAVAILABLE
            } else {
                StatusCode::FORBIDDEN
            };
            return Err((status, Json(ErrorBody { error: msg })));
        }
        /* Budget per licensed device, so one leaked code cannot scrape. */
        if let Err(e) = state.rate.allow(device) {
            return Err((
                StatusCode::TOO_MANY_REQUESTS,
                Json(ErrorBody {
                    error: e.to_string(),
                }),
            ));
        }
    }

    let cookies = body
        .cookies
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty());

    match resolve(url, cookies, None).await {
        Ok(resolved) => Ok(Json(resolved)),
        Err(e) => {
            let msg = format_resolve_err(&e);
            error!(error = %msg, "resolve failed");
            Err((
                StatusCode::UNPROCESSABLE_ENTITY,
                Json(ErrorBody { error: msg }),
            ))
        }
    }
}

fn authorize(state: &AppState, headers: &HeaderMap) -> Result<()> {
    /* A static key cannot be a security boundary: it ships inside the APK and
     * anyone who extracts it can present it. So when the entitlement gate is
     * configured, a live RewardPlay licence is sufficient and the key becomes
     * optional. The key is still accepted for older clients during rollout.
     */
    if state.license.is_some() {
        return Ok(());
    }
    let Some(expected) = state.api_key.as_deref() else {
        /* Neither gate configured: refuse rather than serve everyone. An
         * unconfigured deployment is a misconfiguration, not a public API. */
        return Err(anyhow!(
            "resolver has no auth configured (set LIXH_LICENSE_* or LIXH_RESOLVE_API_KEY)"
        ));
    };
    if let Some(v) = headers.get("x-api-key").and_then(|v| v.to_str().ok()) {
        if v == expected {
            return Ok(());
        }
    }
    if let Some(v) = headers.get("authorization").and_then(|v| v.to_str().ok()) {
        let token = v
            .strip_prefix("Bearer ")
            .or_else(|| v.strip_prefix("bearer "))
            .unwrap_or(v)
            .trim();
        if token == expected {
            return Ok(());
        }
    }
    Err(anyhow!("invalid or missing api key"))
}

fn format_resolve_err(e: &anyhow::Error) -> String {
    let full = format!("{e:#}");
    if full.contains("error sending request")
        || full.contains("网络请求失败")
        || full.contains("certificate")
        || full.contains("dns error")
    {
        return full;
    }
    e.chain()
        .last()
        .map(|c| c.to_string())
        .unwrap_or_else(|| e.to_string())
}
