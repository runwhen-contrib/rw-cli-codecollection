#!/usr/bin/env bash
# Shared helpers for Azure Cosmos DB configuration health scripts.

cosmosdb_resolve_subscription() {
  local sub="${AZ_SUBSCRIPTION:-}"
  if [[ -z "$sub" ]]; then
    sub="${AZURE_RESOURCE_SUBSCRIPTION_ID:-}"
  fi
  if [[ -z "$sub" ]]; then
    sub=$(az account show --query id -o tsv 2>/dev/null || true)
  fi
  printf '%s' "$sub"
}

cosmosdb_account_names() {
  local sub="$1" rg="$2" filter="${3:-All}"
  az account set --subscription "$sub" 2>/dev/null || true
  local fl
  fl=$(echo "$filter" | tr '[:upper:]' '[:lower:]')
  if [[ -z "$filter" || "$fl" == "all" ]]; then
    az cosmosdb list -g "$rg" --subscription "$sub" --query "[].name" -o tsv 2>/dev/null || true
  else
    printf '%s\n' "$filter"
  fi
}

cosmosdb_account_resource_id() {
  local sub="$1" rg="$2" name="$3"
  printf '/subscriptions/%s/resourceGroups/%s/providers/Microsoft.DocumentDB/databaseAccounts/%s' "$sub" "$rg" "$name"
}
