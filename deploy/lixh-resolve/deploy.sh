#!/usr/bin/env bash
# Build + install lixh_resolve_server on the current host (run on 101.35.40.114).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STACK="$ROOT/src-tauri/lixh-stream-stack"
INSTALL_DIR="${LIXH_RESOLVE_INSTALL_DIR:-/opt/livecatch/resolve}"
ENV_FILE="${LIXH_RESOLVE_ENV_FILE:-/etc/livecatch/resolve.env}"
SERVICE_SRC="$ROOT/deploy/lixh-resolve/lixh-resolve.service"
NGINX_SNIPPET_SRC="$ROOT/deploy/lixh-resolve/nginx-livecatch-resolve.conf"
NGINX_SNIPPET_DST="/etc/nginx/snippets/livecatch-resolve.conf"
SITE="/etc/nginx/sites-enabled/rewardplay"

if [[ ! -f "$STACK/Cargo.toml" ]]; then
  echo "stream-stack not found at $STACK" >&2
  exit 1
fi

# China-friendly mirrors (rsproxy) when official rustup is slow.
export RUSTUP_DIST_SERVER="${RUSTUP_DIST_SERVER:-https://rsproxy.cn}"
export RUSTUP_UPDATE_ROOT="${RUSTUP_UPDATE_ROOT:-https://rsproxy.cn/rustup}"
mkdir -p "$HOME/.cargo"
if [[ ! -f "$HOME/.cargo/config.toml" ]]; then
  cat >"$HOME/.cargo/config.toml" <<'EOF'
[source.crates-io]
replace-with = 'rsproxy-sparse'
[source.rsproxy]
registry = "https://rsproxy.cn/crates.io-index"
[source.rsproxy-sparse]
registry = "sparse+https://rsproxy.cn/index/"
[registries.rsproxy]
index = "https://rsproxy.cn/crates.io-index"
[net]
git-fetch-with-cli = true
EOF
fi

if ! command -v cargo >/dev/null 2>&1; then
  echo "Installing rustup (stable via rsproxy)…"
  curl --proto '=https' --tlsv1.2 -sSf https://rsproxy.cn/rustup-init.sh | sh -s -- -y --default-toolchain stable
  # shellcheck disable=SC1091
  source "$HOME/.cargo/env"
fi
# shellcheck disable=SC1091
[[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"

if ! command -v protoc >/dev/null 2>&1; then
  echo "Installing protobuf-compiler…"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq protobuf-compiler
fi

echo "Building lixh_resolve_server (release)…"
cargo build -p lixh-stream-resolver --bin lixh_resolve_server --release \
  --manifest-path "$STACK/Cargo.toml"

BIN="$STACK/target/release/lixh_resolve_server"
test -x "$BIN"

install -d -m 755 "$INSTALL_DIR"
install -d -m 755 "$(dirname "$ENV_FILE")"
install -m 755 "$BIN" "$INSTALL_DIR/lixh_resolve_server"

# Keep in sync with flutter_app/lib/resolve_config.dart default.
DEFAULT_KEY="${LIXH_RESOLVE_API_KEY:-lc_resolve_2026_xhb_7f3a9c2e1b84}"
if [[ ! -f "$ENV_FILE" ]]; then
  cat >"$ENV_FILE" <<EOF
LIXH_RESOLVE_BIND=127.0.0.1:9101
LIXH_RESOLVE_API_KEY=$DEFAULT_KEY
RUST_LOG=info
EOF
  chmod 600 "$ENV_FILE"
  echo "Wrote $ENV_FILE"
else
  echo "Keeping existing $ENV_FILE"
fi

install -m 644 "$SERVICE_SRC" /etc/systemd/system/lixh-resolve.service
systemctl daemon-reload
systemctl enable --now lixh-resolve.service
systemctl restart lixh-resolve.service

install -d -m 755 /etc/nginx/snippets
install -m 644 "$NGINX_SNIPPET_SRC" "$NGINX_SNIPPET_DST"

if [[ -f "$SITE" ]] && ! grep -q 'snippets/livecatch-resolve.conf' "$SITE"; then
  python3 - <<'PY'
from pathlib import Path
path = Path("/etc/nginx/sites-enabled/rewardplay")
text = path.read_text()
needle = "    location /api/ {"
insert = "    include snippets/livecatch-resolve.conf;\n\n"
# Insert into the first server block (Admin :80/:3000) only.
parts = text.split("server {", 1)
if len(parts) != 2:
    raise SystemExit("unexpected nginx site layout")
head, rest = parts
# Only rewrite the first server block body until its closing — find first location /api/
idx = rest.find(needle)
if idx < 0:
    raise SystemExit("location /api/ not found in first server")
rest = rest[:idx] + insert + rest[idx:]
path.write_text(head + "server {" + rest)
print("Patched", path)
PY
fi

nginx -t
systemctl reload nginx

echo "Health (local):"
curl -fsS http://127.0.0.1:9101/health || true
echo
echo "Public: http://101.35.40.114/livecatch/health"
echo "Resolve: POST http://101.35.40.114/livecatch/v1/resolve"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  echo "API key (X-Api-Key): ${LIXH_RESOLVE_API_KEY:-<unset>}"
fi
systemctl --no-pager --full status lixh-resolve.service | head -n 20
