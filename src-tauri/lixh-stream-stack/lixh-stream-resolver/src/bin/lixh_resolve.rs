//! One-shot room URL → JSON ResolvedStream for Flutter / tooling.
//!
//! Usage:
//!   lixh_resolve <room_url> [--cookies COOKIE]
//!
//! stdout: JSON ResolvedStream (same schema as the library types)
//! stderr: human-readable errors
//! exit 0 on success; non-zero on failure

use anyhow::{anyhow, Context, Result};
use lixh_stream_resolver::{resolve, ResolvedStream};
use std::env;
use std::io::{self, Write};
use std::process::ExitCode;

#[tokio::main]
async fn main() -> ExitCode {
    match run().await {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            // Prefer the leaf message for Flutter UI (avoid "resolve: extract: …" chains).
            let leaf = e
                .chain()
                .last()
                .map(|c| c.to_string())
                .unwrap_or_else(|| e.to_string());
            let _ = writeln!(io::stderr(), "lixh_resolve: {leaf}");
            ExitCode::from(1)
        }
    }
}

async fn run() -> Result<()> {
    let mut args = env::args().skip(1);
    let mut url: Option<String> = None;
    let mut cookies: Option<String> = None;

    while let Some(a) = args.next() {
        match a.as_str() {
            "--cookies" => {
                cookies = Some(
                    args.next()
                        .ok_or_else(|| anyhow!("--cookies requires a value"))?,
                );
            }
            "-h" | "--help" => {
                let _ = writeln!(
                    io::stdout(),
                    "Usage: lixh_resolve <room_url> [--cookies COOKIE]"
                );
                return Ok(());
            }
            other if other.starts_with('-') => {
                return Err(anyhow!("unknown flag: {other}"));
            }
            other => {
                if url.is_some() {
                    return Err(anyhow!("unexpected argument: {other}"));
                }
                url = Some(other.to_string());
            }
        }
    }

    let url = url.ok_or_else(|| anyhow!("room URL required"))?;
    let resolved: ResolvedStream = resolve(&url, cookies.as_deref(), None).await?;

    let json = serde_json::to_string(&resolved).context("serialize")?;
    let mut out = io::stdout().lock();
    out.write_all(json.as_bytes())?;
    out.write_all(b"\n")?;
    Ok(())
}
