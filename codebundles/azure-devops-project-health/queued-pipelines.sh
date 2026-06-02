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
#   QUEUE_THRESHOLD      - queue age threshold (e.g. "30m", "1h"; default 30m)
#   RW_LOOKBACK_WINDOW   - build dataset window (default 24h)
#
# This script (Phase 0 single-pass refactor):
#   1) Fetches the project's builds ONCE via the Build REST API (fetch_project_builds),
#      including the currently-queued (notStarted) builds (point-in-time set).
#   2) Derives, with jq, every build queued longer than the threshold -- with NO
#      per-pipeline API calls (previously it looped over every pipeline issuing
#      `az pipelines runs list --pipeline-id <id>`, which timed out at 180s).
#   3) Outputs results in JSON format.
# -----------------------------------------------------------------------------

: "${AZURE_DEVOPS_ORG:?Must set AZURE_DEVOPS_ORG}"
: "${AZURE_DEVOPS_PROJECT:?Must set AZURE_DEVOPS_PROJECT}"
: "${QUEUE_THRESHOLD:=30m}"
: "${RW_LOOKBACK_WINDOW:=24h}"
: "${AUTH_TYPE:=service_principal}"
AZURE_DEVOPS_PAT="${AZURE_DEVOPS_PAT:-${azure_devops_pat:-}}"
export AZURE_DEVOPS_EXT_PAT="${AZURE_DEVOPS_PAT}"

source "$(dirname "$0")/_az_helpers.sh"

OUTPUT_FILE="queued_pipelines.json"
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
            echo "Invalid duration format. Use format like '10m' or '1h'" >&2
            exit 1
            ;;
    esac
}

THRESHOLD_MINUTES=$(convert_to_minutes "$QUEUE_THRESHOLD")

echo "Analyzing Azure DevOps Queued Pipelines..."
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
echo "Fetched $build_count builds. Deriving queued pipelines..."

NOW_EPOCH=$(date +%s)

# Derive every queued (notStarted) build aging past the threshold directly from
# the single dataset -- one jq pass, zero per-pipeline calls.
issues_json=$(jq \
    --argjson now "$NOW_EPOCH" \
    --argjson thr "$THRESHOLD_MINUTES" \
    --arg threshold_label "$THRESHOLD_MINUTES" '
    def parsedate: (sub("\\.[0-9]+";"") | sub("(Z|[+-][0-9][0-9]:?[0-9][0-9])$";"")) + "Z" | (try fromdateiso8601 catch null);
    def fmt(m): if m >= 1440 then "\(m/1440|floor)d \((m%1440)/60|floor)h \(m%60)m"
                elif m >= 60 then "\(m/60|floor)h \(m%60)m"
                else "\(m)m" end;
    [ .[]
      | select(.status == "notStarted" and (.queueTime // null) != null)
      | (.queueTime | parsedate) as $qt
      | select($qt != null)
      | (($now - $qt) / 60 | floor) as $qm
      | select($qm >= $thr)
      | (.definition.name // "Unknown Pipeline") as $pname
      | ((.sourceBranch // "unknown") | sub("refs/heads/";"")) as $branch
      | (._links.web.href // .url // "") as $url
      | ((.definition.id // "") | tostring) as $pid
      | ((.id // "") | tostring) as $rid
      | (if (.reason // null) != null then "Trigger reason: \(.reason)" else "Unknown" end) as $qreason
      | {
          title: "Pipeline Queued Too Long: `\($pname)` (Branch: `\($branch)`)",
          details: "Pipeline has been queued for \(fmt($qm)) (exceeds threshold of \($threshold_label) minutes). \($qreason)",
          next_steps: "Check agent pool capacity and availability. Consider adding more agents or optimizing pipeline concurrency limits.",
          severity: 3,
          resource_url: $url,
          queue_time: fmt($qm),
          queue_minutes: $qm,
          pipeline_id: $pid,
          run_id: $rid,
          branch: $branch,
          queue_reason: $qreason
        } ]
    ' "$BUILDS_FILE")

# Log a short per-build trace for transparency (no extra API calls).
echo "$issues_json" | jq -r '.[] | "  Queued: \(.title) — \(.queue_time)"' 2>/dev/null || true

# Write final JSON
echo "$issues_json" > "$OUTPUT_FILE"
echo "Azure DevOps queued pipeline analysis completed. Saved results to $OUTPUT_FILE"
