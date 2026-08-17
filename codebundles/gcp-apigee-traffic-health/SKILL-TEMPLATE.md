---
name: gcp-apigee-traffic-health
kind: skill-template
description: Monitor the runtime traffic, performance, and reliability of GCP Apigee API proxying via Cloud Monitoring (error/fault rates, latency, throughput anomalies, target/backend performance). Use when triaging or monitoring Apigee workloads with skill template `gcp-apigee-traffic-health`.
runtime:
  runbook: runbook.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [GCP, Apigee]
resource_types: [gcp_apigee_organizations]
access: read-only
---

# GCP Apigee Traffic and Performance Health

## Summary

This codebundle monitors the runtime traffic, performance, and reliability of
Apigee API proxying via Cloud Monitoring. It flags elevated error/fault rates,
high latency percentiles, throughput anomalies and traffic collapses, and
degraded target/backend behavior.

The SLX is anchored on the Apigee **organization**: the generation rule gates on
`gcp_apigee_organizations`, so the matched resource is the org and `APIGEE_ORG`
is known at render time rather than resolved at run time.

See [README.md](README.md) for additional context, including the organization
resolution chain, the response shapes involved, and why this bundle ships
runbook-only.

## Setup (not a task)

`discover_metrics_scope.sh` runs in `Suite Initialization`, not as a task. It can
raise no finding about Apigee itself, only about its own ability to run; as a
task it produced a dishonest task list, because a failed discovery left all four
checks running against an empty scope, finding nothing, and rendering as
**passed**.

- **Underlying script**: `discover_metrics_scope.sh`
- **Reads**: `APIGEE_ORG`, `GCP_PROJECT_ID`
- **Writes**: `apigee_scope.json`, `discovery_issues.json`
- **On failure**: raises an issue and **fails the suite**, so the four checks
  render as NOT RUN rather than as passed

Setup also probes the credential key's shape and gates the suite on whether an
access token can be **minted** — not on whether `gcloud auth
activate-service-account` succeeded, which stays tolerant.

## Tools

### Check Apigee API Error and Fault Rates in `${APIGEE_ORG}`

Queries proxy-level `proxyv2/request_count` and `server/fault_count` metrics over
the window and raises **one** finding listing every proxy whose 5xx or fault rate
exceeds `ERROR_RATE_THRESHOLD`.

- **Robot task name**: <code>Check Apigee API Error and Fault Rates in `${APIGEE_ORG}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_error_rates.sh`
- **Tags**: `gcloud`, `apigee`, `monitoring`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:metrics`
- **Reads**: `APIGEE_ORG`, `GCP_PROJECT_ID`, `ERROR_RATE_THRESHOLD`, `METRIC_WINDOW_MIN`
- **Writes**: `error_rate_issues.json`, `error_rate_report.json`
- **Issues raised**: one severity 3 issue naming the org, listing every offending proxy in `details`

### Check Apigee API Latency Performance in `${APIGEE_ORG}`

Queries `proxyv2/latencies_percentile` and raises **one** finding listing every
proxy whose p95/p99 latency exceeds `LATENCY_MS_THRESHOLD`.

- **Robot task name**: <code>Check Apigee API Latency Performance in `${APIGEE_ORG}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_latency.sh`
- **Tags**: `gcloud`, `apigee`, `monitoring`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:metrics`
- **Reads**: `APIGEE_ORG`, `GCP_PROJECT_ID`, `LATENCY_MS_THRESHOLD`, `METRIC_WINDOW_MIN`
- **Writes**: `latency_issues.json`, `latency_report.json`
- **Issues raised**: one severity 3 issue naming the org, listing every slow proxy in `details`

### Check Apigee Throughput and Anomalies in `${APIGEE_ORG}`

Reviews `environment/api_call_count` and `environment/anomaly_count`, raising one
finding for Apigee-detected anomalies and a **separate** one for environments
whose request volume spiked or collapsed — two failure modes with two remedies.

The deviation band is compared as a ratio in both directions. A drop is bounded
at −100%, so a signed comparison against `THROUGHPUT_DEVIATION_PCT` could only
ever fire on a spike, and a traffic collapse was never reported.

