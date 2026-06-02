#!/usr/bin/env bash
set -euo pipefail
# NOTE: `set -x` is intentionally NOT used (it leaks AZURE_DEVOPS_PAT into logs
# and bloats output). Set AZ_DEBUG=1 to opt in to tracing for local debugging.
[ "${AZ_DEBUG:-0}" = "1" ] && set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AZURE_DEVOPS_ORG
#   AZURE_DEVOPS_PROJECT
#
# OPTIONAL ENV VARS:
#   RW_LOOKBACK_WINDOW            - window for failed builds (default 24h)
#   MAX_FAILURES_TO_INVESTIGATE   - cap on the number of failed builds whose logs
#                                   are fetched (deep per-item work; default 10)
#
# This script (Phase 0 single-pass refactor):
#   1) Fetches the project's builds ONCE via the Build REST API (fetch_project_builds).
#   2) Derives the failed builds from that single dataset with jq -- with NO
#      per-pipeline `az pipelines runs list` calls (which timed out at 180s).
#   3) Fetches LOGS only for the failed builds actually flagged, CAPPED to
#      MAX_FAILURES_TO_INVESTIGATE (log fetching is genuine per-item work that
#      cannot be bulk-fetched).
#   4) Outputs results in JSON format.
# -----------------------------------------------------------------------------

: "${AZURE_DEVOPS_ORG:?Must set AZURE_DEVOPS_ORG}"
: "${AZURE_DEVOPS_PROJECT:?Must set AZURE_DEVOPS_PROJECT}"
: "${RW_LOOKBACK_WINDOW:=24h}"
: "${MAX_FAILURES_TO_INVESTIGATE:=10}"
: "${AUTH_TYPE:=service_principal}"
AZURE_DEVOPS_PAT="${AZURE_DEVOPS_PAT:-${azure_devops_pat:-}}"
export AZURE_DEVOPS_EXT_PAT="${AZURE_DEVOPS_PAT}"

source "$(dirname "$0")/_az_helpers.sh"

OUTPUT_FILE="pipeline_logs_issues.json"
BUILDS_FILE="builds_dataset.json"
TEMP_LOG_FILE="pipeline_log_temp.json"
issues_json='[]'

echo "Analyzing Azure DevOps Pipeline Logs..."
echo "Organization: $AZURE_DEVOPS_ORG"
echo "Project:      $AZURE_DEVOPS_PROJECT"

az devops configure --defaults project="$AZURE_DEVOPS_PROJECT" --output none
setup_azure_auth

# Single-pass: fetch the project's builds ONCE (shared/cached across tasks).
echo "Fetching project build dataset (single pass, window: ${RW_LOOKBACK_WINDOW})..."
if ! build_count=$(fetch_project_builds "$AZURE_DEVOPS_PROJECT" "$BUILDS_FILE" "$RW_LOOKBACK_WINDOW"); then
    echo "ERROR: Could not fetch builds for project."
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Failed to Fetch Builds" \
        --arg details "The Build REST API was unreachable or returned an error while fetching the project build dataset." \
        --arg severity "3" \
        --arg nextStep "Check if the project exists and you have Build (Read) permissions. Verify Azure DevOps API availability." \
        '. += [{
           "title": $title,
           "details": $details,
           "next_steps": $nextStep,
           "severity": ($severity | tonumber)
        }]')
    echo "$issues_json" > "$OUTPUT_FILE"
    exit 1
fi

