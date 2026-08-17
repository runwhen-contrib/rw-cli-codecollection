# GCP Apigee Security and Configuration Health

Monitors the security posture and access configuration of an Apigee organization.
Flags API products with missing or overly permissive quota/rate limits, developer
apps with over-scoped or stale consumer keys, plaintext target servers, and a low
Apigee security score or open incidents — so operators can harden the API gateway
before a leaked key or an unbounded product causes a breach.

## Overview

- **API Product Quota and Rate Limits**: Flags products with no quota, an extreme quota (>= `QUOTA_ABUSE_THRESHOLD`), or `approvalType: auto`, which approves developer apps without review.
- **Developer App Access Scope**: Flags approved apps and approved consumer keys carrying wildcard scopes, and revoked keys still attached to an app.
- **Security Score and Incidents**: Queries Apigee security metrics (`security/score`, `security/detected_request_count`, `security/incident_request_count`) via Cloud Monitoring.
- **Target Server TLS Configuration**: Flags target servers with no TLS configured, i.e. plaintext southbound backends.

### Not here: keystore alias certificate expiry

There is deliberately **no** keystore/TLS alias expiry check in this bundle.

The sibling `gcp-apigee-environment-health` bundle already performs exactly that
check, in `check_keystore_cert_expiry.sh`, and it gates on the **same** resource
type (`gcp_apigee_organizations`). Both bundles therefore generate an SLX for the
same organization, so keeping a keystore check here meant one expiring
certificate raising the same finding **twice, against two different SLXs, with
the same remedy**. That is alert noise, not defence in depth.

The version that was removed also never worked: it read `.name` off each element
of the `/environments/{env}/keystores` response, which is a bare array of
**strings**, so `jq` errored, the name came back empty, and every keystore was
skipped. The check reported clean on every run without ever inspecting a
certificate.

If keystore coverage is ever wanted here specifically, take the working
implementation from the sibling bundle rather than reviving this one, and first
decide how the two SLXs should divide the responsibility.

## Configuration

### Required Variables

- `GCP_PROJECT_ID`: GCP Project ID hosting the Apigee runtime (the Cloud Monitoring scope for the security metric queries).

### Supplied by the SLX

- `APIGEE_ORG`: Apigee organization name. The generation rule gates on `gcp_apigee_organizations`, so the matched resource **is** the organization and its name is known at render time. See *Organization resolution* below.

### Optional Variables

- `QUOTA_ABUSE_THRESHOLD`: Quota value (requests/time) at or above which an API product is flagged as excessive (default: `1000000`).
- `SECURITY_SCORE_THRESHOLD`: Minimum acceptable Apigee security score (0–100) before the org is flagged (default: `80`).
- `SECURITY_WINDOW_HOURS`: Lookback window in hours for the security metric queries (default: `6`).

### Secrets

- `gcp_credentials`: GCP service account JSON key. Format: JSON object containing `type`, `project_id`, `private_key_id`, `private_key`, `client_email`, `client_id`, `auth_uri`, `token_uri`.

## SLI

**This bundle currently ships runbook-only — there is no SLI.**

Nothing is lost by that, and that was verified rather than assumed. The SLI
invoked a strict subset of the scripts the runbook already runs, with an
identical set of imported variables and an identical `${env}`, so the same checks
ran at the same thresholds:

| | Scripts |
|---|---|
| SLI | `check_keystore_tls`, `check_quota_limits`, `check_app_access`, `check_security_score`, `check_target_vhost_config` |
| Only in the SLI | **none** |
| Extra in the runbook | `generate_security_summary` (since removed — see below) |

`check_keystore_tls.sh` is the one script no longer present, and its removal is a
separate, deliberate decision documented above — not a check dropped silently
along with the SLI. The offline tier asserts on the remaining script names
directly, and asserts that the keystore script is absent *on purpose*, so neither
outcome can happen by accident.

You can re-run the comparison against any future revision:

