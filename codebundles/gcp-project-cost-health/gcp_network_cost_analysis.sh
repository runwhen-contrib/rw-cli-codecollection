#!/bin/bash

# GCP Network Cost Analysis by SKU
# Analyzes network egress, ingress, and related costs broken down by SKU

set -euo pipefail

# Logging function
log() {
    echo "🌐 [$(date '+%H:%M:%S')] $*" >&2
}

# Environment Variables
PROJECT_IDS="${GCP_PROJECT_IDS}"
log "DEBUG: Initial GCP_PROJECT_IDS value: '${GCP_PROJECT_IDS}'"
log "DEBUG: Initial PROJECT_IDS value: '$PROJECT_IDS'"
# Normalize empty strings - remove quotes and trim whitespace
PROJECT_IDS=$(echo "$PROJECT_IDS" | sed 's/^"//;s/"$//' | xargs)
log "DEBUG: After normalization PROJECT_IDS value: '$PROJECT_IDS'"
LOOKBACK_DAYS="${COST_ANALYSIS_LOOKBACK_DAYS:-30}"

# Validate LOOKBACK_DAYS is a positive integer
if ! [[ "$LOOKBACK_DAYS" =~ ^[0-9]+$ ]] || [[ "$LOOKBACK_DAYS" -le 0 ]]; then
    echo "⚠️  Invalid COST_ANALYSIS_LOOKBACK_DAYS value: '$LOOKBACK_DAYS' (must be positive integer), defaulting to 30" >&2
    LOOKBACK_DAYS=30
fi

REPORT_FILE="${NETWORK_COST_REPORT_FILE:-gcp_network_cost_report.txt}"
JSON_FILE="${NETWORK_COST_JSON_FILE:-gcp_network_cost_report.json}"
CSV_FILE="${NETWORK_COST_CSV_FILE:-gcp_network_cost_report.csv}"
ISSUES_FILE="${NETWORK_COST_ISSUES_FILE:-gcp_network_cost_issues.json}"
OUTPUT_FORMAT="${OUTPUT_FORMAT:-all}"
# Minimum monthly network cost threshold to raise anomaly issues (default: $50/month)
NETWORK_COST_THRESHOLD_MONTHLY="${NETWORK_COST_THRESHOLD_MONTHLY:-50}"

# Validate NETWORK_COST_THRESHOLD_MONTHLY is a non-negative number
if ! [[ "$NETWORK_COST_THRESHOLD_MONTHLY" =~ ^[0-9]+(\.[0-9]+)?$ ]] || (( $(echo "$NETWORK_COST_THRESHOLD_MONTHLY < 0" | bc -l 2>/dev/null || echo 1) )); then
    echo "⚠️  Invalid NETWORK_COST_THRESHOLD_MONTHLY value: '$NETWORK_COST_THRESHOLD_MONTHLY' (must be non-negative number), defaulting to 50" >&2
    NETWORK_COST_THRESHOLD_MONTHLY=50
fi

# Initialize issues JSON
echo '[]' > "$ISSUES_FILE"

# Source common functions from the main cost script
source_common_functions() {
    # Check if bq command is available
    check_bq_available() {
        if command -v bq &> /dev/null; then
            return 0
        fi
        # Check common installation paths (use ${HOME:-/root} to avoid unbound variable error)
        local home_dir="${HOME:-/root}"
        if [[ -f "$home_dir/google-cloud-sdk/bin/bq" ]] || [[ -f "/usr/local/bin/bq" ]] || [[ -f "/opt/google-cloud-sdk/bin/bq" ]]; then
            return 0
        fi
        return 1
    }

    # Check if Python BigQuery client is available
    check_python_bq_available() {
        if command -v python3 &> /dev/null || command -v python &> /dev/null; then
            local python_cmd=$(command -v python3 2>/dev/null || command -v python 2>/dev/null)
            if $python_cmd -c "from google.cloud import bigquery" 2>/dev/null; then
                echo "$python_cmd"
                return 0
            fi
        fi
        return 1
    }

    # Check for any BigQuery access method
    check_bigquery_access() {
        if check_bq_available; then
            if bq version &>/dev/null || bq --version &>/dev/null || bq help &>/dev/null; then
                echo "bq"
                return 0
            else
                echo "⚠️  'bq' command found but not working properly, falling back to Python" >&2
            fi
        fi
        
        local python_cmd=$(check_python_bq_available)
        if [[ -n "$python_cmd" ]]; then
            echo "python"
            return 0
        fi
        
        return 1
    }
}

source_common_functions

