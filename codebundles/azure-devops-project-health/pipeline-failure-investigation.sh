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
#   MAX_FAILURES_TO_INVESTIGATE   - cap on failed builds whose commits are
#                                   correlated (deep per-item work; default 10)
#
# This script (Phase 0 single-pass refactor):
#   1) Fetches the project's builds ONCE via the Build REST API (fetch_project_builds).
#   2) Derives failed builds AND the per-definition "similar failures in window"
#      count from that SINGLE dataset with jq -- removing the per-failure
#      `az pipelines runs list --pipeline-id` call that previously ran inside the
#      loop.
#   3) Correlates each failure with its commit, CAPPED to
#      MAX_FAILURES_TO_INVESTIGATE (commit lookups are genuine per-item work).
#   4) Outputs results in JSON format.
# -----------------------------------------------------------------------------

: "${AZURE_DEVOPS_ORG:?Must set AZURE_DEVOPS_ORG}"
: "${AZURE_DEVOPS_PROJECT:?Must set AZURE_DEVOPS_PROJECT}"
: "${RW_LOOKBACK_WINDOW:=24h}"
: "${MAX_FAILURES_TO_INVESTIGATE:=10}"
: "${AUTH_TYPE:=service_principal}"
AZURE_DEVOPS_PAT="${AZURE_DEVOPS_PAT:-$azure_devops_pat}"
export AZURE_DEVOPS_EXT_PAT="${AZURE_DEVOPS_PAT}"

source "$(dirname "$0")/_az_helpers.sh"

OUTPUT_FILE="pipeline_failure_investigation.json"
BUILDS_FILE="builds_dataset.json"
investigation_json='[]'

echo "Deep Pipeline Failure Investigation..."
echo "Organization: $AZURE_DEVOPS_ORG"
echo "Project:      $AZURE_DEVOPS_PROJECT"

az devops configure --defaults project="$AZURE_DEVOPS_PROJECT" --output none
setup_azure_auth

# Single-pass: fetch the project's builds ONCE (shared/cached across tasks).
echo "Fetching project build dataset (single pass, window: ${RW_LOOKBACK_WINDOW})..."
if ! build_count=$(fetch_project_builds "$AZURE_DEVOPS_PROJECT" "$BUILDS_FILE" "$RW_LOOKBACK_WINDOW"); then
    echo "ERROR: Could not fetch builds for project."
    investigation_json=$(echo "$investigation_json" | jq \
        --arg title "Failed to Fetch Builds" \
        --arg details "The Build REST API was unreachable or returned an error while fetching the project build dataset." \
        --arg severity "3" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": "Verify Build API access for this project, check network connectivity to dev.azure.com, and confirm the lookback window is appropriate."
        }]')
    echo "$investigation_json" > "$OUTPUT_FILE"
    exit 1
fi

