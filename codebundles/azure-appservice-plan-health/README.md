# Azure App Service Plan Health
This codebundle runs a suite of metrics checks for App Service Plan health in Azure. It identifies:
- Check App Service Plan capacity Utilization
- Check App Service Plan activity logs
- Check App Service Plan recommendations
- **Cost optimization analysis** that identifies underutilized App Service Plans with potential savings opportunities using 30-day Azure Monitor utilization trends
- **Weekly trend analysis** for detecting utilization growth patterns and app-level metrics

## Features

### Health Monitoring
- **Resource Health**: Checks Azure-reported health status of App Service Plan resources
- **Capacity Analysis**: Validates App Service Plan capacity utilization and identifies high usage issues
- **Configuration Recommendations**: Provides scaling recommendations based on current usage patterns
- **Activity Monitoring**: Analyzes recent activities for errors and warnings

### Weekly Trend Analysis (NEW)
- **Week-over-Week Comparison**: Compares CPU and memory utilization across configurable weeks (default: 4)
- **Trend Detection**: Identifies rapidly growing utilization that may require scaling
- **App-Level Metrics**: Collects per-app metrics including:
  - Request counts
  - HTTP 4xx client errors
  - HTTP 5xx server errors
  - Average response times
- **Growth Alerts**: Detects when utilization grows >15% week-over-week
- **Sustained High Usage Alerts**: Flags plans with >80% average utilization

### Cost Optimization
- **30-Day Utilization Analysis**: Uses Azure Monitor to analyze CPU and memory utilization trends
- **Underutilization Detection**: Identifies App Service Plans with consistently low resource usage
- **Cost Savings Estimates**: Provides monthly and annual savings estimates using Azure App Service pricing
- **Severity-Based Alerts**: 
  - **Severity 4**: <$2,000/month potential savings
  - **Severity 3**: $2,000-$10,000/month potential savings  
  - **Severity 2**: >$10,000/month potential savings
- **Azure App Service Pricing Database**: Comprehensive pricing for Free, Shared, Basic, Standard, Premium, and Isolated tiers
- **Conservative Recommendations**: Accounts for overhead and safety margins in scaling suggestions

## Configuration

The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

### Required Variables
- `AZURE_RESOURCE_GROUP`: The Azure resource group containing App Service Plans
- `AZURE_SUBSCRIPTION_ID`: The Azure subscription ID
- `azure_credentials`: Secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET

### Optional Variables
| Variable | Description | Default |
|----------|-------------|---------|
| `LOOKBACK_WEEKS` | Number of weeks for trend analysis | 4 |
| `CPU_THRESHOLD` | CPU % threshold for high usage alerts | 80 |
| `MEMORY_THRESHOLD` | Memory % threshold for high usage alerts | 80 |
| `SCALE_UP_CPU_THRESHOLD` | CPU % threshold for scale-up recommendations | 70 |
| `SCALE_DOWN_CPU_THRESHOLD` | CPU % threshold for scale-down recommendations | 30 |
| `METRICS_OFFSET` | Time offset for metrics collection (e.g., 24h, 7d) | 24h |
| `TIMEOUT_SECONDS` | Task timeout in seconds | 900 |

## Testing 
See the .test directory for infrastructure test code. 

## Notes

This codebundle assumes the service principal authentication flow.

The cost optimization analysis requires Azure Monitor metrics to be available for the App Service Plans. Ensure that monitoring is enabled for accurate utilization data.