```sh
comm -13 <(grep -oE '[a-z_]+\.sh' runbook.robot | sort -u) \
         <(grep -oE '[a-z_]+\.sh' sli.robot    | sort -u)   # SLI-only scripts
```

The scoring model that was removed averaged five dimensions into a 0–1 value.
Reducing five independent failure modes to one mean loses *which* one fired, and
the weighting has never been validated against real organizations — a health
score is only useful once it has been shown to track what operators actually
treat as an incident. Reintroduce an SLI once that is true.

Two constraints any future SLI must honour, both of which caused real defects in
the sibling `gcp-apigee-environment-health` bundle:

- **A run that could not read its inputs must not score healthy.** Score 0 when a
  check could not authenticate or enumerate, and gate every dimension sub-metric
  on that too, not only the aggregate — otherwise anyone alerting on a single
  dimension still sees green during a blind run.
- **Absence is not unhealthy.** Distinguish a positive determination of absence
  (an org that genuinely has no API products, or a security metric that Advanced
  API Security does not populate) from a failure to determine (auth, permission,
  unreachable), and never report the latter as the former.

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

This replaced `APIGEE_ORG: "{{project.name}}"`, which rendered the **project**
where the org was wanted. That works by coincidence on Apigee X, where an org is
1:1 with its project and the org ID *is* the project ID — which is exactly why it
survived testing and would fail on any divergence: an explicit
`custom.apigee_org` override, hybrid, or legacy Edge. The file was already
internally inconsistent about it, since its `alias` resolved the org correctly
while the config value did not.

Setting `APIGEE_ORG` from `{{match_resource.resource_name}}` is not a fix either.
That attribute does not exist — runwhen-local never builds it — and because
`CustomUndefined.__str__` returns a placeholder rather than `""`, it renders the
literal string `missing_workspaceInfo_custom_variable`. The sibling
`gcp-apigee-traffic-health` bundle shipped exactly that.

## Authentication

Setup gates on whether an access token can be **minted**, not on whether
`gcloud auth activate-service-account` succeeded. Those are not the same thing: a
runner can carry a usable ambient identity (workload identity) and still fail
activation, which is why every other GCP bundle here suffixes that call with
`|| true`. Gating on the activation exit code took a whole run down — every task
NOT RUN — on a runner where gcloud misread the key file as a `.p12`. The token
probe is the assertion worth keeping strict: without it, every `curl` ran as no
identity at all, every check found nothing, and the run reported a healthy org
while it was in fact blind.

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

## Response shapes

