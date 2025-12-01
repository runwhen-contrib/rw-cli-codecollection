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

### App Service Plan Optimization Strategies

The tool supports three optimization strategies to balance cost savings with operational safety:

#### **Aggressive** (`OPTIMIZATION_STRATEGY=aggressive`)
- **Target Utilization**: 85-90% max CPU after optimization
- **Risk Tolerance**: Medium to High
- **Best For**: Non-critical workloads, dev/test/staging environments
- **Characteristics**:
  - Maximum cost savings approach
  - Accepts recommendations that may push utilization close to capacity
  - Suitable for workloads with predictable traffic patterns
  - Recommended when quick cost reduction is a priority

#### **Balanced** (default, `OPTIMIZATION_STRATEGY=balanced`)
- **Target Utilization**: 75-80% max CPU after optimization
- **Risk Tolerance**: Low to Medium
- **Best For**: Standard production workloads
- **Characteristics**:
  - Default optimization approach
  - Balances cost savings with operational headroom
  - Maintains buffer for traffic spikes and growth
  - Suitable for most production environments
  - Recommended for general use

#### **Conservative** (`OPTIMIZATION_STRATEGY=conservative`)
- **Target Utilization**: 60-70% max CPU after optimization
- **Risk Tolerance**: Low only
- **Best For**: Critical production workloads, high-growth applications
- **Characteristics**:
  - Safest optimization approach
  - Only LOW-risk recommendations
  - Preserves significant headroom for burst capacity
  - Accounts for traffic growth and seasonal spikes
  - Recommended for mission-critical applications

#### Memory Thresholds (All Strategies)

All strategies now enforce memory safety limits to prevent out-of-memory issues:

| Current Memory Max | SKU Downgrade Risk | Notes |
|--------------------|-------------------|--------|
| **> 90%** | 🔴 **HIGH** (blocked) | SKU downgrade would halve memory - extremely dangerous |
| **80-90%** | 🔴 **HIGH** (warning) | Downgrade likely to cause memory pressure |
| **70-80%** | 🟡 **MEDIUM** | Proceed with caution, monitor closely |
| **< 70%** | Evaluated normally | Safe to consider SKU downgrade |

**Why This Matters**: SKU downgrades (e.g., EP3 → EP2) reduce available memory by 50%. If memory is already elevated, this can cause application crashes, restarts, and service disruptions.

### Enhanced Recommendations with Full Options Table

For each App Service Plan analyzed, the tool now provides:

1. **Comprehensive Options Table**: Shows ALL possible optimization configurations including:
   - Current configuration (baseline)
   - Single instance reduction options
   - 50% capacity reduction scenarios
   - SKU downgrade options
   - Combined SKU + capacity optimizations

2. **Memory-Aware Risk Assessment**:
   - Evaluates **both CPU and Memory** constraints
   - Prevents dangerous SKU downgrades when memory is already high (>80% max)
   - **LOW**: Safe to implement, minimal performance impact (CPU <75%, Memory <80%)
   - **MEDIUM**: Requires monitoring, implement during low-traffic periods (CPU <85%, Memory <90%)
   - **HIGH**: Requires careful evaluation and gradual rollout (CPU >85% or Memory >90%)
   - Critical warnings displayed when memory pressure detected

3. **Projected Utilization**: For each option, see:
   - Projected average CPU and memory
   - Projected maximum CPU and memory
   - Confidence level of the projection

4. **Contextual Information**:
   - Current 7-day utilization metrics
   - Number of running vs total apps
   - Implementation risk assessment
   - Rollback recommendations
   - Specific Azure CLI commands

### Comprehensive Reporting
- **Cost Waste Detection**: Identifies empty App Service Plans with no deployed applications
- **Utilization Analysis**: Evaluates Function App distribution across App Service Plans
- **AKS Node Pool Analysis**: Examines both average and peak CPU/memory utilization over 30 days to identify optimization opportunities
- **Savings-Based Classification**: Issues are grouped by potential monthly savings amount (financial impact):
  - **LOW Savings**: <$2,000/month potential savings per issue group (Severity 3)
  - **MEDIUM Savings**: $2,000-$10,000/month potential savings per issue group (Severity 2)  
  - **HIGH Savings**: >$10,000/month potential savings per issue group (Severity 1)
  - **Note**: Each issue shows the implementation risk (LOW/MEDIUM/HIGH) for each recommendation separately
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
- `AZURE_RESOURCE_GROUPS`: Comma-separated list of resource groups to analyze (leave empty for all)
- `AZURE_SUBSCRIPTION_NAME`: Subscription name for reporting purposes
- `AZURE_DISCOUNT_PERCENTAGE`: Discount percentage off MSRP (e.g., 20 for 20% discount, default: 0)
- `COST_ANALYSIS_LOOKBACK_DAYS`: Days to look back for analysis (default: 30)
- `LOW_COST_THRESHOLD`: Not used (reserved for future use, default: 0)
- `MEDIUM_COST_THRESHOLD`: Monthly savings threshold in USD for MEDIUM savings classification (default: 2000)
  - Recommendations with savings ≥ this value but < HIGH_COST_THRESHOLD are grouped as "MEDIUM Savings"
- `HIGH_COST_THRESHOLD`: Monthly savings threshold in USD for HIGH savings classification (default: 10000)
  - Recommendations with savings ≥ this value are grouped as "HIGH Savings"
- `OPTIMIZATION_STRATEGY`: App Service Plan optimization approach - `aggressive`, `balanced` (default), or `conservative` (see below)

#### Customizing Savings Thresholds

