# Azure NSG and Firewall Change Activity Audit

This CodeBundle queries the Azure Activity Log for create, update, and delete operations on Network Security Groups (including rules), Azure Firewall, and firewall policy resources. It classifies callers against optional allowlists of CI/CD application IDs and managed identity object IDs, flags manual or out-of-band changes, and summarizes activity for governance and incident review.

## Overview

- **NSG mutations**: Write, delete, and action operations on `Microsoft.Network` NSG resources in the configured lookback window, including failed operations and high-volume warnings (Activity Log queries are capped per CLI request).
- **Firewall and policy mutations**: Similar coverage for Azure Firewall, firewall policies, rule collection groups, and related operations.
- **Caller classification**: Compares Activity Log claims (`appid`, object identifier, `caller`) to `CICD_APP_IDS` and `CICD_OBJECT_IDS` when set.
- **Governance flags**: Optional non-allowlisted identity issues and optional UTC maintenance window violations.
- **Summary**: Aggregates counts by operation and caller with a subscription Activity Log portal link.

Activity Log retention is typically 90 days at subscription scope; `az monitor activity-log list` returns at most `--max-events` records (default in scripts: 500) per query for the Microsoft.Network namespace filter.

## Configuration

### Required Variables

- `AZURE_SUBSCRIPTION_ID`: Subscription to audit.

### Optional Variables

- `AZURE_RESOURCE_GROUP`: Limit queries to this resource group; leave empty for subscription scope.
- `ACTIVITY_LOOKBACK_HOURS`: Hours of history to analyze (default: `168`).
- `CICD_APP_IDS`: Comma-separated Azure AD application (client) IDs approved for automation.
- `CICD_OBJECT_IDS`: Comma-separated object IDs for managed identities or service principals.
- `MAINTENANCE_START_HOUR_UTC`: Optional maintenance window start hour `0`–`23` UTC (use with `MAINTENANCE_END_HOUR_UTC`).
- `MAINTENANCE_END_HOUR_UTC`: Optional end hour; window is `[start, end)` when start is less than end, otherwise wraps midnight.
- `AZURE_TENANT_ID`: Optional tenant ID included in the summary JSON for portal context.

### Secrets

- `azure_credentials`: Service principal JSON or environment fields (`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_CLIENT_SECRET`). Reader on the subscription is sufficient for Activity Log read.

## Tasks Overview

### Query Activity Log for NSG Mutations

Lists NSG-related write/delete/action events, records raw JSON to `nsg_writes_raw.json`, and emits issues for failed operations or unusually high volume relative to the query cap.

### Query Activity Log for Azure Firewall and Policy Mutations

Same pattern for Azure Firewall and firewall policy resources; output in `firewall_writes_raw.json` and `firewall_issues.json`.

### Classify Callers Against Allowlist

Merges NSG and firewall events and tags each as automated or manual/unknown. If allowlists are empty, emits an informational issue to configure `CICD_APP_IDS` / `CICD_OBJECT_IDS`.

### Flag Manual or Out-of-Band Changes

Raises higher-severity issues for identities not on the allowlist (when allowlists are configured) and for mutations outside the optional UTC maintenance window.

### Summarize Change Timeline and Top Actors

Produces `summary_report.json` with counts by operation and caller plus an Activity Log blade URL for the subscription.
