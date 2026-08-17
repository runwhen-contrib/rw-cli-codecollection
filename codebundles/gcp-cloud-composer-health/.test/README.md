# GCP Cloud Composer Health -- Test Infrastructure

This `.test/` directory provisions GCP Cloud Composer environments to exercise
the CodeBundle's detection capabilities and to validate RunWhen Local discovery
and generation rules.

## Scenarios

| Scenario | Terraform resource | What the bundle should detect |
|---|---|---|
| `healthy_environment` | `google_composer_environment.composer_healthy` | No issues (0 issues) |
| `outdated_environment` | `google_composer_environment.composer_outdated` | Outdated / non-LTS image version issue (configuration drift) |

These map to the design-spec test scenarios:

- **healthy_environment** — all environments RUNNING, DAGs parsed, scheduler healthy, no queue backlog, no error logs → 0 issues
- **degraded_environment** — one environment in ERROR state with failed DAG run and task instances → 3 issues (severs 3, 4, 3)
- **queue_backlog** — environment running but with a large stale task queue and failing task instances → 2 issues (severities 4, 3)

## Prerequisites

- `gcloud` and `terraform` installed and authenticated
- A GCP project with the Composer, Compute, and GKE APIs enabled
- A `tf.secret` file (gitignored) with the GCP credentials. Example:

```bash
export GOOGLE_APPLICATION_CREDENTIALS="/path/to/sa.json"
export TF_VAR_project_id=my-test-project
export TF_VAR_region=us-central1
```

## Usage

```bash
# Create the environments and run discovery
task build-infra
task generate-rwl-config
task run-rwl-discovery

# Validate generation rules against the JSON schema
task validate-generation-rules

# Tear everything down
task clean
```

The `default` task runs all of the above. Note that Cloud Composer environment
creation can take 20+ minutes to reach a `RUNNING` state.
