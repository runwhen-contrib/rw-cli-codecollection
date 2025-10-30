# Azure Container Apps Health Monitoring

Comprehensive health monitoring and triage for Azure Container Apps, checking application status, metrics, logs, configuration, and environment health to identify and resolve issues.

## Features

This codebundle provides comprehensive monitoring for Azure Container Apps including:

- **Resource Health**: Azure platform-level health status monitoring
- **Replica Health**: Container replica status and scaling analysis  
- **Performance Metrics**: CPU, memory, request volume, and error rate monitoring
- **Configuration Analysis**: Best practices validation and security assessment
- **Revision Management**: Deployment health and traffic distribution monitoring
- **Environment Health**: Infrastructure and networking status
- **Log Analysis**: Intelligent error detection and pattern analysis

## Configuration

The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

### Required Variables
- `CONTAINER_APP_NAME`: The name of the Azure Container App to monitor
- `AZ_RESOURCE_GROUP`: The resource group containing the Container App
- `azure_credentials`: Secret containing Azure service principal credentials

### Optional Variables
- `CONTAINER_APP_ENV_NAME`: Container Apps Environment name (auto-discovered if not provided)
- `AZURE_RESOURCE_SUBSCRIPTION_ID`: Azure subscription ID (uses current subscription if not provided)
- `TIME_PERIOD_MINUTES`: Time period for metrics and logs (default: 10 minutes)
- `CPU_THRESHOLD`: CPU utilization threshold percentage (default: 80%)
- `MEMORY_THRESHOLD`: Memory utilization threshold percentage (default: 80%)
- `REPLICA_COUNT_MIN`: Minimum expected replica count (default: 1)
- `RESTART_COUNT_THRESHOLD`: Restart count threshold for alerts (default: 5)
- `REQUEST_COUNT_THRESHOLD`: Request count per minute threshold (default: 1000)
- `HTTP_ERROR_RATE_THRESHOLD`: HTTP error rate percentage threshold (default: 5%)

## Prerequisites

- Azure CLI installed and authenticated
- Service principal with appropriate permissions:
  - `Container Apps Reader` role for Container Apps resources
  - `Reader` role for metrics and monitoring
  - `Log Analytics Reader` role for log analysis (if using Log Analytics)

## Usage Examples

### Basic Health Check
```bash
export CONTAINER_APP_NAME="my-app"
export AZ_RESOURCE_GROUP="my-rg"
# Run the health monitoring tasks
```

### Advanced Configuration
```bash
export CONTAINER_APP_NAME="production-app"
export AZ_RESOURCE_GROUP="prod-rg"
export CONTAINER_APP_ENV_NAME="prod-env"
export CPU_THRESHOLD="90"
export MEMORY_THRESHOLD="85"
export TIME_PERIOD_MINUTES="30"
```

## Tasks Included

1. **Resource Health Check**: Validates Azure platform health status
2. **Replica Health Analysis**: Monitors replica count and status
3. **Metrics Collection**: Gathers performance and utilization metrics
4. **Log Retrieval**: Collects recent application logs
5. **Configuration Review**: Analyzes Container App configuration
6. **Revision Health**: Monitors deployment and traffic distribution
7. **Environment Health**: Checks Container Apps Environment status
8. **Log Analysis**: Performs intelligent error pattern detection

## Notes

- This codebundle assumes Azure service principal authentication flow
- Requires Container Apps and related Azure resources to be properly configured
- Log analysis works best when Log Analytics is configured for the Container Apps Environment
- Some metrics may not be available for newly deployed Container Apps
- Environment health checks will auto-discover the environment if not specified

## Troubleshooting

- Ensure Azure CLI is authenticated and has access to the subscription
- Verify service principal has necessary permissions for Container Apps resources
- Check that the Container App and resource group names are correct
- For log analysis issues, verify Log Analytics configuration in the Container Apps Environment 