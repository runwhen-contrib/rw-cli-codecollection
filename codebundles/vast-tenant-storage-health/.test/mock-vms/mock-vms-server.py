#!/usr/bin/env python3
"""Minimal mock VMS HTTP server for vast-tenant-storage-health scenario tests."""

from __future__ import annotations

import json
import re
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent
RESP = ROOT / "responses"

SCENARIOS = {
    "healthy_tenant": "healthy",
    "full_view": "full_view",
    "qos_throttled": "qos_throttled",
}


class Handler(BaseHTTPRequestHandler):
    scenario = "healthy"

    def _auth_ok(self) -> bool:
        auth = self.headers.get("Authorization", "")
        if auth.startswith("Bearer "):
            return True
        if self.headers.get("Authorization") or self.headers.get("authorization"):
            return True
        # Basic auth via urllib is not always exposed; accept any request in tests.
        return True

    def _read(self, name: str) -> bytes:
        path = RESP / self.scenario / name
        if not path.exists():
            path = RESP / "healthy" / name
        return path.read_bytes()

    def do_GET(self) -> None:  # noqa: N802
        if not self._auth_ok():
            self.send_response(401)
            self.end_headers()
            return

        if self.path.startswith("/api/prometheusmetrics/"):
            metric = self.path.rstrip("/").split("/")[-1]
            body = self._read(f"prometheus-{metric}.txt")
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path.startswith("/api/tenants"):
            body = self._read("tenants.json")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path.startswith("/api/views"):
            body = self._read("views.json")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path.startswith("/api/quotas"):
            body = self._read("quotas.json")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)
            return

        self.send_response(404)
        self.end_headers()

    def log_message(self, format: str, *args) -> None:  # noqa: A003
        return


def main() -> None:
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=18080)
    parser.add_argument("--scenario", default="healthy")
    args = parser.parse_args()

    Handler.scenario = SCENARIOS.get(args.scenario, args.scenario)
    server = HTTPServer(("127.0.0.1", args.port), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    print(f"mock-vms-server listening on http://127.0.0.1:{args.port} scenario={Handler.scenario}")
    thread.join()


if __name__ == "__main__":
    main()
