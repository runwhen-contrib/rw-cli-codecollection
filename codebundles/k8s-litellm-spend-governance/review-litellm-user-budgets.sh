#!/usr/bin/env bash
# Calls /user/info for each LITELLM_USER_IDS entry; skips when empty.
set -euo pipefail
set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=litellm-http-helpers.sh
source "${SCRIPT_DIR}/litellm-http-helpers.sh"

OUTPUT_FILE="user_budget_issues.json"

# Skip runtime init when there are no IDs to look up; avoids a pointless
# port-forward startup and master-key resolution.
IDS_PRECHECK="${LITELLM_USER_IDS:-}"
if [[ -n "${IDS_PRECHECK// /}" ]]; then
  litellm_init_runtime
fi
issues_json='[]'

IDS="${LITELLM_USER_IDS:-}"
if [[ -z "${IDS// /}" ]]; then
  echo '[]' >"$OUTPUT_FILE"
  echo "LITELLM_USER_IDS empty; wrote empty $OUTPUT_FILE"
  exit 0
fi

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

IFS=',' read -ra ARR <<<"$IDS"
for raw in "${ARR[@]}"; do
  uid=$(echo "$raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [[ -z "$uid" ]] && continue
  enc=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$uid")
  PATH_Q="/user/info?user_id=${enc}"
  HTTP_CODE=$(litellm_get_file "$PATH_Q" "$TMP" || echo "000")
  if [[ "$HTTP_CODE" == "403" ]]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Cannot read LiteLLM user info for \`${uid}\`" \
      --arg details "GET /user/info returned HTTP 403." \
      --argjson severity 2 \
      --arg next_steps "Grant user read permissions or use a master key with user admin scope." \
      '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
    continue
  fi
  if [[ "$HTTP_CODE" != "200" ]]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "user/info request failed for \`${uid}\`" \
      --arg details "HTTP ${HTTP_CODE}" \
      --argjson severity 2 \
      --arg next_steps "Verify user_id exists and PROXY_BASE_URL is correct." \
      '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
    continue
  fi
  COOL=$(jq -r '..|.soft_budget_cooldown? // empty' "$TMP" | head -1)
  if [[ "$COOL" == "true" ]]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "User \`${uid}\` is in soft budget cooldown on \`${LITELLM_SERVICE_NAME:-litellm}\`" \
      --arg details "soft_budget_cooldown=true from /user/info." \
      --argjson severity 3 \
      --arg next_steps "Raise user budget, wait for cooldown, or shift traffic to another key/team." \
      '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
  fi
done

echo "$issues_json" | jq '.' >"$OUTPUT_FILE"
echo "Wrote $OUTPUT_FILE"
