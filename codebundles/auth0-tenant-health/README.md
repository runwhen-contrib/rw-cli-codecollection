# Auth0 Tenant Service Health

Monitors the overall health of an upstream Auth0 tenant: confirms the Auth0
platform is available and reachable, that custom login/authentication domains
are functioning, and that no actionable error, login-failure, or rate-limit
signals are present in the tenant log stream. Surfaces service-level and
tenant-level degradation so operators can detect upstream Auth0 outages,
throttling, and misconfigured domains before end users are impacted.

## Overview

This CodeBundle monitors a single Auth0 tenant against the Management API v2:

- **Tenant Service Availability**: Resolves the tenant domain and queries
  well-known discovery endpoints and the Management API, raising issues when
  the service is unreachable or returns 5xx.
- **Custom Domain Health**: Validates each configured custom domain for DNS
  resolution, TLS certificate validity/expiry, and verified status.
- **Tenant Error Logs**: Pulls recent log events, buckets them by type, and
  flags error/warn/anomaly classes (failed auth, MFA errors, etc.).
- **Login Failures & Anomalous Activity**: Detects elevated login failures,
  blocked users, brute-force patterns, and fraud/hack attempts.
- **Rate Limit & Throttling**: Monitors Management API rate-limit utilization
  and rate-limit/429 events in the log stream.
- **Log Stream Delivery Health**: Verifies configured Log Streams are enabled
  and delivering without backlog/failure states.

## Configuration

### Required Variables

- `AUTH0_TENANT`: The Auth0 tenant name (e.g. `mytenant`; the full domain
  `mytenant.auth0.com` is derived from it by the scripts).

### Optional Variables

- `LOG_LOOKBACK_HOURS`: How far back to analyze tenant logs (hours).
  (default: `24`)
- `LOGIN_FAILURE_THRESHOLD`: Number of login failures within the lookback
  window to flag an anomaly. (default: `50`)
- `RATE_LIMIT_THRESHOLD_PCT`: Management API rate-limit utilization % above
  which a warning issue is raised. (default: `80`)
- `CERT_EXPIRY_WARN_DAYS`: Days before a custom-domain certificate expiry to
  raise a warning. (default: `30`)

### Secrets

- `AUTH0_MGMT_CREDENTIALS`: Auth0 Management API client credentials. Provide
  either a JSON object of the form `{"client_id": "...", "client_secret":
  "..."}` (a machine-to-machine client granted `read:logs`,
  `read:custom_domains`, `read:log_streams`, `read:tenant_settings` scopes),
  or a raw Management API bearer token string. When client credentials are
  supplied the scripts exchange them for a short-lived bearer token against
  `https://<AUTH0_TENANT>.auth0.com/oauth/token` (audience
  `https://<AUTH0_TENANT>.auth0.com/api/v2/`).

## Tasks Overview

### Check Auth0 Tenant Service Availability for Tenant

Verifies the tenant is reachable by resolving its domain and querying
well-known discovery endpoints plus the Management API. Can detect a tenant
that is unreachable, returning 5xx, or missing standard OIDC discovery.

### Check Custom Domain Health for Tenant

Validates each configured custom domain for DNS resolution, TLS certificate
validity/expiry, and its verified status via the Custom Domains API. Can detect
unverified domains, unresolved DNS, and expired or soon-to-expire
certificates.

### Analyze Tenant Error Logs for Tenant

Pulls recent log events from the Logs API, buckets them by type, and flags
error, warn, and anomaly event classes (authentication failures, failed
account linking, MFA errors). Can detect spikes of repeated error types within
the lookback window.

### Check Login Failures and Anomalous Activity for Tenant

Detects elevated login-failure and fraud/hack attempts from the log stream
(blocked users, brute-force patterns, passwordless failures) and reports
per-connection anomalies against a configurable threshold.

### Check Rate Limit and Throttling Signals for Tenant

Monitors the tenant for rate-limit events and 429 responses across the
Management API and authentication traffic. Raises issues when rate-limit
utilization approaches checkpoint limits or sustained throttling is observed.

### Verify Log Stream Delivery Health for Tenant

Checks that configured Log Streams are enabled and delivering. Raises issues
for disabled, suspended, or failing log streams.

## SLI

An in-repo `sli.robot` produces a 0-1 health score by averaging six binary
dimension sub-scores: service availability, custom domain health, error-log
spikes, login-failure anomalies, rate-limit signals, and log-stream delivery.
Each dimension is pushed as a sub-metric via `RW.Core.Push Metric`.

## Notes on Platform

This bundle runs as a read-only Management API consumer using `curl` and
`jq`. Obtain a short-lived bearer token via the `/oauth/token`
client_credentials endpoint rather than storing long-lived tokens. Rate limits
vary by subscription tier (checkpoint limits); keep the rate-limit logic
advisory. Some log events (e.g. `limit`/429) require the `read:logs` scope.
The service availability check does not depend on Auth0's public status page
alone; it also probes tenant-specific endpoints to capture tenant-level
degradation.