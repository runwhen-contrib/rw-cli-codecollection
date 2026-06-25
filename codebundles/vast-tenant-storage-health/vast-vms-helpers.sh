#!/usr/bin/env bash
# Shared VAST VMS API helpers. Source from task scripts; do not execute directly.

vast_require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required command not found: $1" >&2
    exit 1
  }
}

vast_normalize_endpoint() {
  local ep="${VAST_VMS_ENDPOINT%/}"
  ep="${ep%/api}"
  echo "$ep"
}

vast_load_auth() {
  local creds_json="${vast_vms_credentials:-${VAST_VMS_CREDENTIALS:-}}"

  if [[ -n "$creds_json" ]]; then
    VAST_USERNAME="$(printf '%s' "$creds_json" | jq -r '.USERNAME // .username // empty')"
    VAST_PASSWORD="$(printf '%s' "$creds_json" | jq -r '.PASSWORD // .password // empty')"
    VAST_API_TOKEN="$(printf '%s' "$creds_json" | jq -r '.API_TOKEN // .api_token // empty')"
  fi

  VAST_USERNAME="${VAST_USERNAME:-${USERNAME:-}}"
  VAST_PASSWORD="${VAST_PASSWORD:-${PASSWORD:-}}"
  VAST_API_TOKEN="${VAST_API_TOKEN:-${API_TOKEN:-}}"
}

vast_auth_configured() {
  vast_load_auth
  if [[ -n "${VAST_API_TOKEN:-}" ]]; then
    return 0
  fi
  if [[ -n "${VAST_USERNAME:-}" && -n "${VAST_PASSWORD:-}" ]]; then
    return 0
  fi
  return 1
}

vast_curl_common_args() {
  local -n _out=$1
  _out=(-sS --max-time "${VAST_API_TIMEOUT:-90}" -k)
  if [[ -n "${VAST_API_TOKEN:-}" ]]; then
    _out+=(-H "Authorization: Bearer ${VAST_API_TOKEN}")
  elif [[ -n "${VAST_USERNAME:-}" && -n "${VAST_PASSWORD:-}" ]]; then
    _out+=(-u "${VAST_USERNAME}:${VAST_PASSWORD}")
  fi
  if [[ -n "${VAST_TENANT_NAME:-}" ]]; then
    _out+=(-H "X-Tenant-Name: ${VAST_TENANT_NAME}")
  fi
}

