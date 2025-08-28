# Kubernetes Workload Stacktrace Health

This codebundle provides comprehensive stacktrace/traceback detection and analysis for Kubernetes workloads (deployments, statefulsets, and daemonsets). It monitors application logs to identify Python, Java, and other language stacktraces that indicate runtime errors or exceptions.

## Use Cases

### Troubleshooting Tasks
- **Stacktrace Detection**: Automatically identifies and extracts stacktraces from workload logs across all pods and containers
- **Multi-Language Support**: Detects Python tracebacks, Java stack traces, and other common error patterns
- **Container Filtering**: Configurable filtering to ignore sidecar containers (linkerd, istio, etc.) that aren't relevant for application analysis
- **Comprehensive Coverage**: Analyzes logs from all pods and containers in a workload for complete visibility
- **Multi-Workload Support**: Works with deployments, statefulsets, and daemonsets

### SLI Monitoring
- **Health Score**: Provides a binary health score (0 = stacktraces detected, 1 = no stacktraces found)
- **Fast Detection**: Optimized for frequent monitoring with configurable log limits and time windows
- **Early Warning**: Detects application errors through stacktrace analysis before they impact users
- **Scaled Workload Handling**: Properly handles workloads scaled to 0 replicas

## Configuration

### Required Configuration
- `KUBERNETES_DISTRIBUTION_BINARY`: kubectl or oc
- `CONTEXT`: Kubernetes context to use
- `NAMESPACE`: Target namespace
- `WORKLOAD_NAME`: Name of the workload to monitor
- `WORKLOAD_TYPE`: Type of workload (deployment, statefulset, or daemonset)

### Optional Configuration
- `LOG_LINES`: Number of log lines to fetch (default: 100)
- `LOG_AGE`: Time window for log analysis (default: 3h for runbook, 10m for SLI)
- `LOG_SIZE`: Maximum log size in bytes (default: 2MB for runbook, 256KB for SLI)
- `IGNORE_CONTAINERS_MATCHING`: Comma-separated list of container name patterns to ignore (default: "linkerd")
- `MAX_LOG_LINES`: Maximum log lines for SLI checks (default: 100)
- `MAX_LOG_BYTES`: Maximum log bytes for SLI checks (default: 256000)

## Tasks

### Analyze Workload Stacktraces
**Type**: Troubleshooting Task  
**Objective**: Comprehensive stacktrace detection and analysis across all workload pods

This task:
- Fetches logs from all pods and containers in the workload
- Extracts Python tracebacks, Java stack traces, and other error patterns
- Filters out irrelevant containers based on name patterns
- Creates detailed issues for any stacktraces found
- Provides actionable next steps for troubleshooting
- Supports deployments, statefulsets, and daemonsets

### Get Stacktrace Health Score
**Type**: SLI Task  
**Objective**: Fast stacktrace detection for monitoring and alerting

This task:
- Performs rapid stacktrace detection optimized for frequent monitoring
- Returns a binary health score (0 or 1)
- Uses optimized log limits to prevent API overload
- Supports 5-minute interval monitoring
- Handles scaled-down workloads appropriately

## Supported Languages

### Python
- Detects standard Python tracebacks with `Traceback (most recent call last):`
- Handles JSON-formatted logs with embedded stacktraces
- Extracts timestamped traceback information
- Supports various Python logging formats

### Java
- Detects Java stack traces with `at package.Class.method()` patterns
- Handles exception messages and stack trace lines
- Supports various Java logging frameworks
- Extracts complete stack trace information

### Extensible Architecture
The stacktrace detection library is designed to be easily extended for additional languages and error patterns.

## Performance Considerations

### Runbook Tasks
- Designed for comprehensive analysis during troubleshooting
- Configurable limits to balance thoroughness with performance
- Handles large workloads with multiple pods and containers
- Supports all Kubernetes workload types

### SLI Tasks
- Optimized for frequent monitoring (5-minute intervals)
- Lower resource usage with configurable limits
- Fast exit on first stacktrace detection
- Prevents API overload with byte and line limits

## Best Practices

1. **Container Filtering**: Configure `IGNORE_CONTAINERS_MATCHING` to exclude sidecar containers
2. **Log Limits**: Adjust `LOG_LINES` and `LOG_SIZE` based on your application's logging patterns
3. **Time Windows**: Use shorter time windows for SLI monitoring, longer for troubleshooting
4. **Resource Management**: Monitor API usage and adjust limits if needed
5. **Alert Tuning**: Use SLI scores for alerting on application errors
6. **Workload Types**: Ensure proper `WORKLOAD_TYPE` configuration for your specific workload

## Troubleshooting

### Common Issues
- **No stacktraces detected**: Check log patterns and time windows
- **API timeouts**: Reduce log limits or time windows
- **Missing containers**: Verify workload labels and container filtering
- **Performance issues**: Optimize log limits for your environment

### Debug Steps
1. Verify workload exists and has running pods
2. Check container names and filtering patterns
3. Validate log output manually with kubectl logs
4. Review time windows and log limits
5. Check RBAC permissions for log access
6. Confirm workload type is correctly specified

## Example Usage

### For a Deployment
```yaml
WORKLOAD_NAME: "web-app"
WORKLOAD_TYPE: "deployment"
NAMESPACE: "production"
LOG_LINES: "200"
LOG_AGE: "1h"
```

### For a StatefulSet
```yaml
WORKLOAD_NAME: "database"
WORKLOAD_TYPE: "statefulset"
NAMESPACE: "data"
LOG_LINES: "500"
LOG_AGE: "6h"
```

### For a DaemonSet
```yaml
WORKLOAD_NAME: "log-collector"
WORKLOAD_TYPE: "daemonset"
NAMESPACE: "kube-system"
IGNORE_CONTAINERS_MATCHING: "linkerd,istio-proxy"
```