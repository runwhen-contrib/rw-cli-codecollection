# Azure Function App Health Triage
Checks key Function App metrics, individual function invocations, service plan utilization, fetches logs, config and activities for the service and generates a report of present issues for any found.

## Enhanced Features

This codebundle now includes advanced monitoring and analysis capabilities:

### 🔍 Enhanced Invocation Logging
- **Comprehensive tracking**: Logs every function invocation with detailed success/failure analysis
- **Performance metrics**: Captures duration patterns, memory usage, and execution trends
- **Health scoring**: Automatically categorizes function health status (Healthy/Warning/Unhealthy/Idle)
- **Time-series analysis**: Provides detailed breakdowns of function performance over time

### 🚨 Advanced Failure Analysis
- **Error categorization**: Classifies errors into types (Timeout, Memory, Throttling, Dependency, etc.)
- **Temporal pattern detection**: Identifies patterns like Sporadic, Single_Incident, Spike, Recurring
- **Health scoring**: Calculates comprehensive health scores (0-100) based on error rates, duration, and memory usage
- **Structured reporting**: Generates detailed issue reports with actionable next steps

## Configuration

The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

export FUNCTION_APP_NAME
export AZ_RESOURCE_GROUP
export AZURE_RESOURCE_SUBSCRIPTION_ID

## Optional Configuration Variables

The following variables can be customized to adjust thresholds for issue detection:

- `RW_LOOKBACK_WINDOW`: Time period to look back for activities/events (default: 10)
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
- **Enhanced Invocation Logging**: 🆕 Comprehensive logging of every function invocation with success/failure tracking
- **Advanced Failure Analysis**: 🆕 Pattern detection and error categorization with structured data output
- **Log Analysis**: 🆕 Consolidated log retrieval and error analysis in a single task
- **Configuration Health**: Checks Function App configuration
- **Deployment Health**: Monitors deployment status
- **Activity Monitoring**: Tracks recent activities and events with focus on start/stop operations
- **Start/Stop Operations**: Creates severity 4 issues for function app start/stop/restart operations with user details
- **Recommendations**: Fetches Azure Advisor recommendations

## Enhanced Scripts

### `function_invocation_logger.sh`
Provides detailed logging of every function invocation:
- Tracks success/failure counts and rates
- Analyzes duration patterns (avg/max/min)
- Categorizes function health status
- Generates comprehensive JSON output with per-function metrics
- Creates Robot Framework issues for invocation problems

### `function_failure_analysis.sh`  
Advanced failure pattern analysis:
- Detects temporal failure patterns
- Categorizes error types automatically
- Calculates health scores for each function
- Generates LLM-ready structured data for further analysis

## Testing

### Integration Tests
The codebundle includes comprehensive integration tests that work with real Azure Function Apps:

```bash
# Navigate to test directory
cd .test

# Build test infrastructure (creates real Azure Function Apps)
task build-terraform-infra

# Run enhanced features integration tests
task test-enhanced-features

# Clean up infrastructure when done
task cleanup-terraform-infra
```

### Test Infrastructure
- **Real Azure Function Apps**: Tests run against actual consumption and premium Function Apps
- **Application Insights**: Configured for comprehensive monitoring and logging
- **Terraform-managed**: Infrastructure is version-controlled and reproducible
- **Performance validation**: Ensures scripts complete within time constraints
- **JSON validation**: Verifies output structure and data quality

## Notes

This codebundle assumes the service principal authentication flow.

## TODO

- [x] Enhanced invocation logging with detailed success/failure tracking
- [x] Advanced failure pattern analysis with temporal correlation
- [x] Health scoring and categorization
- [x] Integration with existing issue_details format
- [x] Comprehensive test infrastructure with real Azure resources
- [x] Performance validation and JSON structure verification
- [x] Consolidated redundant log tasks into single enhanced task
- [x] Full integration of invocation logging with Robot Framework issues