# GCP Apigee Traffic and Performance Health

This CodeBundle monitors the runtime traffic, performance, and reliability of
Apigee API proxying via Cloud Monitoring. It flags elevated error/fault rates,
high latency percentiles, throughput anomalies and anomalies detected by Apigee,
and degraded target/backend behavior, so operators are alerted to API slowness,
spikes of 5xx errors, or backend degradation before consumers are impacted.

## Overview

The bundle discovers the Apigee organization's proxies, environments, and target
servers once in `Suite Initialization`, then evaluates runtime performance across
four dimensions using Cloud Monitoring metrics:

- **Error and fault rates**: Flags proxies whose 5xx or fault rate exceeds `ERROR_RATE_THRESHOLD`
- **Latency performance**: Flags proxies whose p95/p99 latency exceeds `LATENCY_MS_THRESHOLD`
- **Throughput and anomalies**: Flags Apigee-detected anomalies, and traffic that spiked or collapsed
- **Target and backend performance**: Flags slow or failing backend target servers

All metrics are under the `apigee.googleapis.com/` domain (e.g.
`proxyv2/request_count`, `proxyv2/latencies_percentile`, `server/fault_count`,
`targetv2/request_count`, `environment/anomaly_count`, `environment/api_call_count`)
and are queried via the Cloud Monitoring timeSeries API in `GCP_PROJECT_ID` using
the service-account credentials.

## Configuration

### Required Variables

- `GCP_PROJECT_ID`: The GCP project ID that hosts the Apigee runtime and is the Cloud Monitoring scope for metric queries.

### Supplied by the SLX

- `APIGEE_ORG`: The Apigee organization name that scopes which proxies, environments, and target servers are evaluated. The generation rule gates on `gcp_apigee_organizations`, so the matched resource **is** the organization and its name is known at render time — it is not resolved at run time. See *Organization resolution* below.

### Optional Variables

- `ERROR_RATE_THRESHOLD`: Error/fault rate (percent of requests returning 5xx or faults) above which a proxy is flagged. (default: `5`)
- `LATENCY_MS_THRESHOLD`: p95 latency in milliseconds above which a proxy is flagged as slow. (default: `500`)
- `METRIC_WINDOW_MIN`: Lookback window in minutes for the Cloud Monitoring metric queries. (default: `60`)
- `THROUGHPUT_DEVIATION_PCT`: Deviation band for request volume against the previous window, read as a **factor** — `200` means "tripled, or fell to under a third". (default: `200`)

### Secrets

- `gcp_credentials`: A GCP service account JSON key with `roles/monitoring.viewer`
  and `roles/apigee.readOnlyAdmin` (or `apigee.proxyviewer`) on the organization.
  Format is the standard GCP service account JSON object (containing `type`,
  `project_id`, `private_key_id`, `private_key`, `client_email`, `client_id`,
  `auth_uri`, `token_uri`).

## SLI

**This bundle currently ships runbook-only — there is no SLI, and no SLO.**

Nothing is lost by that, and that was verified rather than assumed. The SLI
invoked a strict subset of the scripts the runbook already runs, with an
identical set of imported variables and an identical `${env}`, so the same
checks ran at the same thresholds:

| | Scripts |
|---|---|
| SLI | `check_error_rates`, `check_latency`, `check_throughput`, `check_target_performance` |
| Only in the SLI | **none** |
| Extra in the runbook | `discover_metrics_scope` |

The SLO carried no independent check either: it pointed at
`slo-default/queries.yaml` with `sloSpecType: simple-mwmb` and consumed the SLI's
metric, so it went with the SLI.

You can re-run that comparison against any future revision:

```sh
comm -13 <(grep -oE '[a-z_]+\.sh' runbook.robot | sort -u) \
         <(grep -oE '[a-z_]+\.sh' sli.robot    | sort -u)   # SLI-only scripts
```

The offline tier also asserts on the script names directly, so deleting the SLI
cannot silently drop a check along with it.

The scoring model that was removed averaged four dimensions into a 0-1 value.
Reducing four independent failure modes to one mean loses *which* one fired, and
the weighting has never been validated against real organizations — a health
score is only useful once it has been shown to track what operators actually
treat as an outage. Reintroduce an SLI once that is true.

Two constraints any future SLI must honour, both of which caused real defects in
the sibling `gcp-apigee-environment-health` bundle:

- **A run that could not read its inputs must not score healthy.** Score 0 when
  discovery fails, and gate every dimension sub-metric on that too, not only the
  aggregate — otherwise anyone alerting on a single dimension still sees green
  during a blind run.
