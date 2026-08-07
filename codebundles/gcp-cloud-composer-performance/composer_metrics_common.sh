#!/usr/bin/env bash
# shellcheck disable=SC2317
# -----------------------------------------------------------------------------
# Shared helpers for querying Google Cloud Monitoring (Cloud Monitoring) MQL
# for Cloud Composer performance metrics.
#
# Sourced by the task analysis scripts. Requires:
#   - GCP_PROJECT_ID  : GCP project that contains the Composer environments
#   - GOOGLE_APPLICATION_CREDENTIALS : path to the service account JSON
#   - gcloud, jq, curl installed
#
# Cloud Monitoring MQL is queried through the timeSeries:query REST endpoint
# so that alignment/aggregation is done server-side regardless of gcloud CLI
# version.
# -----------------------------------------------------------------------------

get_access_token() {
    gcloud auth print-access-token 2>/dev/null
}

# mql_query <mql>  -> prints the raw timeSeries:query JSON response
mql_query() {
    local query="$1"
    local token payload
    token="$(get_access_token)"
    if [ -z "$token" ]; then
        echo '{"timeSeriesData":[]}'
        return 0
    fi
    payload="$(jq -n --arg q "$query" '{query: $q}')"
    curl -s --fail \
        -X POST "https://monitoring.googleapis.com/v3/projects/${GCP_PROJECT_ID}/timeSeries:query" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null || echo '{"timeSeriesData":[]}'
}

# extract_point_values  -> reads raw response on stdin, prints a JSON array of
# numeric point values (handles double/int64/bool).
extract_point_values() {
    jq -c '[.timeSeriesData[]? | .pointData[]? | .values[]? |
            (if has("doubleValue") then .doubleValue
             elif has("int64Value") then (.int64Value | tonumber)
             elif has("boolValue") then (if .boolValue then 1 else 0 end)
             else empty end)]' 2>/dev/null || echo '[]'
}

# points_stats <values_json> -> prints {count, avg, min, max}
points_stats() {
    local values="$1"
    jq -n --argjson v "$values" '{
        count: ($v | length),
        avg: (if ($v|length)>0 then ($v|add)/($v|length) else 0 end),
        min: (if ($v|length)>0 then $v|min else 0 end),
        max: (if ($v|length)>0 then $v|max else 0 end)
    }'
}

# pct_above <values_json> <threshold> -> prints percentage of points > threshold
pct_above() {
    local values="$1" threshold="$2"
    jq -n --argjson v "$values" --argjson t "$threshold" '
        (if ($v|length)>0 then ([$v[] | select(. > $t)] | length) / ($v|length) * 100 else 0 end)
    '
}

# pct_below <values_json> <threshold> -> prints percentage of points < threshold
pct_below() {
    local values="$1" threshold="$2"
    jq -n --argjson v "$values" --argjson t "$threshold" '
        (if ($v|length)>0 then ([$v[] | select(. < $t)] | length) / ($v|length) * 100 else 0 end)
    '
}

# add_issue <issues_json> <title> <detail> <severity> <expected> <actual> <next_steps>
#   -> prints the issues array with the new issue appended.
add_issue() {
    local issues="$1" title="$2" detail="$3" sev="$4" expected="$5" actual="$6" next_steps="$7"
    jq -n \
        --argjson issues "$issues" \
        --arg title "$title" \
        --arg detail "$detail" \
        --arg sev "$sev" \
        --arg expected "$expected" \
        --arg actual "$actual" \
        --arg next_steps "$next_steps" \
        '$issues + [{
            "title": $title,
            "details": $detail,
            "severity": ($sev | tonumber),
            "expected": $expected,
            "actual": $actual,
            "next_steps": $next_steps
        }]'
}

# require_var <name> [<default>]
require_var() {
    local name="$1" default="${2:-}"
    if [ -z "${!name:-}" ]; then
        if [ -n "$default" ]; then
            export "$name"="$default"
        else
            echo "ERROR: Environment variable ${name} is required." >&2
            exit 2
        fi
    fi
}
