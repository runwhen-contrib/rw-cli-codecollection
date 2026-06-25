#!/usr/bin/env bash
# Discover VAST tenants via /api/tenants/ for runbook tenant scoping.
set -euo pipefail
set -x

: "${VAST_VMS_ENDPOINT:?Must set VAST_VMS_ENDPOINT}"
: "${VAST_CLUSTER_NAME:?Must set VAST_CLUSTER_NAME}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vast-vms-helpers.sh
source "${SCRIPT_DIR}/vast-vms-helpers.sh"

vast_require_cmd curl
vast_require_cmd jq
vast_require_cmd python3

if ! vast_auth_configured; then
  echo "[]"
  exit 0
fi

response="$(vast_fetch_json_api "/tenants/")" || {
  echo "[]"
  exit 0
}

http_code="$(vast_fetch_http_code "$response")"
body="$(vast_fetch_body "$response")"

if [[ "$http_code" != "200" ]]; then
  echo "[]"
  exit 0
fi

printf '%s' "$body" | python3 - "$VAST_CLUSTER_NAME" <<'PY'
import json, sys

cluster_name = sys.argv[1]
raw = sys.stdin.read().strip()
if not raw:
    print("[]")
    raise SystemExit

data = json.loads(raw)
items = data if isinstance(data, list) else data.get("results", data.get("tenants", []))
if not isinstance(items, list):
    items = [data]

names = []
for item in items:
    name = item.get("name") or item.get("tenant_name")
    if not name:
        continue
    cluster = item.get("cluster_name") or item.get("cluster") or item.get("cluster_id")
    if cluster_name:
        if cluster and str(cluster) != cluster_name and cluster_name not in str(cluster):
            continue
    names.append(name)

print(json.dumps(sorted(set(names))))
PY
