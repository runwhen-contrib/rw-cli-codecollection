#!/usr/bin/env bash
set -uo pipefail
# NOTE: `set -x` is intentionally NOT used (it leaks AZURE_DEVOPS_PAT into logs
# and bloats output). Set AZ_DEBUG=1 to opt in to tracing for local debugging.
[ "${AZ_DEBUG:-0}" = "1" ] && set -x
# -----------------------------------------------------------------------------
# Organization-health SLI scoring (cheap, hourly).
#
# Computes FOUR {0,1} sub-scores from LIGHTWEIGHT signals only -- explicitly NOT
# the full 168-project / 473-pool deep scans the runbook performs. Convention:
# score 0 ONLY for what we measure and confirm bad; score 1 for what we cannot
# measure.
#
#   platform_incident_ok   no active Azure DevOps platform incident (Status API
#                          overall health is healthy/advisory, not degraded/
#                          unhealthy). Unreachable/unparseable => 1.
#   pool_capacity_ok       queue-derived: no self-hosted pool has a build queued
#                          (notStarted job request) aging past QUEUE_AGING_
#                          THRESHOLD_MIN. A scaled-to-zero elastic/ephemeral pool
#                          with NO aging queue is NOT penalised (consistent with
#                          the landed agent-pool fix). Pool probing is bounded by
#                          ORG_POOL_PROBE_LIMIT to stay cheap at hourly cadence.
#   license_headroom_ok    license utilization (assigned/total) <= LICENSE_
#                          UTILIZATION_THRESHOLD for any billed license whose
#                          total is measurable. Derived from the single
#                          userentitlementsummary call (NOT the full paginated
#                          user scan). Unmeasurable => 1.
#   org_policy_ok          required org security policy present (at least one
#                          Administrator security group). Confirmed-absent => 0;
#                          unmeasurable => 1.
#
# License cost / inactive-user findings are intentionally NOT scored here -- they
# stay report-only in the daily deep runbook.
#
# REQUIRED ENV VARS:
#   AZURE_DEVOPS_ORG
#
# OPTIONAL ENV VARS:
#   LICENSE_UTILIZATION_THRESHOLD  license util % cap (default 90)
#   QUEUE_AGING_THRESHOLD_MIN      queued-job aging minutes (default 30)
#   ORG_POOL_PROBE_LIMIT           max self-hosted pools queue-probed (default 150)
#   AGENT_FETCH_PARALLELISM        parallel job-request probes (default 20)
#
# TEST HOOKS (skip the corresponding live call when set):
#   SLI_INCIDENT_HEALTH        portal numeric (1 unhealthy,2 degraded,3 advisory,4 healthy)
#                              or API string (healthy, degraded, ...)
#   SLI_POOL_AGING_COUNT       integer count of pools with aging queued work
#   SLI_LICENSE_SUMMARY_FILE   path to a userentitlementsummary JSON
#   SLI_SECURITY_GROUPS_FILE   path to a security-group-list JSON array
#
# Writes sli_org_health_score.json and echoes it to stdout.
# -----------------------------------------------------------------------------

: "${AZURE_DEVOPS_ORG:?Must set AZURE_DEVOPS_ORG}"
: "${LICENSE_UTILIZATION_THRESHOLD:=90}"
: "${QUEUE_AGING_THRESHOLD_MIN:=30}"
: "${ORG_POOL_PROBE_LIMIT:=150}"
: "${AUTH_TYPE:=service_principal}"
AZURE_DEVOPS_PAT="${AZURE_DEVOPS_PAT:-${azure_devops_pat:-}}"
export AZURE_DEVOPS_EXT_PAT="${AZURE_DEVOPS_PAT}"

source "$(dirname "$0")/_az_helpers.sh"

OUTPUT_FILE="sli_org_health_score.json"
ORG_URL="https://dev.azure.com/$AZURE_DEVOPS_ORG"

