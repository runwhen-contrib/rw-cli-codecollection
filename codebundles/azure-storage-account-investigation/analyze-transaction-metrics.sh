#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AZURE_SUBSCRIPTION_ID
#   AZURE_RESOURCE_GROUP
#   AZURE_STORAGE_ACCOUNT_NAME
#
# OPTIONAL:
#   LOOKBACK_DAYS  Days of metrics to analyze (default: 7)
# -----------------------------------------------------------------------------

: "${AZURE_SUBSCRIPTION_ID:?Must set AZURE_SUBSCRIPTION_ID}"
: "${AZURE_RESOURCE_GROUP:?Must set AZURE_RESOURCE_GROUP}"
: "${AZURE_STORAGE_ACCOUNT_NAME:?Must set AZURE_STORAGE_ACCOUNT_NAME}"

LOOKBACK_DAYS="${LOOKBACK_DAYS:-7}"
OUTPUT_FILE="transaction_metrics_output.json"
issues_json='[]'

add_issue() {
  local title="$1" severity="$2" expected="$3" actual="$4" details="$5" next_steps="$6"
  local reproduce_hint="${7:-}"
  issues_json=$(echo "$issues_json" | jq \
    --arg title "$title" \
    --arg expected "$expected" \
    --arg actual "$actual" \
    --arg details "$details" \
    --arg next_steps "$next_steps" \
    --arg reproduce_hint "$reproduce_hint" \
    --argjson severity "$severity" \
    '. += [{
      title: $title,
      severity: $severity,
      expected: $expected,
      actual: $actual,
      details: $details,
      next_steps: $next_steps,
      reproduce_hint: $reproduce_hint
    }]')
}

echo "Analyzing transaction metrics for ${AZURE_STORAGE_ACCOUNT_NAME} (last ${LOOKBACK_DAYS} days)" >&2

az account set --subscription "$AZURE_SUBSCRIPTION_ID" 2>/dev/null || true

storage_info=$(az storage account show \
  --name "$AZURE_STORAGE_ACCOUNT_NAME" \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --subscription "$AZURE_SUBSCRIPTION_ID" \
  -o json 2>/dev/null || echo "")

if [[ -z "$storage_info" || "$storage_info" == "null" ]]; then
  add_issue \
    "Cannot access storage account for metrics \`${AZURE_STORAGE_ACCOUNT_NAME}\`" \
    4 \
    "Storage account should be readable" \
    "az storage account show failed" \
    "Verify account and Reader permissions." \
    "Confirm storage account exists before analyzing metrics." \
    "az storage account show --name ${AZURE_STORAGE_ACCOUNT_NAME} --resource-group ${AZURE_RESOURCE_GROUP}"
  jq -n --argjson issues "$issues_json" \
    '{issues: $issues, risk_assessment: {safe_to_disable_public_access: false, safe_to_disable_shared_key: false, rationale: "Account inaccessible"}, summary: {}}' \
    > "$OUTPUT_FILE"
  cat "$OUTPUT_FILE"
  exit 0
fi

