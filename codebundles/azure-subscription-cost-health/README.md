# Azure Subscription Cost Health

This codebundle analyzes Azure subscription cost health by identifying stopped Function Apps on App Service Plans, proposing consolidation opportunities, analyzing AKS node pool utilization, and estimating potential cost savings across one or more subscriptions with configurable discount factors.


## Features

### Cost Analysis & Optimization
- **Stopped Function Discovery**: Identifies stopped Function Apps that are still consuming App Service Plan resources
- **Consolidation Analysis**: Analyzes opportunities to consolidate underutilized App Service Plans
- **AKS Node Pool Optimization**: Analyzes AKS cluster node pools and provides resizing recommendations based on actual CPU/memory utilization
- **Configurable Discounts**: Apply custom discount percentages off MSRP to reflect your Azure pricing agreements (EA, CSP, etc.)
- **Multi-Subscription Support**: Can analyze multiple Azure subscriptions in a single run
- **Resource Group Scoping**: Supports filtering analysis to specific resource groups
- **Cost Estimation**: Provides accurate monthly and annual cost savings estimates using Azure pricing databases

### Comprehensive Reporting
- **Cost Waste Detection**: Identifies empty App Service Plans with no deployed applications
- **Utilization Analysis**: Evaluates Function App distribution across App Service Plans
- **AKS Node Pool Analysis**: Examines both average and peak CPU/memory utilization over 30 days to identify optimization opportunities
- **Severity-Based Classification**: 
  - **Severity 4**: <$500/month potential savings
  - **Severity 3**: $500-$2,000/month potential savings  
  - **Severity 2**: >$2,000/month potential savings
- **Consolidation Recommendations**: Specific guidance on which plans to consolidate and how
- **Node Pool Resizing**: Recommendations for reducing minimum node counts or changing VM types

### Azure Pricing Integration
- **Comprehensive Pricing Database**: 
  - Supports all Azure App Service Plan tiers (Free, Shared, Basic, Standard, Premium, PremiumV2, PremiumV3, Isolated, IsolatedV2)
  - Supports common AKS VM types (D-series, E-series, F-series, B-series, A-series)
- **Custom Discount Factors**: Apply your negotiated Azure discount rates (EA, CSP, Reserved Instances, etc.)
- **Regional Cost Analysis**: Groups analysis by Azure region for optimal consolidation strategies
- **Conservative Estimates**: Provides realistic savings estimates with safety margins

### AKS Node Pool Optimization
- **Utilization Metrics**: Analyzes both **average** and **peak** CPU/memory usage over configurable lookback period (default: 30 days)
- **Two-Tier Capacity Planning**: 
  - **Minimum nodes** based on **average** utilization (150% safety margin by default)
  - **Maximum nodes** based on **peak** utilization (150% safety margin by default)
  - This ensures cost-effective baseline capacity while maintaining ceiling for traffic spikes
- **Autoscaling Optimization**: Recommends minimum node count reductions for underutilized autoscaling node pools
- **VM Type Recommendations**: Suggests alternative VM sizes based on workload patterns (compute vs memory optimized)
- **Static Pool Analysis**: Identifies static node pools that would benefit from autoscaling
- **Operational Safety Limits**: 
  - Caps reductions at 50% per recommendation (prevents dangerous over-optimization)
  - Enforces minimum node floors (5 nodes for user pools, 3 for system pools)
  - Detects and warns about metric anomalies (e.g., 0% average with high peak)
  - Supports gradual, phased reduction strategies for large optimizations
- **Cost-Performance Balance**: Ensures recommendations maintain performance while optimizing costs

## Configuration

The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

### Required Variables
- `AZURE_SUBSCRIPTION_IDS`: Comma-separated list of subscription IDs to analyze (e.g., "sub1,sub2,sub3")
- `azure_credentials`: Secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID

### Optional Variables
- `AZURE_SUBSCRIPTION_ID`: Single subscription ID (for backward compatibility)
- `AZURE_RESOURCE_GROUPS`: Comma-separated list of resource groups to analyze (leave empty for all)
- `AZURE_SUBSCRIPTION_NAME`: Subscription name for reporting purposes
- `AZURE_DISCOUNT_PERCENTAGE`: Discount percentage off MSRP (e.g., 20 for 20% discount, default: 0)
- `COST_ANALYSIS_LOOKBACK_DAYS`: Days to look back for analysis (default: 30)
- `LOW_COST_THRESHOLD`: Monthly cost threshold for low severity (default: 500)
- `MEDIUM_COST_THRESHOLD`: Monthly cost threshold for medium severity (default: 2000)
- `HIGH_COST_THRESHOLD`: Monthly cost threshold for high severity (default: 10000)

#### AKS-Specific Safety Limits
- `MIN_NODE_SAFETY_MARGIN_PERCENT`: Safety margin for minimum node calculations (default: 150)
- `MAX_NODE_SAFETY_MARGIN_PERCENT`: Safety margin for maximum node calculations (default: 150)
- `MAX_REDUCTION_PERCENT`: Maximum percentage reduction allowed per recommendation (default: 50)
- `MIN_USER_POOL_NODES`: Minimum nodes for user pools (default: 5)
- `MIN_SYSTEM_POOL_NODES`: Minimum nodes for system pools (default: 3)

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

