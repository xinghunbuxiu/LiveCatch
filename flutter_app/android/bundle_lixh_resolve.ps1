# Deprecated: room resolve runs on the server (lixh_resolve_server).
# See deploy/lixh-resolve/README.md — no Android jniLibs resolve .so needed.
Write-Host "bundle_lixh_resolve.ps1 is deprecated (remote resolve)."
Write-Host "  POST http://101.35.40.114/livecatch/v1/resolve"
exit 0
