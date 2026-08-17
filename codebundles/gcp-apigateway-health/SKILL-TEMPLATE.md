---
name: gcp-apigateway-health
kind: skill-template
description: Diagnose GCP API Gateway health and the gateway-to-backend edge, distinguishing gateway faults from faults in the... Use when triaging or monitoring GCP, API Gateway, Cloud Run workloads with skill...
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [GCP, API Gateway, Cloud Run]
resource_types: [gcp_resource]
access: read-only
---

# GCP API Gateway Health

## Summary

This CodeBundle diagnoses the health of GCP API Gateway (`apigateway.googleapis.com`) and the gateway-to-backend edge, distinguishing faults at the gateway edge from faults in the Cloud Run backends behind it.

See [README.md](README.md) for additional context.

## Tools

### Check GCP API Gateway Resource States in `${GCP_PROJECT_ID}`

Flags any Api, ApiConfig or Gateway in a FAILED (or otherwise non-ACTIVE critical) state, which indicates a broken deployment that never took effect.

- **Robot task name**: <code>Check GCP API Gateway Resource States in `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_states.sh`
- **Tags**: `gcloud`, `apigateway`, `state`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:state`
- **Reads**: `GCP_PROJECT_ID`
- **Writes**: `resource_state_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check GCP API Gateway Config Drift in `${GCP_PROJECT_ID}`

For each Gateway, verifies gateway.apiConfig points at the newest ACTIVE ApiConfig for its API, flagging silent drift where stale routes are served in production.

- **Robot task name**: <code>Check GCP API Gateway Config Drift in `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_config_drift.sh`
- **Tags**: `gcloud`, `apigateway`, `config`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:config`
- **Reads**: `GCP_PROJECT_ID`
- **Writes**: `config_drift_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Verify API Gateway Managed Service is Enabled in `${GCP_PROJECT_ID}`

Confirms the API's managed Service Infrastructure service (named <api-id>-<hash>.apigateway.<project>.cloud.goog) is enabled on the project, flagging an 'API not enabled' total outage at the edge.

- **Robot task name**: <code>Verify API Gateway Managed Service is Enabled in `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_managed_service.sh`
- **Tags**: `gcloud`, `apigateway`, `services`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:config`
- **Reads**: `GCP_PROJECT_ID`
- **Writes**: `managed_service_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Gateway Backend Invoker Permissions in `${GCP_PROJECT_ID}`

For the deployed ApiConfig of each gateway, verifies the gateway service account holds roles/run.invoker on every Cloud Run backend it calls, flagging the most common 403 failure mode.

- **Robot task name**: <code>Check Gateway Backend Invoker Permissions in `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_invoker_binding.sh`
- **Tags**: `gcloud`, `apigateway`, `run`, `iam`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:config`
- **Reads**: `GCP_PROJECT_ID`
- **Writes**: `invoker_binding_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Detect Dangling and Unreachable Gateway Backends in `${GCP_PROJECT_ID}`

Flags backends referenced by x-google-backend.address that no longer exist (dangling route) and surfaces 504s where backend latency nears the ESPv2 deadline, handing off backend evidence to the Cloud Run bundle.

- **Robot task name**: <code>Detect Dangling and Unreachable Gateway Backends in `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_backends.sh`
- **Tags**: `gcloud`, `apigateway`, `run`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:logs-config`
- **Reads**: `GCP_PROJECT_ID`
- **Writes**: `backend_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Analyze GCP API Gateway Error Rates in `${GCP_PROJECT_ID}`

Queries Cloud Monitoring for gateway request error rates, flagging 5xx rate above ERROR_RATE_THRESHOLD and a tighter 401/403 rate above AUTH_ERROR_RATE_THRESHOLD.

- **Robot task name**: <code>Analyze GCP API Gateway Error Rates in `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_error_rates.sh`
- **Tags**: `gcloud`, `apigateway`, `monitoring`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:metrics`
- **Reads**: `GCP_PROJECT_ID`
- **Writes**: `error_rate_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Analyze GCP API Gateway Latency in `${GCP_PROJECT_ID}`

