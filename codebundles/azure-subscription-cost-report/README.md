# Azure Subscription Cost Report

This codebundle generates detailed cost breakdown reports for Azure subscriptions using the Cost Management API, and provides Reserved Instance purchase recommendations from Azure Advisor.

## Purpose

- Generate historical cost reports by service and resource group
- Compare current period costs against previous period
- Alert when cost increases exceed configured thresholds
- Provide visibility into spending trends
- Identify Reserved Instance (RI) purchase opportunities for additional savings

## Tasks

### Generate Azure Cost Report By Service and Resource Group
Generates a detailed cost breakdown for the configured lookback period (default 30 days) showing:
- Total costs across all subscriptions
- Costs broken down by resource group
- Costs broken down by service/meter category
- Period-over-period comparison with trend analysis

### Analyze Azure Advisor Reserved Instance Recommendations
Queries Azure Advisor and the Reservations API to identify RI purchase opportunities:
- VMs with consistent utilization eligible for VM Reserved Instances
- App Service Plans (P*v3, I*v2) eligible for App Service RIs
- Other resources eligible for reservations (SQL, Cosmos DB, etc.)
- Calculates potential monthly and annual savings
- Provides guidance on 1-year vs 3-year term selection

**Reserved Instance Savings:**
- 1-Year Term: ~35-40% savings vs pay-as-you-go
- 3-Year Term: ~55-72% savings vs pay-as-you-go

## Configuration

| Variable | Description | Default |
|----------|-------------|---------|
| `AZURE_SUBSCRIPTION_IDS` | Comma-separated subscription IDs to analyze | Current subscription |
| `AZURE_SUBSCRIPTION_NAME` | Subscription name for display purposes | "" |
| `COST_ANALYSIS_LOOKBACK_DAYS` | Days to analyze for cost data | 30 |
| `COST_INCREASE_THRESHOLD` | Percentage increase that triggers an alert | 10 |
| `TIMEOUT_SECONDS` | Task timeout in seconds | 1500 |

## SLI

The SLI returns:
- `1` (healthy): Costs are stable or decreasing
- `0` (unhealthy): Cost increase exceeds the configured threshold

## Requirements

- Azure credentials with Cost Management Reader role
- Access to Azure Cost Management API
- Access to Azure Advisor API (for RI recommendations)

## Related Codebundles

When cost increases are detected, the issue next_steps will recommend running these specialized optimization codebundles:

| Codebundle | Purpose |
|------------|---------|
| `azure-vm-cost-optimization` | VM rightsizing, deallocation of stopped VMs, B-series recommendations |
| `azure-aks-cost-optimization` | AKS node pool utilization analysis, autoscaling optimization |
| `azure-storage-cost-optimization` | Orphaned disks, old snapshots, lifecycle policies, redundancy optimization |
| `azure-appservice-cost-optimization` | Empty plans, underutilized plans, SKU rightsizing |
| `azure-databricks-cost-optimization` | Cluster auto-termination, idle detection, over-provisioning |

Each specialized codebundle generates its own SLX and can be scheduled independently for targeted cost optimization.
