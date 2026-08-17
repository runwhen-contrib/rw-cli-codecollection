---
name: gcp-apigee-security-config
kind: skill-template
description: Monitors the security posture and access configuration of an Apigee organization including API product quota/rate limits, developer app access scope, Apigee security score and incidents, and target server TLS. Use when triaging or monitoring GCP, Apigee security posture with skill template `gcp-apigee-security-config`.
runtime:
  runbook: runbook.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [GCP, Apigee, Security]
resource_types: [gcp_apigee_organizations]
access: read-only
---

# GCP Apigee Security and Configuration Health

## Summary

This codebundle monitors the security posture and access configuration of an
Apigee organization, flagging weak or missing API product quotas, over-scoped and
stale developer app credentials, a low security score or open incidents, and
plaintext target servers.

The SLX is anchored on the Apigee **organization**: the generation rule gates on
`gcp_apigee_organizations`, so the matched resource is the org and `APIGEE_ORG`
is known at render time rather than resolved at run time.

See [README.md](README.md) for additional context, including the organization
resolution chain, the Apigee response shapes involved, why this bundle ships
runbook-only, and why it deliberately does **not** check keystore alias expiry.

## Setup

`Suite Initialization` probes the credential key's shape and gates the suite on
whether an access token can be **minted** — not on whether `gcloud auth
activate-service-account` succeeded, which stays tolerant. Without that gate,
every `curl` ran as no identity at all, every check found nothing, and the run
reported a healthy organization while it was blind.

## Tools

### Check Apigee API Product Quota and Rate Limits in `${APIGEE_ORG}`

Raises one finding per failure mode — no quota, quota at/above
`QUOTA_ABUSE_THRESHOLD`, and `approvalType: auto` — each listing every affected
product.

- **Robot task name**: <code>Check Apigee API Product Quota and Rate Limits in `${APIGEE_ORG}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_quota_limits.sh`
- **Tags**: `gcp`, `apigee`, `quota`, `security`, `data:config`, `access:read-only`
- **Reads**: `APIGEE_ORG`, `GCP_PROJECT_ID`, `QUOTA_ABUSE_THRESHOLD`
- **Writes**: `quota_limits_issues.json`
- **Issues raised**: up to three issues (severity 3 / 2 / 2) naming the org, each listing every offending product in `details`

### Check Apigee Developer App Access Scope in `${APIGEE_ORG}`

Raises one finding per failure mode — an approved app with wildcard scopes, an
approved consumer key with wildcard scopes, and a revoked key still attached —
each listing every affected app. A revoked key is reported as a stale credential,
never as a live over-broad one.

- **Robot task name**: <code>Check Apigee Developer App Access Scope in `${APIGEE_ORG}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_app_access.sh`
- **Tags**: `gcp`, `apigee`, `access`, `security`, `data:config`, `access:read-only`
- **Reads**: `APIGEE_ORG`, `GCP_PROJECT_ID`
- **Writes**: `app_access_issues.json`
- **Issues raised**: up to three issues (severity 3 / 3 / 2) naming the org. Consumer keys appear only as an 8-character prefix, and only in `details`.

### Check Apigee Security Score and Incidents in `${APIGEE_ORG}`

Queries Cloud Monitoring for `security/score`, `security/detected_request_count`
and `security/incident_request_count`, raising one finding per metric that is
both populated and out of bounds.

These metrics only populate when Advanced API Security is enabled, so no data
means "not measured" and raises nothing — never "measured as zero risk".

- **Robot task name**: <code>Check Apigee Security Score and Incidents in `${APIGEE_ORG}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_security_score.sh`
- **Tags**: `gcp`, `apigee`, `security`, `monitoring`, `data:metrics`, `access:read-only`
- **Reads**: `APIGEE_ORG`, `GCP_PROJECT_ID`, `SECURITY_SCORE_THRESHOLD`, `SECURITY_WINDOW_HOURS`
- **Writes**: `security_score_issues.json`
- **Issues raised**: up to three issues (severity 3, or 4 when the score is below 40) naming the org

### Check Apigee Target Server and Virtual Host Configuration in `${APIGEE_ORG}`

Fetches each target server's own document and raises one finding listing every
target with no TLS configured. Virtual hosts have no public REST list endpoint on
Apigee X, so there is nothing to enumerate and their absence is not a finding.