The Apigee v1 [discovery document](https://apigee.googleapis.com/$discovery/rest?version=v1)
documents some list endpoints and omits others entirely. `apigee_common.sh` has
one helper per kind so the difference cannot be got wrong in a new call site:

| Endpoint | Response | Helper |
|---|---|---|
| `/apiproducts` | `{"apiProduct":[...]}` — **singular** field | `apigee_obj_list ... apiProduct` |
| `/developers` | `{"developer":[...]}` — **singular** | `apigee_obj_list ... developer` |
| `/developers/{d}/apps` | `{"app":[...]}` — **singular** | `apigee_obj_list ... app` |
| `/environments` | undocumented — `["prod","test"]` | `apigee_str_list` |
| `/environments/{env}/targetservers` | undocumented — `["ts-1"]` | `apigee_str_list` |

Treating a bare array of strings as a list of objects is silent: `jq '.name'` on
a string errors, the field comes back empty, and the loop body skips every
element. `check_target_vhost_config.sh` did exactly that — and because its test
was `[ -z "$ssl_enabled" ]`, the empty field then made it report a **plaintext
backend for every target server in the org**, whether or not TLS was configured,
without ever having read a target server document.

TLS configuration is not on the target server *list* response at all. It lives on
the per-target-server GET, under `sSLInfo` with that exact capitalisation, so
each target server has to be fetched individually.

## Issue titles

Titles carry the **failure mode** and the **organization**, and nothing else:

- No ephemeral data — no counts, no scores, no quota values, no `days_left`. A
  title carrying a number opens and closes an issue on every run.
- No contained-resource names. Findings are aggregated **per failure mode**: four
  products without a quota is *one* issue whose details list all four, not four
  issues.
- No credentials. A consumer key is recorded only as an 8-character prefix, and
  only in `details`.
- The organization is named because there is exactly one per SLX and it never
  changes, so it costs no churn and tells an operator which SLX fired.

Task titles use `${APIGEE_ORG}` because the platform substitutes task names from
`config_provided`, **not** from Robot suite variables, so `Set Suite Variable`
would not work there. *Check Apigee Security Score and Incidents* previously
named the project instead, which disagreed with every other task in the bundle.

## Absence vs failure to determine

Kept distinct in every check:

| Outcome | Result |
|---|---|
| Positive determination of absence (no API products, no developers, a security metric Advanced API Security does not populate) | not a finding |
| Failure to determine (no token, permission denied, unreachable) | issue raised naming what was **not** evaluated |

The security metrics matter most here: `apigee.googleapis.com/security/*` only
populates when Advanced API Security is enabled, so no data means "not measured",
never "measured as zero risk".

## Tasks Overview

### Check Apigee API Product Quota and Rate Limits in `${APIGEE_ORG}`
Raises one finding per failure mode — no quota, quota at/above `QUOTA_ABUSE_THRESHOLD`, and `approvalType: auto` — each listing every affected product.

### Check Apigee Developer App Access Scope in `${APIGEE_ORG}`
Raises one finding per failure mode — an approved app with wildcard scopes, an approved consumer key with wildcard scopes, and a revoked key still attached — each listing every affected app. A revoked key is reported as a stale credential, never as a live over-broad one.

### Check Apigee Security Score and Incidents in `${APIGEE_ORG}`
Queries Cloud Monitoring for `security/score`, `security/detected_request_count` and `security/incident_request_count`, raising one finding per metric that is both populated and out of bounds.

### Check Apigee Target Server and Virtual Host Configuration in `${APIGEE_ORG}`
Fetches each target server's own document and raises one finding listing every target with no TLS configured. Virtual hosts have no public REST list endpoint on Apigee X, so there is nothing to enumerate and their absence is not reported as a finding.

### Removed: Generate Apigee Security Summary
The summary task raised **no finding at all** — it only restated what the other
tasks had already reported, as an extra entry in the task list. Each check's own
`Add Pre To Report` output already carries the detail. Removed along with
`generate_security_summary.sh`.

## Testing

Two tiers run with no cloud, no credentials and no spend:

```sh
./.test/offline/run.sh          # scripts against canned responses + static wiring checks
./.test/render/run.sh           # templates through runwhen-local's jinja2 config
./.test/validate-all-tests.sh   # both
```

or via `task test-offline` / `task test-render` / `task run-mock-tests`.

The render tier needs `jinja2` and `pyyaml`. When they are absent it **skips
loudly** rather than reporting a success it did not earn.

Fixtures under `.test/offline/fixtures/` are generated by `fixtures.sh` from the
Apigee v1 **discovery document**, never from what the code expects to see. The
sibling bundle's first fixture set was written from its own implementation and
consequently passed while the implementation was wrong. If a fixture is ever
"fixed" to make a test pass, that is the bug reproducing itself.

## Requirements

The following GCP IAM roles are required on the service account:
- `roles/apigee.readOnlyAdmin` (read access to Apigee resources)
- `roles/monitoring.viewer` (Cloud Monitoring metric queries)

The Apigee security metrics only populate when Advanced API Security / security
assessment is enabled; otherwise the security-score check returns no data and
raises no issue.

## Platform Tools

- `gcloud` - Google Cloud CLI (authentication + access token)
- `curl` - REST calls to the Apigee Admin and Cloud Monitoring APIs
- `jq` - JSON processor
- `awk` - numeric comparison (replaced a `python3` dependency the runner image does not guarantee)
