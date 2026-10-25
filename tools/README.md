# Weak-network test harness

Reproducing congestion on a non-rooted device: `tc`/`netem` need root, so the
rate limit is applied upstream instead and the device reaches it over
`adb reverse`.

```
App -> resolve_stub.py :18080 -> throttle_proxy.py :18081 -> CDN
```

1. Resolve a room once to get a live CDN URL.
2. `python3 tools/throttle_proxy.py --listen 18081 --upstream "<url>" --kbps 1100`
3. `python3 tools/resolve_stub.py --port 18080 --stream http://127.0.0.1:18081/x.flv`
4. `adb reverse tcp:18080 tcp:18080 && adb reverse tcp:18081 tcp:18081`
5. Build with `--dart-define=LIXH_RESOLVE_BASE_URL=http://127.0.0.1:18080`

The proxy follows the CDN's 302 and re-sends Referer/User-Agent on the hop;
Douyin edge nodes reject bare clients. `resolve_stub` returns the same JSON
shape as the real resolver so the app needs no code change.

Limits worth knowing:

* The token bucket shapes the byte stream, so the player sees real
  backpressure rather than an injected delay.
* CDN URLs carry an `expire` timestamp; refresh via the resolver before a run.
* Rooms without an `only_audio` variant stream video too, so a limit below the
  stream's video bitrate starves audio at the demuxer and the run says nothing
  about listen-mode buffering.