# Derive failed builds (newest first) and attach the per-definition similar-failure
# count -- all from the single dataset (no per-pipeline calls).
jq -c '
    ([ .[] | select(.result == "failed") ]
      | group_by(.definition.id)
      | map({key: (.[0].definition.id | tostring), value: length})
      | from_entries) as $bydef
    | [ .[] | select(.result == "failed")
        | . + {similar_failures_count: ($bydef[(.definition.id | tostring)] // 1)} ]
    | sort_by(.finishTime // .queueTime // "") | reverse
' "$BUILDS_FILE" > failed_builds.json

failed_count=$(jq 'length' failed_builds.json)

if [ "$failed_count" -eq 0 ]; then
    echo "No failed pipeline runs found in the last ${RW_LOOKBACK_WINDOW}."
    investigation_json='[{"title": "No Recent Failures", "details": "No failed pipeline runs found in the lookback window", "severity": 1, "next_steps": "No action required."}]'
    echo "$investigation_json" > "$OUTPUT_FILE"
    rm -f failed_builds.json
    exit 0
fi

echo "Found $failed_count failed builds. Investigating up to $MAX_FAILURES_TO_INVESTIGATE with commit correlation..."

investigate_count=$failed_count
if [ "$investigate_count" -gt "$MAX_FAILURES_TO_INVESTIGATE" ]; then
    investigate_count=$MAX_FAILURES_TO_INVESTIGATE
fi

for ((i=0; i<investigate_count; i++)); do
    run_json=$(jq -c ".[${i}]" failed_builds.json)

    run_id=$(echo "$run_json" | jq -r '.id')
    pipeline_name=$(echo "$run_json" | jq -r '.definition.name // .buildNumber // "Unknown Pipeline"')
    source_version=$(echo "$run_json" | jq -r '.sourceVersion // ""')
    source_branch=$(echo "$run_json" | jq -r '.sourceBranch // "unknown"' | sed 's|refs/heads/||')
    finish_time=$(echo "$run_json" | jq -r '.finishTime // ""')
    pipeline_reason=$(echo "$run_json" | jq -r '.reason // "Unknown"')
    similar_count=$(echo "$run_json" | jq -r '.similar_failures_count // 1')

    echo "Investigating failed run: $pipeline_name (Build ID: $run_id)"

    # Get commit details (deep per-item work; capped above).
    if [ "$source_version" != "null" ] && [ -n "$source_version" ]; then
        echo "  Getting commit details for: $source_version"
        if commit_details=$(az repos commit show --commit-id "$source_version" --output json 2>commit_err.log); then
            commit_author=$(echo "$commit_details" | jq -r '.author.name')
            commit_message=$(echo "$commit_details" | jq -r '.comment')
            commit_date=$(echo "$commit_details" | jq -r '.author.date')
            changes_count=$(echo "$commit_details" | jq -r '.changes | length')
            changed_files=$(echo "$commit_details" | jq -r '.changes[].item.path' | head -10 | tr '\n' ', ' | sed 's/,$//')
        else
            echo "    Warning: Could not get commit details"
            commit_author="Unknown"
            commit_message="Could not retrieve commit details"
            commit_date="Unknown"
            changes_count=0
            changed_files="Unknown"
        fi
        rm -f commit_err.log
    else
        commit_author="Unknown"
        commit_message="No source version available"
        commit_date="Unknown"
        changes_count=0
        changed_files="Unknown"
    fi

    # Get recent commits on the same branch (last 5)
    echo "  Getting recent commit history on branch: $source_branch"
    if recent_commits=$(az repos commit list --branch "$source_branch" --top 5 --output json 2>recent_commits_err.log); then
        recent_commit_summary=$(echo "$recent_commits" | jq -r '.[] | "\(.author.name): \(.comment | split("\n")[0])"' | head -3 | tr '\n' '; ')
    else
        echo "    Warning: Could not get recent commits"
        recent_commit_summary="Could not retrieve recent commits"
    fi
    rm -f recent_commits_err.log

    # Build investigation summary
    investigation_json=$(echo "$investigation_json" | jq \
        --arg title "Pipeline Failure Investigation: $pipeline_name" \
        --arg pipeline_name "$pipeline_name" \
        --arg run_id "$run_id" \
        --arg source_branch "$source_branch" \
        --arg commit_author "$commit_author" \
        --arg commit_message "$commit_message" \
        --arg commit_date "$commit_date" \
        --arg changes_count "$changes_count" \
        --arg changed_files "$changed_files" \
        --arg recent_commits "$recent_commit_summary" \
        --arg pipeline_reason "$pipeline_reason" \
        --arg similar_count "$similar_count" \
        --arg finish_time "$finish_time" \
        --arg severity "3" \
        '. += [{
           "title": $title,
           "pipeline_name": $pipeline_name,
           "run_id": $run_id,
           "source_branch": $source_branch,
           "commit_author": $commit_author,
           "commit_message": $commit_message,
           "commit_date": $commit_date,
           "changes_count": ($changes_count | tonumber),
           "changed_files": $changed_files,
           "recent_commits": $recent_commits,
           "pipeline_reason": $pipeline_reason,
           "similar_failures_count": ($similar_count | tonumber),
           "finish_time": $finish_time,
           "severity": ($severity | tonumber),
           "details": "Pipeline \($pipeline_name) failed on branch \($source_branch). Last commit by \($commit_author): \($commit_message). Changed files: \($changed_files). \($changes_count) files changed total. \($similar_count) similar failures in window. Trigger reason: \($pipeline_reason). Recent activity on branch: \($recent_commits)",
           "next_steps": "Review the commit by \($commit_author) (\($commit_message)) on branch \($source_branch) that triggered this failure. Check the \($changes_count) changed files (\($changed_files)) for breaking changes. If \($similar_count) similar failures exist, investigate a systemic issue with the pipeline configuration or branch.",
           "investigation_summary": "Commit: \($commit_message) by \($commit_author). Files: \($changed_files). Recent activity: \($recent_commits)"
         }]')
done

# Note if more failures existed than we deep-investigated (report-only).
if [ "$failed_count" -gt "$investigate_count" ]; then
    investigation_json=$(echo "$investigation_json" | jq \
        --arg title "Additional Failed Runs Not Correlated" \
        --arg details "Found $failed_count failed builds in the last ${RW_LOOKBACK_WINDOW}; commit correlation ran for the $investigate_count most recent (MAX_FAILURES_TO_INVESTIGATE=$MAX_FAILURES_TO_INVESTIGATE)." \
        --arg severity "4" \
        --arg next_steps "Increase MAX_FAILURES_TO_INVESTIGATE if deeper correlation coverage is required." \
        '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
fi

rm -f failed_builds.json

# Write final JSON
echo "$investigation_json" > "$OUTPUT_FILE"
echo "Pipeline failure investigation completed. Results saved to $OUTPUT_FILE"

# Output summary to stdout
echo ""
echo "=== INVESTIGATION SUMMARY ==="
echo "$investigation_json" | jq -r '.[] | "Pipeline: \(.pipeline_name // .title)\nAuthor: \(.commit_author // "n/a")\nMessage: \(.commit_message // "n/a")\nFiles Changed: \(.changes_count // 0)\nSimilar Failures: \(.similar_failures_count // 0)\n---"'
