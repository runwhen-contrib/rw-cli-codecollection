#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Check for Failed GCP API Gateway Operations
#
# Lists API Gateway operations in the region(s) within OPERATIONS_LOOKBACK and
# flags any operation in a FAILED state, indicating a provisioning or update
# that did not take effect (sev 3).
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID
#   OPERATIONS_LOOKBACK (default 24h)
#
# INPUTS:
#   apigateway_inventory.json - written by discover_apigateway.sh (regions)
#
# OUTPUTS:
#   operations_issues.json
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${OPERATIONS_LOOKBACK:=24h}"
. ./apigateway_common.sh

ISSUES_FILE="operations_issues.json"
issues='[]'

echo "Checking for failed API Gateway operations in project: $GCP_PROJECT_ID"

inventory=$(apigw_load_inventory)
regions_list=$(echo "$inventory" | jq -r '.regions[]' 2>/dev/null)

# If explicit region(s) provided, prefer them.
if [ -n "$GCP_REGIONS" ]; then
    regions_list=$(echo "$GCP_REGIONS" | tr ',' '\n')
fi
[ -z "$regions_list" ] && regions_list="global"

# An auth failure means this check could not be measured -- not that the
# gateway is unhealthy. Reporting it as an issue would score the dimension
# as failing; exit non-zero instead so the task fails loudly.
if ! access_token=$(apigw_get_access_token); then
    echo "ERROR: could not obtain a GCP access token for the API Gateway operations API." >&2
    echo "Cannot query it; refusing to report a result for a check that never ran." >&2
    exit 1
fi

now_epoch=$(date +%s)
# OPERATIONS_LOOKBACK is like 24h
back_secs=$(echo "$OPERATIONS_LOOKBACK" | sed -E 's/([0-9]+)h$/\1*3600/; s/([0-9]+)m$/\1*60/; s/([0-9]+)s$/\1/' | bc 2>/dev/null || echo "86400")
[ -z "$back_secs" ] && back_secs=86400
cutoff_epoch=$(( now_epoch - back_secs ))

while IFS= read -r region; do
    [ -z "$region" ] && continue
    url="https://apigateway.googleapis.com/v1/projects/$GCP_PROJECT_ID/locations/$region/operations"
    resp=$(curl -s -H "Authorization: Bearer $access_token" "$url" -o /tmp/apigw_ops_$$.json -w "%{http_code}" 2>/dev/null || echo "000")
    if [ "$resp" != "200" ]; then
        continue
    fi
    # Process substitution, not `... | while` -- piping would run the body in a
    # subshell and discard every `issues=` accumulation below.
    while IFS= read -r op; do
        create_time=$(echo "$op" | jq -r '.metadata.createTime // ""')
        done_flag=$(echo "$op" | jq -r '.done // false')
        has_error=$(echo "$op" | jq -r 'has("error")')
        created_epoch=0
        if [ -n "$create_time" ]; then
            created_epoch=$(apigw_iso8601_to_epoch "$create_time")
        fi
        if [ "$created_epoch" -lt "$cutoff_epoch" ]; then
            # older than lookback, skip
            continue
        fi
        if [ "$done_flag" = "true" ] && [ "$has_error" = "true" ]; then
            op_name=$(echo "$op" | jq -r '.name')
            err_msg=$(echo "$op" | jq -r '.error.message // ""')
            issue=$(jq -n \
                --arg title "API Gateway operation \`$op_name\` FAILED" \
                --arg details "A GCP API Gateway operation in region '$region' of project '$GCP_PROJECT_ID' failed at $create_time: $err_msg. This indicates a provisioning or update that did not take effect." \
                --arg severity "3" \
                --arg expected "API Gateway operations should complete successfully" \
                --arg actual "Operation failed: $err_msg" \
                --arg next_steps "Inspect the failed operation and retry the provisioning or update that triggered it. Review the ApiConfig and Gateway configuration for errors. Auto-detected suggested next step: analyze API Gateway health." \
                '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
            issues=$(echo "$issues" | jq --argjson i "$issue" '. += [$i]')
        fi
    done < <(jq -c '.operations[]? // empty' /tmp/apigw_ops_$$.json)
    rm -f /tmp/apigw_ops_$$.json
done < <(printf '%s\n' "$regions_list")

apigw_write_issues "$ISSUES_FILE" "$issues"

echo "Operations check complete. Found $(jq length "$ISSUES_FILE") issue(s)."