- **Absence is not unhealthy.** Distinguish a positive determination of absence
  (an org that genuinely has no proxies) from a failure to determine (auth,
  permission, unreachable), and never report the latter as the former.

## Organization resolution

Both the SLX and the taskset template resolve `APIGEE_ORG` through the same
chain, kept byte-identical so the two cannot disagree about which org this SLX
covers:

```jinja
{% set _res = match_resource.resource | default({}, true) %}
{% set apigee_org = custom.apigee_org | default(_res.name, true) | default(qualifiers.resource, true) | default(match_resource.name, true) | default('', true) %}
```

Two details are load-bearing:

- **Boolean mode (`, true`).** Plain `default()` substitutes only for an
  *undefined* value, never an empty one, so a workspaceInfo carrying
  `apigee_org: ""` would render `APIGEE_ORG` empty and skip every fallback.
- **`_res` is materialised first.** runwhen-local's `CustomUndefined` subclasses
  plain `jinja2.Undefined`, whose `__getattr__` **raises**, so writing
  `match_resource.resource.name` inline aborts the *whole render* with
  `UndefinedError` when `.resource` is absent instead of falling through.

`qualifiers.resource` is in the chain because `gcp-tags.yaml` renders the
`resource_name` tag from that same expression; sharing the source is what stops
the tag and the config value naming different things.

This replaced `{{match_resource.resource_name}}`, which is **not an attribute
runwhen-local builds**. `src/resources.py` populates `name`, `qualified_name` and
`resource_type` plus whatever the indexer put in `resource_attributes`, and the
GCP handler's `parse_resource_data` contributes `project_id`, `project_name`,
`project`, `lod`, `zone`, `region` and `location` — never `resource_name`.
Because `CustomUndefined.__str__` returns a placeholder rather than `""`, the
old expression rendered `APIGEE_ORG` as the literal string
`missing_workspaceInfo_custom_variable`, so every Apigee API call targeted a
non-existent org while the SLX displayed that placeholder to operators.

Setting `APIGEE_ORG` from `{{project.name}}` instead is not a fix: it works by
coincidence on Apigee X, where the org ID *is* the project ID, which is exactly
why it survives testing and fails on any divergence (an explicit
`custom.apigee_org` override, hybrid, or legacy Edge).

## Discovery (Suite Initialization, not a task)

`discover_metrics_scope.sh` enumerates proxies, environments and target servers
and writes `apigee_scope.json`, which every check reads.

It runs in `Suite Initialization` rather than as a task, because it can raise no
finding about Apigee itself — only about its own ability to run. As a task it
also produced a dishonest task list: when discovery failed, all four checks
still ran against an empty scope, found nothing, and rendered as **passed**,
which is indistinguishable from a healthy organization. Failing setup means they
render as **NOT RUN** instead.

Two outcomes are kept distinct throughout:

| Outcome | Result |
|---|---|
| Positive determination of absence (org genuinely has no proxies) | not a finding |
| Failure to determine (auth, permission, unreachable) | issue raised, **suite fails**, nothing attempted |

Because setup guarantees the scope file exists, each check treats a **missing**
`apigee_scope.json` as an error rather than as an empty organization.

### Response shapes

