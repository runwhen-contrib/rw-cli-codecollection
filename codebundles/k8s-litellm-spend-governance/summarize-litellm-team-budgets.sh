#!/usr/bin/env bash
# Calls /team/info for configured team ids; skips when LITELLM_TEAM_IDS is empty.
set -euo pipefail
set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=litellm-http-helpers.sh
source "${SCRIPT_DIR}/litellm-http-helpers.sh"

OUTPUT_FILE="team_budget_issues.json"

# Skip runtime init when there are no IDs to look up; avoids a pointless
# port-forward startup and master-key resolution.
IDS_PRECHECK="${LITELLM_TEAM_IDS:-}"
if [[ -n "${IDS_PRECHECK// /}" ]]; then
  litellm_init_runtime
fi
issues_json='[]'

IDS="${LITELLM_TEAM_IDS:-}"
if [[ -z "${IDS// /}" ]]; then
  echo '[]' >"$OUTPUT_FILE"
  echo "LITELLM_TEAM_IDS empty; wrote empty $OUTPUT_FILE"
  exit 0
fi

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

IFS=',' read -ra ARR <<<"$IDS"
for raw in "${ARR[@]}"; do
  tid=$(echo "$raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [[ -z "$tid" ]] && continue
  enc=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$tid")
  PATH_Q="/team/info?team_id=${enc}"
  HTTP_CODE=$(litellm_get_file "$PATH_Q" "$TMP" || echo "000")
  if [[ "$HTTP_CODE" == "403" ]]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Cannot read LiteLLM team info for \`${tid}\`" \
      --arg details "GET /team/info returned HTTP 403 (team routes may require admin)." \
      --argjson severity 2 \
      --arg next_steps "Use a master key or grant team read permissions." \
      '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
    continue
  fi
  if [[ "$HTTP_CODE" != "200" ]]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "team/info request failed for \`${tid}\`" \
      --arg details "HTTP ${HTTP_CODE}" \
      --argjson severity 2 \
      --arg next_steps "Verify team_id and proxy version." \
      '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
    continue
  fi
  RISK=$(python3 - "$TMP" <<'PY'
import json,sys
try:
    with open(sys.argv[1]) as f:
        o=json.load(f)
except Exception:
    print("false")
    raise SystemExit
info=o.get("team_info") if isinstance(o, dict) else None
base=info if isinstance(info, dict) else o
if not isinstance(base, dict):
    print("false")
    raise SystemExit
try:
    s=float(base.get("spend") or 0)
    m=float(base.get("max_budget") or 0)
except (TypeError, ValueError):
    print("false")
    raise SystemExit
print("true" if m > 0 and s >= m * 0.9 else "false")
PY
)
  if [[ "$RISK" == "true" ]]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Team \`${tid}\` near max budget on \`${LITELLM_SERVICE_NAME:-litellm}\`" \
      --arg details "Spend is at or above 90% of max_budget per /team/info." \
      --argjson severity 3 \
      --arg next_steps "Raise team budget, reduce traffic, or add models with lower cost." \
      '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
  fi
done

echo "$issues_json" | jq '.' >"$OUTPUT_FILE"
echo "Wrote $OUTPUT_FILE"
