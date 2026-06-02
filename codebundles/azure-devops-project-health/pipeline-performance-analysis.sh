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
#   RW_LOOKBACK_WINDOW   - window for performance trend analysis (default 24h;
#                          the deep runbook typically sets 30d)
#
# This script (Phase 0 single-pass refactor):
#   1) Fetches the project's builds ONCE via the Build REST API (fetch_project_builds).
#   2) Derives per-definition performance (duration avg/min/max/median, queue
#      times, success rate) with a SINGLE jq group_by(.definition.id) pass --
#      with NO per-pipeline API calls (previously it issued TWO
#      `az pipelines runs list --pipeline-id <id>` calls per pipeline, which
#      regressed into a 180s timeout).
#   3) Outputs results in JSON format.
# -----------------------------------------------------------------------------

: "${AZURE_DEVOPS_ORG:?Must set AZURE_DEVOPS_ORG}"
: "${AZURE_DEVOPS_PROJECT:?Must set AZURE_DEVOPS_PROJECT}"
: "${RW_LOOKBACK_WINDOW:=24h}"
: "${AUTH_TYPE:=service_principal}"
AZURE_DEVOPS_PAT="${AZURE_DEVOPS_PAT:-${azure_devops_pat:-}}"
export AZURE_DEVOPS_EXT_PAT="${AZURE_DEVOPS_PAT}"

source "$(dirname "$0")/_az_helpers.sh"

OUTPUT_FILE="pipeline_performance_analysis.json"
BUILDS_FILE="builds_dataset.json"
analysis_json='[]'

echo "Pipeline Performance Analysis..."
echo "Organization: $AZURE_DEVOPS_ORG"
echo "Project:      $AZURE_DEVOPS_PROJECT"

az devops configure --defaults project="$AZURE_DEVOPS_PROJECT" --output none
setup_azure_auth

# Single-pass: fetch the project's builds ONCE (shared/cached across tasks).
echo "Fetching project build dataset (single pass, window: ${RW_LOOKBACK_WINDOW})..."
if ! build_count=$(fetch_project_builds "$AZURE_DEVOPS_PROJECT" "$BUILDS_FILE" "$RW_LOOKBACK_WINDOW"); then
    echo "ERROR: Could not fetch builds for project."
    analysis_json=$(echo "$analysis_json" | jq \
        --arg title "Failed to Fetch Builds" \
        --arg details "The Build REST API was unreachable or returned an error while fetching the project build dataset." \
        --arg severity "3" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": "Verify Build API access for this project, check network connectivity to dev.azure.com, and confirm the lookback window is appropriate."
        }]')
    echo "$analysis_json" > "$OUTPUT_FILE"
    exit 1
fi

if [ "$build_count" -eq 0 ]; then
    echo "No builds found in window for project."
    analysis_json='[{"title": "No Pipeline Activity Found", "details": "No builds found in the lookback window for the project", "severity": 2, "next_steps": "Confirm pipelines have run recently or widen RW_LOOKBACK_WINDOW for the runbook; no action required if the project is idle."}]'
    echo "$analysis_json" > "$OUTPUT_FILE"
    exit 0
fi

echo "Fetched $build_count builds. Deriving per-definition performance..."

