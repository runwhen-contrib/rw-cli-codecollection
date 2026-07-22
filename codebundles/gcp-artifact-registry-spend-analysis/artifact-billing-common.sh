#!/usr/bin/env bash
# Shared BigQuery billing helpers for GCP Artifact Registry spend analysis.

set -euo pipefail

log() {
    echo "📦 [$(date '+%H:%M:%S')] $*" >&2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROJECT_IDS="${GCP_PROJECT_IDS:-}"
PROJECT_IDS=$(echo "$PROJECT_IDS" | sed 's/^"//;s/"$//' | xargs)
LOOKBACK_DAYS="${COST_ANALYSIS_LOOKBACK_DAYS:-30}"
OUTPUT_FORMAT="${OUTPUT_FORMAT:-table}"
ARTIFACT_COST_SPIKE_MULTIPLIER="${ARTIFACT_COST_SPIKE_MULTIPLIER:-2}"
ARTIFACT_MOM_GROWTH_THRESHOLD_PERCENT="${ARTIFACT_MOM_GROWTH_THRESHOLD_PERCENT:-25}"
ARTIFACT_PROJECT_COST_THRESHOLD_PERCENT="${ARTIFACT_PROJECT_COST_THRESHOLD_PERCENT:-20}"
GCP_ORG_WIDE_REPORT="${GCP_ORG_WIDE_REPORT:-false}"

if ! [[ "$LOOKBACK_DAYS" =~ ^[0-9]+$ ]] || [[ "$LOOKBACK_DAYS" -le 0 ]]; then
    LOOKBACK_DAYS=30
fi

check_bq_available() {
    command -v bq &>/dev/null && return 0
    local home_dir="${HOME:-/root}"
    [[ -f "$home_dir/google-cloud-sdk/bin/bq" ]] || [[ -f "/usr/local/bin/bq" ]] || [[ -f "/opt/google-cloud-sdk/bin/bq" ]]
}

check_python_bq_available() {
    local python_cmd
    python_cmd=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)
    [[ -z "$python_cmd" ]] && return 1
    if "$python_cmd" -c "from google.cloud import bigquery" 2>/dev/null; then
        echo "$python_cmd"
        return 0
    fi
    return 1
}

check_bigquery_access() {
    if check_bq_available && { bq version &>/dev/null || bq --version &>/dev/null || bq help &>/dev/null; }; then
        echo "bq"
        return 0
    fi
    local python_cmd
    python_cmd=$(check_python_bq_available || true)
    [[ -n "$python_cmd" ]] && { echo "python"; return 0; }
    return 1
}

artifact_sku_filter_sql() {
    cat <<'EOF'
(
  LOWER(service.description) LIKE '%artifact registry%'
  OR LOWER(service.description) LIKE '%container registry%'
  OR LOWER(sku.description) LIKE '%artifact registry%'
  OR LOWER(sku.description) LIKE '%container registry%'
  OR LOWER(sku.description) LIKE '%container image%'
  OR LOWER(sku.description) LIKE '%vulnerability scanning%'
)
EOF
}

artifact_storage_sku_filter_sql() {
    cat <<'EOF'
(
  LOWER(sku.description) LIKE '%storage%'
  OR LOWER(sku.description) LIKE '%stored%'
)
EOF
}

artifact_transfer_sku_filter_sql() {
    cat <<'EOF'
(
  LOWER(sku.description) LIKE '%egress%'
  OR LOWER(sku.description) LIKE '%download%'
  OR LOWER(sku.description) LIKE '%transfer%'
  OR LOWER(sku.description) LIKE '%pull%'
  OR LOWER(sku.description) LIKE '%internet%'
)
EOF
}

get_date_ranges() {
    local end_date
    end_date=$(date -u +"%Y-%m-%d")
    local yesterday week_start month_start lookback_start
    yesterday=$(date -u -d '1 day ago' +"%Y-%m-%d" 2>/dev/null || date -u -v-1d +"%Y-%m-%d" 2>/dev/null)
    week_start=$(date -u -d '7 days ago' +"%Y-%m-%d" 2>/dev/null || date -u -v-7d +"%Y-%m-%d" 2>/dev/null)
    month_start=$(date -u -d '30 days ago' +"%Y-%m-%d" 2>/dev/null || date -u -v-30d +"%Y-%m-%d" 2>/dev/null)
    lookback_start=$(date -u -d "${LOOKBACK_DAYS} days ago" +"%Y-%m-%d" 2>/dev/null || date -u -v-${LOOKBACK_DAYS}d +"%Y-%m-%d" 2>/dev/null)

    declare -a daily_dates
    local i days_ago
    for i in {0..6}; do
        days_ago=$((i + 1))
        daily_dates[$i]=$(date -u -d "${days_ago} days ago" +"%Y-%m-%d" 2>/dev/null || date -u -v-${days_ago}d +"%Y-%m-%d" 2>/dev/null)
    done

    jq -n \
        --arg d0 "${daily_dates[0]}" \
        --arg d1 "${daily_dates[1]}" \
        --arg d2 "${daily_dates[2]}" \
        --arg d3 "${daily_dates[3]}" \
        --arg d4 "${daily_dates[4]}" \
        --arg d5 "${daily_dates[5]}" \
        --arg d6 "${daily_dates[6]}" \
        --arg week_start "$week_start" \
        --arg week_end "$yesterday" \
        --arg month_start "$month_start" \
        --arg month_end "$end_date" \
        --arg lookback_start "$lookback_start" \
        --arg lookback_end "$end_date" \
        --argjson lookback_days "$LOOKBACK_DAYS" \
        '{
            daily: [$d6, $d5, $d4, $d3, $d2, $d1, $d0],
            weekly: {start: $week_start, end: $week_end},
            monthly: {start: $month_start, end: $month_end},
            lookback: {start: $lookback_start, end: $lookback_end, days: $lookback_days}
        }'
}

