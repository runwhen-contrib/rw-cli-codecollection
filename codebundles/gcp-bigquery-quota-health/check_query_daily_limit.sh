#!/usr/bin/env bash
set -euo pipefail

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${DAILY_QUERY_THRESHOLD:=80}"

OUTPUT_FILE="query_daily_limit_issues.json"

echo "Analyzing daily query count for project: $GCP_PROJECT_ID"

# -----------------------------------------------------------------------------
# Count queries run today (UTC) across the whole project using
# INFORMATION_SCHEMA.JOBS_BY_PROJECT.
# -----------------------------------------------------------------------------
today=$(date -u +%Y-%m-%d)

query_count=0
query_count=$(bq --project_id "$GCP_PROJECT_ID" query --use_legacy_sql=false --format=json \
  "SELECT COUNT(*) AS cnt FROM \`$GCP_PROJECT_ID.region-us.INFORMATION_SCHEMA.JOBS_BY_PROJECT\` WHERE creation_time >= TIMESTAMP('$today') AND job_type = 'QUERY'" \
  2>/dev/null | jq -r '.[0].cnt // 0' 2>/dev/null)
query_count=${query_count:-0}

# -----------------------------------------------------------------------------
# Determine the per-day query limit. There is no fixed documented cap;
# operators can configure the expected daily query ceiling. Default to a
# large reference limit and allow override via a threshold env var.
# -----------------------------------------------------------------------------
daily_query_limit=${DAILY_QUERY_LIMIT:-100000}

usage_pct=$(python3 -c "print(f'{float($query_count) / float($daily_query_limit) * 100:.2f}')" 2>/dev/null || echo "0")

echo "Queries today: $query_count (limit: $daily_query_limit, usage: ${usage_pct}%)"

if python3 -c "import sys; sys.exit(0 if float('$usage_pct') >= float('$DAILY_QUERY_THRESHOLD') else 1)" 2>/dev/null; then
  if python3 -c "import sys; sys.exit(0 if float('$usage_pct') >= 98 else 1)" 2>/dev/null; then
    severity="4"
  else
    severity="3"
  fi
  jq -n \
    --arg title "BigQuery daily query limit approaching for project \`$GCP_PROJECT_ID\`" \
    --arg details "BigQuery project \`$GCP_PROJECT_ID\` has run ${query_count} queries today, which is ${usage_pct}% of the configured daily limit of ${daily_query_limit}. Threshold is ${DAILY_QUERY_THRESHOLD}%." \
    --arg expected "Daily query count should stay below ${DAILY_QUERY_THRESHOLD}% of the configured limit" \
    --arg actual "Query count is ${query_count} (${usage_pct}% of limit)" \
    --arg severity "$severity" \
    --arg next_steps "Review and consolidate duplicate or redundant queries, schedule heavy jobs for off-peak hours, or work with GCP to increase the project daily query limit." \
    '[{title:$title,details:$details,expected:$expected,actual:$actual,severity:($severity|tonumber),next_steps:$next_steps}]' > "$OUTPUT_FILE"
else
  echo "[]" > "$OUTPUT_FILE"
fi

echo "Daily query limit analysis completed."

echo ""
echo "=== LLM Context ==="
echo "BigQuery Console: https://console.cloud.google.com/bigquery?project=$GCP_PROJECT_ID"
echo "Daily Query Threshold: ${DAILY_QUERY_THRESHOLD}%"
echo "Configured Daily Limit: $daily_query_limit"
echo "Suggested Follow-up Queries:"
echo "  # Show query counts by user today"
echo "  SELECT user_email, COUNT(*) as query_count"
echo "  FROM \`$GCP_PROJECT_ID.region-us.INFORMATION_SCHEMA.JOBS_BY_PROJECT\`"
echo "  WHERE creation_time >= TIMESTAMP('$today') AND job_type = 'QUERY'"
echo "  GROUP BY user_email ORDER BY query_count DESC;"
