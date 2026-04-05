# Azure NSG and Firewall Change Activity Audit

This CodeBundle queries the Azure Activity Log for create, update, and delete operations on Network Security Groups, Azure Firewall, and firewall policies. It classifies callers against optional CI/CD allowlists (application IDs and identity object IDs), flags manual or out-of-band changes relative to maintenance windows, and summarizes top actors and operations for governance and incident review.

## Overview

- **NSG mutations**: Lists write, delete, and action operations whose operation names reference `networkSecurityGroups`, including rule changes, within a configurable lookback window.
- **Firewall and policy mutations**: Same pattern for `azureFirewalls`, `firewallPolicies`, and rule collection operations.
- **Caller classification**: Compares `appId` and object ID claims from each event to `CICD_APP_IDS` and `CICD_OBJECT_IDS`.
- **Governance flags**: Surfaces non-allowlisted callers when allowlists are set, and optional UTC maintenance window violations.
- **Summary**: Aggregates counts by caller and operation with a link to the subscription Activity Log blade in the Azure Portal.

**Limits**: Azure CLI `az monitor activity-log list` returns at most `ACTIVITY_LOG_MAX_EVENTS` events per query (default 500). Subscription-wide logs can be noisy; narrow `ACTIVITY_LOOKBACK_HOURS` or set `AZURE_RESOURCE_GROUP`. Activity log retention and indexing latency apply as documented by Microsoft.

## Configuration

### Required Variables

- `AZURE_SUBSCRIPTION_ID`: Subscription to audit (GUID).

### Optional Variables

- `AZURE_RESOURCE_GROUP`: Limit queries to this resource group; leave empty for the full subscription.
- `ACTIVITY_LOOKBACK_HOURS`: Hours of history to analyze (default: `168`).
- `CICD_APP_IDS`: Comma-separated Azure AD application (client) IDs for approved automation.
- `CICD_OBJECT_IDS`: Comma-separated object IDs for managed identities or service principals to treat as approved automation.
- `ACTIVITY_LOG_MAX_EVENTS`: Maximum rows per activity-log API call (default: `500`; CLI default without this is 50).
- `MAINTENANCE_START_HOUR_UTC` / `MAINTENANCE_END_HOUR_UTC`: Optional inclusive UTC hour window (`0`–`23`) for allowed changes; events outside this range are flagged when both are set. Supports overnight windows when start hour is greater than end hour.
- `TIMEOUT_SECONDS`: Timeout for bash tasks (default: `240`).

### Secrets

- `azure_credentials`: Service principal or equivalent JSON containing `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_CLIENT_SECRET` (and typically subscription context). Reader on the subscription is sufficient for Activity Log reads.

## Tasks Overview

### Query Activity Log for NSG Write Operations

Runs `az monitor activity-log list` at subscription or resource-group scope, filters to NSG-related write/delete/action operations, and emits issues on query failures, truncation risk (result count equals max-events), or failed ARM operations.

### Query Activity Log for Azure Firewall and Policy Write Operations

Same pipeline for Azure Firewall and firewall policy / rule collection operations.

### Classify Activity Log Callers Against CI/CD Allowlist

Merges NSG and firewall event lists, labels each event `automated`, `manual_suspect`, or `unknown`, and raises informational issues when allowlists are empty or unknown identities appear while allowlists are configured.

### Flag Manual or Out-of-Band Network Security Changes

Flags non-allowlisted manual/suspect events when allowlists are set, and flags any event outside the optional UTC maintenance window when start/end hours are configured.

### Summarize Network Security Change Timeline and Top Actors

Prints JSON and human-readable aggregates (by classification, caller, operation) and the subscription Activity Log portal URL.
