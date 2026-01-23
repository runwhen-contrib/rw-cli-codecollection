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
- `gcp_credentials`: GCP service account JSON key with appropriate permissions

### Required Variables  
- `GCP_PROJECT_ID`: The GCP project ID containing the Vertex AI Model Garden resources

### Optional Configuration
- `LOG_FRESHNESS`: Time window for runbook log analysis (default: 2h)
- `SLI_LOG_LOOKBACK`: Time window for SLI quick health check (default: 15m)
- `VERTEX_AI_REGIONS`: Comma-separated list of regions to check for model discovery (optional)
  - Example: `us-central1,us-east4,europe-west4`
  - If not set, checks all available Vertex AI regions worldwide
  - Useful for limiting discovery scope or faster execution

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
# Test error analysis with full model discovery (all regions)
python3 vertex_ai_monitoring.py errors --hours 4

# FAST: Test with common US regions only (saves time)
python3 vertex_ai_monitoring.py latency --hours 1 --fast

# US-ONLY: Test with all US regions
python3 vertex_ai_monitoring.py throughput --hours 6 --us-only

# PRIORITY: Test with most common regions worldwide
python3 vertex_ai_monitoring.py errors --hours 2 --priority-regions

# CUSTOM: Test with specific regions only
python3 vertex_ai_monitoring.py discover --regions us-central1,us-east5,europe-west4

# DEBUG: Show detailed API information and discrepancies
python3 vertex_ai_monitoring.py discover --debug --fast

# Test service health
python3 vertex_ai_monitoring.py health

# Skip proactive discovery (use only monitoring metrics)
python3 vertex_ai_monitoring.py errors --hours 2 --no-discovery
```

### Time-Saving Region Options

**🚀 Fast Mode** (saves the most time):
```bash
python3 vertex_ai_monitoring.py discover --fast
# Checks only: us-central1, us-east1, us-east4, us-east5, us-west1
```

**🇺🇸 US-Only Mode**:
```bash
python3 vertex_ai_monitoring.py discover --us-only  
# Checks all US regions: us-central1, us-east1, us-east4, us-east5, us-west1-4
```

**⭐ Priority Mode**:
```bash
python3 vertex_ai_monitoring.py discover --priority-regions
# Checks: us-central1, us-east1, us-east4, us-east5, us-west1, europe-west1, europe-west4, asia-east1, asia-southeast1
```

**🎯 Custom Regions**:
```bash
python3 vertex_ai_monitoring.py discover --regions us-central1,us-east5
# Checks only the regions you specify
```

### API Service Discrepancy Analysis

**NEW FEATURE**: The codebundle now **cross-references multiple Google Cloud APIs** to identify and explain discrepancies between what different services report.

**API Services Used:**
1. **Discovery API** (`aiplatform.Endpoint.list()`): Finds deployed models on endpoints
2. **Monitoring Metrics API** (`monitoring_v3.list_time_series()`): Finds models with recent activity
3. **Token Metrics API** (`token_count` metrics): Finds models with token usage
4. **Audit Logs API** (`gcloud logging read`): Finds API call errors and usage

### Understanding API Discrepancies

**Common Scenarios:**

**📊 Models with Metrics but NOT in Discovery:**
```
• llama-4-maverick-17b-128e-instruct-maas (us-east5) - ACTIVE MODEL NOT DISCOVERED
```
**Possible Reasons:**
- Model deployed in region not checked by discovery
- Insufficient permissions for Discovery API (`aiplatform.endpoints.list`)
- Model deployed via different method (AutoML, custom deployment)
- Model Garden vs custom model differences

**🔍 Models Discovered but NO Recent Metrics:**
```
• my-deployed-model (us-central1) - deployed but idle
```
**Reasons:**
- Model deployed but not receiving traffic
- Need to send test requests to generate metrics
- Model recently deployed (metrics not accumulated yet)

### Debug Mode for API Analysis

**Enable detailed API debugging:**
```bash
python3 vertex_ai_monitoring.py discover --debug --fast
```

**Debug output shows:**
- Exact API calls being made
- Detailed response data from each API
- Cross-reference analysis between APIs
- Specific error messages and reasons
- Recommendations for resolving discrepancies

**Example debug output:**
```
🐛 DEBUG: Using project: projects/your-project-id
🐛 DEBUG: Time range: 2025-01-15 10:00:00 to 2025-01-15 12:00:00
🐛 DEBUG: Invocation details:
  • llama-4-maverick-17b-128e-instruct-maas (us-east5): {'200': 1245, '4': 23}
