# Azure Storage Account Investigation

Investigate Azure Storage Account utilization, ownership, dependencies, and access patterns so operators can safely assess configuration changes such as disabling public blob access or shared key authentication. Complements Cloud Custodian detection with the investigation data needed for safe remediation.

## Overview

This CodeBundle runs four read-only investigation tasks against a single storage account:

- **RBAC analysis**: Lists all principals with RBAC access including inherited assignments; flags Owner/Contributor at resource scope and user data-plane roles.
- **Dependency mapping**: Queries Azure Resource Graph for resources referencing the account (Data Factory, Function Apps, private endpoints, diagnostic settings, and more).
- **Transaction metrics**: Analyzes blob transaction metrics by authentication type (AccountKey, SAS, OAuth, Anonymous) over a configurable lookback window.
- **Access logs**: Queries StorageBlobLogs in Log Analytics for caller IPs, identities, and authentication types; short-circuits when diagnostic settings are not enabled.

Each task emits structured JSON with an `issues` array and a `risk_assessment` section including `safe_to_disable_public_access` and `safe_to_disable_shared_key` booleans.

## Configuration

### Required Variables

- `AZURE_SUBSCRIPTION_ID`: Azure subscription ID containing the storage account
- `AZURE_RESOURCE_GROUP`: Resource group containing the storage account
- `AZURE_STORAGE_ACCOUNT_NAME`: Name of the storage account to investigate

### Optional Variables

- `LOOKBACK_DAYS`: Days of metrics and logs to analyze (default: `7`)
- `ADDITIONAL_SUBSCRIPTION_IDS`: Comma-separated subscription IDs for cross-subscription Resource Graph dependency queries (default: empty)
- `LOG_ANALYTICS_WORKSPACE_ID`: Log Analytics workspace resource ID for StorageBlobLogs queries; auto-discovered from diagnostic settings when omitted (default: empty)

### Secrets

- `azure_credentials`: Azure Service Principal credentials for `az` CLI authentication. JSON object with `clientId`, `clientSecret`, `tenantId`, and `subscriptionId` (or equivalent fields per the `azure-auth.yaml` workspace template).

## Tasks Overview

### List Storage Account RBAC Role Assignments

Identifies all principals with RBAC access to the storage account, including inherited assignments from resource group and subscription scope. Issues severity 3 for Owner/Contributor at resource scope and severity 4 for user principals with data-plane roles.

### Query Resource Graph for Storage Account Dependencies

Maps dependent Azure resources via property references, private endpoint connections, and diagnostic settings targets. Issues severity 2 when more than five dependents are found, severity 3 for one to five, and severity 4 when none are found (with Resource Graph blind-spot notes).

### Analyze Storage Account Transaction Metrics by Authentication Type

Pulls Azure Monitor blob transaction metrics broken down by Authentication and ApiName dimensions, plus ingress, egress, and capacity metrics. Issues severity 2 for anonymous transactions, severity 3 when AccountKey exceeds 50% of traffic, and severity 4 for SAS usage.

### Query Storage Account Access Logs

Queries StorageBlobLogs for caller IPs, UPNs, service principal object IDs, and authentication types. Issues severity 1 when diagnostic settings are not enabled, severity 2 for anonymous auth from external IPs, severity 3 for anonymous internal IPs, and severity 4 for multiple distinct AccountKey callers.

## Permissions Required

- Reader plus `Microsoft.Authorization/roleAssignments/read` on the target subscription (Task 1)
- Reader at subscription scope for Resource Graph (Task 2)
- Monitoring Reader on the storage account (Task 3)
- Log Analytics Reader on the workspace (Task 4, when configured)

## Related Bundles

- **azure-storage-health** (azure-c7n-codecollection): Detects misconfigurations such as `allowBlobPublicAccess: true`
- **azure-storage-cost-optimization**: Subscription/RG-wide storage spend analysis
- **azure-acr-health**: Reference for Azure resource-scoped investigation patterns
