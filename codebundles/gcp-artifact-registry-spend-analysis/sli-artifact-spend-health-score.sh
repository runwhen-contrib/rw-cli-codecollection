#!/usr/bin/env bash
set -euo pipefail
set -x
# Lightweight SLI health check: artifact spend MoM growth and anomaly signals.
# Outputs sli_artifact_health.json with issue_count and health dimensions.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=artifact-billing-helpers.sh
source "${SCRIPT_DIR}/artifact-billing-helpers.sh"

OUTPUT_FILE="sli_artifact_health.json"
GROWTH_THRESHOLD="${ARTIFACT_MOM_GROWTH_THRESHOLD_PERCENT:-25}"
SPIKE_MULTIPLIER="${ARTIFACT_COST_SPIKE_MULTIPLIER:-2}"

mom_score=1
anomaly_score=1
access_score=1

if ! BILLING_TABLE=$(ensure_billing_access 2>/dev/null); then
    access_score=0
    jq -n \
        --argjson mom "$mom_score" \
        --argjson anomaly "$anomaly_score" \
        --argjson access "$access_score" \
        --argjson health "0" \
        '{mom_score: $mom, anomaly_score: $anomaly, access_score: $access, health_score: $health, issue_count: 1}' > "$OUTPUT_FILE"
    cat "$OUTPUT_FILE"
    exit 0
fi

read -r START_DATE END_DATE <<< "$(get_date_range)"
PROJECT_FILTER=$(build_project_filter_sql)

# Quick 14-day daily totals for spike check
SPIKE_QUERY="
SELECT DATE(usage_start_time) AS d, ROUND(SUM(cost), 4) AS c
FROM \`${BILLING_TABLE}\`
WHERE DATE(usage_start_time) BETWEEN DATE_SUB('${END_DATE}', INTERVAL 14 DAY) AND '${END_DATE}'
  AND ${ARTIFACT_SKU_FILTER}
  ${PROJECT_FILTER}
GROUP BY d ORDER BY d
"
if SPIKE_DATA=$(run_bq_query_json "$BILLING_TABLE" "$SPIKE_QUERY" 20 2>/dev/null); then
    costs=$(echo "$SPIKE_DATA" | jq '[.[].c | tonumber]')
    avg=$(echo "$costs" | jq 'if length > 0 then (add/length) else 0 end')
    max=$(echo "$costs" | jq 'if length > 0 then max else 0 end')
    if (( $(echo "$avg > 0" | bc -l) )); then
        mult=$(echo "scale=2; $max / $avg" | bc -l)
        if (( $(echo "$mult >= $SPIKE_MULTIPLIER" | bc -l) )); then
            anomaly_score=0
        fi
    fi
else
    access_score=0
fi

# Quick 2-month MoM
M2_START=$(date -u -d "$(date -u +%Y-%m-01) -2 months" +%Y-%m-%d 2>/dev/null || date -u -v-2m -v1d +%Y-%m-%d)
M2_END=$(date -u -d "$(date -u +%Y-%m-01) -1 day" +%Y-%m-%d 2>/dev/null || date -u -v-1d +%Y-%m-%d)
MOM_QUERY="
SELECT FORMAT_DATE('%Y-%m', DATE(usage_start_time)) AS m, ROUND(SUM(cost), 2) AS t
FROM \`${BILLING_TABLE}\`
WHERE DATE(usage_start_time) BETWEEN '${M2_START}' AND '${M2_END}'
  AND ${ARTIFACT_SKU_FILTER}
  ${PROJECT_FILTER}
GROUP BY m ORDER BY m
"
if MOM_DATA=$(run_bq_query_json "$BILLING_TABLE" "$MOM_QUERY" 5 2>/dev/null); then
    cnt=$(echo "$MOM_DATA" | jq 'length')
    if [[ "$cnt" -ge 2 ]]; then
        prev=$(echo "$MOM_DATA" | jq -r '.[-2].t')
        curr=$(echo "$MOM_DATA" | jq -r '.[-1].t')
        if (( $(echo "$prev > 0" | bc -l) )); then
            growth=$(echo "scale=1; 100 * ($curr - $prev) / $prev" | bc -l)
            if (( $(echo "$growth >= $GROWTH_THRESHOLD" | bc -l) )); then
                mom_score=0
            fi
        fi
    fi
fi

health=$(echo "scale=2; ($mom_score + $anomaly_score + $access_score) / 3" | bc -l)
issue_count=$((3 - mom_score - anomaly_score - access_score))

jq -n \
    --argjson mom "$mom_score" \
    --argjson anomaly "$anomaly_score" \
    --argjson access "$access_score" \
    --argjson health "$health" \
    --argjson issue_count "$issue_count" \
    '{mom_score: $mom, anomaly_score: $anomaly, access_score: $access, health_score: ($health|tonumber), issue_count: $issue_count}' > "$OUTPUT_FILE"

cat "$OUTPUT_FILE"
