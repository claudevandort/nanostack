#!/usr/bin/env python3
"""Atlas dev server.

Extends ``http.server.SimpleHTTPRequestHandler`` with a single PUT
endpoint at ``/plan.overlay.json`` so the interactive plan board can
persist annotations back to disk. Local-only by design: bound to
127.0.0.1 and refuses PUTs to any other path.

    python3 tools/atlas/serve.py                # default 127.0.0.1:8765
    python3 tools/atlas/serve.py --port 9000

Stop with Ctrl-C.
"""

from __future__ import annotations

import argparse
import http.server
import json
import os
import socketserver
import sys
from pathlib import Path

ATLAS_DIR = Path(__file__).resolve().parent
ALLOWED_PUT = "/plan.overlay.json"
MAX_BODY = 64 * 1024


class AtlasHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(ATLAS_DIR), **kwargs)

    # Slightly quieter log; SimpleHTTPRequestHandler is noisy.
    def log_message(self, fmt, *args):  # type: ignore[override]
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def do_PUT(self) -> None:  # noqa: N802 (stdlib convention)
        if self.path != ALLOWED_PUT:
            self._respond_json(403, {"error": "only /plan.overlay.json accepts PUT"})
            return
        length_str = self.headers.get("Content-Length")
        try:
            length = int(length_str or "0")
        except ValueError:
            self._respond_json(400, {"error": "invalid Content-Length"})
            return
        if length <= 0:
            self._respond_json(400, {"error": "empty body"})
            return
        if length > MAX_BODY:
            self._respond_json(413, {"error": f"body exceeds {MAX_BODY} bytes"})
            return
        body = self.rfile.read(length)
        try:
            parsed = json.loads(body)
        except json.JSONDecodeError as exc:
            self._respond_json(400, {"error": f"malformed JSON: {exc.msg}"})
            return
        if not isinstance(parsed, dict):
            self._respond_json(400, {"error": "top-level JSON must be an object"})
            return
        # Atomic write — tmpfile + rename.
        target = ATLAS_DIR / "plan.overlay.json"
        tmp = target.with_suffix(".json.tmp")
        try:
            tmp.write_text(json.dumps(parsed, indent=2) + "\n", encoding="utf-8")
            os.replace(tmp, target)
        except OSError as exc:
            self._respond_json(500, {"error": f"write failed: {exc}"})
            return
        self._respond_json(200, {"ok": True, "bytes": len(body)})

    def _respond_json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description="Atlas dev server (GET + PUT for plan.overlay.json).")
    ap.add_argument("--port", type=int, default=8765)
    args = ap.parse_args(argv)
    addr = ("127.0.0.1", args.port)
    with socketserver.ThreadingTCPServer(addr, AtlasHandler) as srv:
        srv.allow_reuse_address = True
        url = f"http://{addr[0]}:{addr[1]}/"
        sys.stderr.write(f"Atlas server at {url} (writeable; PUT {ALLOWED_PUT}). Ctrl-C to stop.\n")
        try:
            srv.serve_forever()
        except KeyboardInterrupt:
            sys.stderr.write("\nshutting down\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
