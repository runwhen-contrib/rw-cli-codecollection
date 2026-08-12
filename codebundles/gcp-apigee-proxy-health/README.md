# GCP Apigee API Proxy Deployment and Traffic Health

This CodeBundle monitors the health of Apigee API proxies: whether the intended
proxy revision is actually deployed and serving, whether deployments are
erroring or drifted across environments, and -- the highest-value Apigee signal
-- whether request failures originate **inside Apigee** (`policy_error`) versus
at the backend (`target_error`), plus the Apigee processing-overhead latency
split. It lets operators separate a broken proxy from a broken backend during an
incident instead of manually correlating analytics, deployment state and backend
logs.

## Overview

The bundle discovers all proxies and their deployments from the org-wide
`/organizations/{org}/deployments` endpoint (ONE call, respecting management API
rate limits) plus `/apis`, then analyzes them across nine dimensions:

- **Proxy discovery** (suite setup, not a task): lists all proxies and org-wide
  deployments (proxy / environment / revision / state / errors[]). `APIGEE_ORG`
  is supplied by the SLX, which is generated from the indexed Apigee
  organization; the lookup from `GCP_PROJECT_ID` is the direct-invocation
  fallback.
- **Deployment state**: Flags deployments in `ERROR` or `PROGRESSING` state, or
  with a non-empty `errors[]` array.
- **Revision drift**: Flags proxies running an older-than-latest revision (stale
  logic live) and environments that silently diverge across revisions.
- **Failed deployments**: Flags revisions that failed to deploy (ERROR state or
  a newer revision not replacing an older one) and proxies not deployed to any
  environment.
- **Revision housekeeping**: Flags proxies accumulating many superseded /
  undeployed revisions (severity 4).
- **policy_error vs target_error split**: Flags proxies whose `policy_error`
  rate (fault inside the policy chain) and `target_error` rate (backend failing)
  each exceed their own threshold, tracked separately because they route to
  different owners.
- **Latency and processing overhead**: Flags proxies whose p95
  `total_response_time` exceeds `LATENCY_MS_THRESHOLD`, and proxies whose
  total-minus-target gap exceeds `OVERHEAD_MS_THRESHOLD` (Apigee's own
  processing bottleneck vs a slow backend).
- **Auth and quota error rates**: Flags elevated 401/403 (`AUTH_ERROR_RATE_THRESHOLD`)
  and elevated 429 (`RATE_LIMIT_ERROR_THRESHOLD`) rates.
- **Failed long-running operations**: Flags management operations (deployment,
  environment, instance) that failed in the lookback window.

## Configuration

### Required Variables

- `GCP_PROJECT_ID`: The GCP project ID that owns the Apigee organization, used
  for gcloud auth and the Analytics / stats and operations endpoints.

### Optional Variables

- `APIGEE_ORG`: The Apigee organization name, either `my-org` or
  `organizations/my-org`. Supplied by the SLX, which is generated from the
  indexed Apigee organization, so it arrives already populated. If empty, it is
  resolved by looking up the org mapped to `GCP_PROJECT_ID` — selected on the
  response's own `projectId`, never positionally, because `GET /organizations`
  is credential-scoped and lists every org the service account can see.
  (default: supplied by the SLX)
- `PROXIES`: Comma-separated API proxy names to scope the analysis, or `All`.
  Respects management API rate limits on large orgs. (default: `All`)
- `ENVIRONMENTS`: Comma-separated environment names to scope deployment checks,
  or `All`. (default: `All`)
- `POLICY_ERROR_THRESHOLD`: Maximum acceptable `policy_error` rate
  (`0.01` = 1%). Fault inside Apigee's policy chain. (default: `0.01`)
- `TARGET_ERROR_THRESHOLD`: Maximum acceptable `target_error` rate
  (`0.01` = 1%). Backend failing; hand off to the backend bundle.
  (default: `0.01`)
- `LATENCY_MS_THRESHOLD`: Maximum acceptable p95 `total_response_time` in
  milliseconds. (default: `5000`)
- `OVERHEAD_MS_THRESHOLD`: Maximum acceptable Apigee processing overhead in ms
  (`total_response_time` minus `target_response_time`) before the proxy logic is
  flagged as the bottleneck. (default: `500`)
