#!/usr/bin/env bash
# Shared helpers for Cosmos DB utilization scripts (source from task scripts).

cosmosdb_resolve_subscription() {
  if [[ -n "${AZ_SUBSCRIPTION:-}" ]]; then
    printf '%s' "$AZ_SUBSCRIPTION"
  elif [[ -n "${AZURE_SUBSCRIPTION_ID:-}" ]]; then
    printf '%s' "$AZURE_SUBSCRIPTION_ID"
  else
    az account show --query id -o tsv 2>/dev/null || true
  fi
}

cosmosdb_account_names() {
  local sub="$1" rg="$2" filt="$3"
  if [[ -z "$filt" || "${filt,,}" == "all" ]]; then
    az cosmosdb list -g "$rg" --subscription "$sub" --query '[].name' -o tsv 2>/dev/null || true
  else
    printf '%s\n' "$filt"
  fi
}

cosmosdb_resource_id() {
  local sub="$1" rg="$2" name="$3"
  az cosmosdb show -n "$name" -g "$rg" --subscription "$sub" --query id -o tsv 2>/dev/null || true
}
