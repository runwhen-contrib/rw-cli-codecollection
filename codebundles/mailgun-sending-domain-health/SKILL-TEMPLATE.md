---
name: mailgun-sending-domain-health
kind: skill-template
description: Validates Mailgun sending domain verification state, delivery metrics, and DNS (SPF, DKIM, DMARC, optional MX) for... Use when triaging or monitoring Mailgun, email, DNS workloads with skill templa...
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [Mailgun, email, DNS, delivery, domain]
resource_types: []
access: read-only
---

# Mailgun Sending Domain Delivery & DNS Health

## Summary

This CodeBundle validates Mailgun sending domains using the regional Mailgun HTTP API and public DNS (`dig`).

See [README.md](README.md) for additional context.

## Tools

### Validate Mailgun Domain Scope Configuration

Confirms at least one Mailgun sending domain is in scope before running deeper checks.

- **Robot task name**: <code>Validate Mailgun Domain Scope Configuration</code>
- **Robot file**: `runbook.robot`
- **Tags**: `Mailgun`, `email`, `domain`, `access:read-only`, `data:config`
- **Reads**: `DOMAIN_LIST`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Verify Mailgun Domain Registration and State for Domains in Scope

Calls Mailgun Domains API to confirm each domain exists, is active, and required DNS records are verified.

- **Robot task name**: <code>Verify Mailgun Domain Registration and State for Domains in Scope</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check-mailgun-domain-state.sh`
- **Tags**: `Mailgun`, `email`, `domain`, `access:read-only`, `data:logs-config`
- **Reads**: `DOMAIN`
- **Writes**: `mailgun_domain_state_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Delivery Success Rate for Mailgun Domains in Scope

Aggregates delivered vs failed stats over MAILGUN_STATS_WINDOW_HOURS and compares to MAILGUN_MIN_DELIVERY_SUCCESS_PCT.

- **Robot task name**: <code>Check Delivery Success Rate for Mailgun Domains in Scope</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check-mailgun-delivery-success-rate.sh`
- **Tags**: `Mailgun`, `email`, `metrics`, `delivery`, `access:read-only`, `data:metrics`
- **Reads**: `DOMAIN`
- **Writes**: `mailgun_delivery_success_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Bounce and Complaint Rates for Mailgun Domains in Scope

Evaluates bounce and complaint ratios from Mailgun stats against MAILGUN_MAX_BOUNCE_RATE_PCT and MAILGUN_MAX_COMPLAINT_RATE_PCT.

- **Robot task name**: <code>Check Bounce and Complaint Rates for Mailgun Domains in Scope</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check-mailgun-bounce-complaint-rates.sh`
- **Tags**: `Mailgun`, `email`, `metrics`, `reputation`, `access:read-only`, `data:metrics`
- **Reads**: `DOMAIN`
- **Writes**: `mailgun_bounce_complaint_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Sample Recent Delivered Messages for Mailgun Domains in Scope

Retrieves a sample of recently delivered messages showing recipients, subjects, and delivery details.

- **Robot task name**: <code>Sample Recent Delivered Messages for Mailgun Domains in Scope</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `sample-mailgun-delivered.sh`
- **Tags**: `Mailgun`, `email`, `events`, `delivery`, `access:read-only`, `data:logs-config`
- **Reads**: `DOMAIN`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Analyze 30-Day Volume Trends for Mailgun Domains in Scope

Fetches 30 days of daily metrics, compares week-over-week volume, and flags cliff drops exceeding MAILGUN_VOLUME_DROP_THRESHOLD_PCT.

- **Robot task name**: <code>Analyze 30-Day Volume Trends for Mailgun Domains in Scope</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check-mailgun-volume-trends.sh`
- **Tags**: `Mailgun`, `email`, `metrics`, `trends`, `access:read-only`, `data:metrics`
- **Reads**: `DOMAIN`
- **Writes**: `mailgun_volume_trend_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Recent Permanent Failures in Mailgun Events for Domains in Scope

Samples recent failed events to surface DNS, policy, or authentication-related failures.

- **Robot task name**: <code>Check Recent Permanent Failures in Mailgun Events for Domains in Scope</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check-mailgun-recent-failures.sh`
- **Tags**: `Mailgun`, `email`, `events`, `failures`, `access:read-only`, `data:logs-config`
- **Reads**: `DOMAIN`
- **Writes**: `mailgun_recent_failures_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check for Rejected Messages in Mailgun for Domains in Scope

Samples messages Mailgun refused to process (suppressions, policy blocks, invalid recipients) to diagnose volume drops.

