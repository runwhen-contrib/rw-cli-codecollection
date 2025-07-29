# Kubernetes Deployment Healthcheck SLI

This codebundle now includes a lightweight Service Level Indicator (SLI) for monitoring deployment health at high frequency intervals (e.g., every 5 minutes).

## Overview

The SLI provides a fast, efficient way to monitor deployment health by focusing on six critical metrics:

1. **Container Restarts** - Monitors recent container restarts within a configurable time window
2. **Critical Log Errors** - Scans logs for essential error patterns that indicate application failures
3. **Pod Readiness** - Checks if all deployment pods are in a ready state
4. **Deployment Replica Status** - Verifies deployment has expected ready replicas and is available
5. **Recent Warning Events** - Detects recent warning events that may indicate issues
6. **Service Endpoint Health** - Ensures service endpoints are properly configured and healthy

## Files

- `sli.robot` - The main SLI robot file for lightweight monitoring
- `sli_critical_patterns.json` - Configurable error patterns for log analysis
- `.runwhen/templates/k8s-deployment-health-sli.yaml` - Template for SLI runbook generation

## Configuration

### User Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CONTAINER_RESTART_AGE` | `10m` | Time window to search for container restarts |
| `CONTAINER_RESTART_THRESHOLD` | `1` | Maximum restarts allowed before failing |
| `LOG_AGE` | `10m` | Time window to fetch logs for analysis |
| `EVENT_AGE` | `10m` | Time window to check for recent warning events |
| `EVENT_THRESHOLD` | `2` | Maximum critical warning events before scoring reduction |
| `CHECK_SERVICE_ENDPOINTS` | `true` | Whether to check service endpoint health |

### Critical Error Patterns

The SLI uses a focused set of critical error patterns stored in `sli_critical_patterns.json`:

- **GenericError**: Basic error patterns (error, exception, fatal, panic, etc.)
- **AppFailure**: Application-specific failures (service unavailable, connection refused, etc.)
- **StackTrace**: Stack trace patterns indicating crashes

## Health Checks

### 1. Container Restarts
- **What**: Counts recent container restarts within the time window
- **Fast**: Single kubectl command with jq parsing
- **Threshold**: Configurable restart count (default: 1)

### 2. Critical Log Errors
- **What**: Scans recent logs for critical error patterns
- **Fast**: Focused pattern matching only
- **Categories**: GenericError, AppFailure, StackTrace

### 3. Pod Readiness
- **What**: Checks if all deployment pods are ready
- **Fast**: Single kubectl command with jq filtering
- **Score**: 1 if all pods ready, 0 if any unready

### 4. Deployment Replica Status
- **What**: Verifies deployment has ready replicas and is available
- **Fast**: Single kubectl command with jq parsing
- **Score**: 1 if at least 1 ready replica and deployment available

### 5. Recent Warning Events
- **What**: Detects critical warning events in the last time window
- **Fast**: Single kubectl events query with filtering
- **Filtering**: Only Deployment/ReplicaSet events with critical reasons
- **Scoring**: Threshold-based (1 if ≤threshold, 0.5 if ≤threshold*2, 0 if >threshold*2)
- **Noise Reduction**: Filters out minor warnings, focuses on critical failures

### 6. Service Endpoint Health (Optional)
- **What**: Checks if services associated with the deployment have healthy endpoints
- **Fast**: Two kubectl commands - one to get deployment labels, one to check endpoints
- **Smart Detection**: Automatically finds services that match deployment labels
- **Score**: 1 if matching services have healthy endpoints, 1 if no services found (deployment may not need them)
- **Configurable**: Can be disabled with `CHECK_SERVICE_ENDPOINTS=false`
- **Relationship Detection**: Uses deployment labels to find related services, not just all namespace endpoints

## Service Endpoint Detection Logic

The SLI automatically determines if a deployment should have service endpoints using this logic:

### 1. Label Analysis
- Extracts labels from the deployment's pod template (`spec.template.metadata.labels`)
- These labels define which services should target this deployment

### 2. Service Matching
- Finds all services in the namespace with selectors that match the deployment's labels
- Uses Kubernetes label selector logic: all selector key-value pairs must match deployment labels

### 3. Endpoint Health Check
- Only checks endpoints for services that match the deployment
- Verifies endpoints have healthy subsets with addresses

### 4. Scoring Logic
- **Score 1**: Matching services have healthy endpoints
- **Score 1**: No matching services found (deployment may not need services)
- **Score 0**: Matching services exist but have no healthy endpoints

### Examples

**Deployment with Services:**
```yaml
# Deployment labels
app: frontend
tier: web

# Matching service
apiVersion: v1
kind: Service
metadata:
  name: frontend-service
spec:
  selector:
    app: frontend
    tier: web
```
→ SLI checks if `frontend-service` has healthy endpoints

