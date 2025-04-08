#!/usr/bin/env bash
#
# Collect and evaluate expanded APIM metrics (requests, failures, unauthorized, CPU%, memory%, etc.)
# For APIM ${APIM_NAME} in Resource Group ${AZ_RESOURCE_GROUP}
#
# Usage:
#   export AZ_RESOURCE_GROUP="myResourceGroup"
#   export APIM_NAME="myApimInstance"
#   # Optionally: export AZURE_RESOURCE_SUBSCRIPTION_ID="subscription-id"
#   # Optionally: export METRIC_TIME_RANGE="PT1H" (e.g. PT1H, P1D, etc.)
#   ./apim_metrics.sh
#
# Description:
#   - Ensures correct subscription context
#   - Gathers multiple APIM metrics with valid aggregators
#   - Evaluates them against basic thresholds (error rates, latency, CPU, memory usage)
#   - Outputs a JSON => { "metrics": {...}, "issues": [...] }

set -euo pipefail

###############################################################################
# 1) Get or set subscription ID
###############################################################################
if [ -z "${AZURE_RESOURCE_SUBSCRIPTION_ID:-}" ]; then
  subscription=$(az account show --query "id" -o tsv)
  echo "AZURE_RESOURCE_SUBSCRIPTION_ID is not set. Using current subscription ID: $subscription"
else
  subscription="$AZURE_RESOURCE_SUBSCRIPTION_ID"
  echo "Using specified subscription ID: $subscription"
fi

echo "Switching to subscription ID: $subscription"
az account set --subscription "$subscription" || {
  echo "Failed to set subscription."
  exit 1
}

###############################################################################
# 2) Check env variables & define defaults
###############################################################################
: "${AZ_RESOURCE_GROUP:?Must set AZ_RESOURCE_GROUP}"
: "${APIM_NAME:?Must set APIM_NAME}"

METRIC_TIME_RANGE="${METRIC_TIME_RANGE:-PT1H}"
OUTPUT_FILE="apim_metrics.json"

echo "[INFO] Collecting APIM metrics for '$APIM_NAME' in resource group '$AZ_RESOURCE_GROUP' (Range: $METRIC_TIME_RANGE)..."

###############################################################################
# 3) Construct the APIM resource ID
###############################################################################
APIM_RESOURCE_ID="$(az apim show \
  --name "$APIM_NAME" \
  --resource-group "$AZ_RESOURCE_GROUP" \
  --query "id" -o tsv 2>/dev/null || true)"

if [[ -z "$APIM_RESOURCE_ID" ]]; then
  echo "ERROR: Could not find APIM '$APIM_NAME' in '$AZ_RESOURCE_GROUP'."
  exit 1
fi

echo "[INFO] APIM resource ID: $APIM_RESOURCE_ID"

###############################################################################
# 4) Define valid metrics & aggregators for APIM
#    Metric names from your environment might include:
#      TotalRequests, FailedRequests, SuccessfulRequests, UnauthorizedRequests, OtherRequests, Requests
#      Duration, BackendDuration
#      Capacity
#      CpuPercent_Gateway, MemoryPercent_Gateway
#
#    Allowed aggregators: None, Average, Count, Minimum, Maximum, Total
###############################################################################
declare -A METRIC_TO_AGGREGATOR=(
  # Request counters
  ["TotalRequests"]="Total"
  ["FailedRequests"]="Total"
  ["SuccessfulRequests"]="Total"
  ["UnauthorizedRequests"]="Total"
  ["OtherRequests"]="Total"
  ["Requests"]="Total"

  # Latency metrics
  ["Duration"]="Average"         # end-to-end
  ["BackendDuration"]="Average"  # time spent in backend

  # Capacity usage
  ["Capacity"]="Average"

  # Gateway CPU & memory usage
  ["CpuPercent_Gateway"]="Average"
  ["MemoryPercent_Gateway"]="Average"
)

# Which metrics to actually fetch
METRICS_TO_FETCH=(
  "TotalRequests"
  "FailedRequests"
  "SuccessfulRequests"
  "UnauthorizedRequests"
  "OtherRequests"
  "Requests"
  "Duration"
  "BackendDuration"
  "Capacity"
  "CpuPercent_Gateway"
  "MemoryPercent_Gateway"
)

###############################################################################
# JSON placeholders
###############################################################################
metrics_json='{}'
issues_json='{"issues": []}'

###############################################################################
# Helper: parse_metric_value
###############################################################################
parse_metric_value() {
  local raw_json="$1"
  local aggregator="$2"

  # Check if raw JSON is valid
  if ! echo "$raw_json" | jq '.' >/dev/null 2>&1; then
    echo "0"
    return
  fi

  local val_len
  val_len="$(echo "$raw_json" | jq '.value | length')"
  if [[ "$val_len" == "0" || "$val_len" == "null" ]]; then
    echo "0"
    return
  fi

  # aggregator -> property name
  case "$aggregator" in
    "Total")
      echo "$raw_json" | jq '[.value[].timeseries[].data[].total // 0] | add' || echo "0"
      ;;
    "Average")
      echo "$raw_json" | jq '
        .value[].timeseries[].data[] | (.average // 0)
      ' | awk '{ sum+=$1; cnt++ } END { if(cnt>0){printf "%.2f", sum/cnt} else{print 0} }'
      ;;
    "Count")
      echo "$raw_json" | jq '[.value[].timeseries[].data[].count // 0] | add' || echo "0"
      ;;
    "Minimum")
      echo "$raw_json" | jq '[.value[].timeseries[].data[].minimum // 0] | min' || echo "0"
      ;;
    "Maximum")
      echo "$raw_json" | jq '[.value[].timeseries[].data[].maximum // 0] | max' || echo "0"
      ;;
    *)
      echo "0"
      ;;
  esac
}

