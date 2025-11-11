# Azure Subscription Cost Health

This codebundle analyzes Azure subscription cost health by identifying stopped Function Apps on App Service Plans, proposing consolidation opportunities, and estimating potential cost savings across one or more subscriptions.

## Features

### Cost Analysis & Optimization
- **Stopped Function Discovery**: Identifies stopped Function Apps that are still consuming App Service Plan resources
- **Consolidation Analysis**: Analyzes opportunities to consolidate underutilized App Service Plans
- **Multi-Subscription Support**: Can analyze multiple Azure subscriptions in a single run
- **Resource Group Scoping**: Supports filtering analysis to specific resource groups
- **Cost Estimation**: Provides accurate monthly and annual cost savings estimates using Azure App Service pricing

### Comprehensive Reporting
- **Cost Waste Detection**: Identifies empty App Service Plans with no deployed applications
- **Utilization Analysis**: Evaluates Function App distribution across App Service Plans
- **Severity-Based Classification**: 
  - **Severity 4**: <$500/month potential savings
  - **Severity 3**: $500-$2,000/month potential savings  
  - **Severity 2**: >$2,000/month potential savings
- **Consolidation Recommendations**: Specific guidance on which plans to consolidate and how

### Azure Pricing Integration
- **Comprehensive Pricing Database**: Supports all Azure App Service Plan tiers (Free, Shared, Basic, Standard, Premium, PremiumV2, PremiumV3, Isolated, IsolatedV2)
- **Regional Cost Analysis**: Groups analysis by Azure region for optimal consolidation strategies
- **Conservative Estimates**: Provides realistic savings estimates with safety margins

## Configuration

The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

### Required Variables
- `AZURE_SUBSCRIPTION_IDS`: Comma-separated list of subscription IDs to analyze (e.g., "sub1,sub2,sub3")
- `azure_credentials`: Secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID

### Optional Variables
- `AZURE_SUBSCRIPTION_ID`: Single subscription ID (for backward compatibility)
- `AZURE_RESOURCE_GROUPS`: Comma-separated list of resource groups to analyze (leave empty for all)
- `AZURE_SUBSCRIPTION_NAME`: Subscription name for reporting purposes
- `COST_ANALYSIS_LOOKBACK_DAYS`: Days to look back for analysis (default: 30)
- `LOW_COST_THRESHOLD`: Monthly cost threshold for low severity (default: 500)
- `MEDIUM_COST_THRESHOLD`: Monthly cost threshold for medium severity (default: 2000)
- `HIGH_COST_THRESHOLD`: Monthly cost threshold for high severity (default: 10000)

## Use Cases

### 1. Multi-Subscription Cost Analysis
```yaml
AZURE_SUBSCRIPTION_IDS: "subscription-1,subscription-2,subscription-3"
AZURE_RESOURCE_GROUPS: ""  # Analyze all resource groups
```

### 2. Targeted Resource Group Analysis
```yaml
AZURE_SUBSCRIPTION_IDS: "my-subscription-id"
AZURE_RESOURCE_GROUPS: "production-rg,staging-rg"
```

### 3. Single Subscription Deep Dive
```yaml
AZURE_SUBSCRIPTION_ID: "single-subscription-id"
AZURE_RESOURCE_GROUPS: ""  # All resource groups in subscription
```

## Output

The codebundle generates:

1. **Cost Analysis Issues**: Structured issues with severity levels, cost estimates, and remediation steps
2. **Consolidation Recommendations**: Specific guidance on which App Service Plans to consolidate
3. **Summary Reports**: High-level overview of findings and potential savings
4. **Validation Reports**: Confirmation of Azure access and permissions

## Authentication

This codebundle uses Azure service principal authentication. Ensure your service principal has the following permissions:

- **Reader** role on target subscriptions
- **App Service Plan Reader** permissions
- **Function App Reader** permissions
- **Monitor Reader** for utilization metrics (if available)

## Notes

- The analysis focuses on Function Apps and App Service Plans, not Web Apps
- Stopped Function Apps are identified as primary cost waste opportunities
- Consolidation recommendations consider regional boundaries and technical compatibility
- Cost estimates are based on Azure pay-as-you-go pricing (2024)
- The tool provides conservative estimates to account for performance and scaling considerations