You can adjust how recommendations are grouped by setting environment variables:

```bash
# Example: More granular classification for large environments
export MEDIUM_COST_THRESHOLD=5000   # MEDIUM = $5K-$20K/month
export HIGH_COST_THRESHOLD=20000    # HIGH = $20K+/month
./azure_appservice_cost_optimization.sh

# Example: Stricter classification for smaller environments  
export MEDIUM_COST_THRESHOLD=500    # MEDIUM = $500-$2K/month
export HIGH_COST_THRESHOLD=2000     # HIGH = $2K+/month
./azure_appservice_cost_optimization.sh
```

**How It Works:**
- **LOW Savings**: < `MEDIUM_COST_THRESHOLD` per month (Severity 3 issue)
- **MEDIUM Savings**: `MEDIUM_COST_THRESHOLD` to `HIGH_COST_THRESHOLD` per month (Severity 2 issue)
- **HIGH Savings**: ≥ `HIGH_COST_THRESHOLD` per month (Severity 1 issue)

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
AZURE_SUBSCRIPTION_IDS: "single-subscription-id"
AZURE_RESOURCE_GROUPS: ""  # All resource groups in subscription
```

### 4. Cost Analysis with Custom Discount
```yaml
AZURE_SUBSCRIPTION_IDS: "my-subscription-id"
AZURE_DISCOUNT_PERCENTAGE: "25"  # Apply 25% EA discount
COST_ANALYSIS_LOOKBACK_DAYS: "30"
```

### 5. Aggressive Cost Optimization (Dev/Test Environments)
```yaml
AZURE_SUBSCRIPTION_IDS: "dev-subscription-id"
OPTIMIZATION_STRATEGY: "aggressive"  # Maximum cost savings
AZURE_DISCOUNT_PERCENTAGE: "20"
```

### 6. Conservative Optimization (Critical Production)
```yaml
AZURE_SUBSCRIPTION_IDS: "production-subscription-id"
OPTIMIZATION_STRATEGY: "conservative"  # Safest approach
AZURE_RESOURCE_GROUPS: "critical-apps-rg"
```

### 7. AKS Node Pool Optimization
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

1. **Cost Analysis Issues**: Structured issues grouped by potential savings amount (financial impact)
   - **Important**: Issue titles show **"Savings"** level (LOW/MEDIUM/HIGH) based on dollar amount
   - Each recommendation within the issue shows **"Risk"** level (LOW/MEDIUM/HIGH) for implementation safety
   - Example: A "LOW Savings" issue may contain LOW-risk recommendations that are safe to implement immediately
2. **Consolidation Recommendations**: Specific guidance on which App Service Plans to consolidate
3. **AKS Optimization Issues**: Node pool resizing recommendations with utilization data and cost impact
4. **Summary Reports**: High-level overview of findings and potential savings across all services

#### Understanding Savings vs Risk

- **Savings Level** (in issue title): How much money you'll save per month
  - HIGH Savings: ≥$10,000/month per issue group
  - MEDIUM Savings: $2,000-$10,000/month per issue group
  - LOW Savings: <$2,000/month per issue group
  
- **Risk Level** (per recommendation): How safe is the change to implement
  - LOW Risk: Safe to implement with minimal performance impact
  - MEDIUM Risk: Requires monitoring, implement during low-traffic periods
  - HIGH Risk: Carefully evaluate, may cause performance issues

**Best Practice**: Prioritize LOW-risk recommendations first, regardless of savings level. Many small LOW-risk changes add up quickly and safely!
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
export AZURE_SUBSCRIPTION_IDS="your-subscription-id"

# Optional: Set additional parameters
export AZURE_RESOURCE_GROUPS="your-resource-group"
export AZURE_DISCOUNT_PERCENTAGE="15"
export OPTIMIZATION_STRATEGY="balanced"  # or "aggressive" or "conservative"

# Ensure you're authenticated with Azure CLI
az login

# Run the analysis script
./azure_appservice_cost_optimization.sh
```

**Examples with Different Strategies:**

```bash
# Conservative approach for production
export OPTIMIZATION_STRATEGY="conservative"
./azure_appservice_cost_optimization.sh

# Aggressive approach for dev/test
export OPTIMIZATION_STRATEGY="aggressive"
./azure_appservice_cost_optimization.sh

# Default balanced approach (no need to set)
./azure_appservice_cost_optimization.sh
```

The script will generate:
- `azure_appservice_cost_optimization_issues.json` - Machine-readable issues
- `azure_appservice_cost_optimization_report.txt` - Detailed text report

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
- **Large Dataset Support**: Uses temporary files (created in `CODEBUNDLE_TEMP_DIR` or current directory) instead of command-line arguments to avoid "Argument list too long" errors with 500+ cost records. Temporary files are automatically cleaned up after processing.

### App Service Plan Analysis
- The analysis focuses on Function Apps and App Service Plans, not Web Apps
- Stopped Function Apps are identified as primary cost waste opportunities
- Consolidation recommendations consider regional boundaries and technical compatibility
- **Function App Association**: Uses individual `az functionapp show` calls for accurate App Service Plan associations
- **Optimization Strategies**: Three strategies (aggressive/balanced/conservative) provide flexibility for different environments
- **Full Options Table**: Each analysis now shows ALL possible optimization options with risk assessment
- **Contextual Recommendations**: Includes projected utilization, risk levels, confidence scores, and implementation guidance
- **7-Day Metrics Window**: Uses Azure Monitor data from the past 7 days for recommendations (may differ from 30-day lookback for AKS)

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
