#!/usr/bin/env python3
"""Stub /v1/resolve that points the app at a throttling proxy.

Weak-network tests need the player to pull a rate-limited stream. Neither the
device (no root, so no tc/netem) nor the app can be reconfigured for that, so
this returns the same JSON shape the real resolver does, with the stream URL
rewritten to the local throttle proxy reachable through `adb reverse`.

Usage:
  resolve_stub.py --port 18080 --stream http://127.0.0.1:18081/x.flv
"""
import argparse
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    stream_url = ""
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("[resolve] " + (fmt % args) + "\n")

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else b"{}"
        try:
            req = json.loads(body or b"{}")
        except Exception:
            req = {}

        room = str(req.get("url", ""))
        payload = {
            "platform": "douyin",
            "site_url": room,
            "title": "weak-net test",
            "artist": "",
            "is_live": True,
            "headers": "",
            "streams": [
                {
                    "url": Handler.stream_url,
                    "format": "flv",
                    "media_format": "video",
                    "quality": "NET400",
                    "bitrate": 400,
                    "codec": "h264",
                    "fps": 0.0,
                    "priority": 1000,
                    "headers_needed": False,
                }
            ],
        }
        out = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def do_GET(self):
        # Health probe used by the harness before it starts a run.
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"ok")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=18080)
    ap.add_argument("--stream", required=True)
    args = ap.parse_args()
    Handler.stream_url = args.stream
    with ThreadingHTTPServer(("127.0.0.1", args.port), Handler) as srv:
        sys.stderr.write(
            f"[resolve] listening 127.0.0.1:{args.port} -> {args.stream}\n"
        )
        srv.serve_forever()


if __name__ == "__main__":
    main()
