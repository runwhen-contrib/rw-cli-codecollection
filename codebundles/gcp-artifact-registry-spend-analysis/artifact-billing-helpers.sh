#!/usr/bin/env bash
# Shared helpers for GCP Artifact Registry spend analysis from BigQuery billing export.
set -euo pipefail

log() {
    echo "[artifact-spend $(date '+%H:%M:%S')] $*" >&2
}

ARTIFACT_SKU_FILTER="(
  LOWER(COALESCE(service.description, '')) LIKE '%artifact registry%'
  OR LOWER(COALESCE(sku.description, '')) LIKE '%artifact registry%'
  OR LOWER(COALESCE(service.description, '')) LIKE '%container registry%'
  OR LOWER(COALESCE(sku.description, '')) LIKE '%container registry%'
  OR LOWER(COALESCE(sku.description, '')) LIKE '%gcr.io%'
  OR LOWER(COALESCE(sku.description, '')) LIKE '%google container registry%'
)"

check_bq_available() {
    command -v bq &>/dev/null && bq version &>/dev/null
}

run_bq_query_json() {
    local billing_table="$1"
    local query="$2"
    local max_rows="${3:-10000}"

    IFS='.' read -r billing_project _ _ <<< "$billing_table"
    local result
    if ! result=$(bq query --project_id="$billing_project" --use_legacy_sql=false --format=json --max_rows="$max_rows" "$query" 2>&1); then
        log "BigQuery query failed: $result"
        return 1
    fi
    if echo "$result" | grep -qiE '^Error|^Access Denied|Not found:'; then
        log "BigQuery query error: $result"
        return 1
    fi
    echo "$result"
}

discover_billing_table() {
    log "Auto-discovering billing export table..."
    if ! check_bq_available; then
        log "bq CLI not available"
        return 1
    fi

    local projects
    projects=$(gcloud projects list --format='value(projectId)' 2>/dev/null | head -20 || true)
    [[ -z "$projects" ]] && projects=$(gcloud config get-value project 2>/dev/null || true)

    for proj_id in $projects; do
        [[ -z "$proj_id" ]] && continue
        local datasets
        datasets=$(bq ls --project_id="$proj_id" --format=json 2>/dev/null | jq -r '.[].datasetReference.datasetId' 2>/dev/null || true)
        while IFS= read -r dataset; do
            [[ -z "$dataset" ]] && continue
            local tables
            tables=$(bq ls --project_id="$proj_id" --format=json "$dataset" 2>/dev/null | jq -r '.[].tableReference.tableId' 2>/dev/null || true)
            while IFS= read -r table; do
                [[ -z "$table" ]] && continue
                if [[ "$table" =~ ^gcp_billing_export_v1_ ]]; then
                    local full_table="${proj_id}.${dataset}.${table}"
                    if bq show --format=json "$full_table" &>/dev/null; then
                        log "Found billing table: $full_table"
                        echo "$full_table"
                        return 0
                    fi
                fi
            done <<< "$tables"
        done <<< "$datasets"
    done
    return 1
}

resolve_billing_table() {
    local table="${GCP_BILLING_EXPORT_TABLE:-}"
    table=$(echo "$table" | sed 's/^"//;s/"$//' | xargs || true)
    if [[ -n "$table" ]]; then
        echo "$table"
        return 0
    fi
    discover_billing_table
}

normalize_project_ids() {
    local raw="${GCP_PROJECT_IDS:-}"
    raw=$(echo "$raw" | sed 's/^"//;s/"$//' | xargs || true)
    if [[ -z "$raw" || "$raw" == "All" || "$raw" == "all" ]]; then
        echo ""
        return 0
    fi
    echo "$raw" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | paste -sd, -
}

build_project_filter_sql() {
    local project_ids
    project_ids=$(normalize_project_ids)
    if [[ -z "$project_ids" ]]; then
        echo ""
        return 0
    fi
    local clauses=()
    IFS=',' read -ra ids <<< "$project_ids"
    for id in "${ids[@]}"; do
        id=$(echo "$id" | xargs)
        [[ -z "$id" ]] && continue
        clauses+=("project.id = '${id}'")
    done
    if [[ ${#clauses[@]} -eq 0 ]]; then
        echo ""
        return 0
    fi
    local joined
    joined=$(IFS=' OR '; echo "${clauses[*]}")
    echo "AND ($joined)"
}

get_lookback_days() {
    echo "${COST_ANALYSIS_LOOKBACK_DAYS:-30}"
}

get_date_range() {
    local lookback
    lookback=$(get_lookback_days)
    local end_date
    end_date=$(date -u +"%Y-%m-%d")
    local start_date
    start_date=$(date -u -d "${lookback} days ago" +"%Y-%m-%d" 2>/dev/null || date -u -v-"${lookback}"d +"%Y-%m-%d")
    echo "$start_date $end_date"
}

discover_projects_with_artifact_spend() {
    local billing_table="$1"
    local start_date="$2"
    local end_date="$3"
    local project_filter
    project_filter=$(build_project_filter_sql)

    local query="
SELECT project.id AS project_id, ROUND(SUM(cost), 2) AS total_cost
FROM \`${billing_table}\`
WHERE DATE(usage_start_time) BETWEEN '${start_date}' AND '${end_date}'
  AND ${ARTIFACT_SKU_FILTER}
  ${project_filter}
GROUP BY project.id
HAVING total_cost > 0
ORDER BY total_cost DESC
"
    run_bq_query_json "$billing_table" "$query" 500
}

write_access_issue() {
    local title="$1"
    local details="$2"
    local output_file="${3:-artifact_spend_issues.json}"
    jq -n \
        --arg title "$title" \
        --arg details "$details" \
        --arg next_steps "Verify gcp_credentials has BigQuery billing export read access and GCP_BILLING_EXPORT_TABLE is correct." \
        '[{
            title: $title,
            severity: 4,
            expected: "BigQuery billing export should be readable for artifact SKU analysis",
            actual: $details,
            details: $details,
            next_steps: $next_steps
        }]' > "$output_file"
}

ensure_billing_access() {
    local billing_table
    if ! billing_table=$(resolve_billing_table); then
        write_access_issue "Cannot Access BigQuery Billing Export" "Could not resolve or auto-discover GCP_BILLING_EXPORT_TABLE."
        return 1
    fi
    echo "$billing_table"
}
