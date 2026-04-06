#!/usr/bin/env bash
set -euo pipefail
set -x
# Confirms pool_mode label on database metrics matches EXPECTED_POOL_MODE.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/prom-common.sh"

: "${PROMETHEUS_URL:?}"
: "${PGBOUNCER_JOB_LABEL:?}"
: "${EXPECTED_POOL_MODE:?Must set EXPECTED_POOL_MODE (transaction|session|statement)}"

OUTPUT_FILE="pool_mode_analysis.json"
issues_json='[]'

INNER="$(prom_label_inner)"
Q="pgbouncer_databases_current_connections{${INNER}}"

echo "Validating pool_mode vs EXPECTED_POOL_MODE=${EXPECTED_POOL_MODE}"

if ! resp="$(prom_instant_query "$Q")"; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Prometheus Query Failed for Pool Mode" \
    --arg details "curl error" \
    --arg severity "4" \
    --arg next_steps "Verify Prometheus URL." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

if ! prom_check_api "$resp"; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Prometheus API Error (pool mode)" \
    --arg details "$(echo "$resp" | head -c 400)" \
    --arg severity "3" \
    --arg next_steps "Ensure pgbouncer_databases_current_connections exposes pool_mode label (prometheus-community exporter)." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

modes=$(echo "$resp" | jq -r '[.data.result[]?.metric.pool_mode // empty] | unique | .[]' | sort -u)

if [[ -z "$modes" ]]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Pool Mode Label Missing on Metrics" \
    --arg details "No pool_mode label found on pgbouncer_databases_current_connections. Cannot validate EXPECTED_POOL_MODE=${EXPECTED_POOL_MODE} from metrics alone." \
    --arg severity "2" \
    --arg next_steps "Upgrade exporter or use kubectl exec SHOW CONFIG; as a cross-check if kubeconfig is configured." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
else
  while IFS= read -r m; do
    [[ -z "$m" ]] && continue
    if [[ "$m" != "$EXPECTED_POOL_MODE" ]]; then
      issues_json=$(echo "$issues_json" | jq \
        --arg title "Unexpected PgBouncer Pool Mode (\`found=${m}\`)" \
        --arg details "Observed pool_mode=${m}, expected ${EXPECTED_POOL_MODE} per configuration." \
        --arg severity "2" \
        --arg next_steps "Align PgBouncer pool_mode with application assumptions (transaction vs session vs statement); update CRD/ConfigMap and roll PgBouncer if intentional drift." \
        '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
    fi
  done <<< "$modes"
fi

echo "$issues_json" > "$OUTPUT_FILE"
jq . "$OUTPUT_FILE"
