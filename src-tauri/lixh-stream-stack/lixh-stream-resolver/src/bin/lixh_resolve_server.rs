//! HTTP room resolve service — keep `platforms-parser` off client devices.
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
}

#[derive(Debug, Deserialize)]
struct ResolveRequest {
    url: String,
    #[serde(default)]
    cookies: Option<String>,
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
    let state = Arc::new(AppState { api_key });
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
    info!(%addr, auth_enabled, "lixh_resolve_server listening");
    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .with_context(|| format!("bind {addr}"))?;
    axum::serve(listener, app).await.context("serve")?;
    Ok(())
}

async fn health() -> impl IntoResponse {
    (StatusCode::OK, "ok\n")
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
    let Some(expected) = state.api_key.as_deref() else {
        return Ok(());
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
