#!/bin/bash
# asp-audit.sh – Audit changes to Azure App Service Plans

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
  echo "Error: AZURE_RESOURCE_GROUP must be set" >&2
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

  jq 'if length == 0 then {} else group_by(.aspName) | map({ (.[0].aspName): . }) | add end' _current.json > _grouped.json

  jq 'with_entries(
    .value |= (map(select(.changeStatus == "Succeeded")) | unique_by(.correlationId))
  )' _grouped.json > _succ.json
  jq 'with_entries(
    .value |= (map(select(.changeStatus == "Failed")) | unique_by(.correlationId))
  )' _grouped.json > _fail.json

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