- **Robot task name**: <code>Check Apigee Throughput and Anomalies in `${APIGEE_ORG}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_throughput.sh`
- **Tags**: `gcloud`, `apigee`, `monitoring`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:metrics`
- **Reads**: `APIGEE_ORG`, `GCP_PROJECT_ID`, `METRIC_WINDOW_MIN`, `THROUGHPUT_DEVIATION_PCT`
- **Writes**: `throughput_issues.json`, `throughput_report.json`
- **Issues raised**: up to two severity 2 issues naming the org, each listing every affected environment

### Check Apigee Target and Backend Performance in `${APIGEE_ORG}`

Queries `targetv2/request_count` to detect failing backend target servers,
raising one finding per failure mode (error rate, latency) listing every affected
target.

- **Robot task name**: <code>Check Apigee Target and Backend Performance in `${APIGEE_ORG}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_target_performance.sh`
- **Tags**: `gcloud`, `apigee`, `monitoring`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:metrics`
- **Reads**: `APIGEE_ORG`, `GCP_PROJECT_ID`, `ERROR_RATE_THRESHOLD`, `LATENCY_MS_THRESHOLD`, `METRIC_WINDOW_MIN`
- **Writes**: `target_performance_issues.json`, `target_report.json`
- **Issues raised**: up to two severity 3 issues naming the org, each listing every affected target

## Monitor

**There is no monitor.** This bundle ships runbook-only — no SLI and no SLO.

The SLI invoked a strict subset of the scripts the runbook already runs, with an
identical set of imported variables, so nothing was lost by removing it. The SLO
consumed the SLI's metric and carried no independent check.

Reintroduce an SLI once the scoring model has been validated against real
organizations. See the *SLI* section of [README.md](README.md) for the two
constraints any future SLI must honour.

## Issue titles

Titles carry the failure mode and the organization, and nothing else: no counts,
no rates, no proxy names. Findings are aggregated per failure mode, so several
failing proxies in one run produce one issue whose `details` list them all.

Task titles use `${APIGEE_ORG}` because the platform substitutes task names from
`config_provided`, not from Robot suite variables.

## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `APIGEE_ORG` | string | The Apigee organization. Supplied by the SLX, which is generated from the indexed organization. | — | yes |
| `GCP_PROJECT_ID` | string | The GCP project ID that hosts the Apigee runtime and is the Cloud Monitoring scope for metric queries. | — | yes |
| `ERROR_RATE_THRESHOLD` | string | Error/fault rate (percent of requests returning 5xx or faults) above which a proxy is flagged. | `5` | no |
| `LATENCY_MS_THRESHOLD` | string | p95 latency in milliseconds above which a proxy is flagged as slow. | `500` | no |
| `METRIC_WINDOW_MIN` | string | Lookback window in minutes for the Cloud Monitoring metric queries. | `60` | no |
| `THROUGHPUT_DEVIATION_PCT` | string | Deviation band against the previous window, read as a factor: `200` means "tripled, or fell to under a third". | `200` | no |

## Secrets

| Name | Description | Required |
|---|---|---|
| `gcp_credentials` | GCP service account json used to authenticate with GCP APIs and Cloud Monitoring. | yes |

## Outputs

- `apigee_scope.json`
- `discovery_issues.json`
- `error_rate_issues.json`, `error_rate_report.json`
- `latency_issues.json`, `latency_report.json`
- `throughput_issues.json`, `throughput_report.json`
- `target_performance_issues.json`, `target_report.json`

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/gcp-apigee-traffic-health/runbook.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/gcp-apigee-traffic-health
export APIGEE_ORG=my-apigee-org
export GCP_PROJECT_ID=my-project
export ERROR_RATE_THRESHOLD=5
export LATENCY_MS_THRESHOLD=500
export METRIC_WINDOW_MIN=60
ro runbook.robot
```

### Standalone scripts (no Robot)

Discovery must run first: each check treats a missing `apigee_scope.json` as an
error, not as an empty organization.

```bash
cd codebundles/gcp-apigee-traffic-health
export APIGEE_ORG=my-apigee-org
export GCP_PROJECT_ID=my-project
export ERROR_RATE_THRESHOLD=5
export LATENCY_MS_THRESHOLD=500
export METRIC_WINDOW_MIN=60
bash discover_metrics_scope.sh
bash check_error_rates.sh
bash check_latency.sh
bash check_throughput.sh
bash check_target_performance.sh
```

### Offline (no cloud, no credentials, no spend)

```bash
cd codebundles/gcp-apigee-traffic-health
./.test/validate-all-tests.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues; runs discovery and the auth gate in `Suite Initialization`
- `discover_metrics_scope.sh` — enumerates proxies, environments, and target servers
- `check_error_rates.sh` — queries Cloud Monitoring for 5xx and fault rates
- `check_latency.sh` — queries Cloud Monitoring for p95/p99 latency performance
- `check_throughput.sh` — reviews volume deviation and environment anomaly count
- `check_target_performance.sh` — detects slow or failing target servers
- `.test/offline/` — runs the scripts against canned API responses and asserts on what they report
- `.test/render/` — renders the SLX and taskset templates through runwhen-local's jinja2 configuration
