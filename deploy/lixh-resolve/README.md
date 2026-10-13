# Remote room resolve (`lixh_resolve_server`)

Keeps `platforms-parser` / Douyin extract logic on the server so client apps
do not ship `lixh_resolve` / `liblixh_stream_resolver.so`.

## Endpoints (public)

| Method | Path | Notes |
|--------|------|--------|
| GET | `http://101.35.40.114/livecatch/health` | `ok` |
| POST | `http://101.35.40.114/livecatch/v1/resolve` | JSON body `{ "url", "cookies"? }` |

Auth: header `X-Api-Key` (or `Authorization: Bearer …`).  
Default key matches `flutter_app/lib/resolve_config.dart`.

## Deploy (on the server)

```bash
# After syncing this repo (or at least stream-stack + deploy/lixh-resolve):
bash deploy/lixh-resolve/deploy.sh
```

Installs:

- binary → `/opt/livecatch/resolve/lixh_resolve_server`
- env → `/etc/livecatch/resolve.env`
- systemd → `lixh-resolve.service`
- nginx snippet → `/livecatch/` on Rewardplay `:80` / `:3000`

## Client

Flutter calls the remote API from `room_resolve.dart`. Override at build time:

```bash
flutter run \
  --dart-define=LIXH_RESOLVE_BASE_URL=http://101.35.40.114/livecatch \
  --dart-define=LIXH_RESOLVE_API_KEY=...
```
