# Mailgun Platform Status & Reachability

This CodeBundle detects Mailgun-wide service disruptions and loss of regional API reachability before authenticated domain checks run. It uses only Mailgun’s public Statuspage JSON endpoints and unauthenticated HTTPS probes (no API keys), so it works in environments where secrets are restricted.

## Overview

- **Live status page**: Reads `status.json`, `summary.json`, unresolved incidents, and active scheduled maintenance from `https://status.mailgun.com` to flag non-green indicators, degraded components, active incidents, and maintenance windows.
- **Incident history**: Scans the public incidents feed for major or critical incidents that **resolved** within the configured lookback window (context after an outage even when the banner is green again).
- **US API reachability**: GET `https://api.mailgun.net/v3/domains` without credentials; expects HTTP **401** and JSON (confirms TLS, routing, and API edge behavior).
- **EU API reachability**: Same check against `https://api.eu.mailgun.net/v3/domains` when EU routing is in scope.
- **SLI**: Produces a 0–1 health score from page status, unresolved incidents, and regional probes (see `sli.robot`).

## Configuration

### Required Variables

None. The bundle uses only public endpoints and optional configuration below.

### Optional Variables

- `MAILGUN_STATUS_REGION_FOCUS`: Which regional API reachability checks to run: `us`, `eu`, or `both` (default: `both`). When set to `us` only, the EU probe is skipped (and vice versa).
- `MAILGUN_STATUS_LOOKBACK_HOURS`: Hours of history to consider “recent” for the incident-feed task (default: `24`). Major/critical incidents resolved within this window are surfaced as lower-severity informational issues.

### Secrets

None.

## Tasks Overview

### Check Mailgun Status Page for Published Incidents

Uses Statuspage APIs for overall indicator, per-component status from `summary.json`, any unresolved incidents, and active scheduled maintenance. Raises issues when the page is not all-green, components are degraded, incidents are open, or maintenance is active.

### Check Mailgun Public Incident Feed for Recent Critical Events

Uses the incidents JSON feed to list major or critical incidents that reached **resolved** status inside the lookback window (recent blast-radius context).

### Verify Mailgun US API Endpoint Reachability

Probes the US API base; expects HTTP 401 with JSON without an API key. Skipped when `MAILGUN_STATUS_REGION_FOCUS` is `eu` only.

### Verify Mailgun EU API Endpoint Reachability

Same probe for the EU regional base. Skipped when `MAILGUN_STATUS_REGION_FOCUS` is `us` only.

### SLI (sli.robot)

Aggregates binary checks into a single health score for alerting; see `.runwhen/templates/mailgun-platform-status-health-sli.yaml`.
