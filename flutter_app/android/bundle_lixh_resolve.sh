#!/usr/bin/env bash
# Deprecated: room resolve runs on the server (lixh_resolve_server).
# See deploy/lixh-resolve/README.md — no Android jniLibs resolve .so needed.
echo "bundle_lixh_resolve.sh is deprecated (remote resolve)." >&2
echo "  POST http://101.35.40.114/livecatch/v1/resolve" >&2
exit 0
