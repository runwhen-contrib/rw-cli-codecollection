# gcp-apigateway-health — Test Infrastructure

Two layers:

1. **`offline/`** — known-positive tests for the check scripts. Runs each check
   against a stub `gcloud` **and a stub `curl`** returning real-shaped payloads
   and asserts it *reports* the defect it is meant to catch. All 8 checks plus
   discovery and the summary are covered. No GCP project, no network.
2. **`terraform/`** — live fixtures in a real project, for discovery and
   template rendering.

## Offline checks (run these first)

```bash
cd .test && task test-offline-checks     # or: ./offline/run_offline_checks.sh
```

**Why this layer exists.** `--dryrun` only resolves keywords, it never executes
a check. And a live run proves less than it appears to: a check that crashes, or
that accumulates its findings into a subshell, writes an empty issues file and
reads as "healthy". A bundle in which *no check could report anything* once
presented as 7/10 runbook tasks passing plus an SLI score.

So each check is asserted against a deliberately broken project (it must report
its defect) **and** a healthy one (it must report nothing). A check that finds
nothing in the broken scenario is broken, not healthy.

Add a case here whenever you add a check. Terraform cannot cover everything —
e.g. a FAILED ApiConfig cannot be provisioned reliably (see the scenario 2 note
in `terraform/main.tf`), so that path is only covered offline.

**Two stubs, because the checks use two transports.** `stub-gcloud` covers the
inventory checks; `stub-curl` covers the four that call the Cloud Monitoring and
API Gateway REST APIs directly (`check_latency`, `check_error_rates`,
`check_operations`, and the 504 half of `check_backends`). Before `stub-curl`
existed, `check_operations` had no test of any kind.

Both stubs deliberately reproduce awkward properties of the real APIs, because
each one has already hidden a bug that reached a live run:

| Stub behaviour | What it catches |
|---|---|
| `--view=BASIC` omits `openapiDocuments` | a caller that forgets `--view=FULL` and silently sees zero backends |
| `gatewayServiceAccount` is a resource path, IAM members are `serviceAccount:<email>` | a literal comparison that false-positives every correctly-bound gateway |
| unscoped `serviceruntime` queries return project-wide noise (~63s p95, ~51k requests) | a metric query that measures the whole project instead of the gateways |

The healthy scenario uses real in-threshold data rather than empty responses, so
it also proves the checks do not fire on healthy traffic.

## What the live fixtures create

`terraform/` provisions a set of GCP API Gateway fixtures in the target project
using the **google-beta** provider (API Gateway resources are beta-only),
covering both healthy and deliberately broken states:

| Fixture | State | Purpose |
|---|---|---|
| `apigw-gw-healthy-*` | healthy | Api/ApiConfig/Gateway all ACTIVE, gateway pointed at newest config, managed service explicitly enabled, gateway SA holds `roles/run.invoker` on the backend |
| `apigw-gw-broken-*` | dangling backend | Config references a Cloud Run address that does not exist. **Not** a FAILED ApiConfig — API Gateway accepts a valid spec whose backend host does not resolve, so the config settles ACTIVE. Exercises `check_backends.sh`. |
| `apigw-gw-noinv-*` | missing invoker | Gateway whose service account is NOT bound to `roles/run.invoker` on the backing Cloud Run service — every request 403s |
| `apigw-gw-drift-*` | config drift | A newer ACTIVE ApiConfig (`v2`) exists but the gateway remains pinned to `v1`. `v2` is `depends_on` `v1`: GCP serializes ApiConfig creation per Api and cancels an in-flight older create, so creating them in parallel makes `v1` fail and takes the gateway with it. |

`check_states.sh`'s FAILED branch is **not** covered here — see the offline
layer above.

Two things the fixtures deliberately get right, because getting them wrong makes
the harness quietly useless:

- **Gateways run as a dedicated service account with no project-level role.**
  Under the default compute SA they would hold `roles/editor` project-wide —
  hence `run.invoker` on everything — so the missing-invoker gateway would
  provision without actually being broken.
- **The healthy backend binds that SA, not `allUsers`.** `allUsers` lets every
  gateway reach the backend regardless of its own IAM, which defeats the
  missing-invoker fixture entirely (and leaves a public Cloud Run service
  behind). The check treats `allUsers`/`allAuthenticatedUsers` as satisfying
  invoker, since they genuinely do — that path is covered by the offline
  `public` scenario.

A consequence worth knowing when reading the stub: real GCP returns
`gatewayServiceAccount` as `projects/-/serviceAccounts/<email>` while IAM policy
members are `serviceAccount:<email>`. `stub-gcloud` reproduces that asymmetry
deliberately — emitting a bare email there would let a literal comparison pass
offline while false-positiving every correctly-bound gateway in production.

The `specs/healthy.yaml` and `specs/broken.yaml` templates are rendered with
`templatefile` so the Cloud Run backend URL is injected at plan time.

Note: error-rate and latency checks rely on Cloud Monitoring data generated by
real traffic, so their presence depends on load being sent to the fixtures.

`terraform apply` includes a wait (`var.managed_service_wait`, default 150s)
between creating the Apis and enabling their managed services. A newly created
Api's managed service is not immediately bindable, and enabling too early fails
with a misleading `403: Not found or permission denied for service(s)`. Raise
the variable if apply still fails there.

## Usage

```bash
cd .test

# 1. Credentials: create terraform/tf.secret with:
#    export GOOGLE_APPLICATION_CREDENTIALS="/path/to/svc.json"
#    export TF_VAR_project_id="my-gcp-project"
#    and place the same key at .test/gcp.json.secret for RunWhen Local

# 2. Provision fixtures
task build-infra

# 3. Generate config + run discovery + validate rules
task generate-rwl-config GCP_PROJECT_ID=my-gcp-project RW_WORKSPACE=my-workspace
task run-rwl-discovery
task validate-generation-rules

# 4. Review rendered templates
ls output/workspaces/

# 5. Tear everything down
task clean
```

`task` (default) runs the full flow: check-unpushed-commits →
**test-offline-checks** → build-infra → generate-rwl-config → run-rwl-discovery
→ validate-generation-rules.

## Requirements

- `terraform`, `gcloud`, `docker`, `jq`, `yq`, `ajv`, `curl`
- GCP service account with the following on the test project (used by Terraform
  to create the API Gateway + Cloud Run fixtures):
  - `roles/apigateway.admin`
  - `roles/run.admin`
  - `roles/iam.serviceAccountAdmin`
  - `roles/serviceusage.serviceUsageAdmin`

The offline layer needs only `bash`, `jq` and `yq`.

`terraform/main.tf` enables the APIs it needs itself
(`apigateway`, `servicemanagement`, `servicecontrol`, `run`, `monitoring`,
`logging`) via `google_project_service`, so a project that has never used API
Gateway works out of the box. They are left enabled on `terraform destroy`
(`disable_on_destroy = false`) so teardown cannot disable a service the project
was already relying on — disable them by hand if the project should return to a
pristine state.