- `AUTH_ERROR_RATE_THRESHOLD`: Maximum acceptable 401/403 rate
  (`0.02` = 2%). (default: `0.02`)
- `RATE_LIMIT_ERROR_THRESHOLD`: Maximum acceptable 429 rate (`0.05` = 5%).
  (default: `0.05`)
- `ANALYTICS_WINDOW_MIN`: Analytics lookback window in minutes. Analytics data
  lags real time (~10 min), so this is not for a fast SLI. (default: `60`)
- `APIGEE_MAX_STATUS_CALLS`: Maximum per-deployment runtime-status calls
  discovery may make. `state` and `errors[]` are not returned by any deployment
  *list* endpoint, so each deployment needs its own status call; deployments
  beyond this cap are recorded as `UNKNOWN` and reported as such, never as
  healthy. (default: `250`)
- `REVISION_ACCUMULATION_THRESHOLD`: Number of total revisions at which a proxy
  is flagged for housekeeping (severity 4). (default: `20`)

### Secrets

- `gcp_credentials`: A GCP service account JSON key used to authenticate with
  gcloud; the access token obtained from it authorizes the Apigee REST API
  (including the Analytics stats endpoint). Needs `roles/apigee.readOnlyAdmin`,
  `roles/apigee.analyticsViewer` (required for the stats endpoint),
  `roles/monitoring.viewer`, `roles/logging.viewer`. Format is the standard GCP
  service account JSON object (containing `type`, `project_id`, `private_key_id`,
  `private_key`, `client_email`, `client_id`, `auth_uri`, `token_uri`).

## No SLI — this bundle reports issues, not a score

This bundle ships an SLX and a runbook, and **no SLI**. That is deliberate.

The three checks an SLI would have scored (`deployment_state`,
`revision_drift`, `failed_deployments`) are a strict subset of what the runbook
already runs — same scripts, same API calls, same `*_issues.json`. An SLI would
have added no detection and no diagnostic capability, only a numeric trend, at
the cost of duplicating the discovery calls on a second clock.

The runbook has its own cadence (`intervalStrategy: intermezzo`,
`intervalSeconds: 300`), so the checks still run unprompted; findings surface as
issues with `next_steps` rather than as a 0–1 number.

**What you give up:** a graphable score, an SLO to attach to it, and the SLI's
`alertConfig` score-drop hook. If you later want any of those, the scoring logic
is recoverable from git history — see the commit that removed it, which also
records why each dimension was scored the way it was.

## The SLX covers one Apigee organization

The generation rule gates on `gcp_apigee_organizations` with
`qualifiers: ["resource"]`, so there is **one SLX per Apigee org**, its
`resourcePath` is `gcp/<project>/<org>`, and `APIGEE_ORG` is supplied by the SLX
at render time rather than resolved at run time.

Two alternatives were considered and rejected:

| Gate | Why not |
|---|---|
| bare `project` | An Apigee org is one-per-project and most projects have none, so this generated an SLX for every indexed project. That is what forced the old "does this project even have Apigee?" branch in discovery. Gating on the org **deletes** the case rather than handling it. |
| `gcp_apigee_api_proxies` | The indexer emits one resource per proxy, so this yields one SLX *per proxy* — routinely hundreds per org. Every finding here is already aggregated per failure mode across the org, and the analytics checks query org- and environment-scoped endpoints that cannot be split per proxy without one API call per proxy per run. |

`qualifiers: ["resource"]` is not cosmetic: runwhen-local's `gcp-hierarchy.yaml`
inserts `project_id` into the path **only** when `resource` is a qualifier, so
`["project"]` silently flattens `gcp/<project>/<org>` to `gcp/<project>` and
never names the org. `["project", "resource"]` is wrong too — the SLX name is
built from the qualifier values and an Apigee org is named after its project, so
listing both renders `<project>-<project>-gcp-apigee-proxy-health-<hash>`.

### Everything is named after the org

The SLX is org-anchored, so `... in project <x>` would label an org-level finding
as a project-level one. Task titles, issue titles, the SLX alias, the taskset
description and the `scope` tag all name the organization.

