# Azure Function App Health Triage
Checks key Function App metrics, individual function invocations, service plan utilization, fetches logs, config and activities for the service and generates a report of present issues for any found.

## Configuration

The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

export FUNCTION_APP_NAME
export AZ_RESOURCE_GROUP
export AZURE_RESOURCE_SUBSCRIPTION_ID

## Optional Configuration Variables

The following variables can be customized to adjust thresholds for issue detection:

- `TIME_PERIOD_MINUTES`: Time period to look back for activities/events (default: 10)
- `TIME_PERIOD_DAYS`: Time period to look back for recommendations (default: 7)
- `CPU_THRESHOLD`: CPU % threshold for issues (default: 80)
- `REQUESTS_THRESHOLD`: Requests/s threshold for issues (default: 1000)
- `HTTP5XX_THRESHOLD`: HTTP 5XX errors/s threshold (default: 5)
- `HTTP4XX_THRESHOLD`: HTTP 4XX errors/s threshold (default: 200)
- `DISK_USAGE_THRESHOLD`: Disk usage % threshold (default: 90)
- `AVG_RSP_TIME`: Average response time threshold in ms (default: 300)
- `FUNCTION_ERROR_RATE_THRESHOLD`: Function error rate % threshold (default: 10)
- `FUNCTION_MEMORY_THRESHOLD`: Function memory usage threshold in MB (default: 512)
- `FUNCTION_DURATION_THRESHOLD`: Function execution duration threshold in ms (default: 5000)

## Features

- **Resource Health Check**: Monitors Azure resource health status
- **Function App Health**: Checks overall Function App health metrics
- **Plan Utilization**: Analyzes App Service Plan utilization metrics
- **Individual Function Invocations**: Detailed analysis of each function's performance, errors, and throttles
- **Log Analysis**: Reviews logs for errors and issues
- **Configuration Health**: Checks Function App configuration
- **Deployment Health**: Monitors deployment status
- **Activity Monitoring**: Tracks recent activities and events with focus on start/stop operations
- **Start/Stop Operations**: Creates severity 4 issues for function app start/stop/restart operations with user details
- **Recommendations**: Fetches Azure Advisor recommendations

## Notes

This codebundle assumes the service principal authentication flow.

## TODO
- [x] look for notable activities in list (start/stop operations)
- [ ] config best practices check
- [ ] Add documentation