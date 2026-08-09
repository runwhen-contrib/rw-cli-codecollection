#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Identify Long Running Queries for Cloud SQL Instances in a GCP Project
#
# Queries the Cloud SQL instance logs for queries whose duration exceeds the
# configured LONG_QUERY_SECONDS threshold and reports the offending SQL.
#
# This relies on Cloud SQL query/performance logging being enabled for the
# instance. When logs are unavailable or no slow queries are found the task
# degrades gracefully with a note rather than failing.
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID         - GCP project ID hosting the Cloud SQL instances
#   RESOURCES              - Optional comma-separated instance names (default All)
#   LONG_QUERY_SECONDS     - Query duration (seconds) above which a query is
#                            considered long-running (default 300)
#
# OUTPUTS:
#   long_query_issues.json - JSON array of issues (empty when none found or logs
#                            are unavailable)
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${RESOURCES:=All}"
: "${LONG_QUERY_SECONDS:=300}"

ISSUES_FILE="long_query_issues.json"
CONFIG_FILE="sql_config.json"
TMP_ISSUES="$(mktemp)"
issues_json='[]'
logging_available=1

echo "Finding long running queries for project: $GCP_PROJECT_ID (threshold: ${LONG_QUERY_SECONDS}s)"

if [ ! -s "sql_config.json" ]; then
    echo "No sql_config.json found; running discovery first."
    ./discover_sql_instances.sh
fi

# Fail loud: if discovery could not list the Cloud SQL instances (auth/permission
# failure, API disabled, etc.), surface those discovery issues here instead of
# silently proceeding with an empty instance set and reporting "0 issues / healthy".
if [ -s "sql_instances_issues.json" ] && [ "$(jq 'length' sql_instances_issues.json 2>/dev/null || echo 0)" -gt 0 ]; then
    echo "Cloud SQL discovery reported failure(s); surfacing them instead of scoring as healthy."
    cp sql_instances_issues.json "$ISSUES_FILE"
    rm -f "$TMP_ISSUES"
    exit 0
fi

while IFS= read -r line; do
    inst_name=$(echo "$line" | jq -r '.name')
    db_id=$(echo "$line" | jq -r '.database_id')

    # Cloud SQL instance log entries. Tolerate missing logs -> graceful note.
    entries=$(gcloud logging read \
        "resource.type=\"cloudsql_database\" AND resource.labels.database_id=\"$db_id\"" \
        --project="$GCP_PROJECT_ID" --format=json --limit=500 2>err.log || echo "")
    if [ -s "err.log" ]; then
        rm -f err.log
        logging_available=0
        continue
    fi

    if [ -z "$entries" ] || [ "$(echo "$entries" | jq 'length' 2>/dev/null || echo 0)" = "0" ]; then
        echo "  Instance '$inst_name': no query log entries found (query/performance logging may be disabled)."
        logging_available=0
        continue
    fi

    # Extract duration (in seconds) and SQL from each log entry via jq.
    echo "$entries" | jq -c '.[]' 2>/dev/null | while read -r entry; do
        text=$(echo "$entry" | jq -r '.textPayload // ""')
        duration_s=$(echo "$text" | awk '
          { for (i=1;i<=NF;i++) {
              if ($i ~ /^[0-9]+(\.[0-9]+)?(ms|s)$/) {
                v=$i; gsub(/(ms|s)/,"",v);
                if ($i ~ /ms$/) print v/1000; else print v; exit
              } } }' )
        if [ -z "$duration_s" ]; then
            continue
        fi
        if [ "$(awk -v d="$duration_s" -v t="$LONG_QUERY_SECONDS" 'BEGIN{print (d>=t)?1:0}')" = "1" ]; then
            sql=$(echo "$text" | awk 'NR==1{print}' | cut -c1-500)
            issue=$(jq -n \
                --arg title "Long running query detected on Cloud SQL instance \`$inst_name\`" \
                --arg details "A query on instance '$inst_name' in project '$GCP_PROJECT_ID' took ${duration_s}s, exceeding the ${LONG_QUERY_SECONDS}s threshold. SQL: $sql" \
                --arg severity "3" \
                --arg expected "Queries on Cloud SQL instances should complete within ${LONG_QUERY_SECONDS}s" \
                --arg actual "A query on instance '$inst_name' ran for ${duration_s}s" \
                --arg next_steps "Review the query for full table scans, missing indexes, or locking. Tune the schema or use query plan analysis to reduce execution time." \
                '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
            echo "$issue" >> "$TMP_ISSUES"
        fi
    done
done < <(jq -c '.[]' "$CONFIG_FILE")

if [ -f "${TMP_ISSUES:-}" ]; then
    issues_json=$(jq -s '.' "$TMP_ISSUES" 2>/dev/null || echo "[]")
    rm -f "$TMP_ISSUES"
fi

echo "$issues_json" > "$ISSUES_FILE"

echo "Long running query analysis complete. Found $(jq length "$ISSUES_FILE") issue(s)."
if [ "$logging_available" = "0" ]; then
    echo "Note: no Cloud SQL query/performance logs were available for some instances. Enable query logging on the instances to detect long running queries."
fi
