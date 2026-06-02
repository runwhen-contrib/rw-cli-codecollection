#!/usr/bin/env bash
set -uo pipefail
# NOTE: `set -x` is intentionally NOT used (it leaks AZURE_DEVOPS_PAT into logs
# and bloats output). Set AZ_DEBUG=1 to opt in to tracing for local debugging.
[ "${AZ_DEBUG:-0}" = "1" ] && set -x
# -----------------------------------------------------------------------------
# Project-health SLI scoring (cheap, every ~30 min).
#
# Computes FOUR build-derived {0,1} sub-scores for a single project from ONE
# build dataset (fetched once via fetch_project_builds -- a handful of bounded
# Build-API calls, well under a minute). A fifth sub-score (data_collection_ok)
# is computed by the robot from this script's build_query_ok flag AND the
# preflight access result, so this script never re-implements access probing.
#
# Sub-scores (1 = healthy; convention: score 0 ONLY for what we measure and
# confirm bad; score 1 for what we cannot measure):
#   pipeline_failure_ratio_ok   failed/total completed builds in the window
#                               <= SLI_MAX_FAILURE_RATIO (0 runs => 1)
#   protected_branch_failures_ok no protected-branch (main/master/develop/
#                               release/*) pipeline failing 100% of its runs
#                               in the window
#   queue_aging_ok              no build queued (notStarted) longer than
#                               QUEUE_THRESHOLD (point-in-time). A scaled-to-zero
#                               elastic/ephemeral pool with NO queued work shows
#                               no aging build, so it is NOT penalised here --
#                               consistent with the landed agent-pool fix.
#   long_running_ok             in-flight builds older than DURATION_THRESHOLD
#                               <= SLI_MAX_LONGRUNNING (point-in-time)
#
# The two WINDOWED sub-scores (failure ratio, protected branch) use
# RW_LOOKBACK_WINDOW (default ~45m, i.e. scrape interval x~1.5). The point-in-time
# sub-scores (queue aging, long running) ignore it. Org-singleton data
# (license, the 473-pool scan) is intentionally NOT pulled in here.
#
# REQUIRED ENV VARS:
#   AZURE_DEVOPS_ORG
#   AZURE_DEVOPS_PROJECT
#
# OPTIONAL ENV VARS:
#   RW_LOOKBACK_WINDOW          windowed-sub-score lookback (default 45m)
#   SLI_MAX_FAILURE_RATIO       max failed/total ratio (default 0.50)
#   QUEUE_THRESHOLD             queued-build aging threshold (default 30m)
#   DURATION_THRESHOLD          in-flight long-running threshold (default 60m)
#   SLI_MAX_LONGRUNNING         allowed in-flight long-running builds (default 1)
#   SLI_PROTECTED_BRANCH_PATTERN regex of protected branches
#                               (default ^refs/heads/(main|master|develop|release/))
#   SLI_BUILDS_DATASET          test hook: path to a pre-seeded builds JSON array;
#                               when set & valid, auth/fetch is skipped and the
#                               scores are computed directly from it.
#
# Writes sli_project_health_score.json and echoes it to stdout.
# -----------------------------------------------------------------------------

: "${AZURE_DEVOPS_ORG:?Must set AZURE_DEVOPS_ORG}"
: "${AZURE_DEVOPS_PROJECT:?Must set AZURE_DEVOPS_PROJECT}"
: "${RW_LOOKBACK_WINDOW:=45m}"
: "${SLI_MAX_FAILURE_RATIO:=0.50}"
: "${QUEUE_THRESHOLD:=30m}"
: "${DURATION_THRESHOLD:=60m}"
: "${SLI_MAX_LONGRUNNING:=1}"
: "${SLI_PROTECTED_BRANCH_PATTERN:=^refs/heads/(main|master|develop|release/)}"
: "${AUTH_TYPE:=service_principal}"
AZURE_DEVOPS_PAT="${AZURE_DEVOPS_PAT:-${azure_devops_pat:-}}"
export AZURE_DEVOPS_EXT_PAT="${AZURE_DEVOPS_PAT}"

source "$(dirname "$0")/_az_helpers.sh"

OUTPUT_FILE="sli_project_health_score.json"
BUILDS_FILE="builds_dataset.json"

# Convert a duration like "30m" / "1h" to integer minutes.
convert_to_minutes() {
    local threshold="$1"
    local number unit
    number=$(printf '%s' "$threshold" | sed -E 's/[^0-9].*$//')
    unit=$(printf '%s' "$threshold" | sed -E 's/^[0-9]*//' | tr '[:upper:]' '[:lower:]')
    [ -z "$number" ] && number=0
    case "$unit" in
        m|min|mins|minute|minutes|"") echo "$number" ;;
        h|hr|hrs|hour|hours)          echo $((number * 60)) ;;
        d|day|days)                   echo $((number * 1440)) ;;
        *)                            echo "$number" ;;
    esac
}

QUEUE_MIN=$(convert_to_minutes "$QUEUE_THRESHOLD")
DURATION_MIN=$(convert_to_minutes "$DURATION_THRESHOLD")

build_query_ok=0