- **Robot task name**: <code>Check Apigee Target Server and Virtual Host Configuration in `${APIGEE_ORG}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_target_vhost_config.sh`
- **Tags**: `gcp`, `apigee`, `tls`, `targetserver`, `security`, `data:config`, `access:read-only`
- **Reads**: `APIGEE_ORG`, `GCP_PROJECT_ID`
- **Writes**: `target_vhost_issues.json`
- **Issues raised**: one severity 3 issue naming the org, listing every plaintext target server in `details`

## Not here: keystore alias certificate expiry

There is deliberately no keystore/TLS alias expiry check. The sibling
`gcp-apigee-environment-health` bundle performs exactly that check and gates on
the **same** resource type, so both bundles generate an SLX for the same
organization — meaning one expiring certificate would raise the same finding
twice, against two SLXs, with the same remedy.

The version removed here also never worked: it read `.name` off each element of
the `/keystores` response, which is a bare array of **strings**, so every
keystore was skipped and the check reported clean on every run. See
[README.md](README.md).

## Monitor

**There is no monitor.** This bundle ships runbook-only.

The SLI invoked a strict subset of the scripts the runbook already runs, with an
identical set of imported variables and identical thresholds. Reintroduce an SLI
once the scoring model has been validated against real organizations. See the
*SLI* section of [README.md](README.md) for the two constraints any future SLI
must honour.

## Issue titles

Titles carry the failure mode and the organization, and nothing else: no counts,
no scores, no quota values, no product or app names, and never a credential.
Findings are aggregated per failure mode, so four products without a quota
produce one issue whose `details` list all four.

Task titles use `${APIGEE_ORG}` because the platform substitutes task names from
`config_provided`, not from Robot suite variables.

## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `APIGEE_ORG` | string | The Apigee organization. Supplied by the SLX, which is generated from the indexed organization. | — | yes |
| `GCP_PROJECT_ID` | string | GCP Project ID hosting the Apigee runtime (the Cloud Monitoring scope for the security metric queries). | — | yes |
| `QUOTA_ABUSE_THRESHOLD` | string | Quota value at or above which an API product is flagged as excessive. | `1000000` | no |
| `SECURITY_SCORE_THRESHOLD` | string | Minimum acceptable Apigee security score (0–100) before the org is flagged. | `80` | no |
| `SECURITY_WINDOW_HOURS` | string | Lookback window in hours for the security metric queries. | `6` | no |

## Secrets

| Name | Description | Required |
|---|---|---|
| `gcp_credentials` | GCP service account JSON key used to authenticate with the Apigee Admin and Cloud Monitoring APIs. | yes |

## Outputs

- `quota_limits_issues.json`
- `app_access_issues.json`
- `security_score_issues.json`
- `target_vhost_issues.json`

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/gcp-apigee-security-config/runbook.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/gcp-apigee-security-config
export APIGEE_ORG=my-apigee-org
export GCP_PROJECT_ID=my-gcp-project
export QUOTA_ABUSE_THRESHOLD=1000000
export SECURITY_SCORE_THRESHOLD=80
ro runbook.robot
```

### Standalone scripts (no Robot)

```bash
cd codebundles/gcp-apigee-security-config
export APIGEE_ORG=my-apigee-org
export GCP_PROJECT_ID=my-gcp-project
export QUOTA_ABUSE_THRESHOLD=1000000
export SECURITY_SCORE_THRESHOLD=80
bash check_quota_limits.sh
bash check_app_access.sh
bash check_security_score.sh
bash check_target_vhost_config.sh
```

### Offline (no cloud, no credentials, no spend)

```bash
cd codebundles/gcp-apigee-security-config
./.test/validate-all-tests.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues; runs the auth gate in `Suite Initialization`
- `apigee_common.sh` — shared token and REST helpers; keeps the documented list endpoints (singular field names) and the undocumented ones (bare arrays of strings) apart
- `check_quota_limits.sh` — reviews API product quota, rate limits and approval type
- `check_app_access.sh` — reviews developer app and consumer key scopes and status
- `check_security_score.sh` — queries the Advanced API Security metrics
- `check_target_vhost_config.sh` — fetches each target server and checks its TLS configuration
- `.test/offline/` — runs the scripts against canned API responses and asserts on what they report
- `.test/render/` — renders the SLX and taskset templates through runwhen-local's jinja2 configuration
