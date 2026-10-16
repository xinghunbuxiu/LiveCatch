# Remote room resolve (`lixh_resolve_server`)

HTTP 服务在服务器上跑原生平台解析（抖音 / 快手 / 小红书），客户端**不**内嵌解析库。

协议与平台对齐说明：`src-tauri/lixh-stream-stack/lixh-stream-resolver/src/platforms/README.md`。

**已不再依赖** rust-srec / `platforms-parser`（旧称 strev）。构建无需 `vendor/rust-srec`。

## Endpoints (public)

| Method | Path | Notes |
|--------|------|--------|
| GET | `http://101.35.40.114/livecatch/health` | `ok` |
| POST | `http://101.35.40.114/livecatch/v1/resolve` | JSON body `{ "url", "cookies"? }` |

Auth: header `X-Api-Key` (or `Authorization: Bearer …`).  
Default key matches `flutter_app/lib/resolve_config.dart`.

## Start / recover (from your laptop)

```bash
bash deploy/lixh-resolve/start.sh
```

SSH 到服务器：重启 `lixh-resolve`，若 Rewardplay 冲掉了 nginx include 会自动补回，并检查本地 / 公网 health。

## Deploy (on the server)

```bash
# After syncing this repo (or at least stream-stack + deploy/lixh-resolve):
bash deploy/lixh-resolve/deploy.sh
```

Installs:

- binary → `/opt/livecatch/resolve/lixh_resolve_server`
- env → `/etc/livecatch/resolve.env`
- systemd → `lixh-resolve.service` (`Restart=always`)
- nginx snippet → `/livecatch/` on Rewardplay `:80` / `:3000`

### Why it looks “down” after Rewardplay deploy

`rewardplay.sh deploy` regenerates `/etc/nginx/sites-available/rewardplay` and
**drops** the `include snippets/livecatch-resolve.conf;` line. The systemd
process can still be healthy on `127.0.0.1:9101`, but public
`http://101.35.40.114/livecatch/health` falls through to the Admin SPA.

Fix after any Rewardplay nginx overwrite:

```bash
# On the server — re-run resolve deploy (idempotent nginx patch + restart):
bash deploy/lixh-resolve/deploy.sh
# Or quick check:
curl -fsS http://127.0.0.1:9101/health
curl -fsS http://127.0.0.1/livecatch/health
```

## Client

Flutter calls the remote API from `room_resolve.dart`. Override at build time:

```bash
flutter run \
  --dart-define=LIXH_RESOLVE_BASE_URL=http://101.35.40.114/livecatch \
  --dart-define=LIXH_RESOLVE_API_KEY=...
```
