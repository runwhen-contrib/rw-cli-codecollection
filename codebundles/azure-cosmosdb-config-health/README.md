# Azure Cosmos DB Configuration Health

This CodeBundle validates Azure Cosmos DB account settings that affect availability, security, recoverability, and operability. It uses read-only Azure Resource Manager, Resource Health, monitoring, and activity log APIs—aligned with **Reader**-style access plus diagnostic read permissions where required.

## Overview

- **Resource Health**: Detects Azure platform or account-level availability states that are not `Available`.
- **API and consistency**: Flags `Eventual` default consistency, inconsistent multi-region write configuration, and accounts that still allow key-based metadata writes.
- **Backup**: Ensures a supported backup mode (periodic with reasonable retention or continuous).
- **Public network and firewall**: Surfaces wide-open public access patterns and `0.0.0.0` firewall rules.
- **Private endpoints**: When public access is disabled, verifies private endpoints exist and are `Approved`.
- **Diagnostic settings**: Confirms at least one diagnostic setting exports telemetry.
- **Activity log**: Summarizes recent administrative events for the account to support change correlation.

Pair with utilization-focused bundles (for example RU and latency metrics) for a full operational picture.

## Configuration

### Required variables

- `AZ_SUBSCRIPTION`: Azure subscription ID (UUID) for the Cosmos DB account.
- `AZURE_RESOURCE_GROUP`: Resource group that contains the account (or accounts when scanning `All`).

### Optional variables

- `COSMOSDB_ACCOUNT_NAME`: Cosmos DB account name. Set to `All` (default) to evaluate every account in the resource group.
- `ACTIVITY_LOG_LOOKBACK_HOURS`: Hours of activity log history to scan for administrative events (default: `168`).

### Secrets

- `azure_credentials`: Service principal or workspace secret in the format expected by your Azure CLI login flow (commonly `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_CLIENT_SECRET`, and subscription context). Match the pattern used by other Azure CLI CodeBundles in the workspace.

## Tasks overview

### Check Cosmos DB Resource Health

Queries `Microsoft.ResourceHealth/availabilityStatuses/current` for each scoped account and raises issues when the reported title is not `Available`.

### Check Cosmos DB API and Consistency Configuration

Reads `az cosmosdb show` output to evaluate default consistency, multi-region write flags versus region count, and metadata write protection.

### Check Cosmos DB Backup and Point-in-Time Settings

Validates periodic backup retention (minimum eight hours) or continuous backup mode.

### Check Cosmos DB Public Network Access and Firewall Rules

Detects public network exposure without compensating IP or private-link controls and flags `0.0.0.0` rules.

### Check Cosmos DB Private Endpoint Configuration

When public access is disabled, requires private endpoints in an `Approved` state.

### Check Cosmos DB Diagnostic Settings

Lists Azure Monitor diagnostic settings for the account resource ID and flags a missing configuration.

### Check Cosmos DB Activity Log for Recent Configuration Changes

Lists recent administrative activity log events scoped to the account for change awareness.

## Service Level Indicator

`sli.robot` emits a 0–1 score averaged across seven configuration dimensions using `cosmosdb-sli-dimensions.sh`. Sub-metrics are published per dimension for dashboard drill-down.
