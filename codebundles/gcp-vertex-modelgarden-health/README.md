# GCP Vertex AI Model Garden Health Monitoring

This codebundle provides comprehensive health monitoring for Google Cloud Platform's Vertex AI Model Garden. It combines Cloud Monitoring metrics analysis with audit log monitoring to provide actionable insights for Model Garden deployments.

## Use Cases

- **Operational Health Monitoring**: Track error rates, response codes, and service availability
- **Performance Analysis**: Monitor latency metrics and identify performance bottlenecks  
- **Audit Log Analysis**: Analyze API call patterns and error trends from audit logs
- **Capacity Planning**: Review token consumption and throughput usage patterns
- **Troubleshooting**: Identify service issues, authentication problems, and quota limits
- **SLI/SLO Monitoring**: Calculate composite health scores for service reliability

## Architecture

This codebundle uses a streamlined architecture with direct Google Cloud API integration:

### Core Components

- **`vertex_ai_monitoring.py`**: Python module for Cloud Monitoring metrics analysis
- **`runbook.robot`**: Comprehensive troubleshooting tasks using direct `gcloud` and Python calls
- **`sli.robot`**: Service Level Indicator calculation with quick log health checks
- **`meta.yaml`**: Configuration and task definitions

### Key Features

- **Direct API Integration**: Uses `gcloud` CLI and Python SDK directly (no intermediate keyword files)
- **Audit Log Analysis**: Comprehensive analysis of Vertex AI audit logs with error categorization
- **Endpoint-Specific Monitoring**: Extracts specific endpoint and model details from logs
- **Automatic Permission Validation**: Built-in checks for required IAM permissions
- **Configurable Time Windows**: Flexible lookback periods for different analysis needs

## Monitoring Capabilities

### 1. Cloud Monitoring Metrics Analysis
- **Error Rate Analysis**: HTTP response code patterns and error percentages
- **Latency Performance**: Invocation and first-token latency tracking
- **Throughput Monitoring**: Token consumption and capacity utilization
- **Service Health**: API availability and configuration validation

### 2. Audit Log Analysis
- **Real-time Error Detection**: Recent API call failures and patterns
- **Error Categorization**: Authentication, quota, and service availability issues
- **Endpoint Tracking**: Specific model/endpoint performance analysis
- **Caller Identification**: Service account usage patterns and authentication issues

### 3. Health Scoring Algorithm

The SLI calculates composite health scores using multiple data sources:

**Log Health Score (Quick Check):**
- 1.0 (100%) = No recent errors
- 0.8 (80%) = 1-2 recent errors  
- 0.6 (60%) = 3-5 recent errors
- 0.4 (40%) = 6-10 recent errors
- 0.2 (20%) = 10+ recent errors

**Comprehensive Health Score:**
- **Error Rate Score (50% weight)**: Based on monitoring metrics
- **Latency Performance Score (30% weight)**: Model response time analysis
- **Throughput Usage Score (20% weight)**: Active usage indicator

## Requirements

### GCP Permissions

This codebundle requires specific IAM roles and permissions to access Google Cloud resources. The service account used must have the following permissions:

#### Required IAM Roles

**Core Monitoring Access:**
- **`roles/monitoring.viewer`** - Required for accessing Cloud Monitoring metrics and time series data
- **`roles/logging.privateLogViewer`** - Required for accessing audit logs (data_access logs)

**Service Management:**
- **`roles/serviceusage.serviceUsageConsumer`** - Required for checking API enablement status

#### Optional IAM Roles

**Enhanced Vertex AI Access:**
- **`roles/aiplatform.user`** - Optional, for additional Vertex AI operations and enhanced monitoring

#### Detailed Permission Requirements

**For Metrics Analysis (runbook tasks 1-3, SLI):**
```
monitoring.timeSeries.list
monitoring.metricDescriptors.list
monitoring.monitoredResourceDescriptors.list
```

