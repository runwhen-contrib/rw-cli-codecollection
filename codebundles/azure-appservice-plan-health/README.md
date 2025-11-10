# Azure App Service Plan Health
This codebundle runs a suite of metrics checks for App Service Plan health in Azure. It identifies:
- Check App Service Plan capacity Utilization
- Check App Service Plan activity logs
- Check App Service Plan recommendations
- **Cost optimization analysis** that identifies underutilized App Service Plans with potential savings opportunities using 30-day Azure Monitor utilization trends

## Features

### Health Monitoring
- **Resource Health**: Checks Azure-reported health status of App Service Plan resources
- **Capacity Analysis**: Validates App Service Plan capacity utilization and identifies high usage issues
- **Configuration Recommendations**: Provides scaling recommendations based on current usage patterns
- **Activity Monitoring**: Analyzes recent activities for errors and warnings

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

- `AZ_USERNAME`: Service principal's client ID
- `AZ_SECRET_VALUE`: The credential secret value from the app registration
- `AZ_TENANT`: The Azure tenancy ID
- `AZ_SUBSCRIPTION`: The Azure subscription ID

## Testing 
See the .test directory for infrastructure test code. 

## Notes

This codebundle assumes the service principal authentication flow.

The cost optimization analysis requires Azure Monitor metrics to be available for the App Service Plans. Ensure that monitoring is enabled for accurate utilization data.