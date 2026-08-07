---
name: gcp-apigee-security-config
kind: skill-template
description: Monitors the security posture and access configuration of an Apigee organization including TLS keystore alias expiry, API product quota/rate limits, developer app access scope, Apigee security score, and target server TLS. Use when triaging or monitoring GCP, Apigee security posture with skill template `gcp-apigee-security-config`.
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [GCP, Apigee, Security]
resource_types: [gcp_resource]
access: read-only
---

# GCP Apigee Security and Configuration Health

## Summary

This codebundle monitors the security posture and access configuration of an Apigee organization, flagging expiring TLS aliases, weak API product quotas, over-scoped developer apps, low security scores, and plaintext target servers.

See [README.md](README.md) for additional context.

## Tools

### Check Apigee Keystore and TLS Alias Expiry for `${APIGEE_ORG}`

Enumerates keystore and certificate aliases per environment and flags aliases that are expired or will expire within `CERT_EXPIRY_WARNING_DAYS` days.

- **Robot task name**: <code>Check Apigee Keystore and TLS Alias Expiry for `${APIGEE_ORG}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_keystore_tls.sh`
- **Tags**: `gcp`, `apigee`, `tls`, `security`, `data:config`, `access:read-only`
- **Reads**: `CERT_EXPIRY_WARNING_DAYS`
- **Writes**: `keystore_tls_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail

### Check Apigee API Product Quota and Rate Limits for `${APIGEE_ORG}`

Reviews API products' quota, rate limit, and approval settings, flagging products with no quota, extreme quota, or auto-approval.

- **Robot task name**: <code>Check Apigee API Product Quota and Rate Limits for `${APIGEE_ORG}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_quota_limits.sh`
- **Tags**: `gcp`, `apigee`, `quota`, `security`, `data:config`, `access:read-only`
- **Reads**: `QUOTA_ABUSE_THRESHOLD`
- **Writes**: `quota_limits_issues.json`

### Check Apigee Developer App Access Scope for `${APIGEE_ORG}`

Reviews developer apps and consumer keys for over-broad scopes and inactive keys.

- **Robot task name**: <code>Check Apigee Developer App Access Scope for `${APIGEE_ORG}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_app_access.sh`
- **Tags**: `gcp`, `apigee`, `access`, `security`, `data:config`, `access:read-only`
- **Writes**: `app_access_issues.json`

### Check Apigee Security Score and Incidents for `${GCP_PROJECT_ID}`

Queries Apigee security metrics via Cloud Monitoring to flag a low security score or detected incidents.

- **Robot task name**: <code>Check Apigee Security Score and Incidents for `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_security_score.sh`
- **Tags**: `gcp`, `apigee`, `security`, `monitoring`, `data:metrics`, `access:read-only`
- **Reads**: `SECURITY_SCORE_THRESHOLD`
- **Writes**: `security_score_issues.json`

### Check Apigee Target Server and Virtual Host Configuration for `${APIGEE_ORG}`

Reviews target servers for missing or incorrect TLS configuration, flagging plaintext backends.

- **Robot task name**: <code>Check Apigee Target Server and Virtual Host Configuration for `${APIGEE_ORG}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_target_vhost_config.sh`
- **Tags**: `gcp`, `apigee`, `tls`, `targetserver`, `security`, `data:config`, `access:read-only`
- **Writes**: `target_vhost_issues.json`

### Generate Apigee Security Summary for `${APIGEE_ORG}`

Aggregates all findings into a consolidated org-level security summary.

- **Robot task name**: <code>Generate Apigee Security Summary for `${APIGEE_ORG}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `generate_security_summary.sh`
- **Tags**: `gcp`, `apigee`, `security`, `summary`, `data:config`, `access:read-only`
- **Writes**: `security_summary.json`

## Monitor

This SLI scores Apigee security and configuration health across five dimensions. Produces a value between 0 (completely failing) and 1 (fully passing).

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `300s`

### Sub-checks

- `tls_keystore_expiry` — 1 if no expired/soon-to-expire TLS aliases
- `quota_rate_limits` — 1 if all API products have sensible quotas
- `app_access_scope` — 1 if no over-broad or risky consumer keys
- `security_score` — 1 if the security score is acceptable and no incidents
- `target_vhost_config` — 1 if all target servers are TLS-enabled

## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `APIGEE_ORG` | string | Apigee organization name (security/config scope). | — | yes |
| `GCP_PROJECT_ID` | string | GCP Project ID hosting the Apigee runtime. | — | yes |
| `CERT_EXPIRY_WARNING_DAYS` | string | Days before certificate expiry at which a keystore alias is flagged. | `30` | no |
| `QUOTA_ABUSE_THRESHOLD` | string | Quota value at/above which an API product is flagged as excessive. | `1000000` | no |
| `SECURITY_SCORE_THRESHOLD` | string | Minimum acceptable Apigee security score before the org is flagged. | `80` | no |

## Secrets

| Name | Description | Required |
|---|---|---|
| `gcp_credentials` | GCP service account JSON key used to authenticate with Apigee and Cloud Monitoring APIs. | yes |

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`
- `keystore_tls_issues.json`
- `quota_limits_issues.json`
- `app_access_issues.json`
- `security_score_issues.json`
- `target_vhost_issues.json`
- `security_summary.json`

## How to invoke

### Production (RunWhen runner / worker)

- **Runbook**: `codebundles/gcp-apigee-security-config/runbook.robot`
- **Monitor**: `codebundles/gcp-apigee-security-config/sli.robot`

### Standalone scripts (no Robot)

```bash
cd codebundles/gcp-apigee-security-config
export APIGEE_ORG=...
export GCP_PROJECT_ID=...
export CERT_EXPIRY_WARNING_DAYS=30
export QUOTA_ABUSE_THRESHOLD=1000000
export SECURITY_SCORE_THRESHOLD=80
bash check_keystore_tls.sh
bash check_quota_limits.sh
bash check_app_access.sh
bash check_security_score.sh
bash check_target_vhost_config.sh
bash generate_security_summary.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring
- `check_keystore_tls.sh` — checks TLS alias expiry
- `check_quota_limits.sh` — checks API product quota/rate limits
- `check_app_access.sh` — checks developer app access scope
- `check_security_score.sh` — checks Apigee security score/incidents
- `check_target_vhost_config.sh` — checks target server TLS
- `generate_security_summary.sh` — produces consolidated security summary
