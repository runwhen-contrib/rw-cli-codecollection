# gcp-apigateway-health — Test Infrastructure

Two layers:

1. **`offline/`** — known-positive tests for the check scripts. Runs each check
   against a stub `gcloud` **and a stub `curl`** returning real-shaped payloads
   and asserts it *reports* the defect it is meant to catch. All 8 checks plus
   discovery and the summary are covered. No GCP project, no network.
2. **`terraform/`** — live fixtures in a real project, for discovery and
   template rendering.

Only the first is self-contained: it needs `bash`, `jq` and `yq` and nothing
else. Everything beyond it needs a GCP project, and the discovery/SLX tasks also
need Docker, network egress and the bundle's own `../.runwhen/generation-rules/`.
See [Requirements](#requirements) for what each tier costs.

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
| `STUB_FAIL=<substring>` makes a matching call **exit non-zero** | a check that treats a failed query as an empty answer |

The suite also lints the real `runbook.robot` / `sli.robot`: every
`RW.CLI.Run Bash File` must be preceded by a `rm -f` of its own output and
followed by a `returncode != 0` guard. The runner reuses its working directory,
so without both a failed check is reported using the *previous* run's file —
and because a stale file still parses, the "refusing to report no issues for a
check that never ran" guard cannot see it. Asserted against the real files, not
a copy, so adding a task without the guards fails here.

That last one is why the stub must be able to *fail*, not merely return empty
data. A dropped `get-iam-policy` call once produced a false positive (healthy
gateway reported as missing its binding) and a false negative (the genuinely
broken gateway skipped) in the same run, with every task still reporting PASS.
Success-with-empty-data cannot express that case.

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

### Why there is no FAILED ApiConfig fixture

`check_states.sh`'s FAILED branch is covered offline, not here. That is a
deliberate trade, and worth recording because the obvious objection — "just make
the spec bad enough to fail" — does not work.

FAILED is *reachable*: per the API, `CREATING` means "being created and deployed
to the API Controller" and `FAILED` means "API Config creation failed", so FAILED
is the **asynchronous** outcome after create has already been accepted.

The obstacle is **ownership**. `google_api_gateway_api_config` waits on that
long-running operation, so a config that lands FAILED errors the apply —
terraform cannot own a resource whose creation is defined as failing. Forcing
one means stepping outside terraform (`null_resource` + `local-exec` with
`|| true`), which buys coverage at the cost of a resource terraform does not
track: a new orphaned-resource path, in a harness that already needs explicit
leftover verification.

Not worth it here, because the thing worth testing is the **plumbing** — whether
a FAILED config actually reaches the check — and that is already verified live.
`state` is read from the same field through the same passthrough for every
config, and live runs confirm it works: `check_states` scores from it, and
config drift distinguishes v1 from v2 by reading `.state == "ACTIVE"`. Only the
specific string differs for FAILED.

That is the distinction from the `location`, `gatewayServiceAccount` and
`--view=FULL` bugs, where a field was absent or differently named and the
stub was the only thing asserting otherwise. Here the field demonstrably flows.

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

# 4b. Execute the robots against the fixtures (the highest-signal check)
task test-live GCP_PROJECT_ID=my-gcp-project

# 5. Tear everything down
#    NOTE: `clean` also deletes SLXs, so it needs RW_WORKSPACE/RW_API_URL/RW_PAT.
#    To remove only the cloud fixtures: task check-and-cleanup-terraform
task clean
```

**`task test-live` is not part of `task default`** — it needs credentials and a
provisioned project. It is worth running anyway: every blocking defect found in
review came from executing the robots against real fixtures, a path no task
covered, so the highest-signal check was the one step nobody ran by default.

**Resource naming.** Fixtures are suffixed per user (`RESOURCE_SUFFIX`, default
derived from `$USER`) so concurrent runs against a shared project cannot collide
on Api / Gateway / Cloud Run names — and so teardown verification by suffix
proves *your* run cleaned up rather than matching someone else's live fixtures.
Set `RESOURCE_SUFFIX` explicitly in CI. The static `test001` in
`terraform.tfvars` exists only so `terraform` works standalone; the Taskfile
never relies on it.

**`build-infra` fails if `terraform/tf.secret` is missing** rather than skipping.
It previously exited 0, so `task default` would provision nothing and then run
discovery and generation-rule validation against an empty project, reporting
success throughout — "discovery found no gateways" is indistinguishable from
"discovery worked on a project that has none". To run only the credential-free
parts, opt in explicitly:

```bash
task default SKIP_INFRA=1
```

`task check-and-cleanup-terraform` now also verifies no resources with your
suffix survived the destroy, and fails if any did.

`task` (default) runs the full flow: check-unpushed-commits →
**test-offline-checks** → build-infra → generate-rwl-config → run-rwl-discovery
→ validate-generation-rules.

## Requirements

What you need depends on how far up the stack you go. The offline layer is by
far the cheapest and is worth running on its own.

### Offline checks only

- `bash`, `jq`, `yq`

No network, no GCP project, no Docker, no credentials. `gcloud` and `curl` are
stubbed, so the real binaries need not be installed at all.

Verified rather than assumed — the suite passes 30/30 in a bare
`alpine + bash + jq + yq` container run with `--network none`:

```bash
printf 'FROM alpine:3.20\nRUN apk add --no-cache bash jq yq\n' > Dockerfile.min
docker build -t apigw-offline-minimal -f Dockerfile.min .
docker run --rm --network none -v "$PWD/..:/b:ro" apigw-offline-minimal \
  sh -c 'cp -r /b /work && cd /work && ./.test/offline/run_offline_checks.sh'
```

Worth keeping working: that environment uses BusyBox `date`, which parses
neither the GNU nor the BSD timestamp form, and a silent parse failure makes
`check_operations.sh` treat every operation as outside its lookback window and
report nothing. `apigw_iso8601_to_epoch` handles all three dialects for exactly
this reason.

### Plus live fixtures (`build-infra`, `clean`)

- [`task`](https://taskfile.dev) (the Task runner), `terraform`, `gcloud`
- Network egress to `registry.terraform.io` (provider downloads)
- `terraform/tf.secret` — see Usage below
- GCP service account with the following on the test project (used by Terraform
  to create the API Gateway + Cloud Run fixtures):
  - `roles/apigateway.admin`
  - `roles/run.admin`
  - `roles/iam.serviceAccountAdmin`
  - `roles/serviceusage.serviceUsageAdmin`

### Plus discovery and template rendering (`generate-rwl-config` onward)

- `docker`, `curl`, `ajv`
- Network egress to `ghcr.io` (pulls `runwhen-contrib/runwhen-local:latest`) and
  to `raw.githubusercontent.com` (`validate-generation-rules` fetches
  `generation-rule-schema.json` at run time — it is not vendored)
- `.test/gcp.json.secret`
- `validate-generation-rules` reads the bundle's `../.runwhen/generation-rules/`,
  so `.test` is not self-contained at this tier — it validates the bundle around
  it. That matches the other codebundles in this repo.

### Plus publishing SLXs (`upload-slxs`, and `delete-slxs` via `clean`)

- A reachable RunWhen platform and these environment variables:
  - `RW_WORKSPACE` — target workspace
  - `RW_API_URL` — platform API host
  - `RW_PAT` — personal access token
- Note `task clean` calls `delete-slxs`, which aborts with exit 1 if the
  discovery output directory is absent. To tear down only the cloud fixtures
  after a run that never reached discovery, call
  `task check-and-cleanup-terraform` directly.

`terraform/main.tf` enables the APIs it needs itself
(`apigateway`, `servicemanagement`, `servicecontrol`, `run`, `monitoring`,
`logging`) via `google_project_service`, so a project that has never used API
Gateway works out of the box. They are left enabled on `terraform destroy`
(`disable_on_destroy = false`) so teardown cannot disable a service the project
was already relying on — disable them by hand if the project should return to a
pristine state.
