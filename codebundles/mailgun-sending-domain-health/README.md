# Mailgun Sending Domain Delivery & DNS Health

This CodeBundle validates Mailgun sending domains using the regional Mailgun HTTP API and public DNS (`dig`). It checks domain activation and DNS verification in Mailgun, delivery and reputation metrics from `stats/total`, recent failed events, and SPF, DKIM, DMARC, and optional MX alignment.

## Overview

- **Domain state**: Confirms the domain exists in Mailgun, is `active`, and highlights unverified required DNS records from the Domains API.
- **Delivery metrics**: Compares delivered vs failed volume to `MAILGUN_MIN_DELIVERY_SUCCESS_PCT` over `MAILGUN_STATS_WINDOW_HOURS`.
- **Bounce and complaint rates**: Estimates bounce and complaint percentages vs accepted volume using Mailgun stats.
- **Recent failures**: Samples recent `failed` events for triage.
- **DNS**: Verifies SPF includes Mailgun, DKIM TXT selectors against API expectations, `_dmarc` presence, and optional MX when `MAILGUN_VERIFY_MX` is true.
- **SLI**: `sli.robot` publishes a 0–1 score from domain state, delivery threshold, and SPF alignment.

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
- `MAILGUN_VERIFY_MX`: `true` to enforce MX checks for inbound routing (default: `false`).

### Secrets

- `mailgun_api_key`: Mailgun private API key (HTTP Basic: username `api`, password key).

## Tasks and capabilities

### Validate Mailgun Domain Scope Configuration

Ensures at least one domain is in scope (from `RESOURCES` or API discovery).

### Verify Mailgun Domain Registration and State for Domains in Scope

Uses the Domains API for state and per-record verification flags.

### Check Delivery Success Rate for Mailgun Domains in Scope

Uses `GET /v3/{domain}/stats/total` with `event=delivered,failed` and the configured duration window.

### Check Bounce and Complaint Rates for Mailgun Domains in Scope

Uses stats totals for accepted, bounce, and complaint-related counters.

### Check Recent Permanent Failures in Mailgun Events for Domains in Scope

Samples recent `failed` events via the Events API.

### Verify SPF Record for Mailgun Sending Domains in Scope

Resolves SPF/TXT and cross-checks Mailgun-published expectations when available.

### Verify DKIM DNS Records for Mailgun Domains in Scope

Compares `_domainkey` TXT records to Mailgun `sending_dns_records`.

### Verify DMARC Policy for Mailgun Sending Domains in Scope

Checks `_dmarc.<domain>` for a `v=DMARC1` TXT record.

### Verify MX Records for Mailgun Domains When MX Verification Is Enabled

When `MAILGUN_VERIFY_MX` is true, compares public MX to Mailgun `receiving_dns_records` hints.