# Decide whether any live call is needed (all four hooks provided => pure test).
NEED_AUTH=0
[ -z "${SLI_POOL_AGING_COUNT:-}" ] && NEED_AUTH=1
[ -z "${SLI_LICENSE_SUMMARY_FILE:-}" ] && NEED_AUTH=1
[ -z "${SLI_SECURITY_GROUPS_FILE:-}" ] && NEED_AUTH=1
if [ "$NEED_AUTH" -eq 1 ]; then
    setup_azure_auth >&2 || true
fi

# ===========================================================================
# 1. platform_incident_ok (Status API; portal HTML uses 4=healthy, not 1=healthy)
# ===========================================================================
ado_platform_incident_probe
platform_incident_ok="${ADO_PLATFORM_INCIDENT_OK:-1}"
incident_health="${ADO_PLATFORM_HEALTH:-unknown}"
incident_message="${ADO_PLATFORM_STATUS_MESSAGE:-}"

# ===========================================================================
# 2. pool_capacity_ok (queue-derived, bounded)
# ===========================================================================
pool_aging=0
pools_probed=0
if [ -n "${SLI_POOL_AGING_COUNT:-}" ]; then
    pool_aging="${SLI_POOL_AGING_COUNT}"
else
    if pools=$(az pipelines pool list --org "$ORG_URL" --output json 2>/dev/null) \
            && printf '%s' "$pools" | jq -e 'type == "array"' >/dev/null 2>&1; then
        # Self-hosted pool ids only, capped to keep the hourly probe cheap.
        nonhosted_ids=$(printf '%s' "$pools" \
            | jq -r '.[] | select((.isHosted // false) == false) | .id' \
            | head -n "$ORG_POOL_PROBE_LIMIT")
        if [ -n "$nonhosted_ids" ]; then
            probe_dir=$(mktemp -d sli_orgcap.XXXXXX)
            fetch_pool_job_requests_parallel "$nonhosted_ids" "$probe_dir" >&2 || true
            while IFS= read -r pid; do
                [ -z "$pid" ] && continue
                pools_probed=$((pools_probed + 1))
                eval "$(pool_queue_pressure "$(load_pool_job_requests_json "$probe_dir/jobreqs_${pid}.json")" "$QUEUE_AGING_THRESHOLD_MIN")"
                if [ "${QUEUED_AGING:-0}" -gt 0 ]; then
                    pool_aging=$((pool_aging + 1))
                fi
            done <<< "$nonhosted_ids"
            rm -rf "$probe_dir"
        fi
    fi
fi
if [ "$pool_aging" -gt 0 ] 2>/dev/null; then
    pool_capacity_ok=0
else
    pool_capacity_ok=1
fi

# ===========================================================================
# 3. license_headroom_ok (single userentitlementsummary call)
# ===========================================================================
license_summary=""
if [ -n "${SLI_LICENSE_SUMMARY_FILE:-}" ] && [ -s "${SLI_LICENSE_SUMMARY_FILE}" ]; then
    license_summary=$(cat "${SLI_LICENSE_SUMMARY_FILE}")
else
    license_summary=$(az devops invoke --area MemberEntitlementManagement \
        --resource UserEntitlementSummary --org "$ORG_URL" \
        --api-version 7.1-preview --output json 2>/dev/null || echo "")
    if ! printf '%s' "$license_summary" | jq -e '.licenses' >/dev/null 2>&1; then
        hdr=$(ado_auth_header)
        if [ -n "$hdr" ]; then
            license_summary=$(curl -s --max-time 20 -H "Authorization: $hdr" \
                "https://vsaex.dev.azure.com/$AZURE_DEVOPS_ORG/_apis/userentitlementsummary?api-version=7.1-preview&select=Licenses" \
                2>/dev/null || echo "")
        fi
    fi