# Derive failed builds from the single dataset (no per-pipeline calls). Newest
# first, and capped to MAX_FAILURES_TO_INVESTIGATE for the deep log fetch.
echo "$build_count builds fetched. Deriving failed builds..."
jq -c '
    def parsedate: (sub("\\.[0-9]+";"") | sub("(Z|[+-][0-9][0-9]:?[0-9][0-9])$";"")) + "Z" | (try fromdateiso8601 catch null);
    [ .[] | select(.result == "failed") ]
    | sort_by(.finishTime // .queueTime // "") | reverse
' "$BUILDS_FILE" > failed_builds.json
failed_count=$(jq 'length' failed_builds.json)
echo "Found $failed_count failed builds in window (investigating up to $MAX_FAILURES_TO_INVESTIGATE)."

investigate_count=$failed_count
if [ "$investigate_count" -gt "$MAX_FAILURES_TO_INVESTIGATE" ]; then
    investigate_count=$MAX_FAILURES_TO_INVESTIGATE
fi

for ((i=0; i<investigate_count; i++)); do
    run_json=$(jq -c ".[${i}]" failed_builds.json)

    run_id=$(echo "$run_json" | jq -r '.id')
    pipeline_id=$(echo "$run_json" | jq -r '.definition.id')
    pipeline_name=$(echo "$run_json" | jq -r '.definition.name // .buildNumber // "Unknown Pipeline"')
    web_url=$(echo "$run_json" | jq -r '._links.web.href // .url // ""')
    branch=$(echo "$run_json" | jq -r '.sourceBranch // "unknown"' | sed 's|refs/heads/||')

    echo "  Investigating failed build: $pipeline_name (Build ID: $run_id, Branch: $branch)"

    # Get all logs for the run (deep per-item work; capped above).
    if ! all_logs=$(az devops invoke --org "https://dev.azure.com/$AZURE_DEVOPS_ORG" --area build --resource logs --route-parameters project="$AZURE_DEVOPS_PROJECT" buildId="$run_id" --api-version=7.0 --output json 2>logs_err.log); then
        err_msg=$(cat logs_err.log)
        rm -f logs_err.log
        issues_json=$(echo "$issues_json" | jq \
            --arg title "Failed to Get Logs for Run $run_id in Pipeline $pipeline_name" \
            --arg details "$err_msg" \
            --arg severity "3" \
            --arg nextStep "Check if you have sufficient permissions to view pipeline logs." \
            --arg resource_url "$web_url" \
            '. += [{
               "title": $title,
               "details": $details,
               "next_steps": $nextStep,
               "severity": ($severity | tonumber),
               "resource_url": $resource_url
             }]')
        continue
    fi
    rm -f logs_err.log

    echo "$all_logs" > all_logs.json

    # Get log with highest line count
    if ! log_info=$(jq -c '(.value // .logs // [])[] | {id: .id, lineCount: .lineCount}' all_logs.json | sort -r -k2,2 | head -1); then
        echo "    Failed to find logs with line count information"
        rm -f all_logs.json
        continue
    fi
    log_id=$(echo "$log_info" | jq -r '.id')
    if [ -z "$log_id" ] || [ "$log_id" = "null" ]; then
        echo "    No log id available for build $run_id, skipping..."
        rm -f all_logs.json
        continue
    fi
    echo "    Selected log ID with highest line count: $log_id"

    # Get detailed log content for the selected log
    if ! log_content=$(az devops invoke --org "https://dev.azure.com/$AZURE_DEVOPS_ORG" --area build --resource logs --route-parameters project="$AZURE_DEVOPS_PROJECT" buildId="$run_id" logId="$log_id" --api-version=7.0 --output json --only-show-errors 2>log_content_err.log); then
        echo "      Failed to get log content for log ID $log_id, skipping..."
        rm -f all_logs.json log_content_err.log
        continue
    fi
    rm -f log_content_err.log

    echo "$log_content" > "$TEMP_LOG_FILE"
    log_details=$(jq -r '.value | join("\n")' "$TEMP_LOG_FILE")

    PROJ_ENC=$(ado_urlencode "$AZURE_DEVOPS_PROJECT")
    error_log_url="https://dev.azure.com/$AZURE_DEVOPS_ORG/$PROJ_ENC/_apis/build/builds/$run_id/logs/$log_id"

    rm -f "$TEMP_LOG_FILE" all_logs.json

    issues_json=$(echo "$issues_json" | jq \
        --arg title "Failed Pipeline Run: \`$pipeline_name\` (Branch: \`$branch\`)" \
        --arg details "$log_details" \
        --arg severity "3" \
        --arg nextStep "Review pipeline configuration for \`$pipeline_name\` in project \`$AZURE_DEVOPS_PROJECT\`. Check branch \`$branch\` for recent changes that might have caused the failure." \
        --arg resource_url "$error_log_url" \
        '. += [{
           "title": $title,
           "details": $details,
           "next_steps": $nextStep,
           "severity": ($severity | tonumber),
           "resource_url": $resource_url
         }]')
done

# If there were more failures than we investigated, note the cap (report-only).
if [ "$failed_count" -gt "$investigate_count" ]; then
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Additional Failed Pipeline Runs Not Investigated" \
        --arg details "Found $failed_count failed builds in the last ${RW_LOOKBACK_WINDOW}; logs were fetched for the $investigate_count most recent (MAX_FAILURES_TO_INVESTIGATE=$MAX_FAILURES_TO_INVESTIGATE). Raise MAX_FAILURES_TO_INVESTIGATE to investigate more." \
        --arg severity "4" \
        --arg nextStep "Review the most recent failures first. Increase MAX_FAILURES_TO_INVESTIGATE if deeper coverage is required." \
        --arg resource_url "https://dev.azure.com/$AZURE_DEVOPS_ORG/$(ado_urlencode "$AZURE_DEVOPS_PROJECT")/_build" \
        '. += [{
           "title": $title,
           "details": $details,
           "next_steps": $nextStep,
           "severity": ($severity | tonumber),
           "resource_url": $resource_url
         }]')
fi

rm -f failed_builds.json

# Write final JSON
echo "$issues_json" > "$OUTPUT_FILE"
echo "Azure DevOps pipeline log analysis completed. Saved results to $OUTPUT_FILE"
