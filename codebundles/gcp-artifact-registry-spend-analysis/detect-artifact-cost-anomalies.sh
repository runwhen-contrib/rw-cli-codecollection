#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Detect daily artifact storage cost spikes and sustained weekly deviations.
# Outputs artifact_cost_anomalies_issues.json
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=artifact-billing-helpers.sh
source "${SCRIPT_DIR}/artifact-billing-helpers.sh"

OUTPUT_FILE="artifact_cost_anomalies_issues.json"
REPORT_FILE="artifact_cost_anomalies_report.txt"
SPIKE_MULTIPLIER="${ARTIFACT_COST_SPIKE_MULTIPLIER:-2}"
issues_json='[]'

read -r START_DATE END_DATE <<< "$(get_date_range)"

if ! BILLING_TABLE=$(ensure_billing_access); then
    cat "$OUTPUT_FILE"
    exit 0
fi

PROJECT_FILTER=$(build_project_filter_sql)

DAILY_QUERY="
SELECT
  project.id AS project_id,
  project.name AS project_name,
  DATE(usage_start_time) AS usage_date,
  ROUND(SUM(cost), 4) AS daily_cost
FROM \`${BILLING_TABLE}\`
WHERE DATE(usage_start_time) BETWEEN DATE_SUB('${END_DATE}', INTERVAL 37 DAY) AND '${END_DATE}'
  AND ${ARTIFACT_SKU_FILTER}
  ${PROJECT_FILTER}
GROUP BY project_id, project_name, usage_date
HAVING daily_cost > 0
ORDER BY project_id, usage_date
"

if ! DAILY_RESULT=$(run_bq_query_json "$BILLING_TABLE" "$DAILY_QUERY" 100000); then
    write_access_issue "Cannot Detect Artifact Cost Anomalies" "Daily cost query failed." "$OUTPUT_FILE"
    exit 0
fi

{
    echo "Artifact Registry Cost Anomaly Detection"
    echo "Spike multiplier threshold: ${SPIKE_MULTIPLIER}x 7-day average"
    echo ""
} > "$REPORT_FILE"

PROJECTS=$(echo "$DAILY_RESULT" | jq -r '[.[].project_id] | unique | .[]')
while IFS= read -r proj; do
    [[ -z "$proj" ]] && continue
    proj_data=$(echo "$DAILY_RESULT" | jq --arg p "$proj" '[.[] | select(.project_id == $p)] | sort_by(.usage_date)')
    proj_name=$(echo "$proj_data" | jq -r '.[0].project_name // .[0].project_id')

    # Last 7 days for spike detection
    last7=$(echo "$proj_data" | jq '[.[-7:][] | .daily_cost | tonumber]')
    avg7=$(echo "$last7" | jq 'if length > 0 then (add / length) else 0 end')

    if (( $(echo "$avg7 > 0.01" | bc -l) )); then
        day_count=$(echo "$proj_data" | jq '.[-7:] | length')
        for ((d=0; d<day_count; d++)); do
            day_row=$(echo "$proj_data" | jq -c ".[-7:][$d]")
            cost=$(echo "$day_row" | jq -r '.daily_cost')
            date=$(echo "$day_row" | jq -r '.usage_date')
            mult=$(echo "scale=2; $cost / $avg7" | bc -l)
            if (( $(echo "$mult >= $SPIKE_MULTIPLIER" | bc -l) )); then
                issues_json=$(echo "$issues_json" | jq \
                    --arg title "Artifact Cost Spike: \`${proj}\` on ${date}" \
                    --arg details "Daily artifact cost \$${cost} is ${mult}x the 7-day average (\$${avg7}) for ${proj_name}." \
                    --arg severity "2" \
                    --arg next_steps "Check for bulk image pushes, scanning charges, or egress spikes on ${date}." \
                    '. += [{
                       "title": $title,
                       "severity": ($severity | tonumber),
                       "expected": "Daily artifact costs should stay within '"${SPIKE_MULTIPLIER}"'x the 7-day average",
                       "actual": $details,
                       "details": $details,
                       "next_steps": $next_steps
                     }]')
                echo "  SPIKE: ${proj} ${date} \$${cost} (${mult}x avg)" >> "$REPORT_FILE"
            fi
        done
    fi

    # Weekly vs 30-day trend (last 7 vs prior 23 days average * 7)
    weekly=$(echo "$proj_data" | jq '[.[-7:][] | .daily_cost | tonumber] | add // 0')
    monthly=$(echo "$proj_data" | jq '[.[] | .daily_cost | tonumber] | add // 0')
    if (( $(echo "$monthly > 0 && $weekly > 0" | bc -l) )); then
        expected_weekly=$(echo "scale=4; $monthly * 7 / 30" | bc -l)
        ratio=$(echo "scale=2; $weekly / $expected_weekly" | bc -l)
        if (( $(echo "$ratio >= 1.5" | bc -l) )); then
            pct=$(echo "scale=1; ($ratio - 1) * 100" | bc -l)
            issues_json=$(echo "$issues_json" | jq \
                --arg title "Sustained Artifact Cost Deviation: \`${proj}\`" \
                --arg details "Last 7 days artifact spend \$${weekly} is ${pct}% above the 30-day trend (expected ~\$${expected_weekly})." \
                --arg severity "3" \
                --arg next_steps "Review recent repository growth and scanning settings. Align with gcp-artifact-registry-governance cleanup recommendations." \
                '. += [{
                   "title": $title,
                   "severity": ($severity | tonumber),
                   "expected": "Weekly artifact spend should align with the 30-day trend",
                   "actual": $details,
                   "details": $details,
                   "next_steps": $next_steps
                 }]')
            echo "  DEVIATION: ${proj} weekly \$${weekly} vs expected \$${expected_weekly}" >> "$REPORT_FILE"
        fi
    fi
done <<< "$PROJECTS"

echo "$issues_json" > "$OUTPUT_FILE"
cat "$REPORT_FILE"
