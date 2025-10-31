# Azure AKS Cluster Triage
This CodeBundle checks for AKS Cluster Health based on how Azure is reporting resource health, network configuration recommendations, activities that have occured, and provisioning status of resources. It also includes **cost optimization analysis** that identifies underutilized node pools with potential savings opportunities using 30-day Azure Monitor utilization trends. 

## Configuration

The SLI & TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:
- `AZ_RESOURCE_GROUP`: The Azure resource group that these resources reside in
- `AKS_CLUSTER`: The name of the AKS Cluster in the resource group to target with checks
- `RW_LOOKBACK_WINDOW`: The time window, in minutes, to look back for activities and events which may indicate issues. 

## Features

### Health Monitoring
- **Resource Health**: Checks Azure-reported health status of AKS cluster resources
- **Configuration Analysis**: Validates cluster configuration and identifies potential issues
- **Network Configuration**: Reviews network settings and provides recommendations
- **Activity Monitoring**: Analyzes recent activities for errors and warnings

### Cost Optimization
- **30-Day Utilization Analysis**: Uses Azure Monitor to analyze CPU and memory utilization trends
- **Underutilization Detection**: Identifies node pools with consistently low resource usage
- **Cost Savings Estimates**: Provides monthly and annual savings estimates using Azure VM pricing
- **Severity-Based Alerts**: 
  - **Severity 4**: <$2,000/month potential savings
  - **Severity 3**: $2,000-$10,000/month potential savings  
  - **Severity 2**: >$10,000/month potential savings
- **Azure VM Pricing Database**: Comprehensive pricing for D-series, E-series, F-series, and B-series VMs
- **Conservative Recommendations**: Accounts for overhead and safety margins in scaling suggestions

## Notes

This codebundle assumes the service principal authentication flow which is handled from the import secret Keyword.

The cost optimization analysis requires Azure Monitor metrics to be available for the AKS cluster's Virtual Machine Scale Sets (VMSS). Ensure that monitoring is enabled for accurate utilization data.

## TODO
- [ ] Add documentation
- [x] Implement cost optimization analysis with Azure Monitor integration
- [x] Add Azure VM pricing database for cost calculations
- [x] Implement severity-based cost savings alerts