# ---- obtain the builds dataset -------------------------------------------
if [ -n "${SLI_BUILDS_DATASET:-}" ] && [ -s "${SLI_BUILDS_DATASET}" ] \
        && jq -e 'type == "array"' "${SLI_BUILDS_DATASET}" >/dev/null 2>&1; then
    echo "Using seeded builds dataset: ${SLI_BUILDS_DATASET} (skipping live fetch)." >&2
    cp "${SLI_BUILDS_DATASET}" "$BUILDS_FILE"
    build_query_ok=1
else
    echo "Scoring project '${AZURE_DEVOPS_PROJECT}' in org '${AZURE_DEVOPS_ORG}' (window ${RW_LOOKBACK_WINDOW})." >&2
    az devops configure --defaults project="$AZURE_DEVOPS_PROJECT" --output none 2>/dev/null || true
    setup_azure_auth >&2 || true
    if build_count=$(fetch_project_builds "$AZURE_DEVOPS_PROJECT" "$BUILDS_FILE" "$RW_LOOKBACK_WINDOW" 2>>/dev/stderr); then
        if [ -s "$BUILDS_FILE" ] && jq -e 'type == "array"' "$BUILDS_FILE" >/dev/null 2>&1; then
            build_query_ok=1
        fi
    fi
fi

# When the build query failed, emit a valid payload with build_query_ok=0 and
# neutral (1) sub-scores for the build-derived signals -- the robot will floor
# data_collection_ok to 0, which is the single honest "we couldn't measure"
# signal. We do NOT fabricate failures from a missing dataset.
if [ "$build_query_ok" -eq 0 ]; then
    echo '[]' > "$BUILDS_FILE"
fi

NOW_EPOCH=$(date +%s)

scores=$(jq -n \
    --argjson now "$NOW_EPOCH" \
    --slurpfile builds "$BUILDS_FILE" \
    --argjson qthr "$QUEUE_MIN" \
    --argjson dthr "$DURATION_MIN" \
    --argjson maxlr "$SLI_MAX_LONGRUNNING" \
    --arg maxratio "$SLI_MAX_FAILURE_RATIO" \
    --arg protpat "$SLI_PROTECTED_BRANCH_PATTERN" '
    def parsedate: (sub("\\.[0-9]+";"") | sub("(Z|[+-][0-9][0-9]:?[0-9][0-9])$";"")) + "Z" | fromdateiso8601;
    ($builds[0] // []) as $b
    | ($maxratio | tonumber) as $maxr
    # --- windowed: completed builds in the lookback window -----------------
    | ([ $b[] | select(.status == "completed" and (.result != null)) ]) as $done
    | ($done | length) as $total
    | ([ $done[] | select(.result == "failed") ] | length) as $failed
    | (if $total == 0 then 0 else ($failed / $total) end) as $ratio
    | (if $total == 0 then 1 elif $ratio <= $maxr then 1 else 0 end) as $failure_ratio_ok
    # --- windowed: protected-branch pipelines failing 100% in window -------
    | ([ $done[] | select((.sourceBranch // "") | test($protpat)) ]
        | group_by(.definition.id)
        | map({total: length, failed: (map(select(.result == "failed")) | length)})
        | map(select(.total > 0 and .failed == .total))) as $prot_bad
    | (if ($prot_bad | length) > 0 then 0 else 1 end) as $protected_ok
    # --- point-in-time: queued (notStarted) builds aging past threshold ----
    | ([ $b[]
          | select(.status == "notStarted" and (.queueTime // null) != null)
          | (($now - (.queueTime | parsedate)) / 60)
          | select(. >= $qthr) ] | length) as $aged_q
    | (if $aged_q > 0 then 0 else 1 end) as $queue_ok
    # --- point-in-time: in-flight builds running past threshold ------------
    | ([ $b[]
          | select(.status == "inProgress" and (.startTime // null) != null)
          | (($now - (.startTime | parsedate)) / 60)
          | select(. >= $dthr) ] | length) as $lr
    | (if $lr <= $maxlr then 1 else 0 end) as $long_ok
    | {
        pipeline_failure_ratio_ok:    $failure_ratio_ok,
        protected_branch_failures_ok: $protected_ok,
        queue_aging_ok:               $queue_ok,
        long_running_ok:              $long_ok,
        details: {
          build_count:          ($b | length),
          completed_in_window:  $total,
          failed_in_window:     $failed,
          failure_ratio:        (($ratio * 1000 | floor) / 1000),
          max_failure_ratio:    $maxr,
          protected_pipelines_failing_100pct: ($prot_bad | length),
          queued_aging_builds:  $aged_q,
          queue_threshold_min:  $qthr,
          longrunning_inflight: $lr,
          duration_threshold_min: $dthr,
          max_longrunning:      $maxlr,
          window:               "'"$RW_LOOKBACK_WINDOW"'"
        }
      }
    ' 2>/dev/null)

# Defensive fallback: if jq somehow produced nothing, emit neutral build-derived
# scores so the robot still gets a parseable payload (data_collection_ok will be
# floored to 0 via build_query_ok).
if [ -z "$scores" ] || ! echo "$scores" | jq -e . >/dev/null 2>&1; then
    scores='{"pipeline_failure_ratio_ok":1,"protected_branch_failures_ok":1,"queue_aging_ok":1,"long_running_ok":1,"details":{"error":"score computation failed"}}'
    build_query_ok=0
fi

result=$(echo "$scores" | jq --argjson bq "$build_query_ok" '. + {build_query_ok: $bq}')

echo "$result" > "$OUTPUT_FILE"
echo "$result"
