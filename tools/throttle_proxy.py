#!/usr/bin/env python3
"""Token-bucket throttling proxy for FLV byte-rate tests.

Forwards an HTTP GET upstream and re-emits the body at a fixed bitrate so the
client sees genuine link congestion (small bursts, sustained backpressure)
rather than a fast download with a delay injected.

Usage:
  throttle_proxy.py --listen 18081 --upstream <url> --kbps 400
"""
import argparse
import http.server
import socket
import socketserver
import ssl
import sys
import threading
import time
import urllib.request


class Bucket:
    """Leaky bucket: allows at most `rate` bytes/sec, small burst tolerated."""

    def __init__(self, kbps: int, burst_ms: int = 200):
        self.rate = max(1, kbps * 1024 // 8)          # bytes per second
        self.capacity = max(self.rate, self.rate * burst_ms // 1000)
        self.tokens = float(self.capacity)
        self.updated = time.monotonic()
        self.lock = threading.Lock()

    def take(self, n: int) -> float:
        """Block until n bytes of budget are available; return seconds waited."""
        waited = 0.0
        while n > 0:
            with self.lock:
                now = time.monotonic()
                self.tokens = min(
                    self.capacity, self.tokens + (now - self.updated) * self.rate
                )
                self.updated = now
                take = min(n, int(self.tokens))
                if take > 0:
                    self.tokens -= take
                    n -= take
                deficit = n
            if deficit > 0:
                # Sleep exactly as long as the missing budget needs.
                need = deficit / self.rate
                time.sleep(min(need, 0.05))
                waited += min(need, 0.05)
        return waited


def build_opener():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    # Douyin edge nodes answer 302 to a different pull host; follow it, and keep
    # sending Referer/UA on the hop (the CDN rejects bare Lavf clients).
    class Redirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            new = super().redirect_request(req, fp, code, msg, headers, newurl)
            if new is not None:
                for h in ("Referer", "User-Agent"):
                    if h in req.headers:
                        new.add_header(h, req.headers[h])
                sys.stderr.write(f"[proxy] redirect {code} -> {newurl[:90]}\n")
            return new

    return urllib.request.build_opener(
        urllib.request.HTTPSHandler(context=ctx),
        Redirect(),
    )


class Handler(http.server.BaseHTTPRequestHandler):
    upstream = None
    kbps = 0
    stats = {"sent": 0, "started": 0.0, "connections": 0}

    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # keep stdout readable
        sys.stderr.write("[proxy] " + (fmt % args) + "\n")

    def do_GET(self):
        Handler.stats["connections"] += 1
        conn_id = Handler.stats["connections"]
        bucket = Bucket(Handler.kbps)
        handler = self

        headers = {
            "User-Agent": handler.headers.get(
                "User-Agent",
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
            ),
            "Referer": handler.headers.get("Referer", "https://live.douyin.com/"),
            "Accept": "*/*",
        }
        req = urllib.request.Request(Handler.upstream, headers=headers)
        try:
            resp = build_opener().open(req, timeout=15)
        except Exception as exc:  # upstream refused
            handler.send_error(502, f"upstream: {exc}")
            return

        handler.send_response(resp.status)
        handler.send_header("Content-Type", resp.headers.get("Content-Type", "video/x-flv"))
        handler.send_header("Cache-Control", "no-store")
        # No Content-Length: this is a live stream.
        handler.end_headers()

        Handler.stats["started"] = time.monotonic()
        start = time.monotonic()
        total = 0
        chunk = 4096
        try:
            while True:
                data = resp.read(chunk)
                if not data:
                    break
                bucket.take(len(data))
                handler.wfile.write(data)
                handler.wfile.flush()
                total += len(data)
                Handler.stats["sent"] = total
                elapsed = time.monotonic() - start
                if elapsed > 0 and int(elapsed) % 5 == 0 and total % (chunk * 40) < chunk:
                    kbps_now = total * 8 / elapsed / 1000
                    sys.stderr.write(
                        f"[proxy] conn{conn_id} {total/1024:.0f}KB "
                        f"avg {kbps_now:.0f}kbps target {Handler.kbps}kbps\n"
                    )
        except (BrokenPipeError, ConnectionResetError):
            sys.stderr.write(f"[proxy] conn{conn_id} client closed after "
                             f"{total/1024:.0f}KB\n")
        except Exception as exc:
            sys.stderr.write(f"[proxy] conn{conn_id} error: {exc}\n")
        finally:
            try:
                resp.close()
            except Exception:
                pass


class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", type=int, default=18081)
    ap.add_argument("--upstream", required=True)
    ap.add_argument("--kbps", type=int, required=True)
    args = ap.parse_args()

    Handler.upstream = args.upstream
    Handler.kbps = args.kbps

    with Server(("127.0.0.1", args.listen), Handler) as srv:
        sys.stderr.write(
            f"[proxy] listening 127.0.0.1:{args.listen} -> {args.kbps}kbps\n"
            f"[proxy] upstream {args.upstream[:100]}\n"
        )
        srv.serve_forever()


if __name__ == "__main__":
    main()
