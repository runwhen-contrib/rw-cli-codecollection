# Azure App Service Triage

Checks key App Service metrics and the service plan, fetches logs, config and activities for the service and generates a report of present issues for any found.

## Configuration

The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

export APP_SERVICE_NAME
export AZ_RESOURCE_GROUP

## Log Collection Configuration (Optimized for Size)

The log collection has been optimized to prevent large report files while maintaining diagnostic value. You can control the verbosity:

### Log Levels

- `ERROR`: Only errors and critical issues (minimal output)
- `WARN`: Warnings and errors  
- `INFO`: Informational messages (default, filters for errors/warnings)
- `DEBUG`: Detailed debugging information
- `VERBOSE`: All logs including system events (use with caution)

### Configuration Variables

- `LOG_LEVEL`: Set log verbosity (default: INFO)
- `MAX_LOG_LINES`: Maximum lines per log file (default: 100)
- `MAX_TOTAL_SIZE`: Maximum total output size in bytes (default: 500000)

### Examples

```bash
# For production troubleshooting (minimal output)
export LOG_LEVEL=ERROR
export MAX_LOG_LINES=50

# For development debugging (more detailed)
export LOG_LEVEL=DEBUG
export MAX_LOG_LINES=200
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