**For Audit Log Analysis (runbook task 4):**
```
logging.logs.list
logging.logEntries.list
logging.privateLogEntries.list
```

**For Service Health Checks (runbook task 5):**
```
serviceusage.services.list
serviceusage.services.get
```

#### Permission Validation

The codebundle includes automatic permission validation:

1. **Empty Log Results**: If audit log queries return `[]`, the codebundle will create an issue indicating missing `roles/logging.privateLogViewer`
2. **Metrics Access**: If monitoring metrics are inaccessible, error messages will indicate the missing `roles/monitoring.viewer`
3. **Service Check Failures**: Service availability checks will fail gracefully if `roles/serviceusage.serviceUsageConsumer` is missing

#### Granting Permissions

**Via gcloud CLI:**
```bash
# Grant required roles to service account
export PROJECT_ID="your-project-id"
export SERVICE_ACCOUNT="your-service-account@project.iam.gserviceaccount.com"

gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:$SERVICE_ACCOUNT" \
    --role="roles/monitoring.viewer"

gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:$SERVICE_ACCOUNT" \
    --role="roles/logging.privateLogViewer"

gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:$SERVICE_ACCOUNT" \
    --role="roles/serviceusage.serviceUsageConsumer"
```

**Via Google Cloud Console:**
1. Navigate to **IAM & Admin > IAM**
2. Find your service account
3. Click **Edit Principal**
4. Add the required roles listed above

#### Cross-Project Considerations

If monitoring Vertex AI resources across multiple projects:
- Grant permissions in **each target project**
- Ensure the service account has access to audit logs in all monitored projects
- Consider using **organization-level roles** for multi-project monitoring

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
- `LOG_FRESHNESS`: Time window for runbook log analysis (default: 2h)
- `SLI_LOG_LOOKBACK`: Time window for SLI quick health check (default: 15m)

## Tasks Overview

### Runbook Tasks

1. **Analyze Vertex AI Model Garden Error Patterns and Response Codes in `{project}`**
   - Analyzes error patterns using Cloud Monitoring metrics
   - Creates issues for high error rates and specific error counts

2. **Investigate Vertex AI Model Latency Performance Issues in `{project}`**
   - Examines latency metrics and performance bottlenecks
   - Identifies high-latency and elevated-latency models

3. **Monitor Vertex AI Throughput and Token Consumption Patterns in `{project}`**
   - Reviews token usage and throughput patterns for capacity planning

4. **Check Vertex AI Model Garden API Logs for Issues in `{project}`**
   - Comprehensive audit log analysis with error categorization
   - Extracts endpoint-specific details and service account usage
   - Creates targeted issues for different error types

5. **Check Vertex AI Model Garden Service Health and Quotas in `{project}`**
   - Verifies API enablement and service availability
   - Validates monitoring access and configuration

6. **Generate Vertex AI Model Garden Health Summary and Next Steps for `{project}`**
   - Comprehensive health summary with actionable recommendations

### SLI Tasks

1. **Quick Vertex AI Log Health Check for `{project}`**
   - Fast 15-minute audit log check for immediate health assessment
   - Provides quick health score based on recent error patterns

2. **Calculate Vertex AI Model Garden Health Score for `{project}`**
   - Comprehensive health scoring using metrics and usage data
   - Weighted composite score for overall service health

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

### Manual Log Analysis
```bash
# Check recent Vertex AI errors
gcloud logging read 'resource.type="audited_resource" AND resource.labels.service="aiplatform.googleapis.com" AND severity="ERROR"' \
  --format="json" --freshness="1h" --project=your-project-id

# Check specific endpoint errors
gcloud logging read 'resource.type="audited_resource" AND resource.labels.service="aiplatform.googleapis.com" AND protoPayload.resourceName:"endpoints/your-endpoint"' \
  --format="json" --freshness="2h" --project=your-project-id
```