🐛 DEBUG: This suggests the model exists in region but Discovery API didn't find it
🐛 DEBUG: Recommend running with --regions us-east5
```

## Troubleshooting

### Self-Hosted Models Not Appearing in Monitoring

**Problem**: Your model (like `llama-3-1-8b-instruct-mg-one-click-deploy`) is deployed but doesn't show up in health checks.

**Root Cause**: The model is deployed but hasn't generated recent monitoring metrics due to:
- No recent traffic/requests  
- Recently deployed (metrics haven't accumulated)
- Self-hosted models may have different metric generation patterns

**Solution**:
1. **Run discovery first**: `python3 vertex_ai_monitoring.py discover`
2. **Verify model is found**: Look for "LLAMA MODEL DETECTED!" in output  
3. **Generate metrics**: Send test requests to your model endpoint
4. **Check monitoring**: `python3 vertex_ai_monitoring.py errors --hours 2`

**Example workflow**:
```bash
# Step 1: Discover all models
python3 vertex_ai_monitoring.py discover

# Step 2: Send test request to generate metrics
curl -X POST \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H "Content-Type: application/json" \
  "https://us-central1-aiplatform.googleapis.com/v1/projects/YOUR_PROJECT/locations/us-central1/endpoints/YOUR_ENDPOINT_ID:predict" \
  -d '{"instances": [{"input": "test prompt"}]}'

# Step 3: Wait a few minutes, then check monitoring
python3 vertex_ai_monitoring.py errors --hours 1
```

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

**Model Discovery Access Denied (403)**
```
❌ Permission denied for region us-central1
   Required permissions: aiplatform.endpoints.list, aiplatform.models.list
```
**Solution**: Grant `roles/aiplatform.viewer` for model discovery:
```bash
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:$SERVICE_ACCOUNT" \
    --role="roles/aiplatform.viewer"
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
**Solution**: Verify the `gcp_credentials` secret is properly configured with a valid service account key.

### Model Discovery Shows Endpoints But No Models

**Problem**: Discovery finds endpoints but reports 0 models deployed.

**Possible Causes**:
- **Permission Issues**: Service account may lack `aiplatform.endpoints.get` permission
- **Empty Endpoints**: Endpoints exist but have no models deployed to them
- **Model Undeployment**: Models were recently undeployed from endpoints
- **Different Model Types**: Only certain model types are counted in discovery

**Solution**:
1. **Check Permissions**: Ensure service account has `roles/aiplatform.viewer`
2. **Verify Endpoint Status**: Check if models are actually deployed to the endpoints
3. **Check All Regions**: Your model might be in a region not scanned by default
4. **Look at Metrics**: If you see metrics for models, they exist somewhere

**Example Debug Commands**:
```bash
# Check what's actually on the endpoint
gcloud ai endpoints describe YOUR_ENDPOINT_ID \
  --region=us-central1 \
  --project=YOUR_PROJECT

# List all models across regions  
for region in us-central1 us-east4 us-east5 us-west1; do
  echo "=== $region ==="
  gcloud ai endpoints list --region=$region --project=YOUR_PROJECT
done
```

### Discovery vs. Metrics Mismatch

**Problem**: Discovery finds models in one region, but metrics show activity in another region.

**Root Cause**: Models can be deployed in multiple regions, or you might have multiple models with similar names.

**Example from Test Results**:
- Discovery: Looking for `llama-3-1-8b-instruct-mg-one-click-deploy` in `us-central1`
- Metrics: Found `llama-4-maverick-17b-128e-instruct-maas` active in `us-east5`

**Solution**:
1. **Verify Model Names**: Check exact model names and deployment locations
2. **Expand Region Coverage**: The discovery now includes `us-east5` 
3. **Cross-Reference**: Compare discovery results with metrics to find all active models

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