fi
# Max utilization across billed licenses whose total is measurable (>0). Stakeholder
# (free) and unlimited/0-total entries are skipped: cannot measure => no penalty.
license_eval=$(printf '%s' "$license_summary" | jq -c \
    --argjson thr "$LICENSE_UTILIZATION_THRESHOLD" '
    (.licenses // []) as $lics
    | [ $lics[]
        | (.total // 0) as $t
        | (.assigned // 0) as $a
        | (.licenseName // .accountLicenseType // "license") as $name
        | select(($t | type) == "number" and $t > 0 and ($name | ascii_downcase | test("stakeholder") | not))
        | {name:$name, total:$t, assigned:$a, util: (($a * 100) / $t)} ]
    | if length == 0 then {ok:1, max:-1, detail:"unmeasurable"}
      else (max_by(.util)) as $m
        | {ok:(if $m.util >= $thr then 0 else 1 end), max:(($m.util * 10 | floor) / 10), detail:"\($m.name):\($m.assigned)/\($m.total)"}
      end
    ' 2>/dev/null || echo '{"ok":1,"max":-1,"detail":"parse-error"}')
license_headroom_ok=$(printf '%s' "$license_eval" | jq -r '.ok')
license_max_util=$(printf '%s' "$license_eval" | jq -r '.max')
license_detail=$(printf '%s' "$license_eval" | jq -r '.detail')
case "$license_headroom_ok" in 0|1) ;; *) license_headroom_ok=1 ;; esac

# ===========================================================================
# 4. org_policy_ok (at least one Administrator security group present)
# ===========================================================================
sec_groups=""
if [ -n "${SLI_SECURITY_GROUPS_FILE:-}" ] && [ -s "${SLI_SECURITY_GROUPS_FILE}" ]; then
    sec_groups=$(cat "${SLI_SECURITY_GROUPS_FILE}")
else
    sec_groups=$(ado_security_groups_json)
fi
# `az devops security group list` returns a top-level array; the REST graph API
# returns {graphGroups:[...]} or {value:[...]}. Normalise all three shapes.
admin_groups=-1
groups_arr=$(printf '%s' "$sec_groups" | jq -c 'if type == "array" then . elif type == "object" then (.graphGroups // .value // []) else [] end' 2>/dev/null || echo "")
if [ -n "$groups_arr" ] && printf '%s' "$groups_arr" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1; then
    admin_groups=$(printf '%s' "$groups_arr" | jq '[.[] | select((.displayName // .principalName // "") | test("Administrator"; "i"))] | length' 2>/dev/null || echo -1)
fi
# Confirmed-absent (list readable, zero admin groups) => 0; unmeasurable => 1.
if [ "$admin_groups" = "0" ]; then
    org_policy_ok=0
else
    org_policy_ok=1
fi

# ===========================================================================
# Assemble result
# ===========================================================================
result=$(jq -n \
    --argjson platform "$platform_incident_ok" \
    --argjson pool "$pool_capacity_ok" \
    --argjson license "$license_headroom_ok" \
    --argjson policy "$org_policy_ok" \
    --arg incident_health "${incident_health:-unknown}" \
    --arg incident_message "${incident_message:-}" \
    --argjson pools_probed "$pools_probed" \
    --argjson pool_aging "$pool_aging" \
    --arg license_max_util "$license_max_util" \
    --arg license_detail "$license_detail" \
    --argjson license_thr "$LICENSE_UTILIZATION_THRESHOLD" \
    --arg admin_groups "$admin_groups" \
    '{
       platform_incident_ok: $platform,
       pool_capacity_ok: $pool,
       license_headroom_ok: $license,
       org_policy_ok: $policy,
       details: {
         incident_health: $incident_health,
         incident_message: $incident_message,
         pools_probed: $pools_probed,
         pools_with_aging_queue: $pool_aging,
         license_max_utilization_pct: $license_max_util,
         license_headroom_detail: $license_detail,
         license_utilization_threshold_pct: $license_thr,
         admin_security_groups: $admin_groups
       }
     }')

echo "$result" > "$OUTPUT_FILE"
echo "$result"