## Troubleshooting

### Common Permission Issues

**Monitoring Metrics Access Denied (403)**
```
❌ Permission denied accessing monitoring metrics
   Required permission: monitoring.timeSeries.list
   Service account needs: Monitoring Viewer role
```
**Solution**: Grant `roles/monitoring.viewer` to the service account:
```bash
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:$SERVICE_ACCOUNT" \
    --role="roles/monitoring.viewer"
```

**Audit Logs Empty Results**
```
⚠️ Empty audit log results - service account may need roles/logging.privateLogViewer permission
```
**Solution**: Grant `roles/logging.privateLogViewer` to access audit logs:
```bash
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:$SERVICE_ACCOUNT" \
    --role="roles/logging.privateLogViewer"
```

**Service API Check Failures**
```
❌ Unable to check API enablement status
   Required permission: serviceusage.services.list
```
**Solution**: Grant `roles/serviceusage.serviceUsageConsumer`:
```bash
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:$SERVICE_ACCOUNT" \
    --role="roles/serviceusage.serviceUsageConsumer"
```

**Cross-Project Permission Issues**
```
❌ Permission denied in project X while monitoring from project Y
```
**Solution**: Grant permissions in the target project being monitored, not just the project running the codebundle.

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

### Issue Types Generated

**Error Rate Issues:**
- High error rates (>5% or >10 errors)
- Service unavailable errors (HTTP 503, code 14)
- Authentication errors (HTTP 401/403, codes 7/16)
- Quota exceeded errors (HTTP 429, code 8)

**Performance Issues:**
- High latency models (>30s average response time)
- Elevated latency models (10-30s average response time)

**Configuration Issues:**
- Vertex AI API not enabled
- Missing permissions for audit log access

### SLI Metrics

**Quick Log Health Check:**
- **Metric Name**: `vertex_ai_log_health_score`
- **Value Range**: 0.0 to 1.0 (higher is better)
- **Lookback**: Configurable (default: 15 minutes)

**Comprehensive Health Score:**
- **Metric Name**: `vertex_ai_modelgarden_health_score`
- **Value Range**: 0.0 to 1.0 (higher is better)
- **Interpretation**:
  - 0.9-1.0: Excellent health
  - 0.7-0.9: Good health
  - 0.5-0.7: Fair health (monitoring recommended)
  - 0.3-0.5: Poor health (action required)  
  - 0.0-0.3: Critical health (immediate attention needed)

### Detailed Log Information

All issues include specific log snippets with:
- **Timestamps**: Exact time of errors
- **Endpoints**: Specific model/endpoint paths
- **Error Codes**: HTTP status and gRPC codes
- **Service Accounts**: Caller identification
- **Error Messages**: Detailed failure reasons

Example issue detail:
```
Service unavailable error details:
- 2025-06-26T02:01:24.504132280Z | google.cloud.aiplatform.v1.PredictionService.ChatCompletions | projects/runwhen-nonprod-shared/locations/us-east5/endpoints/openapi | papi-sa@runwhen-nonprod-watcher.iam.gserviceaccount.com | The service is currently unavailable.
```

## Related Documentation

- [Vertex AI Model Garden Monitoring](https://cloud.google.com/vertex-ai/docs/model-garden/monitor-models)
- [Provisioned Throughput](https://cloud.google.com/vertex-ai/generative-ai/docs/provisioned-throughput)
- [Vertex AI Troubleshooting](https://cloud.google.com/vertex-ai/docs/general/troubleshooting)
- [GCP Quota Management](https://cloud.google.com/vertex-ai/quotas)
- [Cloud Monitoring Python SDK](https://cloud.google.com/monitoring/api/client-libraries)
- [Cloud Logging Query Language](https://cloud.google.com/logging/docs/view/logging-query-language)
- [Audit Logs Overview](https://cloud.google.com/logging/docs/audit/understanding-audit-logs) 