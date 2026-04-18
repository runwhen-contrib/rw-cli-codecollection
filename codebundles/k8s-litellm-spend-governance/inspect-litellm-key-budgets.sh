#!/usr/bin/env bash
# Lists virtual keys and flags high spend vs max_budget or expired keys when /key/list is available.
set -euo pipefail
set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=litellm-http-helpers.sh
source "${SCRIPT_DIR}/litellm-http-helpers.sh"
litellm_init_runtime

OUTPUT_FILE="key_budget_issues.json"
issues_json='[]'
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

HTTP_CODE=$(litellm_get_file "/key/list" "$TMP" || echo "000")

if [[ "$HTTP_CODE" == "403" ]]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "LiteLLM key list not accessible for \`${LITELLM_SERVICE_NAME:-litellm}\`" \
    --arg details "GET /key/list returned HTTP 403 (admin route may require master key permissions)." \
    --argjson severity 2 \
    --arg next_steps "Use the configured master key or grant list/get key admin routes." \
    '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
  echo "$issues_json" >"$OUTPUT_FILE"
  exit 0
fi

if [[ "$HTTP_CODE" != "200" ]]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "LiteLLM key list unavailable for \`${LITELLM_SERVICE_NAME:-litellm}\`" \
    --arg details "GET /key/list returned HTTP ${HTTP_CODE}. This proxy build may use a different admin path." \
    --argjson severity 2 \
    --arg next_steps "Confirm proxy version and admin API paths; use UI or /user/info for scoped checks instead." \
    '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
  echo "$issues_json" >"$OUTPUT_FILE"
  exit 0
fi

NEAR=$(python3 - "$TMP" <<'PY'
import json,sys
try:
    with open(sys.argv[1]) as f:
        raw=json.load(f)
except Exception:
    print(0)
    raise SystemExit
items = raw.get("keys") if isinstance(raw, dict) else raw
if items is None:
    items = raw.get("data") if isinstance(raw, dict) else None
if items is None and isinstance(raw, list):
    items = raw
if not isinstance(items, list):
    items = []
near=0
for k in items:
    if not isinstance(k, dict):
        continue
    mb=k.get("max_budget")
    sp=k.get("spend") or 0
    try:
        mb=float(mb)
        sp=float(sp)
    except (TypeError, ValueError):
        continue
    if mb > 0 and sp >= 0.9 * mb:
        near += 1
print(near)
PY
)

EXPIRED=$(python3 - "$TMP" <<'PY'
import json,sys
from datetime import datetime, timezone
def parse_iso(s):
    if not s or not isinstance(s, str):
        return None
    s=s.replace("Z","+00:00")
    try:
        return datetime.fromisoformat(s)
    except ValueError:
        return None
try:
    with open(sys.argv[1]) as f:
        raw=json.load(f)
except Exception:
    print(0)
    raise SystemExit
items = raw.get("keys") if isinstance(raw, dict) else raw
if items is None:
    items = raw.get("data") if isinstance(raw, dict) else None
if items is None and isinstance(raw, list):
    items = raw
if not isinstance(items, list):
    items = []
now=datetime.now(timezone.utc)
exp=0
for k in items:
    if not isinstance(k, dict):
        continue
    dt=parse_iso(k.get("expires"))
    if dt and dt.tzinfo is None:
        dt=dt.replace(tzinfo=timezone.utc)
    if dt and dt < now:
        exp += 1
print(exp)
PY
)

echo "Key scan: near_budget=${NEAR} expired=${EXPIRED} (JSON parsing)"

if [[ "${NEAR}" =~ ^[0-9]+$ ]] && [[ "${NEAR}" -gt 0 ]]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Virtual keys near max budget on \`${LITELLM_SERVICE_NAME:-litellm}\`" \
    --arg details "${NEAR} key(s) have spend >= 90% of max_budget in /key/list response." \
    --argjson severity 3 \
    --arg next_steps "Rotate or raise budgets, split traffic across keys, or review team budgets." \
    '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
fi

if [[ "${EXPIRED}" =~ ^[0-9]+$ ]] && [[ "${EXPIRED}" -gt 0 ]]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Expired LiteLLM API keys detected for \`${LITELLM_SERVICE_NAME:-litellm}\`" \
    --arg details "${EXPIRED} key(s) show expires in the past." \
    --argjson severity 2 \
    --arg next_steps "Renew or replace expired keys before traffic fails authentication." \
    '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
fi

echo "$issues_json" | jq '.' >"$OUTPUT_FILE"
echo "Wrote $OUTPUT_FILE"
