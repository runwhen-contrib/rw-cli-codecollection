#!/usr/bin/env bash
set -euo pipefail
set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/prometheus-common.sh
source "${SCRIPT_DIR}/lib/prometheus-common.sh"

: "${PROMETHEUS_URL:?Must set PROMETHEUS_URL}"
: "${PGBOUNCER_JOB_LABEL:?Must set PGBOUNCER_JOB_LABEL}"
: "${EXPECTED_POOL_MODE:?Must set EXPECTED_POOL_MODE}"

OUTPUT_FILE="check_pool_mode_output.json"
issues_json='[]'

exp=$(echo "$EXPECTED_POOL_MODE" | tr '[:upper:]' '[:lower:]')

# Try label on pgbouncer_up series (some environments add static labels)
q="$(wrap_metric pgbouncer_up)"
raw=$(prometheus_instant_query "$q" || true)
observed=""

if [ -n "${raw:-}" ] && prometheus_query_status_ok "$raw"; then
  observed=$(echo "$raw" | jq -r '[.data.result[]?.metric | to_entries[] | select(.key|test("pool_?mode";"i")) | .value] | first // empty' | tr '[:upper:]' '[:lower:]')
fi

if [ -z "$observed" ] && [ -n "${PGBOUNCER_NAMESPACE:-}" ] && [ -n "${KUBECONFIG:-}" ]; then
  kb=$(kubectl_bin)
  ctx=$(kubectl_context_args)
  sel="${PGBOUNCER_POD_LABEL_SELECTOR:-app.kubernetes.io/name=pgbouncer-exporter}"
  pod=$($kb $ctx get pods -n "$PGBOUNCER_NAMESPACE" -l "$sel" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -n "$pod" ]; then
    ctr="${PGBOUNCER_PGBOUNCER_CONTAINER:-}"
    cargs=()
    if [ -n "$ctr" ]; then
      cargs=(-c "$ctr")
    fi
    ini=$($kb $ctx exec -n "$PGBOUNCER_NAMESPACE" "${cargs[@]}" "$pod" -- sh -c 'for f in /etc/pgbouncer/pgbouncer.ini /etc/pgbouncer.ini /opt/bitnami/pgbouncer/conf/pgbouncer.ini; do [ -f "$f" ] && cat "$f" && break; done' 2>/dev/null || true)
    observed=$(echo "$ini" | awk -F= '/^[[:space:]]*pool_mode/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print tolower($2); exit}')
  fi
fi

if [ -n "$observed" ]; then
  if [ "$observed" != "$exp" ]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "PgBouncer Pool Mode Drift" \
      --arg details "Observed pool_mode is '${observed}' but EXPECTED_POOL_MODE is '${exp}'." \
      --arg severity "3" \
      --arg next_steps "Align pgbouncer.ini pool_mode with application transaction patterns; redeploy if intentional change, or fix misconfiguration." \
      '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
  fi
else
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Pool Mode Could Not Be Verified" \
    --arg details "No pool_mode label found on metrics and kubectl could not read pgbouncer.ini (set PGBOUNCER_NAMESPACE, kubeconfig, and PGBOUNCER_POD_LABEL_SELECTOR to enable exec-based checks)." \
    --arg severity "2" \
    --arg next_steps "Add a static pool_mode label in scrape config, or provide namespace/pod selector for kubectl access to the PgBouncer configuration." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
fi

echo "$issues_json" > "$OUTPUT_FILE"
jq '.' "$OUTPUT_FILE"
