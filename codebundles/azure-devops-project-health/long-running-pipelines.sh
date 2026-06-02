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
#   DURATION_THRESHOLD   - Threshold in minutes or hours (e.g., "60m" or "2h") for long-running pipelines (default: "60m")
#   RW_LOOKBACK_WINDOW   - window for completed builds considered (default 24h)
#
# This script (Phase 0 single-pass refactor):
#   1) Fetches the project's builds ONCE via the Build REST API (fetch_project_builds).
#   2) Derives, with jq, in-flight builds running longer than the threshold AND
#      completed builds whose run time exceeded it -- with NO per-pipeline API
#      calls (previously it looped over every pipeline issuing
#      `az pipelines runs list --pipeline-id <id>`, which timed out at 180s).
#   3) Outputs results in JSON format.
# -----------------------------------------------------------------------------

: "${AZURE_DEVOPS_ORG:?Must set AZURE_DEVOPS_ORG}"
: "${AZURE_DEVOPS_PROJECT:?Must set AZURE_DEVOPS_PROJECT}"
: "${DURATION_THRESHOLD:=60m}"
: "${RW_LOOKBACK_WINDOW:=24h}"
: "${AUTH_TYPE:=service_principal}"
AZURE_DEVOPS_PAT="${AZURE_DEVOPS_PAT:-${azure_devops_pat:-}}"
export AZURE_DEVOPS_EXT_PAT="${AZURE_DEVOPS_PAT}"

source "$(dirname "$0")/_az_helpers.sh"

OUTPUT_FILE="long_running_pipelines.json"
BUILDS_FILE="builds_dataset.json"
issues_json='[]'

# Convert duration threshold to minutes
convert_to_minutes() {
    local threshold=$1
    local number=$(echo "$threshold" | sed -E 's/[^0-9]//g')
    local unit=$(echo "$threshold" | sed -E 's/[0-9]//g')

    case $unit in
        m|min|mins)
            echo $number
            ;;
        h|hr|hrs|hour|hours)
            echo $((number * 60))
            ;;
        *)
            echo "Invalid duration format. Use format like '60m' or '2h'" >&2
            exit 1
            ;;
    esac
}

THRESHOLD_MINUTES=$(convert_to_minutes "$DURATION_THRESHOLD")

echo "Analyzing Azure DevOps Pipeline Durations..."
echo "Organization: $AZURE_DEVOPS_ORG"
echo "Project:      $AZURE_DEVOPS_PROJECT"
echo "Threshold:    $THRESHOLD_MINUTES minutes"

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
echo "Fetched $build_count builds. Deriving long-running pipelines..."

NOW_EPOCH=$(date +%s)

# Derive both in-flight (inProgress) and completed long-running builds from the
# single dataset in one jq pass. Severities preserved: in-flight = sev 3,
# completed-over-threshold = sev 2.
issues_json=$(jq \
    --argjson now "$NOW_EPOCH" \
    --argjson thr "$THRESHOLD_MINUTES" \
    --arg threshold_label "$THRESHOLD_MINUTES" \
    --arg project "$AZURE_DEVOPS_PROJECT" '
    def parsedate: (sub("\\.[0-9]+";"") | sub("(Z|[+-][0-9][0-9]:?[0-9][0-9])$";"")) + "Z" | (try fromdateiso8601 catch null);
    def fmt(m): if m >= 1440 then "\(m/1440|floor)d \((m%1440)/60|floor)h \(m%60)m"
                elif m >= 60 then "\(m/60|floor)h \(m%60)m"
                else "\(m)m" end;
    def common:
      (.definition.name // "Unknown Pipeline") as $pname
      | ((.sourceBranch // "unknown") | sub("refs/heads/";"")) as $branch
      | {pname:$pname, branch:$branch, url:(._links.web.href // .url // ""),
         pid:((.definition.id // "") | tostring), rid:((.id // "") | tostring)};
    (
      # In-flight builds running past the threshold (current duration).
      [ .[]
        | select(.status == "inProgress" and (.startTime // null) != null)
        | (.startTime | parsedate) as $st
        | select($st != null)
        | (($now - $st) / 60 | floor) as $dm
        | select($dm >= $thr)
        | common as $c
        | {
            title: "Long Running Pipeline: `\($c.pname)` (Branch: `\($c.branch)`)",
            details: "Pipeline has been running for \(fmt($dm)) (exceeds threshold of \($threshold_label) minutes)",
            next_steps: "Investigate why pipeline `\($c.pname)` in project `\($project)` is taking longer than expected. Check for resource constraints or inefficient tasks.",
            severity: 3,
            resource_url: $c.url, duration: fmt($dm), duration_minutes: $dm,
            pipeline_id: $c.pid, run_id: $c.rid, branch: $c.branch
          } ]
      +
      # Completed builds whose run time exceeded the threshold.
      [ .[]
        | select(.status == "completed" and (.startTime // null) != null and (.finishTime // null) != null)
        | (.startTime | parsedate) as $st
        | (.finishTime | parsedate) as $ft
        | select($st != null and $ft != null)
        | (($ft - $st) / 60 | floor) as $dm
        | select($dm >= $thr)
        | common as $c
        | {
            title: "Long Running Completed Pipeline: `\($c.pname)` (Branch: `\($c.branch)`)",
            details: "Pipeline run completed in \(fmt($dm)) (exceeds threshold of \($threshold_label) minutes)",
            next_steps: "Review pipeline `\($c.pname)` in project `\($project)` for optimization opportunities. Consider parallelizing tasks or upgrading agent resources.",
            severity: 2,
            resource_url: $c.url, duration: fmt($dm), duration_minutes: $dm,
            pipeline_id: $c.pid, run_id: $c.rid, branch: $c.branch
          } ]
    )
    ' "$BUILDS_FILE")

echo "$issues_json" | jq -r '.[] | "  \(.title) — \(.duration)"' 2>/dev/null || true

# Write final JSON
echo "$issues_json" > "$OUTPUT_FILE"
echo "Azure DevOps long-running pipeline analysis completed. Saved results to $OUTPUT_FILE"