get_last_three_complete_months() {
    local month1_start month1_end month2_start month2_end month3_start month3_end
    month1_start=$(date -u -d "$(date -u +%Y-%m-01) -1 month" +"%Y-%m-01" 2>/dev/null || date -u -v1d -v-1m +"%Y-%m-01" 2>/dev/null)
    month1_end=$(date -u -d "$(date -u +%Y-%m-01) -1 day" +"%Y-%m-%d" 2>/dev/null || date -u -v1d -v-1m -v-1d +"%Y-%m-%d" 2>/dev/null)
    month2_start=$(date -u -d "$month1_start -1 month" +"%Y-%m-01" 2>/dev/null || date -u -v1d -v-2m +"%Y-%m-01" 2>/dev/null)
    month2_end=$(date -u -d "$month1_start -1 day" +"%Y-%m-%d" 2>/dev/null || date -u -v1d -v-1m -v-1d +"%Y-%m-%d" 2>/dev/null)
    month3_start=$(date -u -d "$month2_start -1 month" +"%Y-%m-01" 2>/dev/null || date -u -v1d -v-3m +"%Y-%m-01" 2>/dev/null)
    month3_end=$(date -u -d "$month2_start -1 day" +"%Y-%m-%d" 2>/dev/null || date -u -v1d -v-2m -v-1d +"%Y-%m-%d" 2>/dev/null)

    jq -n \
        --arg m1s "$month1_start" --arg m1e "$month1_end" \
        --arg m2s "$month2_start" --arg m2e "$month2_end" \
        --arg m3s "$month3_start" --arg m3e "$month3_end" \
        '{
            month1: {start: $m1s, end: $m1e, label: $m1s},
            month2: {start: $m2s, end: $m2e, label: $m2s},
            month3: {start: $m3s, end: $m3e, label: $m3s}
        }'
}

discover_billing_table() {
    log "Discovering billing export table..."
    local bq_method
    bq_method=$(check_bigquery_access || true)
    [[ -z "$bq_method" ]] && return 1

    local search_projects=()
    if [[ -n "$PROJECT_IDS" ]]; then
        IFS=',' read -ra search_projects <<< "$PROJECT_IDS"
    else
        local current_project
        current_project=$(gcloud config get-value project 2>/dev/null || true)
        [[ -n "$current_project" ]] && search_projects=("$current_project")
    fi

    local proj_id dataset tables table billing_table
    for proj_id in "${search_projects[@]}"; do
        proj_id=$(echo "$proj_id" | xargs)
        [[ -z "$proj_id" ]] && continue
        datasets=$(bq ls --format=json --project_id="$proj_id" 2>/dev/null | jq -r '.[].datasetReference.datasetId' 2>/dev/null || true)
        while IFS= read -r dataset; do
            [[ -z "$dataset" ]] && continue
            tables=$(bq ls --format=json --project_id="$proj_id" "$dataset" 2>/dev/null | jq -r '.[].tableReference.tableId' 2>/dev/null || true)
            while IFS= read -r table; do
                [[ -z "$table" ]] && continue
                if [[ "$table" =~ ^gcp_billing_export_v1_ ]]; then
                    billing_table="${proj_id}.${dataset}.${table}"
                    log "Found billing table: $billing_table"
                    echo "$billing_table"
                    return 0
                fi
            done <<< "$tables"
        done <<< "$datasets"
    done
    return 1
}

resolve_billing_table() {
    local billing_table="${GCP_BILLING_EXPORT_TABLE:-}"
    billing_table=$(echo "$billing_table" | sed 's/^"//;s/"$//' | xargs)
    if [[ -z "$billing_table" ]]; then
        billing_table=$(discover_billing_table || true)
    fi
    [[ -z "$billing_table" ]] && return 1
    echo "$billing_table"
}

build_project_filter() {
    if [[ -z "$PROJECT_IDS" ]] || [[ "${GCP_ORG_WIDE_REPORT,,}" == "true" ]]; then
        echo ""
        return 0
    fi
    local project_list
    project_list=$(echo "$PROJECT_IDS" | tr ',' '\n' | sed "s/^[[:space:]]*//;s/[[:space:]]*$//;s/^/'/;s/$/'/" | paste -sd, -)
    echo "AND project.id IN (${project_list})"
}