**Deployment without Services:**
```yaml
# Deployment labels  
app: batch-processor
tier: worker

# No services with matching selectors
```
→ SLI scores 1 (deployment doesn't need service endpoints)

**Deployment with Broken Services:**
```yaml
# Deployment labels
app: api
tier: backend

# Service exists but no healthy endpoints
apiVersion: v1
kind: Service
metadata:
  name: api-service
spec:
  selector:
    app: api
```
→ SLI scores 0 (service exists but no healthy endpoints)

## Summary

The improved SLI now provides **accurate, deployment-specific service endpoint health checking** by:

1. **Automatic Relationship Detection**: Uses deployment labels to find related services
2. **Smart Scoring**: Only checks endpoints for services that should target the deployment
3. **Graceful Handling**: Scores appropriately when deployments don't need services
4. **Accurate Results**: No more false positives from unrelated namespace endpoints

### Key Improvements

- **Before**: Checked all endpoints in namespace (11 healthy endpoints = deployment healthy)
- **After**: Checks only endpoints for services that match deployment labels (accurate relationship detection)

### Example Output

```
Deployment runner labels: app=runner,app.kubernetes.io/instance=public-runner,app.kubernetes.io/name=runwhen-local
Found 3 services that match deployment runner labels: ['otel-collector', 'runner-metrics', 'runner-relay']
3 healthy endpoints found for services matching deployment runner
```

This approach ensures the SLI provides meaningful, deployment-specific health metrics rather than namespace-wide assumptions.

## Usage

### For 5-Minute Interval Monitoring

The SLI is optimized for frequent monitoring with these characteristics:

- **Fast Execution**: 6 lightweight checks, typically 15-45 seconds total
- **Focused Analysis**: Only critical patterns and recent issues
- **Short Time Windows**: 10-minute lookback periods for recent issues
- **Binary Scoring**: Returns 0 (unhealthy) or 1 (healthy) for clear SLO/SLI metrics

### Template Usage

Use the SLI template for lightweight monitoring:

```yaml
# Use the SLI template for frequent monitoring
pathToRobot: codebundles/k8s-deployment-healthcheck/sli.robot
```

### Customization

#### Adjusting Time Windows

For different monitoring intervals, adjust the time variables:

```yaml
# For 1-minute intervals
CONTAINER_RESTART_AGE: "5m"
LOG_AGE: "5m"
EVENT_AGE: "5m"

# For 15-minute intervals  
CONTAINER_RESTART_AGE: "15m"
LOG_AGE: "15m"
EVENT_AGE: "15m"
```

#### Modifying Error Patterns

Edit `sli_critical_patterns.json` to add or modify error patterns:

```json
{
  "critical_patterns": {
    "CustomError": {
      "description": "Your custom error patterns",
      "patterns": [
        "your.*error.*pattern",
        "custom.*failure"
      ],
      "severity": 1
    }
  }
}
```

## Performance Characteristics

- **Execution Time**: Typically 15-45 seconds (6 checks)
- **Resource Usage**: Minimal CPU and memory footprint
- **Network**: Light kubectl API calls (6-8 commands)
- **Storage**: Temporary log files cleaned up automatically

## Integration

The SLI integrates with the existing deployment healthcheck codebundle:

- Uses the same authentication and configuration patterns
- Compatible with existing Kubernetes distributions (AKS, EKS, GKE, OpenShift)
- Follows the same variable naming conventions
- Can be used alongside the comprehensive runbook.robot for detailed analysis

## Monitoring Strategy

### Recommended Approach

1. **SLI (5-minute intervals)**: Use for real-time health monitoring and alerting
2. **Full Runbook (hourly/daily)**: Use for comprehensive analysis and detailed troubleshooting

### Alerting Thresholds

- **SLI Score < 0.5**: Immediate attention required
- **SLI Score < 0.8**: Warning - investigate recent changes
- **SLI Score = 1.0**: Healthy deployment

### Score Calculation

The final health score is the average of all active component scores:
```
Health Score = (Container Restarts + Log Errors + Pod Readiness + Replica Status + Events + [Endpoints]) / Active Checks
```

**Note**: The Endpoints check is optional and can be disabled with `CHECK_SERVICE_ENDPOINTS=false`. When disabled, the score is averaged over 5 checks instead of 6.

### Noise Reduction Strategies

To minimize false alerts and reduce noise:

#### 1. Warning Events Configuration
- **Increase EVENT_THRESHOLD**: Set to 3-5 for less sensitive environments
- **Increase EVENT_AGE**: Use 15-30m to avoid transient issues
- **Monitor Event Types**: The SLI filters for critical events only

#### 2. Container Restarts
- **Increase CONTAINER_RESTART_THRESHOLD**: Allow 2-3 restarts before alerting
- **Adjust CONTAINER_RESTART_AGE**: Use 15-30m for more stable environments

#### 3. Log Analysis
- **Review Error Patterns**: Customize `sli_critical_patterns.json` for your application (now properly integrated with RW.K8sLog library)
- **Adjust LOG_AGE**: Balance between recent issues and noise

#### 4. Alert Timing
- **Use Alert For Duration**: Configure alerts to trigger only after sustained issues
- **Example**: Alert only if score < 0.8 for 10+ minutes

#### 5. Environment-Specific Tuning
- **Development**: Higher thresholds, longer time windows
- **Production**: Lower thresholds, shorter time windows
- **Staging**: Medium thresholds for balanced monitoring

## Troubleshooting

### Common Issues

1. **High Execution Time**: Reduce time windows or adjust error patterns
2. **False Positives**: Review and refine error patterns in `sli_critical_patterns.json`
3. **Missing Logs**: Verify log retention policies and access permissions
4. **Service Endpoint Issues**: Check if service selector matches deployment labels

### Debugging

Enable verbose logging by setting the `LOG_LEVEL` environment variable:

```bash
export LOG_LEVEL=DEBUG
```

## Migration from Full Runbook

If migrating from the comprehensive runbook to the SLI:

1. **Start with SLI**: Deploy the SLI for basic monitoring
2. **Compare Results**: Run both in parallel to validate SLI accuracy
3. **Adjust Patterns**: Fine-tune error patterns based on your application
4. **Scale Back**: Reduce full runbook frequency once SLI is validated 