resource_id=$(echo "$storage_info" | jq -r '.id')
blob_resource_id="${resource_id}/blobServices/default"
portal_url="https://portal.azure.com/#@/resource${resource_id}/metrics"
end_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
start_time=$(date -u -d "${LOOKBACK_DAYS} days ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v-"${LOOKBACK_DAYS}"d +"%Y-%m-%dT%H:%M:%SZ")

fetch_metric() {
  local metric_name="$1"
  shift
  local dim_args=("$@")
  az monitor metrics list \
    --resource "$blob_resource_id" \
    --metric "$metric_name" \
    --aggregation Total Average Maximum \
    --interval PT1H \
    --start-time "$start_time" \
    --end-time "$end_time" \
    "${dim_args[@]}" \
    -o json 2>metrics.err || echo ""
}

tx_metrics=$(fetch_metric "Transactions" --dimension Authentication ApiName)
if [[ -z "$tx_metrics" ]]; then
  err_msg=$(cat metrics.err 2>/dev/null || echo "Unknown metrics error")
  if echo "$err_msg" | grep -qiE 'AuthorizationFailed|403|Forbidden|network rules'; then
    add_issue \
      "Transaction metrics blocked by network rules for \`${AZURE_STORAGE_ACCOUNT_NAME}\`" \
      3 \
      "Metrics should be readable via Azure Monitor control plane" \
      "Metrics API returned authorization/network failure" \
      "${err_msg}" \
      "Storage firewall may block data-plane calls; control-plane metrics should still be attempted. Review network rules before remediation." \
      "az monitor metrics list --resource ${blob_resource_id} --metric Transactions"
  else
    add_issue \
      "Unable to retrieve transaction metrics for \`${AZURE_STORAGE_ACCOUNT_NAME}\`" \
      3 \
      "Monitoring Reader should allow blob transaction metrics" \
      "az monitor metrics list failed or returned empty" \
      "${err_msg}" \
      "Grant Monitoring Reader on the storage account and retry." \
      "az monitor metrics list --resource ${blob_resource_id} --metric Transactions --dimension Authentication"
  fi
  jq -n --argjson issues "$issues_json" --arg portal_url "$portal_url" \
    '{issues: $issues, risk_assessment: {safe_to_disable_public_access: false, safe_to_disable_shared_key: false, rationale: "Metrics unavailable"}, summary: {}, portal_url: $portal_url}' \
    > "$OUTPUT_FILE"
  cat "$OUTPUT_FILE"
  exit 0
fi

# Sum transactions by Authentication dimension
auth_totals=$(echo "$tx_metrics" | jq '
  [.value[0].timeseries[]? | .metadata[]? | select(.name.value == "Authentication") | .value] as $auths |
  [.value[0].timeseries[]? | .data[]? | .total // 0] as $totals |
  reduce range(0; ($auths | length)) as $i ({}; . + {($auths[$i]): ((.[ $auths[$i] ] // 0) + ($totals[$i] // 0))})
' 2>/dev/null || echo '{}')

if [[ "$auth_totals" == "{}" || "$auth_totals" == "null" ]]; then
  auth_totals=$(echo "$tx_metrics" | jq '
    [.value[]?.timeseries[]? |
      (.metadata[]? | select(.name.value == "Authentication") | .value) as $auth |
      ([.data[]?.total // 0] | add // 0) as $sum |
      {key: $auth, value: $sum}
    ] | from_entries
  ' 2>/dev/null || echo '{}')
fi

anonymous_count=$(echo "$auth_totals" | jq '.Anonymous // .anonymous // 0')
account_key_count=$(echo "$auth_totals" | jq '.AccountKey // .accountkey // 0')
sas_count=$(echo "$auth_totals" | jq '.SAS // .sas // 0')
oauth_count=$(echo "$auth_totals" | jq '.OAuth // .oauth // 0')
total_tx=$(echo "$auth_totals" | jq '[.[] | tonumber? // 0] | add // 0')

ingress_metrics=$(fetch_metric "Ingress")
egress_metrics=$(fetch_metric "Egress")
capacity_metrics=$(fetch_metric "BlobCapacity")

ingress_total=$(echo "$ingress_metrics" | jq '[.value[]?.timeseries[]?.data[]?.total // 0] | add // 0')
egress_total=$(echo "$egress_metrics" | jq '[.value[]?.timeseries[]?.data[]?.total // 0] | add // 0')
capacity_latest=$(echo "$capacity_metrics" | jq '[.value[]?.timeseries[]?.data[]?.average // 0] | max // 0')

echo "Transaction totals by auth: $(echo "$auth_totals" | jq -c .)" >&2

safe_public=true
safe_shared_key=true
rationale_parts=()

if [[ $(echo "$anonymous_count >= 1" | bc -l 2>/dev/null || python3 -c "print(1 if float('${anonymous_count}') >= 1 else 0)") -eq 1 ]]; then
  add_issue \
    "Anonymous blob transactions detected on \`${AZURE_STORAGE_ACCOUNT_NAME}\`" \
    2 \
    "No anonymous (public) blob transactions before disabling public access" \
    "${anonymous_count} anonymous transaction(s) in last ${LOOKBACK_DAYS} day(s)" \
    "Anonymous auth indicates public blob/container access or anonymous endpoints are in use." \
    "Identify public containers and anonymous callers via access logs before setting allowBlobPublicAccess=false." \
    "az monitor metrics list --resource ${blob_resource_id} --metric Transactions --dimension Authentication"
  safe_public=false
  rationale_parts+=("Anonymous transactions detected")
fi

if [[ "$total_tx" != "0" && "$total_tx" != "0.0" ]]; then
  account_key_pct=$(python3 -c "t=float('${total_tx}'); k=float('${account_key_count}'); print(round(100*k/t,1) if t>0 else 0)")
  if python3 -c "exit(0 if float('${account_key_pct}') > 50 else 1)"; then
    add_issue \
      "AccountKey authentication exceeds 50% of transactions on \`${AZURE_STORAGE_ACCOUNT_NAME}\`" \
      3 \
      "Shared key should not dominate authentication mix before disablement" \
      "AccountKey represents ${account_key_pct}% of ${total_tx} total transactions" \
      "Auth breakdown: $(echo "$auth_totals" | jq -c .)" \
      "Migrate AccountKey callers to OAuth/managed identity before disabling allowSharedKeyAccess." \
      "az monitor metrics list --resource ${blob_resource_id} --metric Transactions --dimension Authentication"
    safe_shared_key=false
    rationale_parts+=("AccountKey >50% of transactions")
  fi
else
  account_key_pct=0
fi

if [[ $(echo "$sas_count >= 1" | bc -l 2>/dev/null || python3 -c "print(1 if float('${sas_count}') >= 1 else 0)") -eq 1 ]]; then
  add_issue \
    "SAS token usage detected on \`${AZURE_STORAGE_ACCOUNT_NAME}\`" \
    4 \
    "SAS usage should be inventoried before shared key disablement" \
    "${sas_count} SAS-authenticated transaction(s) in lookback window" \
    "SAS tokens often depend on shared key backing; disabling shared keys breaks SAS." \
    "Identify SAS issuers and migrate to user delegation SAS or OAuth where possible." \
    "az monitor metrics list --resource ${blob_resource_id} --metric Transactions --dimension Authentication"
  safe_shared_key=false
  rationale_parts+=("SAS usage detected")
fi

if [[ "$total_tx" != "0" && "$total_tx" != "0.0" ]]; then
  oauth_pct=$(python3 -c "t=float('${total_tx}'); o=float('${oauth_count}'); print(round(100*o/t,1) if t>0 else 0)")
  if python3 -c "exit(0 if float('${oauth_pct}') >= 99.9 and float('${anonymous_count}') == 0 and float('${account_key_count}') == 0 and float('${sas_count}') == 0 else 1)"; then
    echo "Healthy: 100% OAuth authentication in lookback window" >&2
  fi
else
  oauth_pct=0
  add_issue \
    "No blob transactions recorded for \`${AZURE_STORAGE_ACCOUNT_NAME}\`" \
    4 \
    "Metrics should confirm whether the account is actively used" \
    "Zero Transactions metric totals in last ${LOOKBACK_DAYS} day(s)" \
    "Absence of metrics may indicate idle account or insufficient monitoring permissions." \
    "Cross-check with access logs and Resource Graph before assuming safe remediation." \
    "az monitor metrics list --resource ${blob_resource_id} --metric Transactions"
fi

rationale="Metrics analyzed over ${LOOKBACK_DAYS} day(s). Total transactions: ${total_tx}."
if [[ ${#rationale_parts[@]} -gt 0 ]]; then
  rationale="${rationale} $(IFS='; '; echo "${rationale_parts[*]}")."
else
  rationale="${rationale} No anonymous, high AccountKey, or SAS blockers detected."
fi

jq -n \
  --argjson issues "$issues_json" \
  --argjson auth_totals "$auth_totals" \
  --argjson total_tx "$total_tx" \
  --argjson anonymous_count "$anonymous_count" \
  --argjson account_key_count "$account_key_count" \
  --argjson sas_count "$sas_count" \
  --argjson oauth_count "$oauth_count" \
  --argjson ingress_total "$ingress_total" \
  --argjson egress_total "$egress_total" \
  --argjson capacity_latest "$capacity_latest" \
  --arg portal_url "$portal_url" \
  --argjson safe_public "$safe_public" \
  --argjson safe_shared_key "$safe_shared_key" \
  --arg rationale "$rationale" \
  --argjson lookback_days "$LOOKBACK_DAYS" \
  '{
    issues: $issues,
    risk_assessment: {
      safe_to_disable_public_access: $safe_public,
      safe_to_disable_shared_key: $safe_shared_key,
      rationale: $rationale
    },
    summary: {
      lookback_days: $lookback_days,
      transactions_by_authentication: $auth_totals,
      total_transactions: $total_tx,
      ingress_bytes: $ingress_total,
      egress_bytes: $egress_total,
      blob_capacity_bytes: $capacity_latest
    },
    portal_url: $portal_url
  }' > "$OUTPUT_FILE"

cat "$OUTPUT_FILE"
