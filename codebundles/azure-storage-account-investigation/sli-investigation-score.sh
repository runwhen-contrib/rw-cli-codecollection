#!/usr/bin/env bash
set -euo pipefail
set -x
# Lightweight SLI probe: returns JSON with dimension scores (0 or 1).

: "${AZURE_SUBSCRIPTION_ID:?Must set AZURE_SUBSCRIPTION_ID}"
: "${AZURE_RESOURCE_GROUP:?Must set AZURE_RESOURCE_GROUP}"
: "${AZURE_STORAGE_ACCOUNT_NAME:?Must set AZURE_STORAGE_ACCOUNT_NAME}"

OUTPUT_FILE="sli_probe_output.json"

az account set --subscription "$AZURE_SUBSCRIPTION_ID" 2>/dev/null || true

score_account=0
score_rbac=0
score_metrics=0
score_logs=0

if storage_info=$(az storage account show \
  --name "$AZURE_STORAGE_ACCOUNT_NAME" \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --subscription "$AZURE_SUBSCRIPTION_ID" \
  -o json 2>/dev/null); then
  score_account=1
  resource_id=$(echo "$storage_info" | jq -r '.id')
  blob_resource_id="${resource_id}/blobServices/default"

  if rbac=$(az role assignment list --scope "$resource_id" --include-inherited --all -o json 2>/dev/null); then
    [[ -n "$rbac" ]] && score_rbac=1
  fi

  end_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  start_time=$(date -u -d "1 day ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v-1d +"%Y-%m-%dT%H:%M:%SZ")
  if metrics=$(az monitor metrics list \
    --resource "$blob_resource_id" \
    --metric "Transactions" \
    --aggregation Total \
    --interval PT1H \
    --start-time "$start_time" \
    --end-time "$end_time" \
    -o json 2>/dev/null); then
    [[ -n "$metrics" && "$metrics" != "null" ]] && score_metrics=1
  fi

  if diag=$(az monitor diagnostic-settings list --resource "$blob_resource_id" -o json 2>/dev/null); then
    ws=$(echo "$diag" | jq -r '.[].workspaceId // empty' | head -1)
    logs_on=$(echo "$diag" | jq '[.[] | .logs[]? | select(.enabled == true)] | length')
    if [[ -n "$ws" || "$logs_on" -gt 0 ]]; then
      score_logs=1
    fi
  fi
fi

health_score=$(python3 -c "print(round((${score_account}+${score_rbac}+${score_metrics}+${score_logs})/4, 2))")

jq -n \
  --argjson score_account "$score_account" \
  --argjson score_rbac "$score_rbac" \
  --argjson score_metrics "$score_metrics" \
  --argjson score_logs "$score_logs" \
  --argjson health_score "$health_score" \
  '{
    dimensions: {
      account_accessible: $score_account,
      rbac_enumerated: $score_rbac,
      metrics_available: $score_metrics,
      logs_enabled: $score_logs
    },
    health_score: $health_score
  }' > "$OUTPUT_FILE"

cat "$OUTPUT_FILE"
