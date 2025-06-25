# Azure App Service Triage

Checks key App Service metrics and the service plan, fetches logs, config and activities for the service and generates a report of present issues for any found.

## Configuration

The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

export APP_SERVICE_NAME
export AZ_RESOURCE_GROUP

## Log Collection Configuration (Enhanced & Optimized)

The log collection has been enhanced with multiple log sources while maintaining size optimization. You can control both verbosity and which log sources to include:

### Log Levels

- `ERROR`: Only errors and critical issues (minimal output)
- `WARN`: Warnings and errors  
- `INFO`: Informational messages (default, filters for errors/warnings)
- `DEBUG`: Detailed debugging information
- `VERBOSE`: All logs including system events (use with caution)

### Enhanced Features

- **Docker Container Logs**: Container startup, runtime, and error diagnostics
- **Deployment History**: Recent deployment success/failure status and build logs
- **Performance Traces**: Slow requests and failed API calls (DEBUG+ only)

### Configuration Variables

#### Core Settings

- `LOG_LEVEL`: Set log verbosity (default: INFO)
- `MAX_LOG_LINES`: Maximum lines per log file (default: 100)
- `MAX_TOTAL_SIZE`: Maximum total output size in bytes (default: 500000)

#### Enhanced Features (New)

- `INCLUDE_DOCKER_LOGS`: Include Docker container logs (default: true)
- `INCLUDE_DEPLOYMENT_LOGS`: Include deployment history (default: true)
- `INCLUDE_PERFORMANCE_TRACES`: Include performance traces (default: false)

### Configuration Examples

```bash
# Production troubleshooting (minimal output)
export LOG_LEVEL=ERROR
export INCLUDE_DOCKER_LOGS=false
export INCLUDE_DEPLOYMENT_LOGS=false

# Standard configuration (recommended default)
export LOG_LEVEL=INFO
export INCLUDE_DOCKER_LOGS=true
export INCLUDE_DEPLOYMENT_LOGS=true

# Docker container troubleshooting
export LOG_LEVEL=INFO
export INCLUDE_DOCKER_LOGS=true
export INCLUDE_DEPLOYMENT_LOGS=false

# Deployment troubleshooting
export LOG_LEVEL=INFO
export INCLUDE_DOCKER_LOGS=false
export INCLUDE_DEPLOYMENT_LOGS=true

# Full diagnostic mode (advanced)
export LOG_LEVEL=DEBUG
export INCLUDE_DOCKER_LOGS=true
export INCLUDE_DEPLOYMENT_LOGS=true
export INCLUDE_PERFORMANCE_TRACES=true
```

## Size Optimization

The logs task now automatically:

- Filters out verbose HTTP access logs
- Focuses on application-level logs and errors
- Limits output to 500KB by default
- Provides truncation warnings when limits are reached
- Directs users to Azure Portal for complete logs when needed

This prevents report.jsonl files from exceeding UI rendering limits while maintaining diagnostic capability.

## Notes

This codebundle assumes the service principal authentication flow.

## TODO

- [ ] look for notable activities in list
- [ ] config best practices check
