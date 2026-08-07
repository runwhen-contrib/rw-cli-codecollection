# gcp-apigee-traffic-health — Test Infrastructure

Tests the deterministic threshold logic and template rendering for the
`gcp-apigee-traffic-health` codebundle.

## What the fixtures create

Because creating real Apigee runtime traffic and Cloud Monitoring time series
is impractical in ephemeral test environments, the primary test strategy is
**deterministic mock-based testing**. Mock fixture files live under `mock/` and
are consumed by the bundle's scripts via the `MOCK_DATA_FILE` environment
variable, so thresholds are verified exactly.

The design-spec test scenarios are covered:

| Scenario | Mock fixtures set | Expected per-check findings |
|---|---|---|
| `healthy_traffic` | All proxies/targets under thresholds, no anomalies | 0 issues across every check |
| `high_error_rate` | One proxy (`payments-api`) at ~10.5% error/fault rate | 1 error-rate issue + 1 aggregate summary issue |
| `high_latency_and_slow_target` | One proxy (`orders-api`) with p95 900ms; one target (`backend-payments`) with p95 800ms | 1 latency issue + 1 target issue + 1 aggregate summary issue |

`terraform/` is provided as a buildable scaffold for optional future
provisioning of real Apigee/Cloud Monitoring test assets; it is not required for
the mock tests and does nothing unless the user supplies `tf.secret`.

## Usage

```bash
cd .test

# Deterministic mock tests (no cloud access required)
task run-mock-tests
# or
./validate-all-tests.sh

# Validate the generation-rules YAML against the runwhen-local schema
task validate-generation-rules

# Full local flow (requires a GCP service account + docker for RunWhen Local)
task default
```

## Requirements

- `jq` (required for the script evaluations and the mock test runner)
- `task` (go-task) to run the Taskfile targets
- For `validate-generation-rules`: `curl`, `yq`, `ajv`
- For the optional `run-rwl-discovery` flow: `docker`, `gcloud`, and a GCP
  service account with `roles/monitoring.viewer` and `roles/apigee.viewer`
