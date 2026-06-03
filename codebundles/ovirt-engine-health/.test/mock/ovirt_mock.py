#!/usr/bin/env python3
"""Minimal mock of the oVirt engine REST API for testing ovirt-engine-health.

Serves just the endpoints the codebundle calls, with v4-shaped JSON:
  POST /ovirt-engine/sso/oauth/token        -> bearer token
  GET  /ovirt-engine/api                     -> product_info + summary
  GET  /ovirt-engine/api/hosts
  GET  /ovirt-engine/api/vms
  GET  /ovirt-engine/api/storagedomains
  GET  /ovirt-engine/api/clusters
  GET  /ovirt-engine/api/events              -> error/alert + a filtered warning
  GET  /ovirt-engine/api/vms/<id>/snapshots

No external dependencies (Python stdlib only). Timestamps are generated
relative to "now" so the bundle's time-window filters (events lookback, stale
snapshot age) behave realistically.

Scenario is chosen with the MOCK_SCENARIO env var:
  unhealthy (default) -> problems in every category, so the runbook raises
                         issues and the SLI score drops below 1.
  healthy             -> everything nominal, SLI score == 1, no issues.

Run:  MOCK_SCENARIO=unhealthy python3 ovirt_mock.py   # listens on :8080
"""

import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

PORT = int(os.environ.get("MOCK_PORT", "8080"))
SCENARIO = os.environ.get("MOCK_SCENARIO", "unhealthy").lower()

MS = 1000


def now_ms():
    return int(time.time() * MS)


def root_summary():
    return {
        "product_info": {"name": "oVirt", "version": {"full_version": "4.5.4-1.el8"}},
        "summary": {
            "vms": {"total": 3},
            "hosts": {"total": 3},
            "storage_domains": {"total": 2},
        },
    }


def clusters():
    return {"cluster": [{"name": "Default", "id": "cluster-1"}]}


def hosts():
    if SCENARIO == "healthy":
        host_list = [
            {"name": "host-01", "id": "host-1", "status": "up",
             "cluster": {"id": "cluster-1"}, "address": "10.0.0.11"},
            {"name": "host-02", "id": "host-2", "status": "up",
             "cluster": {"id": "cluster-1"}, "address": "10.0.0.12"},
        ]
    else:
        host_list = [
            {"name": "host-01", "id": "host-1", "status": "up",
             "cluster": {"id": "cluster-1"}, "address": "10.0.0.11"},
            {"name": "host-02", "id": "host-2", "status": "non_operational",
             "cluster": {"id": "cluster-1"}, "address": "10.0.0.12"},
            {"name": "host-03", "id": "host-3", "status": "maintenance",
             "cluster": {"id": "cluster-1"}, "address": "10.0.0.13"},
        ]
    return {"host": host_list}


def vms():
    if SCENARIO == "healthy":
        vm_list = [
            {"name": "web-01", "id": "vm-1", "status": "up",
             "cluster": {"id": "cluster-1"}, "host": {"id": "host-1"}},
            {"name": "batch-01", "id": "vm-2", "status": "down",
             "cluster": {"id": "cluster-1"}},
        ]
    else:
        vm_list = [
            {"name": "web-01", "id": "vm-1", "status": "up",
             "cluster": {"id": "cluster-1"}, "host": {"id": "host-1"}},
            {"name": "db-01", "id": "vm-2", "status": "paused",
             "cluster": {"id": "cluster-1"}, "host": {"id": "host-2"}},
            {"name": "batch-01", "id": "vm-3", "status": "down",
             "cluster": {"id": "cluster-1"}},
        ]
    return {"vm": vm_list}


def storagedomains():
    if SCENARIO == "healthy":
        sd_list = [
            {"name": "data", "id": "sd-1", "type": "data",
             "external_status": "ok", "available": 900 * 10**9, "used": 100 * 10**9},
            {"name": "iso", "id": "sd-2", "type": "iso",
             "external_status": "ok", "available": 40 * 10**9, "used": 10 * 10**9},
        ]
    else:
        sd_list = [
            # ~5% free -> below default 10% threshold
            {"name": "data", "id": "sd-1", "type": "data",
             "external_status": "ok", "available": 5 * 10**9, "used": 95 * 10**9},
            {"name": "iso", "id": "sd-2", "type": "iso",
             "external_status": "error", "available": 40 * 10**9, "used": 10 * 10**9},
        ]
    return {"storage_domain": sd_list}


def events():
    if SCENARIO == "healthy":
        ev_list = [
            {"id": "ev-100", "severity": "normal", "time": now_ms() - 120 * MS,
             "code": 30, "description": "VM web-01 started"},
        ]
    else:
        ev_list = [
            {"id": "ev-1", "severity": "error", "time": now_ms() - 300 * MS,
             "code": 119, "description": "VM db-01 has paused due to a storage I/O error",
             "vm": {"name": "db-01"}, "storage_domain": {"name": "data"}},
            {"id": "ev-2", "severity": "alert", "time": now_ms() - 600 * MS,
             "code": 9000, "description": "Host host-02 became non-operational",
             "host": {"name": "host-02"}},
            # a warning the client-side filter should drop
            {"id": "ev-3", "severity": "warning", "time": now_ms() - 90 * MS,
             "code": 50, "description": "High memory usage on host-01",
             "host": {"name": "host-01"}},
        ]
    return {"event": ev_list}


def snapshots(vm_id):
    active = {"id": f"{vm_id}-active", "snapshot_type": "active",
              "description": "Active VM", "date": now_ms()}
    if SCENARIO != "healthy" and vm_id == "vm-1":
        stale = {"id": f"{vm_id}-snap-1", "snapshot_type": "regular",
                 "description": "pre-upgrade", "date": now_ms() - 30 * 86400 * MS}
        return {"snapshot": [active, stale]}
    return {"snapshot": [active]}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):  # quiet by default
        pass

    def _send(self, payload, code=200):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        path = urlparse(self.path).path
        if path == "/ovirt-engine/sso/oauth/token":
            self._send({
                "access_token": "mock-token-abc123",
                "token_type": "bearer",
                "scope": "ovirt-app-api",
                "exp": "9999999999999",
            })
            return
        self._send({"error": f"unhandled POST {path}"}, 404)

    def do_GET(self):
        path = urlparse(self.path).path.rstrip("/")
        api = "/ovirt-engine/api"
        if path == api:
            self._send(root_summary())
        elif path == f"{api}/hosts":
            self._send(hosts())
        elif path == f"{api}/vms":
            self._send(vms())
        elif path == f"{api}/storagedomains":
            self._send(storagedomains())
        elif path == f"{api}/clusters":
            self._send(clusters())
        elif path == f"{api}/events":
            self._send(events())
        elif path.startswith(f"{api}/vms/") and path.endswith("/snapshots"):
            vm_id = path[len(f"{api}/vms/"):-len("/snapshots")]
            self._send(snapshots(vm_id))
        else:
            self._send({"error": f"unhandled GET {path}"}, 404)


def main():
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"oVirt mock listening on :{PORT} (scenario={SCENARIO})", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()


if __name__ == "__main__":
    main()