# Get date ranges for different periods
get_date_ranges() {
    local end_date=$(date -u +"%Y-%m-%d")
    
    # Last 7 days (individual days)
    declare -a daily_dates
    for i in {0..6}; do
        daily_dates[$i]=$(date -u -d "${i} days ago" +"%Y-%m-%d" 2>/dev/null || date -u -v-${i}d +"%Y-%m-%d" 2>/dev/null)
    done
    
    # Weekly (last 7 days)
    local week_start=$(date -u -d '7 days ago' +"%Y-%m-%d" 2>/dev/null || date -u -v-7d +"%Y-%m-%d" 2>/dev/null)
    local week_end=$end_date
    
    # Monthly (last 30 days)
    local month_start=$(date -u -d '30 days ago' +"%Y-%m-%d" 2>/dev/null || date -u -v-30d +"%Y-%m-%d" 2>/dev/null)
    local month_end=$end_date
    
    # Full lookback period (configurable, default 30 days)
    local lookback_start=$(date -u -d "${LOOKBACK_DAYS} days ago" +"%Y-%m-%d" 2>/dev/null || date -u -v-${LOOKBACK_DAYS}d +"%Y-%m-%d" 2>/dev/null)
    local lookback_end=$end_date
    
    # Output as JSON
    jq -n \
        --arg d0 "${daily_dates[0]}" \
        --arg d1 "${daily_dates[1]}" \
        --arg d2 "${daily_dates[2]}" \
        --arg d3 "${daily_dates[3]}" \
        --arg d4 "${daily_dates[4]}" \
        --arg d5 "${daily_dates[5]}" \
        --arg d6 "${daily_dates[6]}" \
        --arg week_start "$week_start" \
        --arg week_end "$week_end" \
        --arg month_start "$month_start" \
        --arg month_end "$month_end" \
        --arg lookback_start "$lookback_start" \
        --arg lookback_end "$lookback_end" \
        --argjson lookback_days "$LOOKBACK_DAYS" \
        '{
            daily: [$d6, $d5, $d4, $d3, $d2, $d1, $d0],
            weekly: {start: $week_start, end: $week_end},
            monthly: {start: $month_start, end: $month_end},
            lookback: {start: $lookback_start, end: $lookback_end, days: $lookback_days}
        }'
}

# Discover billing table (re-use logic from main cost script)
discover_billing_table() {
    log "Discovering billing export table..."
    
    local bq_method=$(check_bigquery_access)
    if [[ -z "$bq_method" ]]; then
        log "❌ No BigQuery access method found"
        return 1
    fi
    
    local current_project=$(gcloud config get-value project 2>/dev/null || echo "")
    local billing_table=""
    
    # Try to find billing export table
    if [[ -n "$PROJECT_IDS" ]]; then
        IFS=',' read -ra PROJ_ARRAY <<< "$PROJECT_IDS"
        for proj_id in "${PROJ_ARRAY[@]}"; do
            proj_id=$(echo "$proj_id" | xargs)
            [[ -z "$proj_id" ]] && continue
            
            local datasets=""
            if [[ "$bq_method" == "bq" ]]; then
                datasets=$(bq ls --format=json --project_id="$proj_id" 2>&1 | jq -r '.[].datasetReference.datasetId' 2>/dev/null || echo "")
            fi
            
            while IFS= read -r dataset; do
                [[ -z "$dataset" ]] && continue
                
                if [[ "$bq_method" == "bq" ]]; then
                    local tables=$(bq ls --format=json --project_id="$proj_id" "$dataset" 2>&1 | jq -r '.[].tableReference.tableId' 2>/dev/null || echo "")
                    
                    while IFS= read -r table; do
                        [[ -z "$table" ]] && continue
                        
                        if [[ "$table" =~ ^gcp_billing_export_v1_ ]]; then
                            billing_table="${proj_id}.${dataset}.${table}"
                            log "✅ Found billing table: $billing_table"
                            echo "$billing_table"
                            return 0
                        fi
                    done <<< "$tables"
                fi
            done <<< "$datasets"
        done
    fi
    
    return 1
}