- **Robot task name**: <code>Check for Rejected Messages in Mailgun for Domains in Scope</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check-mailgun-rejected-events.sh`
- **Tags**: `Mailgun`, `email`, `events`, `rejected`, `access:read-only`, `data:logs-config`
- **Reads**: `DOMAIN`
- **Writes**: `mailgun_rejected_events_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Verify SPF Record for Mailgun Sending Domains in Scope

Resolves TXT/SPF and checks Mailgun include expectations using API-ground truth when available.

- **Robot task name**: <code>Verify SPF Record for Mailgun Sending Domains in Scope</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `verify-mailgun-spf-dns.sh`
- **Tags**: `Mailgun`, `email`, `DNS`, `SPF`, `access:read-only`, `data:logs-config`
- **Reads**: `DOMAIN`
- **Writes**: `mailgun_spf_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Verify DKIM DNS Records for Mailgun Domains in Scope

Confirms DKIM TXT records in DNS match Mailgun-reported expectations for each selector.

- **Robot task name**: <code>Verify DKIM DNS Records for Mailgun Domains in Scope</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `verify-mailgun-dkim-dns.sh`
- **Tags**: `Mailgun`, `email`, `DNS`, `DKIM`, `access:read-only`, `data:logs-config`
- **Reads**: `DOMAIN`
- **Writes**: `mailgun_dkim_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Verify DMARC Policy for Mailgun Sending Domains in Scope

Checks _dmarc TXT presence for the organizational domain used in From headers.

- **Robot task name**: <code>Verify DMARC Policy for Mailgun Sending Domains in Scope</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `verify-mailgun-dmarc-dns.sh`
- **Tags**: `Mailgun`, `email`, `DNS`, `DMARC`, `access:read-only`, `data:logs-config`
- **Reads**: `DOMAIN`
- **Writes**: `mailgun_dmarc_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Verify MX Records for Mailgun Domains When MX Verification Is Enabled

When MAILGUN_VERIFY_MX is true, validates published MX against Mailgun receiving hints for inbound routing.

- **Robot task name**: <code>Verify MX Records for Mailgun Domains When MX Verification Is Enabled</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `verify-mailgun-mx-dns.sh`
- **Tags**: `Mailgun`, `email`, `DNS`, `MX`, `access:read-only`, `data:logs-config`
- **Reads**: `DOMAIN`
- **Writes**: `mailgun_mx_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Monitor

Measures Mailgun sending domain health from domain state, delivery success, and SPF alignment. Produces a score between 0 and 1.

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `180s`

### Sub-checks

#### Score Mailgun Domain Active State

Binary 1/0 score from Mailgun Domains API active state.

- **Robot task name**: <code>Score Mailgun Domain Active State</code>
- **Sub-metric name**: `domain_active`
- **Underlying script**: `sli-mailgun-domain-score.sh`
- **Tags**: `Mailgun`, `email`, `sli`, `access:read-only`, `data:metrics`
- **Reads**: —


#### Score Mailgun Delivery Success Threshold

Binary 1/0 score comparing delivery success to MAILGUN_MIN_DELIVERY_SUCCESS_PCT.

- **Robot task name**: <code>Score Mailgun Delivery Success Threshold</code>
- **Sub-metric name**: `delivery_success`
- **Underlying script**: `sli-mailgun-delivery-score.sh`
- **Tags**: `Mailgun`, `email`, `sli`, `access:read-only`, `data:metrics`
- **Reads**: —


#### Score Mailgun SPF Alignment

Binary 1/0 score when SPF authorizes Mailgun.

- **Robot task name**: <code>Score Mailgun SPF Alignment</code>
- **Sub-metric name**: `spf_mailgun`
- **Underlying script**: `sli-mailgun-spf-score.sh`
- **Tags**: `Mailgun`, `email`, `sli`, `access:read-only`, `data:metrics`
- **Reads**: —


#### Score Mailgun Volume Trend

Binary 1/0 score comparing current-week volume to 30-day historical weekly average.