###############################################################################
# 5) Fetch each metric and store result
###############################################################################
for metric_name in "${METRICS_TO_FETCH[@]}"; do
  aggregator="${METRIC_TO_AGGREGATOR[$metric_name]:-}"
  if [[ -z "$aggregator" ]]; then
    echo "[WARN] No aggregator defined for '$metric_name'. Using 0."
    metrics_json="$(echo "$metrics_json" | jq \
      --arg m "$metric_name" --argjson val 0 \
      '. + {($m): $val}')"
    continue
  fi

  cmd="az monitor metrics list \
    --resource \"$APIM_RESOURCE_ID\" \
    --metric \"$metric_name\" \
    --interval \"$METRIC_TIME_RANGE\" \
    --aggregation \"$aggregator\" \
    -o json"

  echo "[INFO] Querying metric '$metric_name' with aggregator '$aggregator'..."
  echo "[INFO] Command: $cmd"

  if ! cli_stdout=$(eval "$cmd" 2>apim_metric_errors.log); then
    echo "ERROR fetching metric=$metric_name aggregator=$aggregator"
    cat apim_metric_errors.log

    # Add issue about fetch failure
    issues_json="$(echo "$issues_json" | jq \
      --arg t "Failed to Fetch APIM Metric '$metric_name'" \
      --arg d "$(cat apim_metric_errors.log)" \
      --arg n "Check aggregator validity or APIM tier. Possibly not supported." \
      '.issues += [{
         "title": $t,
         "details": $d,
         "next_steps": $n,
         "severity": 4
       }]')"

    # Store 0 in metrics
    metrics_json="$(echo "$metrics_json" | jq \
      --arg m "$metric_name" --argjson val 0 \
      '. + {($m): $val}')"

    rm -f apim_metric_errors.log
    continue
  fi
  rm -f apim_metric_errors.log

  raw_val="$(parse_metric_value "$cli_stdout" "$aggregator")"
  val="$(echo "$raw_val" | xargs)"  # trim whitespace
  [ -z "$val" ] && val="0"

  echo "[INFO] Value for '$metric_name': $val"

  # numeric or string
  if [[ "$val" =~ ^-?[0-9]*\.?[0-9]+$ ]]; then
    metrics_json="$(echo "$metrics_json" | jq \
      --arg m "$metric_name" --argjson v "$val" \
      '. + {($m): $v}')"
  else
    metrics_json="$(echo "$metrics_json" | jq \
      --arg m "$metric_name" --arg v "$val" \
      '. + {($m): $v}')"
  fi
done

###############################################################################
# 6) Basic threshold checks
###############################################################################
total_requests="$(echo "$metrics_json" | jq '.TotalRequests // 0')"
failed_requests="$(echo "$metrics_json" | jq '.FailedRequests // 0')"
success_requests="$(echo "$metrics_json" | jq '.SuccessfulRequests // 0')"
unauth_requests="$(echo "$metrics_json" | jq '.UnauthorizedRequests // 0')"
other_requests="$(echo "$metrics_json" | jq '.OtherRequests // 0')"
requests="$(echo "$metrics_json" | jq '.Requests // 0')"

duration_avg="$(echo "$metrics_json" | jq '.Duration // 0')"
backend_avg="$(echo "$metrics_json" | jq '.BackendDuration // 0')"
capacity_avg="$(echo "$metrics_json" | jq '.Capacity // 0')"
cpu_avg="$(echo "$metrics_json" | jq '.CpuPercent_Gateway // 0')"
mem_avg="$(echo "$metrics_json" | jq '.MemoryPercent_Gateway // 0')"

# (A) Check for fail rate
if (( $(echo "$total_requests > 0" | bc -l) )); then
  fail_rate=$(awk "BEGIN { printf \"%.2f\", $failed_requests/$total_requests * 100 }")
  if (( $(echo "$fail_rate >= 5.0" | bc -l) )); then
    issues_json="$(echo "$issues_json" | jq \
      --arg t "Elevated Failure Rate" \
      --arg d "Failed=$failed_requests / Total=$total_requests => ${fail_rate}% fail" \
      --arg n "Check APIM logs/policies or backends for errors (RG '$AZ_RESOURCE_GROUP')." \
      '.issues += [{
         "title": $t,
         "details": $d,
         "next_steps": $n,
         "severity": 2
       }]')"
  fi
fi