Two of the three Apigee endpoints used here have **no entry at all** in the
[v1 discovery document](https://apigee.googleapis.com/$discovery/rest?version=v1)
and return a **bare JSON array of strings**:

| Endpoint | Response |
|---|---|
| `organizations/{org}/apis` | documented — `{"proxies":[{"name":...}]}` |
| `organizations/{org}/environments` | undocumented — `["prod","staging"]` |
| `organizations/{org}/environments/{env}/targetservers` | undocumented — `["ts-1","ts-2"]` |

Reading the target server list as `.targetServers[].name` — which is what this
bundle did — matches no real response, so `target_servers` was **always empty**
and *Check Apigee Target and Backend Performance* evaluated nothing on every run
while rendering as passed. The offline tier's fixtures are built from the
discovery document precisely so this class of defect cannot hide.

## Authentication

Setup gates on whether an access token can be **minted**, not on whether
`gcloud auth activate-service-account` succeeded. Those are not the same thing:
a runner can carry a usable ambient identity (workload identity) and still fail
activation, which is why every other GCP bundle here suffixes that call with
`|| true`. Gating on the activation exit code took a whole run down — every task
NOT RUN — on a runner where gcloud misread the key file as a `.p12`. The token
probe is the assertion worth keeping strict: it is what every downstream
`gcloud` and `curl` call actually depends on, so a run with no identity at all
still cannot report green with empty metrics.

When the token probe fails, the issue reports the key file's **shape** rather
than leaving it to be inferred from gcloud's error, which is ambiguous:
`Missing required argument [ACCOUNT] ... .p12 keys` does not mean the key is a
p12, only that gcloud's `json.load()` failed and it guessed one. That single
message covers three different things to go fix.

| Shape | Meaning |
|---|---|
| `KEY_JSON` | well-formed, so suspect the key's contents or its IAM grants |
| `KEY_NOT_JSON` | not JSON at all — commonly a base64-encoded key stored without decoding |
| `KEY_EMPTY` / `KEY_MISSING` | the secret never reached the runner |

The probe emits only that sentinel; no byte of the key is echoed, logged or put
in an issue.

## Issue titles

Titles carry the **failure mode** and the **organization**, and nothing else:

- No ephemeral data — no counts, no rates, no latency values. A title carrying a
  number opens and closes an issue on every run.
- No contained-resource names. Findings are aggregated **per failure mode**:
  three proxies over the error threshold in one run is *one* issue whose details
  list all three, not three issues.
- The organization is named because there is exactly one per SLX and it never
  changes, so it costs no churn and tells an operator which SLX fired.

The project appears in exactly one title — the issue raised when `APIGEE_ORG`
could not be determined at all, where it is the only identifier available.

Task titles use `${APIGEE_ORG}` because the platform substitutes task names from
`config_provided`, **not** from Robot suite variables, so `Set Suite Variable`
would not work there.

## Tasks Overview

### Check Apigee API Error and Fault Rates in `${APIGEE_ORG}`
Queries proxy-level `proxyv2/request_count` and `server/fault_count` metrics over the window, and raises one finding listing every proxy whose 5xx or fault rate exceeds `ERROR_RATE_THRESHOLD`.

### Check Apigee API Latency Performance in `${APIGEE_ORG}`
Queries `proxyv2/latencies_percentile` and raises one finding listing every proxy whose p95/p99 latency exceeds `LATENCY_MS_THRESHOLD`.

### Check Apigee Throughput and Anomalies in `${APIGEE_ORG}`
Reviews `environment/api_call_count` and `environment/anomaly_count`, raising one finding for Apigee-detected anomalies and a separate one for environments whose request volume spiked or collapsed. These are separate failure modes with separate remedies, so they are separate issues.

The deviation band is compared as a **ratio in both directions**, not as a signed percentage. A drop is bounded at −100%, so `abs(deviation) > 200` could only ever fire on a spike: an environment whose traffic fell to zero — the most important throughput signal there is — scored −100% and was never flagged.

### Check Apigee Target and Backend Performance in `${APIGEE_ORG}`
Queries `targetv2/request_count` to detect failing backend target servers, raising one finding per failure mode (error rate, latency) listing every affected target.

### Removed: Generate Apigee Traffic Health Summary
The summary task raised no finding of its own — it restated what the four checks
had already reported, as a *second* issue against the same underlying fault, and
its verdict added a task to the list that could never fail on its own terms.
Each check's own `Add Pre To Report` output already carries the detail. Removed
along with `generate_traffic_summary.sh`.

## Testing

Two tiers run with no cloud, no credentials and no spend:

```sh
./.test/offline/run.sh      # scripts against canned responses + static wiring checks
./.test/render/run.sh       # templates through runwhen-local's jinja2 config
./.test/validate-all-tests.sh   # both
```

or via `task test-offline` / `task test-render` / `task ci`.

The render tier needs `jinja2` and `pyyaml`. When they are absent it **skips
loudly** rather than reporting a success it did not earn.

Fixtures under `.test/offline/fixtures/` are generated by `fixtures.sh` from the
Apigee v1 **discovery document**, never from what the code expects to see. The
sibling bundle's first fixture set was written from its own implementation and
consequently passed while the implementation was wrong. If a fixture is ever
"fixed" to make a test pass, that is the bug reproducing itself.

Fixtures under `.test/mock/` are Cloud Monitoring aggregates in the bundle's own
`MOCK_DATA_FILE` format — there is no API shape to get wrong in these; they
exercise threshold and aggregation logic. `multi_offender` exists specifically so
the aggregation contract is testable: several failing proxies must still produce
one issue.

## Requirements

The following IAM permissions are required on the service account (via a custom
role, or `roles/monitoring.viewer` + `roles/apigee.readOnlyAdmin`):

- `monitoring.timeSeries.list`
- `apigee.proxies.list`
- `apigee.environments.list`
- `apigee.targetservers.list`

The `gcloud`, `jq`, and `curl` CLI tools are required at runtime. The Cloud
Monitoring and Apigee APIs must be enabled for the project, and the Apigee
runtime must be sending metrics to Cloud Monitoring.
