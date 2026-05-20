#!/usr/bin/env python3
"""
mac_open.py — open a file or URL on the local Mac via mac_open_listener.

Reaches the Mac through the SSH reverse forward (-R 8765:127.0.0.1:8765) set
in connect_nvim.sh. The Dockerfile installs this script as /usr/local/bin/
mac-open inside the container; yazi and snacks-explorer call it as the opener
for PDF / HTML / image files.

Usage:
    mac-open <file-or-url>
    mac-open paper.pdf
    mac-open https://example.com

Env overrides:
    MAC_OPEN_HOST   default 127.0.0.1
    MAC_OPEN_PORT   default 8765
"""

from __future__ import annotations

import http.client
import os
import re
import sys
import urllib.parse

HOST = os.environ.get("MAC_OPEN_HOST", "127.0.0.1")
PORT = int(os.environ.get("MAC_OPEN_PORT", "8765"))
URL_RE = re.compile(r"^(https?|file)://", re.I)
TIMEOUT = 30  # seconds — covers large PDF uploads over SSH


def post(path: str, body: bytes, headers: dict[str, str]) -> None:
    conn = http.client.HTTPConnection(HOST, PORT, timeout=TIMEOUT)
    try:
        conn.request("POST", path, body=body, headers=headers)
        resp = conn.getresponse()
        if resp.status != 200:
            sys.exit(
                f"mac-open: server returned {resp.status}: "
                f"{resp.read().decode(errors='replace').strip()}"
            )
        resp.read()  # drain
    except (ConnectionRefusedError, OSError) as e:
        sys.exit(
            f"mac-open: cannot reach Mac listener at {HOST}:{PORT} ({e}). "
            "Is mac_open_listener.py running on the Mac, and is the SSH -R "
            "forward up (connect_nvim.sh adds -R 8765:127.0.0.1:8765)?"
        )
    finally:
        conn.close()


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        sys.exit("usage: mac-open <file|url>")
    target = argv[1]

    if URL_RE.match(target):
        post("/open-url", target.encode("utf-8"),
             {"Content-Type": "text/plain; charset=utf-8"})
        return 0

    if not os.path.isfile(target):
        sys.exit(f"mac-open: not a file: {target}")

    with open(target, "rb") as f:
        data = f.read()
    headers = {
        "Content-Type": "application/octet-stream",
        "Content-Length": str(len(data)),
        "X-Filename": urllib.parse.quote(os.path.basename(target)),
    }
    post("/open-file", data, headers)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