# (B) Unauthorized ratio if there are enough total requests
#     if unauthorizedRequests is >10% => possible auth config issues
if (( $(echo "$total_requests > 0" | bc -l) )); then
  unauth_rate=$(awk "BEGIN { printf \"%.2f\", $unauth_requests/$total_requests * 100 }")
  if (( $(echo "$unauth_rate >= 10.0" | bc -l) )); then
    issues_json="$(echo "$issues_json" | jq \
      --arg t "High Unauthorized Requests" \
      --arg d "Unauthorized=$unauth_requests / Total=$total_requests => ${unauth_rate}%" \
      --arg n "Check auth policies or tokens for APIM '$APIM_NAME' in RG '$AZ_RESOURCE_GROUP'." \
      '.issues += [{
         "title": $t,
         "details": $d,
         "next_steps": $n,
         "severity": 2
       }]')"
  fi
fi

# (C) If the fraction of "OtherRequests" is large => might indicate unexpected status codes
if (( $(echo "$total_requests > 0" | bc -l) )); then
  other_rate=$(awk "BEGIN { printf \"%.2f\", $other_requests/$total_requests * 100 }")
  if (( $(echo "$other_rate >= 10.0" | bc -l) )); then
    issues_json="$(echo "$issues_json" | jq \
      --arg t "Excessive 'OtherRequests' in APIM" \
      --arg d "OtherRequests=$other_requests / Total=$total_requests => ${other_rate}%" \
      --arg n "Check unusual status codes or APIM classifications for RG '$AZ_RESOURCE_GROUP'." \
      '.issues += [{
         "title": $t,
         "details": $d,
         "next_steps": $n,
         "severity": 3
       }]')"
  fi
fi

# (D) If average Duration is above 300 ms => possible user-facing latency
if (( $(echo "$duration_avg > 300" | bc -l) )); then
  issues_json="$(echo "$issues_json" | jq \
    --arg t "High End-to-End Latency" \
    --arg d "Duration average ${duration_avg} ms" \
    --arg n "Review transformations/policies or network overhead in APIM '$APIM_NAME'." \
    '.issues += [{
       "title": $t,
       "details": $d,
       "next_steps": $n,
       "severity": 2
     }]')"
fi

# (E) If average BackendDuration is above 200 ms => slow backend
if (( $(echo "$backend_avg > 200" | bc -l) )); then
  issues_json="$(echo "$issues_json" | jq \
    --arg t "High Backend Duration" \
    --arg d "BackendDuration average ${backend_avg} ms" \
    --arg n "Investigate backend performance or network. RG='$AZ_RESOURCE_GROUP'." \
    '.issues += [{
       "title": $t,
       "details": $d,
       "next_steps": $n,
       "severity": 2
     }]')"
fi

# (F) If CPU usage is above 80%
if (( $(echo "$cpu_avg > 80" | bc -l) )); then
  issues_json="$(echo "$issues_json" | jq \
    --arg t "High APIM Gateway CPU Usage" \
    --arg d "CpuPercent_Gateway ~ ${cpu_avg}%" \
    --arg n "Scale or check concurrency for APIM '$APIM_NAME' in RG '$AZ_RESOURCE_GROUP'." \
    '.issues += [{
       "title": $t,
       "details": $d,
       "next_steps": $n,
       "severity": 2
     }]')"
fi

# (G) If memory usage is above 80%
if (( $(echo "$mem_avg > 80" | bc -l) )); then
  issues_json="$(echo "$issues_json" | jq \
    --arg t "High APIM Gateway Memory Usage" \
    --arg d "MemoryPercent_Gateway ~ ${mem_avg}%" \
    --arg n "Evaluate memory pressure or consider scale. RG='$AZ_RESOURCE_GROUP'." \
    '.issues += [{
       "title": $t,
       "details": $d,
       "next_steps": $n,
       "severity": 2
     }]')"
fi

# (H) If average capacity is near 1 or higher => might be saturating your APIM tier
#     (This is a rough check, depends on your tier. E.g. dev tier has capacity=1, premium can scale up, etc.)
if (( $(echo "$capacity_avg >= 1" | bc -l) )); then
  issues_json="$(echo "$issues_json" | jq \
    --arg t "APIM Capacity Possibly Reached" \
    --arg d "Capacity average = ${capacity_avg}" \
    --arg n "Check if you need to scale up or move to higher tier for APIM '$APIM_NAME'." \
    '.issues += [{
       "title": $t,
       "details": $d,
       "next_steps": $n,
       "severity": 3
     }]')"
fi

###############################################################################
# 7) Final JSON => { "metrics": { ... }, "issues": [ ... ] }
###############################################################################
final_json="$(jq -n \
  --argjson m "$metrics_json" \
  --argjson i "$(echo "$issues_json" | jq '.issues')" \
  '{ "metrics": $m, "issues": $i }'
)"

echo "--------------------------------------------------"
echo "[INFO] APIM Metrics & Potential Issues (Last $METRIC_TIME_RANGE):"
echo "$final_json" | jq .
echo "--------------------------------------------------"

echo "$final_json" > "$OUTPUT_FILE"
echo "[INFO] Results saved to $OUTPUT_FILE."
