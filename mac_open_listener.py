#!/usr/bin/env python3
"""
mac_open_listener.py — local-only HTTP listener that hands incoming open
requests to macOS's `open` command.

Pair with mac_open.py running on a remote host reached through an SSH reverse
forward, e.g.

    ssh -R 8765:127.0.0.1:8765 user@compute

Then on the remote:

    mac-open report.pdf            # POST /open-file → ~/.mac-open-inbox + `open`
    mac-open https://example.com   # POST /open-url  → `open <url>`

Usage on Mac:

    python3 mac_open_listener.py [--port 8765] [--inbox ~/.mac-open-inbox]

Stop with Ctrl-C.

Security: binds to 127.0.0.1 only; reachable from local processes and from
remotes via SSH's reverse forward (which lands on the Mac's loopback). The
remote-supplied filename is reduced to `basename` and sanitised before use.
"""

from __future__ import annotations

import argparse
import os
import pathlib
import re
import subprocess
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

DEFAULT_PORT = 8765
DEFAULT_INBOX = "~/.mac-open-inbox"
HOST = "127.0.0.1"

URL_RE = re.compile(r"^(https?|file)://", re.I)
SAFE_NAME_RE = re.compile(r"[^A-Za-z0-9._\- ]+")


def safe_filename(name: str) -> str:
    name = os.path.basename(urllib.parse.unquote(name))
    name = SAFE_NAME_RE.sub("_", name).strip()
    return name or "file"


def make_handler(inbox: pathlib.Path):
    class Handler(BaseHTTPRequestHandler):
        def _respond(self, status: int, body: bytes = b"") -> None:
            self.send_response(status)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _read_body(self) -> bytes:
            length = int(self.headers.get("Content-Length", "0"))
            chunks: list[bytes] = []
            remaining = length
            while remaining > 0:
                chunk = self.rfile.read(min(remaining, 1 << 16))
                if not chunk:
                    break
                chunks.append(chunk)
                remaining -= len(chunk)
            return b"".join(chunks)

        def do_POST(self) -> None:  # noqa: N802 — http.server API
            if self.path == "/open-url":
                url = self._read_body().decode("utf-8", errors="replace").strip()
                if not URL_RE.match(url):
                    self._respond(400, b"invalid url\n")
                    return
                print(f"open-url: {url}", file=sys.stderr, flush=True)
                subprocess.run(["open", url], check=False)
                self._respond(200, b"ok\n")
                return

            if self.path == "/open-file":
                name = safe_filename(self.headers.get("X-Filename", "file"))
                path = inbox / name
                data = self._read_body()
                path.write_bytes(data)
                print(f"open-file: {path} ({len(data)} bytes)", file=sys.stderr, flush=True)
                subprocess.run(["open", str(path)], check=False)
                self._respond(200, b"ok\n")
                return

            self._respond(404, b"unknown path\n")

        def log_message(self, format: str, *args) -> None:
            # Suppress the default per-request access log; we log explicitly above.
            return

    return Handler


def main() -> int:
    ap = argparse.ArgumentParser(description="Mac listener for mac-open requests.")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT,
                    help=f"TCP port to listen on (default: {DEFAULT_PORT})")
    ap.add_argument("--inbox", default=DEFAULT_INBOX,
                    help=f"Where to save received files (default: {DEFAULT_INBOX})")
    args = ap.parse_args()

    inbox = pathlib.Path(args.inbox).expanduser()
    inbox.mkdir(parents=True, exist_ok=True)

    HTTPServer.allow_reuse_address = True
    server = HTTPServer((HOST, args.port), make_handler(inbox))
    print(f"mac-open listener on http://{HOST}:{args.port}  (inbox: {inbox})", file=sys.stderr)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nshutting down", file=sys.stderr)
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
