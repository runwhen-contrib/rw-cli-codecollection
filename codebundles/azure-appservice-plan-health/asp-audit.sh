#!/bin/bash
# asp-audit.sh – Audit changes to Azure App Service Plans

# Function to extract timestamp from log line, fallback to current time
extract_log_timestamp() {
    local log_line="$1"
    local fallback_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
    
    if [[ -z "$log_line" ]]; then
        echo "$fallback_timestamp"
        return
    fi
    
    # Try to extract common timestamp patterns
    # ISO 8601 format: 2024-01-15T10:30:45.123Z
    if [[ "$log_line" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{3})?Z?) ]]; then
        echo "${BASH_REMATCH[1]}"
        return
    fi
    
    # Standard log format: 2024-01-15 10:30:45
    if [[ "$log_line" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
        # Convert to ISO format
        local extracted_time="${BASH_REMATCH[1]}"
        local iso_time=$(date -d "$extracted_time" -u +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            echo "$iso_time"
        else
            echo "$fallback_timestamp"
        fi
        return
    fi
    
    # DD-MM-YYYY HH:MM:SS format
    if [[ "$log_line" =~ ([0-9]{2}-[0-9]{2}-[0-9]{4}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
        local extracted_time="${BASH_REMATCH[1]}"
        # Convert DD-MM-YYYY to YYYY-MM-DD for date parsing
        local day=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f1)
        local month=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f2)
        local year=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f3)
        local time_part=$(echo "$extracted_time" | cut -d' ' -f2)
        local iso_time=$(date -d "$year-$month-$day $time_part" -u +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            echo "$iso_time"
        else
            echo "$fallback_timestamp"
        fi
        return
    fi
    
    # Fallback to current timestamp
    echo "$fallback_timestamp"
}

set -euo pipefail

FILE_PREFIX="${FILE_PREFIX:-}"
SUCCESS_OUTPUT="${FILE_PREFIX}asp_changes_success.json"
FAILED_OUTPUT="${FILE_PREFIX}asp_changes_failed.json"
echo "{}" > "$SUCCESS_OUTPUT"
echo "{}" > "$FAILED_OUTPUT"

# Select subscription
if [ -z "${AZURE_SUBSCRIPTION_ID:-}" ]; then
  subscription=$(az account show --query "id" -o tsv)
else
  subscription="$AZURE_SUBSCRIPTION_ID"
fi
az account set --subscription "$subscription"

# Resource group validation
if [ -z "${AZURE_RESOURCE_GROUP:-}" ]; then
  # Extract timestamp from log context

  log_timestamp=$(extract_log_timestamp "$0")

  echo "Error: AZURE_RESOURCE_GROUP must be set (detected at $log_timestamp)" >&2
  exit 1
fi

TIME_OFFSET="${AZURE_ACTIVITY_LOG_OFFSET:-24h}"
echo "TIME_OFFSET: $TIME_OFFSET"
plans=$(az appservice plan list -g "$AZURE_RESOURCE_GROUP" --query "[].id" -o tsv)

if [ -z "$plans" ]; then
  echo "No App Service Plans found in resource group $AZURE_RESOURCE_GROUP"
  exit 0
fi

tmp_success="${FILE_PREFIX}tmp_success_$(date +%s).json"
tmp_failed="${FILE_PREFIX}tmp_failed_$(date +%s).json"
echo "{}" > "$tmp_success"
echo "{}" > "$tmp_failed"

for plan in $plans; do
  asp_name=$(basename "$plan")
  logs=$(az monitor activity-log list \
    --resource-id "$plan" \
    --offset "$TIME_OFFSET" \
    --output json)
  echo "$logs" | jq --arg asp "$asp_name" '
    map(select(.operationName.value | test("write|delete|scale|update")) | {
      aspName: $asp,
      operation: (.operationName.value | split("/") | last),
      operationDisplay: .operationName.localizedValue,
      timestamp: .eventTimestamp,
      caller: .caller,
      changeStatus: .status.value,
      resourceId: .resourceId,
      correlationId: .correlationId,
      resourceUrl: ("https://portal.azure.com/#resource" + .resourceId),
      security_classification:
        (if .operationName.value | test("delete") then "High"
         elif .operationName.value | test("scale") then "Medium"
         elif .operationName.value | test("write|update") then "Medium"
         else "Info" end),
      reason:
        (if .operationName.value | test("delete") then "Deleting an App Service Plan removes all hosted apps"
         elif .operationName.value | test("scale") then "Scaling changes resource allocation and cost"
         elif .operationName.value | test("write|update") then "Configuration or permission changes"
         else "Miscellaneous operation" end)
    })' > _current.json

  if ! jq empty _current.json 2>/dev/null; then
    echo "Invalid JSON detected in _current.json"
    exit 1
  fi

  jq 'if length == 0 then {} else group_by(.aspName) | map({ (.[0].aspName): . }) | add end' _current.json > _grouped.json

  if ! jq empty _grouped.json 2>/dev/null; then
    echo "Invalid JSON detected in _grouped.json"
    exit 1
  fi

  jq 'with_entries(
    .value |= (map(select(.changeStatus == "Succeeded")) | unique_by(.correlationId))
  )' _grouped.json > _succ.json
  if ! jq empty _succ.json 2>/dev/null; then
    echo "Invalid JSON detected in _succ.json"
    exit 1
  fi
  jq 'with_entries(
    .value |= (map(select(.changeStatus == "Failed")) | unique_by(.correlationId))
  )' _grouped.json > _fail.json
  if ! jq empty _fail.json 2>/dev/null; then
    echo "Invalid JSON detected in _fail.json"
    exit 1
  fi

  jq -s 'add' "$tmp_success" _succ.json > _sc.tmp && mv _sc.tmp "$tmp_success"
  jq -s 'add' "$tmp_failed"  _fail.json > _fl.tmp && mv _fl.tmp "$tmp_failed"

  rm -f _current.json _grouped.json _succ.json _fail.json
done

# Sort each group by timestamp (desc)
for file in "$tmp_success" "$tmp_failed"; do
  jq 'with_entries({ key: .key, value: (.value | sort_by(.timestamp) | reverse) })' "$file" > "$file.sorted"
  mv "$file.sorted" "$file"
done

mv "$tmp_success" "$SUCCESS_OUTPUT"
mv "$tmp_failed"  "$FAILED_OUTPUT"

echo "Audit completed:"
echo "  ✅ Successful changes → $SUCCESS_OUTPUT"
echo "  ⚠️  Failed changes     → $FAILED_OUTPUT"