# Derive per-definition performance from the single dataset in one jq pass.
analysis_json=$(jq \
    --arg project "$AZURE_DEVOPS_PROJECT" \
    --arg window "$RW_LOOKBACK_WINDOW" '
    def parsedate: (sub("\\.[0-9]+";"") | sub("(Z|[+-][0-9][0-9]:?[0-9][0-9])$";"")) + "Z" | fromdateiso8601;
    def stats(a):
      (a | length) as $n
      | if $n == 0 then null
        else
          (a | add / $n) as $avg | (a | min) as $mn | (a | max) as $mx
          | (a | sort) as $s
          | (if ($n % 2) == 1 then $s[($n-1)/2] else (($s[$n/2-1] + $s[$n/2]) / 2) end) as $med
          | {n: $n, avg: ($avg|floor), min: ($mn|floor), max: ($mx|floor), median: ($med|floor)}
        end;

    [ group_by(.definition.id)[]
      | (.[0].definition.id // "unknown") as $pid
      | (.[0].definition.name // "Unknown Pipeline") as $pname
      | length as $total
      | [ .[] | select(.result == "succeeded") ] as $succ
      | ($succ | length) as $succ_n
      | stats([ $succ[] | select(.startTime != null and .finishTime != null)
                | ((.finishTime | parsedate) - (.startTime | parsedate)) ]) as $dur
      | stats([ $succ[] | select(.queueTime != null and .startTime != null)
                | ((.startTime | parsedate) - (.queueTime | parsedate)) ]) as $q
      | ($dur.avg // 0) as $avg_d | ($dur.min // 0) as $min_d | ($dur.max // 0) as $max_d | ($dur.median // 0) as $med_d
      | ($q.avg // 0) as $avg_q | ($q.max // 0) as $max_q
      | (if $total > 0 then (($succ_n * 1000 / $total | floor) / 10) else 0 end) as $success_rate
      # Build the list of performance findings + the worst (highest-number, i.e.
      # most escalated in this script local 1..3 scale) severity among them.
      | ([ ( if ($max_d > ($min_d * 3) and $min_d > 60) then {m:"High duration variability: \($min_d/60|floor)m to \($max_d/60|floor)m", s:2} else empty end ),
           ( if $avg_d > 1800 then {m:"Long average duration: \($avg_d/60|floor) minutes", s:2} else empty end ),
           ( if $max_d > 7200 then {m:"Very long maximum duration: \($max_d/60|floor) minutes", s:3} else empty end ),
           ( if $avg_q > 300  then {m:"Long average queue time: \($avg_q/60|floor) minutes", s:2} else empty end ),
           ( if $max_q > 1800 then {m:"Very long maximum queue time: \($max_q/60|floor) minutes", s:3} else empty end ),
           ( if ($total > 0 and $success_rate < 80) then {m:"Low success rate: \($success_rate)%", s:3} else empty end ),
           ( if $succ_n == 0 then {m:"No successful runs in window", s:3} else empty end )
         ]) as $findings
      | (if ($findings | length) == 0 then 1 else ([ $findings[].s ] | max) end) as $severity
      | (if ($findings | length) == 0 then "Performance appears normal"
         else ([ $findings[].m ] | join("; ")) end) as $issues_summary
      | (if $severity > 1
         then "Pipeline Performance: \($pname) - Issues Found"
         else "Pipeline Performance: \($pname) - Normal" end) as $title
      | {
          title: $title,
          pipeline_name: $pname,
          pipeline_id: ($pid | tostring),
          successful_runs: $succ_n,
          total_runs: $total,
          avg_duration_seconds: $avg_d,
          min_duration_seconds: $min_d,
          max_duration_seconds: $max_d,
          median_duration_seconds: $med_d,
          avg_queue_time_seconds: $avg_q,
          max_queue_time_seconds: $max_q,
          success_rate_percent: ($success_rate | tostring),
          issues_summary: $issues_summary,
          severity: $severity,
          next_steps: (if $severity > 1
            then "Review pipeline `\($pname)` performance: \($issues_summary). Consider optimizing slow stages, adding caching, parallelizing tasks, or scaling agent pools to improve throughput."
            else "No action required - pipeline performance is within acceptable parameters." end),
          details: "Pipeline \($pname): \($succ_n) successful of \($total) runs in \($window), avg duration \($avg_d/60|floor)m, success rate \($success_rate)%. Issues: \($issues_summary)"
        } ]
    ' "$BUILDS_FILE")

# Write final JSON
echo "$analysis_json" > "$OUTPUT_FILE"
echo "Pipeline performance analysis completed. Results saved to $OUTPUT_FILE"

# Output summary to stdout
echo ""
echo "=== PIPELINE PERFORMANCE SUMMARY ==="
echo "$analysis_json" | jq -r '.[] | "Pipeline: \(.pipeline_name)\nRuns: \(.successful_runs)/\(.total_runs), Avg Duration: \((.avg_duration_seconds / 60) | floor)m\nSuccess Rate: \(.success_rate_percent)%\nIssues: \(.issues_summary)\n---"'