Queries Cloud Monitoring for p95 gateway latency, flagging values above LATENCY_THRESHOLD_MS and a large gap between total gateway and backend latency that isolates gateway (ESPv2) overhead.

- **Robot task name**: <code>Analyze GCP API Gateway Latency in `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_latency.sh`
- **Tags**: `gcloud`, `apigateway`, `monitoring`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:metrics`
- **Reads**: `GCP_PROJECT_ID`
- **Writes**: `latency_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check for Failed GCP API Gateway Operations in `${GCP_PROJECT_ID}`

Lists API Gateway operations in the region(s) within OPERATIONS_LOOKBACK and flags any operation in a FAILED state, indicating a provisioning or update that did not take effect.

- **Robot task name**: <code>Check for Failed GCP API Gateway Operations in `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_operations.sh`
- **Tags**: `gcloud`, `apigateway`, `operations`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:logs-config`
- **Reads**: `GCP_PROJECT_ID`
- **Writes**: `operations_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Monitor

Scores GCP API Gateway health as a 0-1 weighted composite across six dimensions: resource states, config drift, invoker binding, managed service, error rate, and latency. Weights are 0.20/0.20/0.20/0.15/0.15/0.10 per the design spec.

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `180s`

### Sub-checks

#### Score API Gateway Resource States in `${GCP_PROJECT_ID}`

Scores 1.0 if all Api/ApiConfig/Gateway resources are ACTIVE (no state issues), 0.0 otherwise. Weight 0.20.

- **Robot task name**: <code>Score API Gateway Resource States in `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `resource_state_issue_count`
- **Underlying script**: `check_states.sh`
- **Tags**: `gcloud`, `apigateway`, `gcp`, `${GCP_PROJECT_ID}`, `data:state`, `access:read-only`
- **Reads**: `GCP_PROJECT_ID`
- **Pass condition**: `int(${issue_count}) == 0`


#### Score API Gateway Config Drift in `${GCP_PROJECT_ID}`

Scores 1.0 if every gateway points at the newest ACTIVE config (no drift), 0.0 otherwise. Weight 0.20.

- **Robot task name**: <code>Score API Gateway Config Drift in `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `config_drift_count`
- **Underlying script**: `check_config_drift.sh`
- **Tags**: `gcloud`, `apigateway`, `gcp`, `${GCP_PROJECT_ID}`, `data:config`, `access:read-only`
- **Reads**: `GCP_PROJECT_ID`
- **Pass condition**: `int(${issue_count}) == 0`


#### Score Gateway Invoker Bindings in `${GCP_PROJECT_ID}`

Scores 1.0 if every gateway service account holds roles/run.invoker on its backends, 0.0 otherwise. Weight 0.20.

- **Robot task name**: <code>Score Gateway Invoker Bindings in `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `missing_invoker_count`
- **Underlying script**: `check_invoker_binding.sh`
- **Tags**: `gcloud`, `apigateway`, `run`, `gcp`, `${GCP_PROJECT_ID}`, `data:config`, `access:read-only`
- **Reads**: `GCP_PROJECT_ID`
- **Pass condition**: `int(${issue_count}) == 0`


#### Score API Gateway Managed Service in `${GCP_PROJECT_ID}`

Scores 1.0 if every API's managed service is enabled, 0.0 otherwise. Weight 0.15.

- **Robot task name**: <code>Score API Gateway Managed Service in `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `managed_service_issue_count`
- **Underlying script**: `check_managed_service.sh`
- **Tags**: `gcloud`, `apigateway`, `gcp`, `${GCP_PROJECT_ID}`, `data:config`, `access:read-only`
- **Reads**: `GCP_PROJECT_ID`
- **Pass condition**: `int(${issue_count}) == 0`


#### Score API Gateway Error Rates in `${GCP_PROJECT_ID}`

Scores 1.0 if 5xx and 401/403 rates are below thresholds, 0.0 otherwise. Weight 0.15.

