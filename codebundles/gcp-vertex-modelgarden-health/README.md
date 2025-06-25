# GCP Vertex AI Model Garden Health Monitoring

This codebundle provides comprehensive health monitoring for Google Cloud Platform's Vertex AI Model Garden using the Google Cloud Monitoring Python SDK. It focuses on operational metrics like error rates, latency performance, and throughput consumption to provide actionable insights for Model Garden deployments.

## Use Cases

- **Operational Health Monitoring**: Track error rates, response codes, and service availability
- **Performance Analysis**: Monitor latency metrics including invocation and first-token latencies  
- **Capacity Planning**: Analyze token consumption and throughput usage patterns
- **Troubleshooting**: Identify performance bottlenecks and error patterns
- **SLI/SLO Monitoring**: Calculate composite health scores for service reliability

## Architecture

This codebundle uses a clean, modular architecture:

### Core Components

- **`vertex_ai_monitoring.py`**: Python module containing all monitoring functions using Google Cloud Monitoring SDK
- **`VertexAIKeywords.robot`**: Robot Framework resource file with custom keywords that call the Python functions
- **`sli.robot`**: Service Level Indicator calculation using composite health scoring
- **`runbook.robot`**: Troubleshooting and remediation tasks
- **`meta.yaml`**: Configuration with monitoring commands

### Python Module Functions

- `analyze_error_patterns()`: Analyzes Model Garden error patterns and response codes
- `analyze_latency_performance()`: Examines latency metrics and performance bottlenecks  
- `analyze_throughput_consumption()`: Reviews token usage and throughput patterns
- `check_service_health()`: Verifies service availability and metric accessibility

## Monitoring Metrics

This codebundle focuses on the following Vertex AI Model Garden metrics:

### Error Rate Analysis
- **Metric**: `aiplatform.googleapis.com/publisher/online_serving/model_invocation_count`
- **Labels**: `response_code`, `model_user_id`
- **Purpose**: Calculate error rates from HTTP response codes (non-2xx vs total)

### Latency Performance  
- **Metric**: `aiplatform.googleapis.com/publisher/online_serving/model_invocation_latencies`
- **Metric**: `aiplatform.googleapis.com/publisher/online_serving/first_token_latencies`
- **Labels**: `model_user_id`
- **Purpose**: Track response times and identify performance issues

### Throughput & Token Consumption
- **Metric**: `aiplatform.googleapis.com/publisher/online_serving/token_count`
- **Metric**: `aiplatform.googleapis.com/publisher/online_serving/consumed_throughput`
- **Labels**: `model_user_id`, `type`, `request_type`
- **Purpose**: Monitor usage patterns and capacity planning

## Health Scoring Algorithm

The SLI calculates a composite health score using weighted components:

- **Error Rate Score (50% weight)**: 
  - 1.0 for 0% errors
  - 0.8 for 1-5% errors  
  - 0.5 for 5-10% errors
  - 0.2 for 10-20% errors
  - 0.0 for >20% errors

- **Latency Performance Score (30% weight)**:
  - Based on percentage of models with acceptable performance
  - Models with >30s average latency are considered "Poor"
  - Models with 10-30s average latency are "Fair-Poor"

- **Throughput Usage Score (20% weight)**:
  - 1.0 if active usage data is present
  - 0.5 if no usage data (indicates potential issues or no traffic)

**Final Score**: `(Error Score × 0.5) + (Latency Score × 0.3) + (Throughput Score × 0.2)`

## Requirements

### GCP Permissions
The service account requires these IAM roles:
- **Monitoring Viewer** (`roles/monitoring.viewer`) - Required for accessing Cloud Monitoring metrics
- **Vertex AI User** (`roles/aiplatform.user`) - Optional, for additional Vertex AI operations
- **Service Usage Consumer** (`roles/serviceusage.serviceUsageConsumer`) - For API availability checks

### Python Dependencies
```
google-cloud-monitoring>=2.0.0
google-auth>=2.0.0
```

## Configuration

### Required Secrets
- `gcp_credentials_json`: GCP service account JSON key with appropriate permissions

### Required Variables  
- `GCP_PROJECT_ID`: The GCP project ID containing the Vertex AI Model Garden resources

### Optional Configuration
- Analysis time window can be adjusted in the Python functions (default: 2 hours)
- Health score thresholds can be modified in the scoring algorithm
- Metric filters can be customized for specific models or regions

## Usage Examples

### Command Line Testing
```bash
# Test error analysis
python3 vertex_ai_monitoring.py errors --hours 4

# Test latency analysis  
python3 vertex_ai_monitoring.py latency --hours 1

# Test throughput analysis
python3 vertex_ai_monitoring.py throughput --hours 6

# Test service health
python3 vertex_ai_monitoring.py health
```

### Robot Framework Integration
The custom keywords can be used in other Robot Framework files:
```robot
*** Settings ***
Resource    VertexAIKeywords.robot

*** Test Cases ***
Check Model Garden Health
    ${analysis}=    Analyze Model Garden Error Patterns    hours=1
    ${results}=     Parse Error Analysis Results    ${analysis.stdout}
    Should Be True  ${results['error_count']} < 10
```

## Troubleshooting

### Common Issues

**Permission Denied (403)**
```
❌ Permission denied accessing monitoring metrics
   Required permission: monitoring.timeSeries.list
   Service account needs: Monitoring Viewer role
```
**Solution**: Ensure the service account has the `roles/monitoring.viewer` role.

**No Metrics Available**
```
⚠️  No Model Garden metrics found - this could indicate:
   • No Model Garden usage in this project
   • Model Garden not available in this region  
   • Monitoring not properly configured
```
**Solution**: Verify Model Garden is deployed and being used in the specified project and region.

**Authentication Errors**
```
❌ Authentication error: Could not automatically determine credentials
```
**Solution**: Verify the `gcp_credentials_json` secret is properly configured with a valid service account key.

## Outputs

### SLI Output
- **Metric Name**: `vertex_ai_modelgarden_health_score`
- **Value Range**: 0.0 to 1.0 (higher is better)
- **Interpretation**:
  - 0.9-1.0: Excellent health
  - 0.7-0.9: Good health
  - 0.5-0.7: Fair health (monitoring recommended)
  - 0.3-0.5: Poor health (action required)  
  - 0.0-0.3: Critical health (immediate attention needed)

### Runbook Issues
The runbook automatically creates issues for:
- High error rates (>5%)
- High latency models (>30s average)
- Elevated latency models (10-30s average)
- Service configuration problems

## Related Documentation

- [Vertex AI Model Garden Monitoring](https://cloud.google.com/vertex-ai/docs/model-garden/monitor-models)
- [Provisioned Throughput](https://cloud.google.com/vertex-ai/generative-ai/docs/provisioned-throughput)
- [Vertex AI Troubleshooting](https://cloud.google.com/vertex-ai/docs/general/troubleshooting)
- [GCP Quota Management](https://cloud.google.com/vertex-ai/quotas)
- [Cloud Monitoring Python SDK](https://cloud.google.com/monitoring/api/client-libraries) 