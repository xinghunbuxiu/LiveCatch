#!/usr/bin/env bash
# From your laptop: restart remote resolve + re-attach nginx if Rewardplay wiped it.
# Usage: bash deploy/lixh-resolve/start.sh
set -euo pipefail

HOST="${LIXH_RESOLVE_HOST:-root@101.35.40.114}"
PUBLIC_URL="${LIXH_RESOLVE_PUBLIC_URL:-http://101.35.40.114/livecatch}"

ssh -o BatchMode=yes -o ConnectTimeout=15 "$HOST" 'set -euo pipefail
SITE_AVAIL=/etc/nginx/sites-available/rewardplay
SITE_EDIT="$SITE_AVAIL"
if [[ -L /etc/nginx/sites-enabled/rewardplay ]]; then
  SITE_EDIT="$(readlink -f /etc/nginx/sites-enabled/rewardplay || true)"
fi
[[ -f "${SITE_EDIT:-}" ]] || SITE_EDIT="$SITE_AVAIL"

SNIPPET=/etc/nginx/snippets/livecatch-resolve.conf
if [[ ! -f "$SNIPPET" ]]; then
  install -d -m 755 /etc/nginx/snippets
  cat >"$SNIPPET" <<'"'"'NGX'"'"'
location /livecatch/ {
    proxy_pass http://127.0.0.1:9101/;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Api-Key $http_x_api_key;
    proxy_set_header Authorization $http_authorization;
    proxy_connect_timeout 10s;
    proxy_send_timeout 60s;
    proxy_read_timeout 60s;
}
NGX
  echo "wrote $SNIPPET"
fi

NEED_RELOAD=0
if [[ -f "$SITE_EDIT" ]] && ! grep -q "snippets/livecatch-resolve.conf" "$SITE_EDIT"; then
  cp -a "$SITE_EDIT" "${SITE_EDIT}.bak.livecatch.$(date +%Y%m%d%H%M%S)"
  python3 - <<PY
from pathlib import Path
path = Path("$SITE_EDIT")
text = path.read_text()
needle = "    location /api/ {"
insert = "    include snippets/livecatch-resolve.conf;\n\n"
parts = text.split("server {", 1)
if len(parts) != 2:
    raise SystemExit("unexpected nginx site layout")
head, rest = parts
idx = rest.find(needle)
if idx < 0:
    raise SystemExit("location /api/ not found in first server")
rest = rest[:idx] + insert + rest[idx:]
path.write_text(head + "server {" + rest)
print("patched nginx include ->", path)
PY
  NEED_RELOAD=1
else
  echo "nginx include ok ($SITE_EDIT)"
fi

systemctl restart lixh-resolve.service
if [[ "$NEED_RELOAD" -eq 1 ]]; then
  nginx -t
  systemctl reload nginx
fi

sleep 1
echo -n "local :9101 -> "
curl -fsS http://127.0.0.1:9101/health
echo
echo -n "via nginx  -> "
curl -fsS http://127.0.0.1/livecatch/health
echo
systemctl --no-pager --full status lixh-resolve.service | head -n 12
'

echo -n "public     -> "
curl -fsS -m 8 "$PUBLIC_URL/health"
echo
echo "ready: $PUBLIC_URL"