- **Robot task name**: <code>Score API Gateway Error Rates in `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `error_rate`
- **Underlying script**: `check_error_rates.sh`
- **Tags**: `gcloud`, `apigateway`, `gcp`, `${GCP_PROJECT_ID}`, `data:metrics`, `access:read-only`
- **Reads**: `GCP_PROJECT_ID`
- **Pass condition**: `int(${issue_count}) == 0`


#### Score API Gateway Latency in `${GCP_PROJECT_ID}`

Scores 1.0 if p95 latency and the gateway-vs-backend gap are below thresholds, 0.0 otherwise. Weight 0.10.

- **Robot task name**: <code>Score API Gateway Latency in `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `latency`
- **Underlying script**: `check_latency.sh`
- **Tags**: `gcloud`, `apigateway`, `gcp`, `${GCP_PROJECT_ID}`, `data:metrics`, `access:read-only`
- **Reads**: `GCP_PROJECT_ID`
- **Pass condition**: `int(${issue_count}) == 0`


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `GCP_PROJECT_ID` | string | The GCP Project ID that hosts the API Gateways to check. | — | yes |
| `GCP_REGIONS` | string | Comma-separated list of regions to search for regional Gateways and operations. Empty means discover regions dynamically from the Gateway list. | `` | yes |
| `API_NAME` | string | Optional: restrict to a single API id. Empty means all APIs. | `` | yes |
| `API_CONFIG_NAME` | string | Optional: restrict to a single ApiConfig. Empty means all. | `` | yes |
| `METRIC_LOOKBACK_PERIOD` | string | Cloud Monitoring lookback period for metric queries (seconds, e.g. 3600s). | `3600s` | no |
| `ERROR_RATE_THRESHOLD` | string | Maximum acceptable 5xx error ratio (0.01 = 1%). | `0.01` | no |
| `AUTH_ERROR_RATE_THRESHOLD` | string | Tighter maximum acceptable 401/403 ratio (0.005 = 0.5%). | `0.005` | no |
| `LATENCY_THRESHOLD_MS` | string | Maximum acceptable p95 gateway latency in milliseconds. | `5000` | no |
| `LATENCY_GAP_THRESHOLD_MS` | string | Maximum acceptable gateway-vs-backend latency gap in milliseconds. | `1000` | no |
| `OPERATIONS_LOOKBACK` | string | Lookback window for failed operations (e.g. 1h or 24h). | `24h` | no |

## Secrets

| Name | Description | Required |
|---|---|---|
| `gcp_credentials` | GCP service account json used to authenticate with GCP APIs. | yes |

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`
- `resource_state_issues.json`
- `config_drift_issues.json`
- `managed_service_issues.json`
- `invoker_binding_issues.json`
- `backend_issues.json`
- `error_rate_issues.json`
- `latency_issues.json`
- `operations_issues.json`

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/gcp-apigateway-health/runbook.robot`
- **Monitor**: `codebundles/gcp-apigateway-health/sli.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/gcp-apigateway-health
export GCP_PROJECT_ID=...
export GCP_REGIONS=...
export API_NAME=...
export API_CONFIG_NAME=...
export METRIC_LOOKBACK_PERIOD=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/gcp-apigateway-health
export GCP_PROJECT_ID=...
export GCP_REGIONS=...
export API_NAME=...
bash apigateway_common.sh
bash check_backends.sh
bash check_config_drift.sh
bash check_error_rates.sh
bash check_invoker_binding.sh
bash check_latency.sh
bash check_managed_service.sh
bash check_operations.sh
bash check_states.sh
bash discover_apigateway.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring (`sli.robot` runtime file)
- `apigateway_common.sh` — Bash helper script `apigateway_common.sh`.
- `check_backends.sh` — Bash helper script `check_backends.sh`.
- `check_config_drift.sh` — Bash helper script `check_config_drift.sh`.
- `check_error_rates.sh` — Bash helper script `check_error_rates.sh`.
- `check_invoker_binding.sh` — Bash helper script `check_invoker_binding.sh`.
- `check_latency.sh` — Bash helper script `check_latency.sh`.
- `check_managed_service.sh` — Bash helper script `check_managed_service.sh`.
- `check_operations.sh` — Bash helper script `check_operations.sh`.
- `check_states.sh` — Bash helper script `check_states.sh`.
- `discover_apigateway.sh` — Bash helper script `discover_apigateway.sh`.