There is **one deliberate exception**: an issue raised *because the org could not
be determined* keeps the project, since at that point the project is the only
identifier that exists.

### Absence versus failure to determine

With the org gate, "this project has no Apigee" is no longer a state the bundle
reasons about — an SLX exists only where an organization was indexed. What
remains is the distinction that always mattered:

| Outcome | Result |
|---|---|
| Positive determination of absence | not a finding |
| Failure to determine (auth, permission, unreachable, no org for this project) | issue raised, suite fails, no check attempted |

Discovery runs in Suite Initialization, so a failure there leaves the checks
**NOT RUN** rather than passing with nothing found — and every check treats a
missing topology as an error rather than as an empty estate. The offline tier
asserts each route to that verdict separately.

## Tasks Overview

Discovery is **suite setup, not a task**: it builds the inventory every check
reads and can only ever report its own failure. As a task, a discovery failure
showed up as one issue while the eight dependent checks each reported "no issues
found" -- they had found nothing because they could not look. In setup it is one
honest failure and the checks are not attempted.

### Check Apigee Proxy Deployment Health
For each deployment, verifies state is `READY` with an empty `errors[]` array;
flags deployments in `ERROR` or `PROGRESSING` state or reporting errors, meaning
the deploy did not take full effect.

### Check Apigee Deployed Revision vs Expected and Revision Drift
Verifies the deployed revision per environment matches the latest revision and
that environments do not diverge; flags stale logic live in production and
environments that silently fell back to an older revision after a failed deploy.

### Check Apigee Undeployed and Orphaned Proxies
Detects proxies that exist but are deployed to no environment -- orphaned, or
left unexposed by a deploy that never landed. Deployment `ERROR` state is owned
by the deployment health task above and is deliberately not repeated here.

### Check Apigee Proxy Revision Housekeeping
Identifies proxies accumulating many undeployed/superseded revisions without
cleanup (severity 4), preventing drift and deploy confusion over time.

### Analyze Apigee policy_error vs target_error Split
Queries the Analytics stats endpoint (dimension `apiproxy`) for
`sum(is_error)`, `sum(policy_error)`, `sum(target_error)`, `sum(message_count)`.
Flags proxies whose `policy_error` rate and `target_error` rate each exceed their
own threshold, tracked separately because `policy_error` is a proxy-policy-chain
problem and `target_error` is a backend (hand off) problem.

### Analyze Apigee Latency and Processing Overhead
Queries `avg`/percentile `total_response_time` and `target_response_time`.
Flags proxies whose p95 `total_response_time` exceeds `LATENCY_MS_THRESHOLD`, and
proxies whose total-minus-target gap exceeds `OVERHEAD_MS_THRESHOLD` -- isolating
a proxy-logic bottleneck from a merely slow backend.

### Analyze Apigee Auth and Quota Error Elevation
Queries Analytics by `response_status_code` for 401/403/429 rates. Flags
elevated 401/403 (token validation failure, API product mismatch, expired
developer app credentials) and elevated 429 beyond the intended quota /
spike-arrest policy.

### Check Apigee Failed Long-Running Operations
Flags management operations that failed AND left no trace in deployment state --
environment-group changes, instance changes, and deploys that failed before any
deployment record existed. A failed deploy that did leave an `ERROR` deployment
is reported by the deployment health task, not twice here. Not time-bounded:
Apigee's operations API exposes no timestamps to filter on.

## Requirements

The service account needs the following IAM permissions (via
`roles/apigee.readOnlyAdmin` plus `roles/apigee.analyticsViewer`, and
`roles/monitoring.viewer` / `roles/logging.viewer` where needed):

- `apigee.deployments.list`
- `apigee.proxies.list`
- `apigee.proxyrevisions.list`
- `apigee.environments.list`
- `apigee.environments.getStats`
- `apigee.environments.get`
- `apigee.organizations.list` / org get
- `apigee.operations.list`

The `gcloud`, `curl`, and `jq` CLI tools are required at runtime, and the Apigee
Management API (`apigee.googleapis.com`) must be enabled. Analytics metric and
dimension names are org-specific -- verify them against
`/organizations/{org}/environments/{env}/analytics/admin/schemav2` before
relying on a specific metric; a wrong metric name returns an empty series and
fails silently.
