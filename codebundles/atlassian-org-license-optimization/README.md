# Atlassian Organization License Optimization

Identifies Atlassian Cloud license waste and rightsizing opportunities across inactive billable users, overlapping product entitlements, and stale pending invites. Produces prioritized, read-only reclamation recommendations with estimated seat savings for IT and finance teams before renewal.

## Overview

- **Inactive billable users**: Flags users where `access_billable` is true but no monitored product shows activity within `INACTIVE_DAYS_THRESHOLD` days.
- **Product overlap**: Highlights users licensed on multiple products (Jira, Confluence, Loom, etc.) who are active on only a subset.
- **Pending invites**: Surfaces invited-but-not-accepted accounts and stale invitations that still consume tier capacity.
- **Reclamation recommendations**: Synthesizes findings into suspend/remove/consolidate guidance and a markdown handoff report.

All tasks are strictly read-only. Scripts never call suspend, revoke, remove, or invite endpoints.

## Configuration

### Required Variables

- `ATLASSIAN_ORG_ID`: Atlassian Cloud organization UUID.
- `ATLASSIAN_ORG_NAME`: Human-readable organization name for reports and task titles.

### Optional Variables

- `ATLASSIAN_DIRECTORY_ID`: Primary user directory ID (default: auto-discover via `GET /v2/orgs/{orgId}/directories`).
- `INACTIVE_DAYS_THRESHOLD`: Days without product activity before flagging a billable user as inactive (default: `90`).
- `PENDING_INVITE_DAYS_THRESHOLD`: Days an outstanding invite may sit before it is flagged as stale (default: `30`).
- `MIN_OVERLAP_PRODUCTS`: Minimum licensed products before overlap analysis applies (default: `2`).
- `PRODUCTS`: Comma-separated product keys to analyze or `All` (default: `All`).
- `RECLAMATION_MIN_SEATS`: Minimum reclaimable seats per category before emitting a recommendation issue (default: `5`).
- `TIMEOUT_SECONDS`: Per-task timeout for large organizations (default: `900`).
- `SLI_MAX_PAGES`: Maximum API pages fetched per SLI run for speed (default: `2`).

### Secrets

- `atlassian_org_api_key`: Organization Admin API key used as a Bearer token. Create at [Atlassian Administration](https://admin.atlassian.com/) with organization read permissions.

### Platform Setup

1. Create an Organization Admin API key with read access to user and directory data.
2. Bind the key as workspace secret `atlassian_org_api_key`.
3. Provide `ATLASSIAN_ORG_ID` and `ATLASSIAN_ORG_NAME` from your Atlassian organization settings.

API reference: [Atlassian Organization REST API](https://developer.atlassian.com/cloud/admin/organization/rest/intro/)

## Tasks Overview

### Identify Inactive Billable Users Across Atlassian Products

Pages managed accounts via `GET /v1/orgs/{orgId}/users`, evaluates per-product `last_active` dates, and groups inactive billable users by product and department metadata when available. Emits severity 2–3 issues when inactive counts are detected.

### Analyze Overlapping Product Entitlements

Finds users with `MIN_OVERLAP_PRODUCTS` or more licensed products who are inactive on one or more assignments. Explains Teamwork Collection licensing nuances where duplicate product rows may not imply duplicate billing.

### Surface Pending Invites and Unaccepted Seats

Queries `GET /v2/orgs/{orgId}/directories/{directoryId}/users` for pending membership status and flags stale invites older than `PENDING_INVITE_DAYS_THRESHOLD` days.

### Recommend License Reclamation Actions

Synthesizes prior task outputs into prioritized recommendations (suspend before remove, revoke stale invites, consolidate product access) with estimated seat savings and a consolidated `atlassian_license_reclamation_report.md` for handoff.

## SLI

The in-repo `sli.robot` produces a 0–1 health score across four dimensions:

- Inactive billable users below `RECLAMATION_MIN_SEATS`
- Product overlap candidates below threshold
- No stale pending invites
- API reachability

The SLI is healthy (score near 1) when zero severity-3+ reclamation signals are present.

## Related Bundles

- `atlassian-org-license-utilization` — utilization reporting; run together for full cost-management coverage.