vast_api_url() {
  local path="$1"
  local endpoint
  endpoint="$(vast_normalize_endpoint)"
  if [[ "$path" != /* ]]; then
    path="/${path}"
  fi
  if [[ "$path" == /api/* ]]; then
    echo "${endpoint}${path}"
  else
    echo "${endpoint}/api${path}"
  fi
}

vast_http_request() {
  local method="${1:-GET}"
  local path="$2"
  local url
  url="$(vast_api_url "$path")"
  local -a curl_args=()
  vast_curl_common_args curl_args
  curl "${curl_args[@]}" -X "$method" -w $'\n%{http_code}' "$url"
}

vast_fetch_body() {
  local response="$1"
  printf '%s' "$response" | sed '$d'
}

vast_fetch_http_code() {
  local response="$1"
  printf '%s' "$response" | tail -n1
}

vast_fetch_prometheus_metrics() {
  local metrics_path="$1"
  vast_http_request GET "/api/prometheusmetrics/${metrics_path}"
}

vast_fetch_json_api() {
  local path="$1"
  vast_http_request GET "$path"
}

vast_add_api_error_issue() {
  local issues_json="$1"
  local title="$2"
  local details="$3"
  local severity="${4:-4}"
  local next_steps="${5:-Verify VAST_VMS_ENDPOINT, credentials, and network access to the VMS API.}"
  echo "$issues_json" | jq \
    --arg title "$title" \
    --arg details "$details" \
    --argjson severity "$severity" \
    --arg next_steps "$next_steps" \
    '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]'
}

vast_prom_metric_values() {
  local prom_text="$1"
  local metric_prefix="$2"
  local tenant="${VAST_TENANT_NAME:-}"
  local cluster="${VAST_CLUSTER_NAME:-}"
  python3 - "$metric_prefix" "$tenant" "$cluster" <<'PY'
import sys

metric_prefix, tenant, cluster = sys.argv[1:4]
text = sys.stdin.read()
values = []

def labels_match(labels: str) -> bool:
    if tenant:
        tenant_keys = (
            f'tenant_name="{tenant}"',
            f'tenant="{tenant}"',
            f'name="{tenant}"',
        )
        if not any(k in labels for k in tenant_keys):
            return False
    if cluster and f'cluster="{cluster}"' not in labels:
        return False
    return True

for line in text.splitlines():
    if not line or line.startswith("#"):
        continue
    if not line.startswith(metric_prefix):
        continue
    if "{" in line:
        name_part, rest = line.split("{", 1)
        labels_part, value_part = rest.rsplit("}", 1)
        if not name_part.startswith(metric_prefix):
            continue
        if not labels_match("{" + labels_part + "}"):
            continue
        try:
            values.append(float(value_part.strip()))
        except ValueError:
            pass
    else:
        parts = line.split()
        if len(parts) >= 2 and parts[0].startswith(metric_prefix):
            try:
                values.append(float(parts[-1]))
            except ValueError:
                pass

if values:
    print(max(values))
PY
}

vast_prom_metric_sum() {
  local prom_text="$1"
  local metric_prefix="$2"
  local tenant="${VAST_TENANT_NAME:-}"
  local cluster="${VAST_CLUSTER_NAME:-}"
  python3 - "$metric_prefix" "$tenant" "$cluster" <<'PY'
import sys

metric_prefix, tenant, cluster = sys.argv[1:4]
text = sys.stdin.read()
total = 0.0
found = False

def labels_match(labels: str) -> bool:
    if tenant:
        tenant_keys = (
            f'tenant_name="{tenant}"',
            f'tenant="{tenant}"',
            f'name="{tenant}"',
        )
        if not any(k in labels for k in tenant_keys):
            return False
    if cluster and f'cluster="{cluster}"' not in labels:
        return False
    return True

for line in text.splitlines():
    if not line or line.startswith("#"):
        continue
    if not line.startswith(metric_prefix):
        continue
    if "{" in line:
        name_part, rest = line.split("{", 1)
        labels_part, value_part = rest.rsplit("}", 1)
        if not name_part.startswith(metric_prefix):
            continue
        if not labels_match("{" + labels_part + "}"):
            continue
        try:
            total += float(value_part.strip())
            found = True
        except ValueError:
            pass

print(total if found else "")
PY
}

vast_percent_util() {
  local used="$1"
  local limit="$2"
  python3 - "$used" "$limit" <<'PY'
import sys
used, limit = sys.argv[1:3]
try:
    u = float(used)
    l = float(limit)
except ValueError:
    print("")
    raise SystemExit
if l <= 0:
    print("")
else:
    print(f"{(u / l) * 100:.2f}")
PY
}

vast_find_tenant_json() {
  local tenants_json="$1"
  local tenant_name="${VAST_TENANT_NAME:-}"
  local cluster_name="${VAST_CLUSTER_NAME:-}"
  python3 - "$tenant_name" "$cluster_name" <<'PY'
import json, sys

tenant_name, cluster_name = sys.argv[1:3]
raw = sys.stdin.read().strip()
if not raw:
    print("{}")
    raise SystemExit

data = json.loads(raw)
items = data if isinstance(data, list) else data.get("results", data.get("tenants", []))
if not isinstance(items, list):
    items = [data]

for item in items:
    name = item.get("name") or item.get("tenant_name")
    if name != tenant_name:
        continue
    if cluster_name:
        cluster = item.get("cluster_name") or item.get("cluster") or item.get("cluster_id")
        if cluster and str(cluster) != cluster_name and cluster_name not in str(cluster):
            continue
    print(json.dumps(item))
    raise SystemExit

print("{}")
PY
}
