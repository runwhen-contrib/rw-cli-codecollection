---
name: gcp-vertex-modelgarden-health
kind: skill-template
description: Troubleshooting and remediation tasks for GCP Vertex AI Model Garden using Google Cloud Monitoring Python SDK. Use when triaging or monitoring GCP, Vertex AI, Model Garden workloads with skill temp...
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  runner: ro
platforms: [GCP, Vertex AI, Model Garden]
resource_types: [gcp_resource]
access: read-only
---

# GCP Vertex AI Model Garden Health

## Summary

This codebundle provides comprehensive health monitoring for Google Cloud Platform's Vertex AI Model Garden.

See [README.md](README.md) for additional context.

## Tools

### Discover All Deployed Vertex AI Models in `${GCP_PROJECT_ID}`

Discovers all deployed Vertex AI models across regions to establish baseline for subsequent analysis

- **Robot task name**: <code>Discover All Deployed Vertex AI Models in `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `vertex-ai`, `discovery`, `models`, `endpoints`, `access:read-only`, `data:config`
- **Reads**: `DISCOVERED_ENDPOINTS`, `DISCOVERED_MODELS`, `EMPTY`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Analyze Vertex AI Model Garden Error Patterns and Response Codes in `${GCP_PROJECT_ID}`

Analyzes error patterns and response codes from Model Garden invocations to identify issues using Python SDK

- **Robot task name**: <code>Analyze Vertex AI Model Garden Error Patterns and Response Codes in `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `vertex-ai`, `error-analysis`, `response-codes`, `troubleshooting`, `access:read-only`, `data:logs-regexp`
- **Reads**: `DISCOVERED_ENDPOINTS`, `DISCOVERED_MODELS`, `EMPTY`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Investigate Vertex AI Model Latency Performance Issues in `${GCP_PROJECT_ID}`

Analyzes latency metrics to identify performance bottlenecks and degradation using Python SDK

- **Robot task name**: <code>Investigate Vertex AI Model Latency Performance Issues in `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `vertex-ai`, `latency`, `performance`, `analysis`, `access:read-only`, `data:config`
- **Reads**: `DISCOVERED_ENDPOINTS`, `DISCOVERED_MODELS`, `EMPTY`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Monitor Vertex AI Throughput and Token Consumption Patterns in `${GCP_PROJECT_ID}`

Analyzes throughput consumption and token usage patterns for capacity planning using Python SDK

- **Robot task name**: <code>Monitor Vertex AI Throughput and Token Consumption Patterns in `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `vertex-ai`, `throughput`, `tokens`, `capacity-planning`, `access:read-only`, `data:config`
- **Reads**: `DISCOVERED_ENDPOINTS`, `DISCOVERED_MODELS`, `EMPTY`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Vertex AI Model Garden API Logs for Issues in `${GCP_PROJECT_ID}`

Analyzes recent API logs for error patterns and usage issues

- **Robot task name**: <code>Check Vertex AI Model Garden API Logs for Issues in `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `vertex-ai`, `logs`, `api-calls`, `monitoring`, `access:read-only`, `data:logs-regexp`
- **Reads**: `GCP_PROJECT_ID`, `LOG_FRESHNESS`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Vertex AI Model Garden Service Health and Quotas in `${GCP_PROJECT_ID}`

Performs comprehensive health checks on Vertex AI services and quotas

- **Robot task name**: <code>Check Vertex AI Model Garden Service Health and Quotas in `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `vertex-ai`, `health-check`, `quotas`, `service-status`, `access:read-only`, `data:config`
- **Reads**: `DISCOVERED_ENDPOINTS`, `DISCOVERED_MODELS`, `EMPTY`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Generate Vertex AI Model Garden Health Summary and Next Steps for `${GCP_PROJECT_ID}`

Generates a comprehensive health summary with actionable recommendations

