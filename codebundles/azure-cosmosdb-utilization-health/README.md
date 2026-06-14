# Azure Cosmos DB Utilization and Sizing Health

This CodeBundle evaluates historical and point-in-time utilization for Azure Cosmos DB using Azure Monitor: normalized RU consumption, total RU, HTTP 429 throttling, server-side latency, storage growth, and throughput sizing signals. It complements configuration-focused bundles (for example `azure-cosmosdb-config-health`) with capacity and cost-oriented metrics.

## Overview

- **Normalized RU trends**: Detects sustained high utilization and rising pressure versus the first half of the lookback window.
- **Total RU consumed**: Flags sharp growth in daily `TotalRequestUnits` between halves of the window.
- **Throttling / 429**: Sums `TotalRequests` filtered to status `429` to catch undersizing or hot partitions.
- **Server-side latency**: Compares `ServerSideLatency` hourly averages to a configurable millisecond threshold.
- **Storage**: Tracks `DataUsage` and `IndexUsage` for rapid expansion.
- **Throughput sizing**: Highlights ceiling risk from high normalized RU and possible over-provisioning when normalized RU stays low while `ProvisionedThroughput` remains high.
- **SLI**: A lightweight `sli.robot` averages binary checks (normalized RU, 429 count, latency) into a 0–1 score.

Metric names follow Microsoft’s supported metrics for `Microsoft.DocumentDB/databaseAccounts` (for example `NormalizedRUConsumption`, `TotalRequestUnits`, `TotalRequests` with `StatusCode`, `ServerSideLatency`, `DataUsage`, `IndexUsage`, `ProvisionedThroughput`).

## Configuration

### Required variables

- `AZ_SUBSCRIPTION`: Azure subscription ID (UUID) used for `az account set` and metric queries.
- `AZURE_RESOURCE_GROUP`: Resource group containing the Cosmos DB account(s).

### Optional variables

- `COSMOSDB_ACCOUNT_NAME`: Cosmos DB account name, or `All` to scan every account in the group (default: `All`).
- `METRICS_LOOKBACK_DAYS`: Days of history for runbook tasks (default: `14`).
- `NORMALIZED_RU_THRESHOLD_PCT`: Normalized RU percentage that triggers utilization and sizing issues (default: `80`).
- `THROTTLE_EVENTS_THRESHOLD`: Minimum total HTTP 429 count in the window to raise throttling issues (default: `1`).
- `SERVER_LATENCY_MS_THRESHOLD`: Maximum acceptable hourly average `ServerSideLatency` in ms (default: `100`).
- `STORAGE_GROWTH_PCT_THRESHOLD`: Percent growth from start to end of the window on `DataUsage` / `IndexUsage` that flags storage expansion (default: `25`).
- `UNDERUTILIZED_NORMALIZED_PCT`: Normalized RU level used with `ProvisionedThroughput` to suggest over-provisioning (default: `15`).
- `RU_DAILY_GROWTH_RATIO`: Ratio of later-window to earlier-window average daily total RU for spike detection (default: `1.5`).
- `AZURE_SUBSCRIPTION_NAME`: Friendly subscription label for context in reports (default: `Azure Subscription`).

### SLI-only variables

- `SLI_METRICS_OFFSET`: Short lookback for the SLI snapshot (default: `2d`), for example `2d` or `24h`.

### Secrets

- `azure_credentials`: JSON or structured secret consumed by the RunWhen Azure integration (typically `CLIENT_ID`, `TENANT_ID`, `CLIENT_SECRET`, `SUBSCRIPTION_ID` / `AZURE_SUBSCRIPTION_ID`). If absent, ambient `az login` / workload identity is assumed.

## Tasks overview

### Analyze Cosmos DB Normalized RU Consumption Trends

Uses `NormalizedRUConsumption` to detect sustained values above the threshold and upward trends correlated with the second half of the window.

### Analyze Cosmos DB Total Request Units Consumed

Uses daily `TotalRequestUnits` totals to detect a sharp increase between the first and second half of the lookback period.

### Check Cosmos DB Throttling and HTTP 429 Rate

Queries `TotalRequests` with dimension filter `StatusCode eq '429'` and compares the aggregate to `THROTTLE_EVENTS_THRESHOLD`.

### Analyze Cosmos DB Server-side Latency

Evaluates `ServerSideLatency` hourly averages against `SERVER_LATENCY_MS_THRESHOLD`.

### Analyze Cosmos DB Data and Index Storage Utilization

Measures relative growth on `DataUsage` and `IndexUsage` against `STORAGE_GROWTH_PCT_THRESHOLD`.

### Analyze Cosmos DB Provisioned Throughput vs Consumed Load

Combines `NormalizedRUConsumption` with `ProvisionedThroughput` for ceiling and over-provisioning hints.
