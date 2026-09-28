# Atlassian Organization License Utilization Report

Monitors Atlassian Cloud organization license utilization across Jira, Confluence, Jira Service Management, Loom, and other entitled products. Computes active-user versus billable-user ratios, tracks proximity to purchased user-tier limits, and raises issues when utilization falls below operator thresholds.

## Overview

This CodeBundle provides read-only SaaS license utilization reporting for Atlassian organizations:

- **License utilization report**: Per-product billable, active, and utilization percentages from managed accounts
- **Tier proximity analysis**: Billable seat fill versus purchased tier using workspaces `usage`/`capacity`
- **Utilization threshold evaluation**: Flags products below `LICENSE_UTILIZATION_MIN_PERCENT`
- **Active user trends**: Highlights declining active-user share versus billable seats for renewal planning

Last-active timestamps from the Organizations API may lag up to 24 hours. This bundle does not call suspend, revoke, or remove endpoints.

## Configuration

### Required Variables

- `ATLASSIAN_ORG_ID`: Atlassian Cloud organization UUID from Atlassian Administration
- `ATLASSIAN_ORG_NAME`: Human-readable organization name for reports and task titles

### Optional Variables

- `ATLASSIAN_DIRECTORY_ID`: Primary user directory ID when the org has multiple directories (default: discover first directory)
- `LICENSE_UTILIZATION_MIN_PERCENT`: Minimum acceptable active/billable utilization percentage per product before raising an issue (default: `70`)
- `USER_TIER_PROXIMITY_PERCENT`: Billable-user count as a percentage of purchased tier that triggers proximity alerts (default: `80`)
- `INACTIVE_DAYS_THRESHOLD`: Days without product activity before a user is treated as inactive for utilization math (default: `90`)
- `PRODUCTS`: Comma-separated product keys to include (e.g. `jira-software,confluence,loom`) or `All` (default: `All`)
- `TIMEOUT_SECONDS`: Per-task timeout; orgs with large user bases may need higher values (default: `600`)
- `SLI_MAX_USER_PAGES`: Maximum managed-account pages fetched during SLI scoring to cap runtime (default: `10`)

### Secrets

- `atlassian_org_api_key`: Organization Admin API key used as Bearer token for the [Organizations REST API](https://developer.atlassian.com/cloud/admin/organization/rest/intro/). Plain text API key string.

### Prerequisites

- Organization Admin role on the target Atlassian Cloud organization
- At least one paid subscription for full managed-accounts API access
- `curl` and `jq` available in the execution environment

## Tasks Overview

### Generate Atlassian License Utilization Report

Queries `GET /v1/orgs/{orgId}/users` (managed accounts) and aggregates per-product billable users, recently active users, and utilization percentage. Produces organization-wide summary tables suitable for finance and IT admin review. Raises issues on API access failures or empty directories.

### Analyze Billable User Counts Versus Tier Limits

Correlates billable counts with workspace `usage` and `capacity` from `POST /v2/orgs/{orgId}/workspaces`. Flags products at or above `USER_TIER_PROXIMITY_PERCENT` and overage conditions. Degrades gracefully when tier quantities are unavailable.

### Evaluate License Utilization Thresholds

Compares per-product active/billable ratios against `LICENSE_UTILIZATION_MIN_PERCENT`. Emits structured issues with expected versus actual utilization and remediation hints (review inactive users, suspend access, right-size tier).

### Report Active User Trends

Summarizes unique active users per product using `product_access.last_active` from managed accounts. Highlights products with declining active-user share versus billable seats to guide renewal decisions.

## API Notes

- **Managed accounts**: `GET https://api.atlassian.com/admin/v1/orgs/{orgId}/users` — includes `access_billable`, `product_access`, and `last_active`
- **Workspaces**: `POST https://api.atlassian.com/admin/v2/orgs/{orgId}/workspaces` — includes `usage` and `capacity` for tier proximity
- **Directories**: `GET https://api.atlassian.com/admin/v2/orgs/{orgId}/directories` — used for directory discovery and SLI auth checks
- **Rate limits**: HTTP 429 responses trigger exponential backoff; paginate with `cursor` from `links.next`

## Test Scenarios

| Scenario | Description | Expected issues |
|---|---|---|
| `healthy_high_utilization` | Org with >80% active/billable ratio and tier headroom | 0 |
| `low_utilization_jira` | Jira Software billable high but active below threshold | 2 (severity 3–4) |
| `tier_proximity_confluence` | Confluence billable at 85% of purchased tier | 1 (severity 3) |

Local static validation is available under `.test/` (no live Atlassian org required for structure checks).