### 4. Cost Analysis with Custom Discount
```yaml
AZURE_SUBSCRIPTION_IDS: "my-subscription-id"
AZURE_DISCOUNT_PERCENTAGE: "25"  # Apply 25% EA discount
COST_ANALYSIS_LOOKBACK_DAYS: "30"
```

### 5. AKS Node Pool Optimization
The codebundle includes a dedicated task for analyzing AKS cluster node pools:
- Examines all AKS clusters in target subscriptions
- Retrieves **both average and peak** CPU and memory metrics from Azure Monitor (past 30 days)
- Uses two-tier capacity planning: minimum nodes based on average utilization, maximum nodes based on peak
- Identifies underutilized node pools (CPU < 60%, Memory < 65%)
- Recommends minimum node count reductions for autoscaling pools with configurable safety margins (default: 150%)
- Suggests alternative VM types based on workload patterns
- Enforces 3-node minimum for system node pools
- Provides cost savings estimates with all discount factors applied

## Output

The codebundle generates:

1. **Cost Analysis Issues**: Structured issues with severity levels, cost estimates, and remediation steps
2. **Consolidation Recommendations**: Specific guidance on which App Service Plans to consolidate
3. **AKS Optimization Issues**: Node pool resizing recommendations with utilization data and cost impact
4. **Summary Reports**: High-level overview of findings and potential savings across all services
5. **Validation Reports**: Confirmation of Azure access and permissions
6. **Detailed Reports**: Text-based reports with comprehensive analysis data

### Example Outputs

**App Service Plan Optimization**:
- Empty App Service Plans with monthly waste estimates
- Consolidation opportunities grouped by region
- Stopped Function Apps with associated costs

**AKS Node Pool Optimization**:
- Underutilized autoscaling pools with recommended minimum node count reductions
- Static node pools that should enable autoscaling
- Alternative VM type recommendations for compute/memory optimization
- Both average and peak utilization metrics (CPU and memory percentages)
- Detailed capacity planning showing minimum based on average, maximum based on peak

## Authentication

This codebundle uses Azure service principal authentication. Ensure your service principal has the following permissions:

- **Reader** role on target subscriptions
- **App Service Plan Reader** permissions
- **Function App Reader** permissions
- **AKS Cluster Reader** permissions (for AKS optimization tasks)
- **Monitor Reader** for utilization metrics (required for AKS analysis)

## Direct Testing

For rapid testing and development, you can run the script directly:

```bash
# Set required environment variables
export AZURE_SUBSCRIPTION_ID="your-subscription-id"

# Optional: Set additional parameters
export AZURE_RESOURCE_GROUPS="your-resource-group"
export AZURE_DISCOUNT_PERCENTAGE="15"

# Ensure you're authenticated with Azure CLI
az login

# Run the analysis script
./azure_subscription_cost_analysis.sh
```

The script will generate:
- `azure_subscription_cost_analysis_issues.json` - Machine-readable issues
- `azure_subscription_cost_analysis_report.txt` - Detailed text report

## Notes

### General
- All cost estimates reflect configurable discount percentages (AZURE_DISCOUNT_PERCENTAGE)
- Multiple subscriptions and resource groups can be analyzed in a single run
- Cost estimates are based on Azure pay-as-you-go pricing (2024) before discounts
- The tool provides conservative estimates to account for performance and scaling considerations

### Performance Optimizations
- **Intelligent Caching**: Function App details are cached per subscription to eliminate redundant API calls
- **Parallel Processing**: Uses parallel Azure CLI calls with controlled concurrency to avoid API throttling
- **Timeout Protection**: 5-minute timeout prevents script hanging on large environments
- **Execution Time**: Reduced from 10+ minutes to under 2 minutes for typical subscriptions
- **Scalability**: Handles environments with 200+ Function Apps efficiently

### App Service Plan Analysis
- The analysis focuses on Function Apps and App Service Plans, not Web Apps
- Stopped Function Apps are identified as primary cost waste opportunities
- Consolidation recommendations consider regional boundaries and technical compatibility
- **Function App Association**: Uses individual `az functionapp show` calls for accurate App Service Plan associations

### AKS Node Pool Analysis
- Requires Azure Monitor metrics to be enabled on AKS clusters
- Analysis period defaults to 30 days (configurable via COST_ANALYSIS_LOOKBACK_DAYS)
- Recommendations preserve maximum node counts to handle peak loads
- VM type recommendations consider both compute and memory utilization patterns
- Static node pools with low utilization receive recommendations to enable autoscaling
- **Safety Limits Applied**:
  - Reductions capped at 50% per change (configurable via MAX_REDUCTION_PERCENT)
  - Minimum 5 nodes for user pools, 3 for system pools (configurable)
  - Warns when metrics show anomalies (e.g., 0% average but high peak)
  - Large reductions suggest phased implementation strategy
