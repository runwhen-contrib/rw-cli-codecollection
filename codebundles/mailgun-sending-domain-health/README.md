# Mailgun Sending Domain Delivery & DNS Health

This CodeBundle validates Mailgun sending domains using the regional Mailgun HTTP API and public DNS (`dig`). It checks domain activation and DNS verification, delivery and reputation metrics, volume trends and anomaly detection, recent delivered/failed/rejected events, suppression and rate-limit diagnostics, and SPF, DKIM, DMARC, and optional MX alignment.

## API Key Requirements

This codebundle requires a Mailgun API key with **Analyst** role or higher. The Analyst role provides read-only access to the APIs used here:

| Permission | Access | Used By |
|---|---|---|
| Metrics | Read | Delivery stats, bounce/complaint rates, volume trends, suppressions, rate limiting |
| Logs | Read | Delivered/failed/rejected event sampling |
| Domains | Read | Domain state, DNS verification |
| Sending | No Access | Not required |

> **Important**: The legacy `GET /v3/{domain}/stats/total` and `GET /v3/{domain}/events` endpoints return HTTP 404 for Analyst keys. This codebundle uses the current `POST /v1/analytics/metrics` and `POST /v1/analytics/logs` endpoints which are RBAC-compatible.

See [Mailgun API Key Roles](https://help.mailgun.com/hc/en-us/articles/26016288026907-API-Key-Roles) for details.

## Overview

- **Domain state**: Confirms the domain exists in Mailgun, is `active`, and highlights unverified required DNS records from the Domains API.
- **Delivery metrics**: Compares delivered vs failed volume to `MAILGUN_MIN_DELIVERY_SUCCESS_PCT` over `MAILGUN_STATS_WINDOW_HOURS`.
- **Bounce and complaint rates**: Evaluates bounce and complaint percentages vs accepted volume.
- **Delivered mail sampling**: Shows recent successfully delivered messages with recipients, subjects, timestamps, and TLS status.
- **Volume trend analysis**: 30-day daily breakdown, week-over-week comparison, and cliff-drop detection with configurable threshold.
- **Mailgun-side diagnostics**: Checks suppressions (bounce, complaint, unsubscribe), rate limiting, and rejected events to rule out Mailgun as the cause of volume drops.
- **Recent failures**: Samples recent permanent `failed` events for triage.
- **Rejected events**: Samples messages Mailgun refused to process (suppression matches, policy blocks).
- **DNS**: Verifies SPF includes Mailgun, DKIM TXT selectors against API expectations, `_dmarc` presence, and optional MX when `MAILGUN_VERIFY_MX` is true.
- **SLI**: `sli.robot` publishes a 0–1 score from domain state, delivery threshold, SPF alignment, and volume trend health.

Use `https://api.mailgun.net` for `MAILGUN_API_REGION=us` and `https://api.eu.mailgun.net` for `eu`. Authenticate with HTTP Basic (`api` / private key). Do not log the API key.

## Configuration

### Required Variables

- `MAILGUN_SENDING_DOMAIN`: FQDN of the Mailgun sending domain (also used when discovery returns no domains).
- `MAILGUN_API_REGION`: `us` or `eu` (selects the API host).

### Optional Variables

- `RESOURCES`: Set to `All` to list domains with `GET /v3/domains`, or set to a single domain FQDN to override scope (default: `All`).
- `MAILGUN_STATS_WINDOW_HOURS`: Rolling stats window in hours (default: `24`).
- `MAILGUN_MIN_DELIVERY_SUCCESS_PCT`: Minimum delivery success percent (default: `95`).
- `MAILGUN_MAX_BOUNCE_RATE_PCT`: Maximum bounce rate percent vs accepted (default: `5`).
- `MAILGUN_MAX_COMPLAINT_RATE_PCT`: Maximum complaint rate percent vs accepted (default: `0.1`).
- `MAILGUN_VOLUME_DROP_THRESHOLD_PCT`: Week-over-week volume decline percentage that triggers an alert (default: `80`).
- `MAILGUN_DELIVERED_SAMPLE_SIZE`: Number of recent delivered messages to sample in the report (default: `10`).
- `MAILGUN_VERIFY_MX`: `true` to enforce MX checks for inbound routing (default: `false`).

### Secrets

- `mailgun_api_key`: Mailgun private API key with **Analyst** role or higher (HTTP Basic: username `api`, password key).

## Tasks

### Runbook (`runbook.robot`)

| Task | Description | API Endpoint |
|---|---|---|
| Validate Mailgun Domain Scope Configuration | Ensures at least one domain is in scope | — |
| Verify Mailgun Domain Registration and State | Domain state, activation, DNS record verification | `GET /v3/domains/{domain}` |
| Check Delivery Success Rate | Delivered vs failed over the stats window | `POST /v1/analytics/metrics` |
| Check Bounce and Complaint Rates | Bounce/complaint percentages vs accepted volume | `POST /v1/analytics/metrics` |
| Sample Recent Delivered Messages | Recent successful deliveries with recipients, subjects, MX hosts | `POST /v1/analytics/logs` |
| Analyze 30-Day Volume Trends | Daily breakdown, week-over-week, cliff detection, suppression/rate-limit diagnostics | `POST /v1/analytics/metrics` |
| Check Recent Permanent Failures | Samples failed events for DNS/policy/auth issues | `POST /v1/analytics/logs` |
| Check for Rejected Messages | Messages Mailgun refused (suppressions, policy blocks) | `POST /v1/analytics/logs` |
| Verify SPF Record | SPF/TXT cross-check with Mailgun expectations | `GET /v3/domains/{domain}` + DNS |
| Verify DKIM DNS Records | `_domainkey` TXT vs Mailgun `sending_dns_records` | `GET /v3/domains/{domain}` + DNS |
| Verify DMARC Policy | `_dmarc` TXT record presence | DNS only |
| Verify MX Records | MX vs Mailgun `receiving_dns_records` (when enabled) | `GET /v3/domains/{domain}` + DNS |

### SLI (`sli.robot`)

Produces a 0–1 health score averaged from four binary sub-scores:

| Sub-score | Weight | Description |
|---|---|---|
| `domain_active` | 1/4 | Domain is active in Mailgun |
| `delivery_success` | 1/4 | Delivery rate meets `MAILGUN_MIN_DELIVERY_SUCCESS_PCT` |
| `spf_mailgun` | 1/4 | SPF authorizes Mailgun |
| `volume_trend` | 1/4 | Current week volume not below `MAILGUN_VOLUME_DROP_THRESHOLD_PCT` vs 30-day average |