# Query monthly network cost summary by SKU (lightweight - for threshold filtering)
query_network_costs_summary() {
    local billing_table="$1"
    local start_date="$2"
    local end_date="$3"
    local project_filter="$4"
    
    local billing_project=$(echo "$billing_table" | cut -d'.' -f1)
    
    # Lightweight query - just get monthly totals per SKU
    local query="
    SELECT 
        service.description as service_name,
        sku.description as sku_description,
        SUM(cost) as monthly_cost
    FROM \`${billing_table}\`
    WHERE DATE(usage_start_time) >= '${start_date}'
      AND DATE(usage_start_time) <= '${end_date}'
      AND (
          service.description LIKE '%Network%' 
          OR service.description LIKE '%Networking%'
          OR service.description = 'Networking'
          OR service.description LIKE '%VPC%'
          OR service.description LIKE '%CDN%'
          OR service.description LIKE '%Interconnect%'
          OR service.description LIKE '%VPN%'
          OR service.description LIKE '%NAT%'
          OR service.description LIKE '%Load Balancing%'
          OR sku.description LIKE '%Egress%'
          OR sku.description LIKE '%Ingress%'
          OR sku.description LIKE '%Network%'
          OR sku.description LIKE '%Data Transfer%'
          OR sku.description LIKE '%Inter Zone%'
          OR sku.description LIKE '%Intra Zone%'
          OR sku.description LIKE '%Inter Region%'
      )
      ${project_filter}
    GROUP BY service_name, sku_description
    HAVING monthly_cost >= ${NETWORK_COST_THRESHOLD_MONTHLY}
    ORDER BY monthly_cost DESC
    "
    
    log "📊 Querying network cost summary (SKUs >= \$${NETWORK_COST_THRESHOLD_MONTHLY}/month)..."
    log "DEBUG: Summary query SQL:"
    log "$query"
    
    local query_result=""
    local bq_method=$(check_bigquery_access)
    
    if check_bq_available; then
        query_result=$(bq query --project_id="$billing_project" --use_legacy_sql=false --format=json --max_rows=1000 "$query" 2>&1)
        local query_exit=$?
        
        if [[ $query_exit -ne 0 ]]; then
            log "❌ Summary query failed"
            echo '[]'
            return 1
        fi
        
        local json_result=$(echo "$query_result" | grep -E '^\[' | head -1)
        if [[ -z "$json_result" ]]; then
            log "❌ No valid JSON from summary query"
            echo '[]'
        else
            echo "$json_result"
        fi
    else
        local python_cmd=$(check_python_bq_available)
        if [[ -n "$python_cmd" ]]; then
            log "DEBUG: Using Python command: $python_cmd"
            query_result=$($python_cmd -c "
from google.cloud import bigquery
import json
import sys

try:
    client = bigquery.Client(project='$billing_project')
    query = '''$query'''
    query_job = client.query(query)
    results = query_job.result()
    
    rows = []
    for row in results:
        rows.append({
            'service_name': row['service_name'],
            'sku_description': row['sku_description'],
            'monthly_cost': float(row['monthly_cost'])
        })
    
    print(json.dumps(rows))
except Exception as e:
    sys.stderr.write(f'Error: {e}\n')
    sys.exit(1)
" 2>&1)
            local python_exit=$?
            
            if [[ $python_exit -ne 0 ]]; then
                log "❌ Python summary query failed"
                echo '[]'
                return 1
            fi
            
            if echo "$query_result" | grep -qi "error"; then
                log "❌ Python query error: $(echo "$query_result" | head -5)"
                echo '[]'
            else
                echo "$query_result" | jq -r '.' 2>/dev/null || echo '[]'
            fi
        else
            log "❌ No BigQuery access method available"
            echo '[]'
            return 1
        fi
    fi
}

# Query detailed network costs by SKU for specific SKUs (after threshold filter)
query_network_costs() {
    local billing_table="$1"
    local start_date="$2"
    local end_date="$3"
    local project_filter="$4"
    local sku_filter="${5:-}"  # Optional SKU filter (JSON array of SKU descriptions)
    
    local billing_project=$(echo "$billing_table" | cut -d'.' -f1)
    
    # Build SKU WHERE clause if filter provided
    local sku_where_clause=""
    if [[ -n "$sku_filter" && "$sku_filter" != "[]" ]]; then
        # Convert JSON array to SQL IN clause
        local sku_list=$(echo "$sku_filter" | jq -r '.[] | @json' | paste -sd ',' -)
        if [[ -n "$sku_list" ]]; then
            sku_where_clause="AND sku.description IN ($sku_list)"
            log "DEBUG: Filtering to $(echo "$sku_filter" | jq 'length') specific SKUs above threshold"
        fi
    fi
    
    # Network-related service patterns
    # Covers: Networking service, Compute Engine Network, VPC, Cloud CDN, Cloud Interconnect, 
    # Cloud VPN, Cloud NAT, Load Balancing, plus all SKUs with Egress, Ingress, Network, 
    # Data Transfer, Inter Zone, Intra Zone, and Inter Region patterns
    local query="
    SELECT 
        DATE(usage_start_time) as usage_date,
        project.id as project_id,
        project.name as project_name,
        service.description as service_name,
        sku.description as sku_description,
        SUM(cost) as total_cost,
        SUM(usage.amount) as usage_amount,
        usage.unit as usage_unit
    FROM \`${billing_table}\`
    WHERE DATE(usage_start_time) >= '${start_date}'
      AND DATE(usage_start_time) <= '${end_date}'
      AND (
          service.description LIKE '%Network%' 
          OR service.description LIKE '%Networking%'
          OR service.description = 'Networking'
          OR service.description LIKE '%VPC%'
          OR service.description LIKE '%CDN%'
          OR service.description LIKE '%Interconnect%'
          OR service.description LIKE '%VPN%'
          OR service.description LIKE '%NAT%'
          OR service.description LIKE '%Load Balancing%'
          OR sku.description LIKE '%Egress%'
          OR sku.description LIKE '%Ingress%'
          OR sku.description LIKE '%Network%'
          OR sku.description LIKE '%Data Transfer%'
          OR sku.description LIKE '%Inter Zone%'
          OR sku.description LIKE '%Intra Zone%'
          OR sku.description LIKE '%Inter Region%'
      )
      ${project_filter}
      ${sku_where_clause}
    GROUP BY usage_date, project_id, project_name, service_name, sku_description, usage_unit
    HAVING total_cost > 0
    ORDER BY usage_date DESC, total_cost DESC
    "
    
    log "Querying network costs from $start_date to $end_date"
    log "DEBUG: Full query SQL:"
    log "$query"
    
    # Check which method we'll use
    local bq_method=$(check_bigquery_access)
    log "DEBUG: Using BigQuery access method: $bq_method"
    
    local query_result=""
    if check_bq_available; then
        log "DEBUG: Attempting bq CLI query..."
        query_result=$(bq query --project_id="$billing_project" --use_legacy_sql=false --format=json --max_rows=100000 "$query" 2>&1)
        local query_exit=$?
        
        if [[ $query_exit -ne 0 ]]; then
            log "❌ Query failed (exit code: $query_exit)"
            echo '[]'
            return 1
        fi
        
        # Don't filter out errors - we need to see them!
        local json_result=$(echo "$query_result" | grep -E '^\[' | head -1)
        if [[ -z "$json_result" ]]; then
            log "❌ No valid JSON result from query"
            log "Query output: $query_result"
            echo '[]'
        else
            echo "$json_result"
        fi
    else
        log "DEBUG: bq CLI not available, trying Python..."
        local python_cmd=$(check_python_bq_available)
        if [[ -n "$python_cmd" ]]; then
            log "DEBUG: Using Python command: $python_cmd"
            query_result=$($python_cmd -c "
from google.cloud import bigquery
import json
import sys

try:
    client = bigquery.Client()
    query_job = client.query('''${query}''')
    results = query_job.result(max_results=100000)
    rows = []
    for row in results:
        rows.append({
            'usage_date': str(row.usage_date),
            'project_id': row.project_id,
            'project_name': row.project_name,
            'service_name': row.service_name,
            'sku_description': row.sku_description,
            'total_cost': float(row.total_cost),
            'usage_amount': float(row.usage_amount) if row.usage_amount else 0,
            'usage_unit': row.usage_unit if row.usage_unit else ''
        })
    print(json.dumps(rows))
except Exception as e:
    sys.stderr.write(f'Error: {e}\n')
    sys.exit(1)
" 2>&1)
            local python_exit=$?
            
            if [[ $python_exit -ne 0 ]]; then
                log "❌ Query failed"
                echo '[]'
                return 1
            fi
            
            # Show errors instead of hiding them
            if echo "$query_result" | grep -qi "error"; then
                log "❌ Python query error: $query_result"
                
                # Store error for issue generation in main
                echo "QUERY_ERROR" > /tmp/network_query_error.flag
                echo "$query_result" > /tmp/network_query_error.txt
                
                echo '[]'
            else
                echo "$query_result"
            fi
        else
            log "❌ No BigQuery access method available"
            echo '[]'
            return 1
        fi
    fi
}

# Aggregate network costs by time period
aggregate_network_costs() {
    local cost_data="$1"
    local date_ranges="$2"
    
    # Extract dates from date_ranges
    local daily_dates=$(echo "$date_ranges" | jq -r '.daily[]')
    local week_start=$(echo "$date_ranges" | jq -r '.weekly.start')
    local week_end=$(echo "$date_ranges" | jq -r '.weekly.end')
    local month_start=$(echo "$date_ranges" | jq -r '.monthly.start')
    local month_end=$(echo "$date_ranges" | jq -r '.monthly.end')
    local lookback_start=$(echo "$date_ranges" | jq -r '.lookback.start')
    local lookback_end=$(echo "$date_ranges" | jq -r '.lookback.end')
    
    echo "$cost_data" | jq \
        --argjson dates "$date_ranges" \
        '
        # Group by SKU across all data
        group_by(.sku_description) | 
        map(. as $sku_records | {
            sku: $sku_records[0].sku_description,
            service: $sku_records[0].service_name,
            totalCost: ($sku_records | map(.total_cost | tonumber) | add),
            totalUsage: ($sku_records | map(.usage_amount | tonumber) | add),
            usageUnit: $sku_records[0].usage_unit,
            projects: ($sku_records | group_by(.project_id) | map({
                projectId: .[0].project_id,
                projectName: .[0].project_name,
                cost: (map(.total_cost | tonumber) | add)
            }) | sort_by(-.cost)),
            # Aggregate by time periods
            daily: ($dates.daily | map(. as $date | {
                date: $date,
                cost: ([$sku_records[] | select(.usage_date == $date) | .total_cost | tonumber] | add // 0)
            })),
            weekly: {
                startDate: $dates.weekly.start,
                endDate: $dates.weekly.end,
                cost: ([$sku_records[] | select(.usage_date >= $dates.weekly.start and .usage_date <= $dates.weekly.end) | .total_cost | tonumber] | add // 0)
            },
            monthly: {
                startDate: $dates.monthly.start,
                endDate: $dates.monthly.end,
                cost: ([$sku_records[] | select(.usage_date >= $dates.monthly.start and .usage_date <= $dates.monthly.end) | .total_cost | tonumber] | add // 0)
            },
            quarterly: {
                startDate: $dates.lookback.start,
                endDate: $dates.lookback.end,
                cost: ([$sku_records[] | select(.usage_date >= $dates.lookback.start and .usage_date <= $dates.lookback.end) | .total_cost | tonumber] | add // 0)
            }
        }) |
        sort_by(-.totalCost)
        '
}

# Detect cost anomalies and deviations
detect_cost_anomalies() {
    local aggregated_data="$1"
    
    log "Detecting anomalies in pre-filtered SKUs (already filtered by \$${NETWORK_COST_THRESHOLD_MONTHLY}/month threshold)"
    
    local issues='[]'
    
    # Check for significant daily spikes (2x average daily cost)
    # Note: Data is already filtered to SKUs >= threshold, so no need to re-check
    while IFS= read -r sku_data; do
        local sku=$(echo "$sku_data" | jq -r '.sku')
        local service=$(echo "$sku_data" | jq -r '.service')
        local daily_costs=$(echo "$sku_data" | jq -r '.daily[].cost')
        
        # Calculate average daily cost (excluding zeros)
        local avg_daily=$(echo "$daily_costs" | awk 'BEGIN{sum=0; count=0} $1>0{sum+=$1; count++} END{if(count>0) print sum/count; else print 0}')
        
        # Check each day for spikes
        while IFS= read -r day; do
            local date=$(echo "$day" | jq -r '.date')
            local cost=$(echo "$day" | jq -r '.cost')
            
            # Skip if no cost or average is zero
            if (( $(echo "$cost > 0" | bc -l) )) && (( $(echo "$avg_daily > 0" | bc -l) )); then
                local multiplier=$(echo "scale=2; $cost / $avg_daily" | bc -l)
                
                # Alert if cost is 2x or more than average
                if (( $(echo "$multiplier >= 2.0" | bc -l) )); then
                    local issue=$(jq -n \
                        --arg title "Network Cost Spike Detected: $sku" \
                        --argjson severity 2 \
                        --arg sku "$sku" \
                        --arg service "$service" \
                        --arg date "$date" \
                        --arg cost "$cost" \
                        --arg avg "$avg_daily" \
                        --arg multiplier "$multiplier" \
                        '{
                            title: $title,
                            severity: $severity,
                            expected: ("Daily network cost for " + $sku + " should be around $" + $avg + " (7-day average)"),
                            actual: ("Cost on " + $date + " was $" + $cost + ", which is " + $multiplier + "x the average"),
                            details: ("Service: " + $service + "\nSKU: " + $sku + "\nDate: " + $date + "\nCost: $" + $cost + "\n7-day average: $" + $avg + "\nMultiplier: " + $multiplier + "x"),
                            reproduce_hint: ("Review network usage metrics and traffic patterns for " + $date),
                            next_steps: "1. Investigate network traffic patterns on the spike date\n2. Check for unexpected data transfers or traffic spikes\n3. Review application logs for unusual activity\n4. Consider implementing network egress optimizations"
                        }')
                    
                    issues=$(echo "$issues" | jq --argjson issue "$issue" '. + [$issue]')
                    log "⚠️  Spike detected for $sku on $date: \$$cost ($multiplier x average)"
                fi
            fi
        done < <(echo "$sku_data" | jq -c '.daily[]')
    done < <(echo "$aggregated_data" | jq -c '.[]')
    
    # Check for significant weekly vs monthly cost increases (50% increase)
    # Note: Data is already filtered to SKUs >= threshold
    while IFS= read -r sku_data; do
        local sku=$(echo "$sku_data" | jq -r '.sku')
        local service=$(echo "$sku_data" | jq -r '.service')
        local weekly_cost=$(echo "$sku_data" | jq -r '.weekly.cost')
        local monthly_cost=$(echo "$sku_data" | jq -r '.monthly.cost')
        
        # Skip if no meaningful data
        if (( $(echo "$monthly_cost > 0" | bc -l) )) && (( $(echo "$weekly_cost > 0" | bc -l) )); then
            # Expected weekly cost should be ~1/4 of monthly (30-day) cost
            local expected_weekly=$(echo "scale=2; $monthly_cost * 7 / 30" | bc -l)
            local weekly_ratio=$(echo "scale=2; $weekly_cost / $expected_weekly" | bc -l)
            
            # Alert if weekly cost is 1.5x or more than expected
            if (( $(echo "$weekly_ratio >= 1.5" | bc -l) )); then
                local increase_percent=$(echo "scale=1; ($weekly_ratio - 1) * 100" | bc -l)
                
                local issue=$(jq -n \
                    --arg title "Elevated Network Costs (Weekly): $sku" \
                    --argjson severity 3 \
                    --arg sku "$sku" \
                    --arg service "$service" \
                    --arg weekly "$weekly_cost" \
                    --arg expected "$expected_weekly" \
                    --arg increase "$increase_percent" \
                    '{
                        title: $title,
                        severity: $severity,
                        expected: ("Weekly network cost for " + $sku + " should be around $" + $expected + " based on monthly trend"),
                        actual: ("Last 7 days cost was $" + $weekly + ", " + $increase + "% higher than expected"),
                        details: ("Service: " + $service + "\nSKU: " + $sku + "\nLast 7 days: $" + $weekly + "\nExpected (based on monthly): $" + $expected + "\nIncrease: " + $increase + "%"),
                        reproduce_hint: "Compare weekly network costs to monthly averages",
                        next_steps: "1. Review recent changes in network architecture or traffic patterns\n2. Check for new services or applications generating network traffic\n3. Investigate egress patterns and destinations\n4. Consider cost optimization strategies (CDN, Cloud Interconnect, etc.)"
                    }')
                
                issues=$(echo "$issues" | jq --argjson issue "$issue" '. + [$issue]')
                log "⚠️  Weekly cost elevation for $sku: \$$weekly_cost vs expected \$$expected_weekly ($increase_percent% increase)"
            fi
        fi
    done < <(echo "$aggregated_data" | jq -c '.[]')
    
    # Generate informational issues for high-cost SKUs (above threshold)
    # This alerts on consistently high costs, not just anomalies
    log "Generating high-cost awareness alerts for SKUs above threshold..."
    while IFS= read -r sku_data; do
        local sku=$(echo "$sku_data" | jq -r '.sku')
        local service=$(echo "$sku_data" | jq -r '.service')
        local monthly_cost=$(echo "$sku_data" | jq -r '.monthly.cost')
        local total_cost=$(echo "$sku_data" | jq -r '.totalCost')
        
        # Generate informational issue for any SKU above threshold
        # This is not an anomaly - just awareness that this SKU is expensive
        if (( $(echo "$monthly_cost >= ${NETWORK_COST_THRESHOLD_MONTHLY}" | bc -l) )); then
            # Determine severity based on cost level
            local severity=4  # Default: Low (informational)
            if (( $(echo "$monthly_cost >= 1000" | bc -l) )); then
                severity=3  # Medium for costs >= $1000/month
            fi
            if (( $(echo "$monthly_cost >= 5000" | bc -l) )); then
                severity=2  # High for costs >= $5000/month
            fi
            
            local issue=$(jq -n \
                --arg title "High Network Cost: $sku" \
                --argjson severity "$severity" \
                --arg sku "$sku" \
                --arg service "$service" \
                --arg monthly "$monthly_cost" \
                --arg threshold "$NETWORK_COST_THRESHOLD_MONTHLY" \
                '{
                    title: $title,
                    severity: $severity,
                    expected: ("Network costs for individual SKUs should be reviewed when exceeding $" + $threshold + "/month"),
                    actual: ("Currently spending $" + $monthly + "/month on " + $sku),
                    details: ("Service: " + $service + "\nSKU: " + $sku + "\nMonthly Cost (30 days): $" + $monthly + "\nThreshold: $" + $threshold + "\n\nThis is a high-cost network SKU that warrants review for potential optimization opportunities."),
                    reproduce_hint: "Review network traffic patterns and usage for this SKU in GCP Console",
                    next_steps: "1. Review if this network cost is expected and necessary\n2. Investigate optimization opportunities (CDN, Cloud Interconnect, compression)\n3. Check for inefficient data transfer patterns\n4. Consider architecture changes to reduce egress/transfer costs\n5. Review if workloads can be colocated to reduce inter-zone/region transfers"
                }')
            
            issues=$(echo "$issues" | jq --argjson issue "$issue" '. + [$issue]')
            log "ℹ️  High-cost SKU alert generated for $sku: \$$monthly_cost/month (threshold: \$$NETWORK_COST_THRESHOLD_MONTHLY)"
        fi
    done < <(echo "$aggregated_data" | jq -c '.[]')
    
    echo "$issues"
}

# Generate text report
generate_text_report() {
    local aggregated_data="$1"
    local date_ranges="$2"
    
    local total_cost=$(echo "$aggregated_data" | jq '[.[].totalCost] | add // 0 | (. * 100 | round) / 100')
    local sku_count=$(echo "$aggregated_data" | jq 'length')
    
    local week_start=$(echo "$date_ranges" | jq -r '.weekly.start')
    local week_end=$(echo "$date_ranges" | jq -r '.weekly.end')
    local month_start=$(echo "$date_ranges" | jq -r '.monthly.start')
    local month_end=$(echo "$date_ranges" | jq -r '.monthly.end')
    local lookback_start=$(echo "$date_ranges" | jq -r '.lookback.start')
    local lookback_end=$(echo "$date_ranges" | jq -r '.lookback.end')
    
    cat > "$REPORT_FILE" << EOF
╔══════════════════════════════════════════════════════════════════════╗
║          GCP NETWORK COST ANALYSIS BY SKU                            ║
╚══════════════════════════════════════════════════════════════════════╝

📊 NETWORK COST SUMMARY
$(printf '═%.0s' {1..72})

   💰 Total Network Cost ($LOOKBACK_DAYS days):       \$$total_cost
   🔍 Unique Network SKUs:                $sku_count
   📅 Analysis Period:                    $lookback_start to $lookback_end

$(printf '═%.0s' {1..72})

🌐 TOP 10 NETWORK SKUs BY COST
$(printf '═%.0s' {1..72})

EOF

    # Top 10 SKUs summary
    echo "$aggregated_data" | jq -r '
        .[:10] |
        to_entries |
        map(
            ((.key + 1) | tostring | if length == 1 then " " + . else . end) + 
            ". " + 
            (.value.sku | 
                if length > 45 then .[:42] + "..." else . + (" " * (45 - length)) end
            ) + 
            "  $" + 
            ((.value.totalCost | . * 100 | round / 100 | tostring) as $cost |
             if ($cost | contains(".")) then
                 ($cost | split(".") | 
                  if (.[1] | length) == 1 then .[0] + "." + .[1] + "0"
                  else $cost end)
             else
                 $cost + ".00"
             end |
             if length < 9 then (" " * (9 - length)) + . else . end
            )
        ) |
        join("\n")
    ' >> "$REPORT_FILE"

    cat >> "$REPORT_FILE" << EOF

$(printf '═%.0s' {1..72})

📈 DETAILED BREAKDOWN BY SKU
$(printf '═%.0s' {1..72})

EOF

    # Detailed breakdown per SKU
    echo "$aggregated_data" | jq -r --arg sep "$(printf '─%.0s' {1..72})" --arg days "$LOOKBACK_DAYS" '
        .[] | 
        "
🔹 SKU: " + .sku + "
   Service: " + .service + "
   Total Cost (" + $days + " days): $" + (((.totalCost // 0) * 100 | round) / 100 | tostring) + "
   
   📅 DAILY SPEND (Last 7 Days):
" + (
    .daily | 
    map("      " + .date + ":  $" + (((.cost // 0) * 100 | round) / 100 | tostring)) | 
    join("\n")
) + "
   
   📊 AGGREGATED SPEND:
      Last 7 Days:   $" + (((.weekly.cost // 0) * 100 | round) / 100 | tostring) + "
      Last 30 Days:  $" + (((.monthly.cost // 0) * 100 | round) / 100 | tostring) + "
      Last " + $days + " Days:  $" + (((.lookback.cost // 0) * 100 | round) / 100 | tostring) + "
   
   🏢 TOP PROJECTS:
" + (
    .projects[:5] | 
    map("      • " + .projectName + ": $" + (((.cost // 0) * 100 | round) / 100 | tostring)) | 
    join("\n")
) + "
   " + (if (.projects | length) > 5 then "... and " + ((.projects | length) - 5 | tostring) + " more projects" else "" end) + "
" + $sep
    ' >> "$REPORT_FILE"

    cat >> "$REPORT_FILE" << EOF

$(printf '═%.0s' {1..72})

💡 NETWORK COST OPTIMIZATION TIPS:
   • Use Cloud CDN to cache content closer to users
   • Consider Cloud Interconnect for high-volume data transfers
   • Review egress charges and optimize data transfer patterns
   • Use compression for data transfers
   • Implement Cloud NAT for outbound traffic
   • Leverage Google's internal network (Premium vs Standard Tier)
   • Monitor and optimize inter-region data transfers

EOF
    
    log "Network cost report saved to: $REPORT_FILE"
}

# Generate JSON report
generate_json_report() {
    local aggregated_data="$1"
    local date_ranges="$2"
    
    local total_cost=$(echo "$aggregated_data" | jq '[.[].totalCost] | add // 0 | (. * 100 | round) / 100')
    
    jq -n \
        --argjson data "$aggregated_data" \
        --argjson ranges "$date_ranges" \
        --arg total "$total_cost" \
        '{
            reportType: "GCP Network Cost Analysis",
            totalCost: ($total | tonumber),
            currency: "USD",
            dateRanges: $ranges,
            skus: $data
        }' > "$JSON_FILE"
    
    log "JSON report saved to: $JSON_FILE"
}

# Generate CSV report
generate_csv_report() {
    local aggregated_data="$1"
    
    echo "SKU,Service,TotalCost,UsageAmount,UsageUnit,Day0,Day1,Day2,Day3,Day4,Day5,Day6,Weekly,Monthly,Quarterly" > "$CSV_FILE"
    
    echo "$aggregated_data" | jq -r '
        .[] |
        [
            .sku,
            .service,
            (.totalCost | tostring),
            (.totalUsage | tostring),
            .usageUnit,
            (.daily[6].cost | tostring),
            (.daily[5].cost | tostring),
            (.daily[4].cost | tostring),
            (.daily[3].cost | tostring),
            (.daily[2].cost | tostring),
            (.daily[1].cost | tostring),
            (.daily[0].cost | tostring),
            (.weekly.cost | tostring),
            (.monthly.cost | tostring),
            (.lookback.cost | tostring)
        ] |
        @csv
    ' >> "$CSV_FILE"
    
    log "CSV report saved to: $CSV_FILE"
}

# Main function
main() {
    log "Starting GCP Network Cost Analysis"
    
    # Get BigQuery billing table
    local BILLING_TABLE="${GCP_BILLING_EXPORT_TABLE}"
    if [[ -z "$BILLING_TABLE" ]]; then
        log "Attempting to discover billing table..."
        BILLING_TABLE=$(discover_billing_table)
        if [[ -z "$BILLING_TABLE" ]]; then
            echo "Error: Could not find billing export table"
            echo "Please set GCP_BILLING_EXPORT_TABLE environment variable"
            exit 1
        fi
    fi
    
    log "Using billing table: $BILLING_TABLE"
    
    # Get date ranges
    local date_ranges=$(get_date_ranges)
    log "Date ranges configured for analysis"
    
    # Build project filter
    local project_filter=""
    if [[ -n "$PROJECT_IDS" ]]; then
        # Convert comma-separated list to SQL IN clause
        local project_list=$(echo "$PROJECT_IDS" | tr ',' '\n' | sed "s/^/'/;s/$/'/" | tr '\n' ',' | sed 's/,$//')
        project_filter="AND project.id IN ($project_list)"
        log "Filtering by projects: $PROJECT_IDS"
    fi
    
    # Query network costs (use quarterly range to get all data)
    local lookback_start=$(echo "$date_ranges" | jq -r '.lookback.start')
    local lookback_end=$(echo "$date_ranges" | jq -r '.lookback.end')
    
    log "DEBUG: Querying from $lookback_start to $lookback_end"
    log "DEBUG: Project filter: '$project_filter'"
    
    # STEP 1: Get summary of monthly costs to filter by threshold
    log "🔍 Step 1: Getting monthly cost summary (threshold: \$${NETWORK_COST_THRESHOLD_MONTHLY})"
    local cost_summary=$(query_network_costs_summary "$BILLING_TABLE" "$lookback_start" "$lookback_end" "$project_filter")
    local summary_sku_count=$(echo "$cost_summary" | jq 'length' 2>/dev/null || echo "0")
    
    if [[ $summary_sku_count -eq 0 ]]; then
        log "⚠️  No network SKUs found with monthly cost >= \$${NETWORK_COST_THRESHOLD_MONTHLY}"
        log "💡 This means all network costs are below the alert threshold"
        
        cat > "$REPORT_FILE" << EOF
╔══════════════════════════════════════════════════════════════════════╗
║          GCP NETWORK COST ANALYSIS BY SKU                            ║
╚══════════════════════════════════════════════════════════════════════╝

ℹ️  ALL NETWORK COSTS BELOW THRESHOLD

Analysis Period: $lookback_start to $lookback_end
Cost Threshold: \$${NETWORK_COST_THRESHOLD_MONTHLY}/month

Your network costs are all below the configured threshold of \$${NETWORK_COST_THRESHOLD_MONTHLY}/month.
This means:
• Network spending is minimal (likely just a few dollars)
• No anomaly alerts will be generated for these costs
• Detailed SKU breakdown skipped to save query costs

To see all network costs regardless of threshold, set:
  NETWORK_COST_THRESHOLD_MONTHLY=0

EOF
        log "Report saved to: $REPORT_FILE"
        echo '[]' > "$ISSUES_FILE"
        exit 0
    fi
    
    log "✅ Found $summary_sku_count SKUs above threshold"
    log "💰 SKUs to analyze: $(echo "$cost_summary" | jq -r '.[].sku_description' | head -5 | paste -sd ', ' -)"
    if [[ $summary_sku_count -gt 5 ]]; then
        log "   ... and $((summary_sku_count - 5)) more"
    fi
    
    # STEP 2: Extract SKU list for detailed query
    local sku_filter=$(echo "$cost_summary" | jq -c '[.[].sku_description]')
    
    # STEP 3: Query detailed time-series data for only those SKUs
    log "🔎 Step 2: Getting detailed time-series data for $summary_sku_count SKUs"
    local cost_data=$(query_network_costs "$BILLING_TABLE" "$lookback_start" "$lookback_end" "$project_filter" "$sku_filter")
    
    # Check if query failed with error
    if [[ -f /tmp/network_query_error.flag ]]; then
        local query_error=$(cat /tmp/network_query_error.txt 2>/dev/null || echo "Unknown error")
        rm -f /tmp/network_query_error.flag /tmp/network_query_error.txt
        
        log "❌ Network cost query failed with error"
        
        cat > "$REPORT_FILE" << EOF
╔══════════════════════════════════════════════════════════════════════╗
║          GCP NETWORK COST ANALYSIS BY SKU                            ║
╚══════════════════════════════════════════════════════════════════════╝

❌  NETWORK COST QUERY FAILED

Analysis Period: $lookback_start to $lookback_end

Query encountered an error. See issue details for troubleshooting steps.

EOF
        
        # Generate issue for query failure
        local error_details="BigQuery query error:\n\n${query_error}\n\nBilling table: ${BILLING_TABLE}\n\nThis indicates a problem with:\n- BigQuery permissions\n- Table schema or structure\n- Query syntax\n- Python BigQuery client configuration"
        
        local issue=$(jq -n \
            --arg title "Network Cost Query Failed" \
            --argjson severity 2 \
            --arg details "$error_details" \
            '{
                title: $title,
                severity: $severity,
                expected: "Network cost BigQuery query should execute successfully",
                actual: "Query failed with error",
                details: $details,
                reproduce_hint: "Check script stderr output for full error details",
                next_steps: "1. Verify BigQuery Data Viewer permissions on billing export project\n2. Test query manually in BigQuery Console\n3. Check if bq CLI or Python BigQuery client is properly configured\n4. Verify billing export table path is correct\n5. Review query filters for compatibility with your billing export schema"
            }')
        
        echo "[$issue]" > "$ISSUES_FILE"
        log "Generated issue for query failure"
        exit 1
    fi
    
    # Check if we got data
    local row_count=$(echo "$cost_data" | jq 'length' 2>/dev/null || echo "0")
    log "DEBUG: Query returned $row_count rows"
    log "DEBUG: First 200 chars of cost_data: $(echo "$cost_data" | head -c 200)"
    
    if [[ $row_count -eq 0 ]]; then
        log "⚠️  No network cost data found for the specified period"
        
        cat > "$REPORT_FILE" << EOF
╔══════════════════════════════════════════════════════════════════════╗
║          GCP NETWORK COST ANALYSIS BY SKU                            ║
╚══════════════════════════════════════════════════════════════════════╝

⚠️  NO NETWORK COST DATA FOUND

Analysis Period: $lookback_start to $lookback_end

This could mean:
• No network-related charges during this period
• Network costs are negligible
• Billing export may not include network costs yet
• Query filters may not match your billing data structure

EOF
        log "Report saved to: $REPORT_FILE"
        
        # Generate an issue to alert about the problem
        local actual_msg="Network cost query returned 0 rows for period ${lookback_start} to ${lookback_end}"
        local details_msg="The network cost analysis query did not find any matching records. This could indicate:\n\n1. No network-related charges during this period\n2. Query filters do not match the service names in your billing export\n3. BigQuery permissions or access issues\n4. Billing export schema differences\n\nBilling table used: ${BILLING_TABLE}\n\nIf you expect to have network costs (egress, CDN, VPN, NAT, etc.), investigate the query filters and billing export structure."
        
        local issue=$(jq -n \
            --arg title "Network Cost Analysis Returned No Data" \
            --argjson severity 4 \
            --arg actual "$actual_msg" \
            --arg details "$details_msg" \
            '{
                title: $title,
                severity: $severity,
                expected: "Network cost analysis should return data if network charges exist in billing export",
                actual: $actual,
                details: $details,
                reproduce_hint: "Check BigQuery billing export for service.description = Networking or similar network-related services",
                next_steps: "1. Verify network costs exist in GCP Console Billing Reports\n2. Query BigQuery billing export directly to check service names\n3. Review script logs for query errors\n4. Check if bq CLI or Python BigQuery client is working\n5. Verify service account has BigQuery Data Viewer permissions"
            }')
        
        echo "[$issue]" > "$ISSUES_FILE"
        log "Generated issue for no network cost data"
        
        exit 0
    fi
    
    log "✅ Retrieved $row_count network cost records"
    
    # Aggregate costs by time periods
    local aggregated_data=$(aggregate_network_costs "$cost_data" "$date_ranges")
    local sku_count=$(echo "$aggregated_data" | jq 'length')
    log "Aggregated into $sku_count unique network SKUs"
    
    # Generate reports
    if [[ "$OUTPUT_FORMAT" == "table" || "$OUTPUT_FORMAT" == "all" ]]; then
        generate_text_report "$aggregated_data" "$date_ranges"
        cat "$REPORT_FILE"
    fi
    
    if [[ "$OUTPUT_FORMAT" == "json" || "$OUTPUT_FORMAT" == "all" ]]; then
        generate_json_report "$aggregated_data" "$date_ranges"
    fi
    
    if [[ "$OUTPUT_FORMAT" == "csv" || "$OUTPUT_FORMAT" == "all" ]]; then
        generate_csv_report "$aggregated_data"
    fi
    
    # Detect anomalies and generate issues
    log "Analyzing for cost anomalies..."
    local issues=$(detect_cost_anomalies "$aggregated_data")
    echo "$issues" > "$ISSUES_FILE"
    
    local issue_count=$(echo "$issues" | jq 'length')
    log "Generated $issue_count issue(s) based on cost anomalies"
    
    log "✅ Network cost analysis complete!"
}

main "$@"