run_bq_json_query() {
    local billing_table="$1"
    local query="$2"
    local billing_project
    billing_project="${billing_table%%.*}"

    local query_result json_result bq_method python_cmd
    if check_bq_available; then
        query_result=$(bq query --project_id="$billing_project" --use_legacy_sql=false --format=json --max_rows=100000 "$query" 2>&1) || {
            log "BigQuery query failed: $query_result"
            echo '[]'
            return 1
        }
        json_result=$(echo "$query_result" | grep -E '^\[' | head -1)
        [[ -z "$json_result" ]] && json_result='[]'
        echo "$json_result"
        return 0
    fi

    python_cmd=$(check_python_bq_available || true)
    if [[ -n "$python_cmd" ]]; then
        QUERY="$query" BILLING_PROJECT="$billing_project" "$python_cmd" - <<'PY'
import json
import os
from google.cloud import bigquery

client = bigquery.Client(project=os.environ["BILLING_PROJECT"])
rows = [dict(row.items()) for row in client.query(os.environ["QUERY"]).result()]
print(json.dumps(rows, default=str))
PY
        return 0
    fi

    echo '[]'
    return 1
}

write_access_issue() {
    local title="$1"
    local details="$2"
    local output_file="${3:-artifact_access_issues.json}"
    jq -n \
        --arg title "$title" \
        --arg details "$details" \
        --argjson severity 4 \
        '[{
            title: $title,
            severity: $severity,
            expected: "BigQuery billing export should be readable for artifact spend analysis",
            actual: $details,
            details: $details,
            next_steps: "Verify gcp_credentials has BigQuery Data Viewer and Job User on the billing export project. Set GCP_BILLING_EXPORT_TABLE if auto-discovery fails."
        }]' > "$output_file"
}

init_issues_file() {
    local file="$1"
    echo '[]' > "$file"
}

append_issue() {
    local issues_file="$1"
    local issue_json="$2"
    local tmp
    tmp=$(mktemp)
    jq --argjson issue "$issue_json" '. + [$issue]' "$issues_file" > "$tmp"
    mv "$tmp" "$issues_file"
}

query_artifact_cost_rows() {
    local billing_table="$1"
    local start_date="$2"
    local end_date="$3"
    local project_filter="$4"
    local sku_filter
    sku_filter=$(artifact_sku_filter_sql)

    local query="
SELECT
  project.id AS project_id,
  project.name AS project_name,
  service.description AS service_name,
  sku.description AS sku_description,
  DATE(usage_start_time) AS usage_date,
  SUM(cost) + SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)) AS total_cost,
  SUM(usage.amount_in_pricing_units) AS usage_amount,
  usage.pricing_unit AS usage_unit
FROM \`${billing_table}\`
WHERE DATE(usage_start_time) >= '${start_date}'
  AND DATE(usage_start_time) <= '${end_date}'
  AND ${sku_filter}
  ${project_filter}
GROUP BY project_id, project_name, service_name, sku_description, usage_date, usage_unit
ORDER BY usage_date DESC, total_cost DESC
"
    run_bq_json_query "$billing_table" "$query"
}

discover_projects_with_artifact_spend() {
    local billing_table="$1"
    local start_date="$2"
    local end_date="$3"
    local sku_filter project_filter query
    sku_filter=$(artifact_sku_filter_sql)
    project_filter=$(build_project_filter)

    query="
SELECT DISTINCT project.id AS project_id
FROM \`${billing_table}\`
WHERE DATE(usage_start_time) >= '${start_date}'
  AND DATE(usage_start_time) <= '${end_date}'
  AND ${sku_filter}
  ${project_filter}
ORDER BY project_id
"
    run_bq_json_query "$billing_table" "$query" | jq -r '.[].project_id' | paste -sd, -
}

ensure_billing_context() {
    local billing_table project_filter date_ranges
    billing_table=$(resolve_billing_table || true)
    if [[ -z "$billing_table" ]]; then
        write_access_issue "Cannot Access BigQuery Billing Export" "Billing export table not found. Set GCP_BILLING_EXPORT_TABLE or ensure billing export is configured."
        return 1
    fi

    if [[ -z "$PROJECT_IDS" ]]; then
        date_ranges=$(get_date_ranges)
        local lookback_start lookback_end discovered
        lookback_start=$(echo "$date_ranges" | jq -r '.lookback.start')
        lookback_end=$(echo "$date_ranges" | jq -r '.lookback.end')
        discovered=$(discover_projects_with_artifact_spend "$billing_table" "$lookback_start" "$lookback_end" || true)
        if [[ -n "$discovered" ]]; then
            PROJECT_IDS="$discovered"
            log "Auto-discovered projects with artifact spend: $PROJECT_IDS"
        fi
    fi

    project_filter=$(build_project_filter)
    date_ranges=$(get_date_ranges)
    BILLING_TABLE="$billing_table"
    PROJECT_FILTER="$project_filter"
    DATE_RANGES="$date_ranges"
    export BILLING_TABLE PROJECT_FILTER DATE_RANGES PROJECT_IDS
    return 0
}