- **Robot task name**: <code>Generate Vertex AI Model Garden Health Summary and Next Steps for `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `summary`, `health-report`, `recommendations`, `access:read-only`
- **Reads**: `GCP_PROJECT_ID`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Generate Normalized Health Report Table for `${GCP_PROJECT_ID}`

Generates a normalized tabular health report for regular monitoring of all LLAMA models (MaaS and Self-hosted)

- **Robot task name**: <code>Generate Normalized Health Report Table for `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `vertex-ai`, `health-report`, `monitoring`, `table`, `access:read-only`, `data:config`
- **Reads**: `EMPTY`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Monitor

Calculates SLI for GCP Vertex AI Model Garden health using Google Cloud Monitoring Python SDK.

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `180s`

### Sub-checks

#### Quick Vertex AI Log Health Check for `${GCP_PROJECT_ID}`

Performs a quick check of recent Vertex AI logs for immediate health assessment

- **Robot task name**: <code>Quick Vertex AI Log Health Check for `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `log_health`
- **Tags**: `vertex-ai`, `logs`, `health-check`, `quick`, `access:read-only`, `data:logs-regexp`
- **Reads**: `GCP_PROJECT_ID`, `SLI_LOG_LOOKBACK`


#### Calculate Error Rate Score for `${GCP_PROJECT_ID}`

Calculates error rate score based on Model Garden invocation errors

- **Robot task name**: <code>Calculate Error Rate Score for `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `error_rate`
- **Tags**: `vertex-ai`, `error-rate`, `sli`, `monitoring`, `access:read-only`, `data:logs-regexp`
- **Reads**: `GCP_PROJECT_ID`


#### Calculate Latency Performance Score for `${GCP_PROJECT_ID}`

Calculates latency performance score based on model response times

- **Robot task name**: <code>Calculate Latency Performance Score for `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `latency_performance`
- **Tags**: `vertex-ai`, `latency`, `performance`, `sli`, `access:read-only`, `data:config`
- **Reads**: `GCP_PROJECT_ID`


#### Calculate Throughput Usage Score for `${GCP_PROJECT_ID}`

Calculates throughput usage score based on token consumption data

- **Robot task name**: <code>Calculate Throughput Usage Score for `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `throughput_usage`
- **Tags**: `vertex-ai`, `throughput`, `usage`, `sli`, `access:read-only`, `data:config`
- **Reads**: `GCP_PROJECT_ID`


#### Discover All Deployed Models for `${GCP_PROJECT_ID}`

Proactively discovers all deployed Vertex AI models and endpoints

- **Robot task name**: <code>Discover All Deployed Models for `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `model_discovery`
- **Tags**: `vertex-ai`, `discovery`, `model-inventory`, `access:read-only`, `data:config`
- **Reads**: `GCP_PROJECT_ID`


#### Check Service Availability Score for `${GCP_PROJECT_ID}`

Checks Vertex AI service availability and configuration

- **Robot task name**: <code>Check Service Availability Score for `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `service_availability`
- **Tags**: `vertex-ai`, `service-health`, `availability`, `sli`, `access:read-only`, `data:config`
- **Reads**: `GCP_PROJECT_ID`


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `GCP_PROJECT_ID` | string | The GCP Project ID to scope the API to. | — | yes |
| `LOG_FRESHNESS` | string | Time window for log analysis (e.g., 1h, 30m, 2h, 1d). | `2h` | no |
| `VERTEX_AI_REGIONS` | string | Comma-separated list of regions to check for model discovery (optional). Use 'fast' for common US regions, 'us-only' for all US regions, 'priority' for worldwide common regions. | `` | yes |
| `SLI_LOG_LOOKBACK` | string | Time window for SLI log health check (e.g., 15m, 30m, 1h). | `15m` | no |

## Secrets

| Name | Description | Required |
|---|---|---|
| `gcp_credentials` | GCP service account json used to authenticate with GCP APIs. | yes |

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/gcp-vertex-modelgarden-health
export GCP_PROJECT_ID=...
export LOG_FRESHNESS=...
export VERTEX_AI_REGIONS=...
export SLI_LOG_LOOKBACK=...
ro runbook.robot
```

### Standalone scripts (no Robot)


_No standalone shell scripts in this bundle._

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring (`sli.robot` runtime file)