- **Robot task name**: <code>Score Mailgun Volume Trend</code>
- **Sub-metric name**: `volume_trend`
- **Underlying script**: `sli-mailgun-volume-trend-score.sh`
- **Tags**: `Mailgun`, `email`, `sli`, `access:read-only`, `data:metrics`
- **Reads**: —


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `MAILGUN_SENDING_DOMAIN` | string | FQDN of the Mailgun sending domain to assess. | — | yes |
| `MAILGUN_API_REGION` | string | Mailgun API region (us or eu). | — | yes |
| `RESOURCES` | string | Specific domain FQDN or All to list domains via the Mailgun API. | `All` | no |
| `MAILGUN_STATS_WINDOW_HOURS` | string | Rolling window in hours for Mailgun stats queries. | `24` | no |
| `MAILGUN_MIN_DELIVERY_SUCCESS_PCT` | string | Minimum acceptable delivered divided by delivered plus failed percentage. | `95` | no |
| `MAILGUN_MAX_BOUNCE_RATE_PCT` | string | Maximum acceptable bounce rate percentage vs accepted volume. | `5` | no |
| `MAILGUN_MAX_COMPLAINT_RATE_PCT` | string | Maximum acceptable complaint rate percentage vs accepted volume. | `0.1` | no |
| `MAILGUN_VERIFY_MX` | string | Set true to enforce MX checks for inbound routing. | `false` | no |
| `MAILGUN_VOLUME_DROP_THRESHOLD_PCT` | string | Week-over-week volume decline percentage that triggers an alert (e.g. 80 means a drop of 80%+). | `80` | no |
| `MAILGUN_DELIVERED_SAMPLE_SIZE` | string | Number of recent delivered messages to sample in the report. | `10` | no |

## Secrets

| Name | Description | Required |
|---|---|---|
| `mailgun_api_key` | Mailgun private API key (HTTP Basic user=api, password=key) | yes |

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`
- `mailgun_domain_state_issues.json`
- `mailgun_delivery_success_issues.json`
- `mailgun_bounce_complaint_issues.json`
- `mailgun_volume_trend_issues.json`
- `mailgun_recent_failures_issues.json`
- `mailgun_rejected_events_issues.json`
- `mailgun_spf_issues.json`
- `mailgun_dkim_issues.json`
- `mailgun_dmarc_issues.json`
- `mailgun_mx_issues.json`

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/mailgun-sending-domain-health/runbook.robot`
- **Monitor**: `codebundles/mailgun-sending-domain-health/sli.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/mailgun-sending-domain-health
export MAILGUN_SENDING_DOMAIN=...
export MAILGUN_API_REGION=...
export RESOURCES=...
export MAILGUN_STATS_WINDOW_HOURS=...
export MAILGUN_MIN_DELIVERY_SUCCESS_PCT=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/mailgun-sending-domain-health
export MAILGUN_SENDING_DOMAIN=...
export MAILGUN_API_REGION=...
export RESOURCES=...
bash check-mailgun-bounce-complaint-rates.sh
bash check-mailgun-delivery-success-rate.sh
bash check-mailgun-domain-state.sh
bash check-mailgun-recent-failures.sh
bash check-mailgun-rejected-events.sh
bash check-mailgun-volume-trends.sh
bash discover-mailgun-domains.sh
bash sample-mailgun-delivered.sh
bash sli-mailgun-delivery-score.sh
bash sli-mailgun-domain-score.sh
bash sli-mailgun-spf-score.sh
bash sli-mailgun-volume-trend-score.sh
# ... and 4 more scripts
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring (`sli.robot` runtime file)
- `check-mailgun-bounce-complaint-rates.sh` — Bash helper script `check-mailgun-bounce-complaint-rates.sh`.
- `check-mailgun-delivery-success-rate.sh` — Bash helper script `check-mailgun-delivery-success-rate.sh`.
- `check-mailgun-domain-state.sh` — Bash helper script `check-mailgun-domain-state.sh`.
- `check-mailgun-recent-failures.sh` — Bash helper script `check-mailgun-recent-failures.sh`.
- `check-mailgun-rejected-events.sh` — Bash helper script `check-mailgun-rejected-events.sh`.
- `check-mailgun-volume-trends.sh` — Bash helper script `check-mailgun-volume-trends.sh`.
- `discover-mailgun-domains.sh` — Bash helper script `discover-mailgun-domains.sh`.
- `sample-mailgun-delivered.sh` — Bash helper script `sample-mailgun-delivered.sh`.
- `sli-mailgun-delivery-score.sh` — Bash helper script `sli-mailgun-delivery-score.sh`.
- `sli-mailgun-domain-score.sh` — Bash helper script `sli-mailgun-domain-score.sh`.
- `sli-mailgun-spf-score.sh` — Bash helper script `sli-mailgun-spf-score.sh`.
- `sli-mailgun-volume-trend-score.sh` — Bash helper script `sli-mailgun-volume-trend-score.sh`.
- `verify-mailgun-dkim-dns.sh` — Bash helper script `verify-mailgun-dkim-dns.sh`.
- `verify-mailgun-dmarc-dns.sh` — Bash helper script `verify-mailgun-dmarc-dns.sh`.
- `verify-mailgun-mx-dns.sh` — Bash helper script `verify-mailgun-mx-dns.sh`.
- `verify-mailgun-spf-dns.sh` — Bash helper script `verify-mailgun-spf-dns.sh`.
