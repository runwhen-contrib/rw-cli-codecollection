# GCP Apigee Product and Developer Governance

Governs the consumer-side entitlement layer of an Apigee X organization: API
products, developer apps and their consumer keys/credentials, developer status,
and dangling product references. It flags inactive or over-permissive API
products, expiring developer-app credentials (consumer keys), orphaned or
unused products/apps, and stale entitlements so access control stays healthy.

This is the lower-priority bundle in the Apigee family and shares
`apigee_common.sh` (token acquisition, org resolution, REST paging/error
handling) with `gcp-apigee-environment-health` and `gcp-apigee-proxy-health`.

## Overview

- **API product governance**: Flags API products that permit auto-approval
  (unapproved access) or have missing/zero quota or rate limits.
- **Consumer-key expiry**: Flags developer-app consumer keys that are expired
  or expiring within a configurable window (these silently break consumer
  traffic with 401s).
- **Orphaned / unused entitlements**: Flags API products with no developer app
  attached, developer apps with no consumer keys, and apps seeing no traffic
  over the lookback window (Analytics `developer_app` cross-reference).
- **Developer status & dangling references**: Flags inactive/blocked developers
  with active apps, and apps whose credentials reference API products that no
  longer exist.

## Configuration

The bundle runs once per Apigee organization. `GCP_PROJECT_ID` is required;
`APIGEE_ORG` is optional and is discovered from the project when empty. The
discovery task lists all products/developers/apps at org scope and each
downstream task iterates over the discovered entitlements. Optional
`APIPRODUCTS` and `DEVELOPER_APPS` variables scope iteration for large orgs.

### Required Variables

- `GCP_PROJECT_ID`: The GCP project that owns the Apigee organization, used for
  `gcloud` auth and the Analytics `developer_app` cross-reference.

### Optional Variables

- `APIGEE_ORG`: The Apigee organization name (`organizations/{org}`). If empty,
  resolved by discovering the Apigee org(s) in `GCP_PROJECT_ID`. (default: empty)
- `APIPRODUCTS`: Comma-separated API product names to scope the analysis, or
  `All`. (default: `All`)
- `DEVELOPER_APPS`: Comma-separated developer app names to scope the analysis,
  or `All`. (default: `All`)
- `KEY_EXPIRY_WARNING_DAYS`: Days before a developer-app consumer key expires to
  raise a warning (severity 3). (default: `30`)
- `USAGE_LOOKBACK_DAYS`: Lookback window in days for the Analytics
  `developer_app` usage cross-reference used to detect unused products/apps.
  (default: `30`)

### Secrets

- `gcp_credentials`: GCP service account JSON key used to authenticate with
  `gcloud`; an access token from it authorizes the Apigee management REST API
  and the Analytics stats endpoint. Needs `roles/apigee.readOnlyAdmin`,
  `roles/apigee.analyticsViewer` (for the `developer_app` usage
  cross-reference), `roles/monitoring.viewer`, and `roles/logging.viewer`.

## Tasks Overview

### Discover Apigee API Products, Developers and Apps in the Organization

Lists all API products, developers and developer apps at org scope (with their
consumer keys) so downstream checks can evaluate entitlements without per-object
looping. Reports a summary; raises a discovery issue if the management API is
inaccessible.

### Check Apigee API Product Expiry and Status

Flags API products that permit auto-approval (unapproved access, severity 2) or
that have missing/zero quota or rate limits (severity 3). Both weaken access
control or break intended limits.

### Check Apigee Developer App Credential Expiry

For each developer-app consumer key, flags credentials that are expired or
expiring within `KEY_EXPIRY_WARNING_DAYS` (severity 3). Expiring/expired keys
silently break consumer traffic with 401s.

### Check Apigee Orphaned and Unused Products and Apps

Identifies API products with no developer app attached, developer apps with no
consumer keys, and entitlements that see no traffic over
`USAGE_LOOKBACK_DAYS` (cross-referenced against the Analytics `developer_app`
dimension). Flags these for housekeeping (severity 4). The Analytics lookup is
best-effort and skipped if unavailable.

### Check Apigee Developer Status and Dangling References

Flags developers that are breached/blocked/inactive while their apps remain
active, and apps that reference API products that no longer exist or have been
taken down (severity 3), so access-control drift is caught.

## Notes

- Respect management API rate limits: the scripts use org-wide endpoints and
  honor the `APIPRODUCTS` / `DEVELOPER_APPS` filters. They do not build heavy
  analytics queries -- the sibling proxy bundle owns analytics depth.
- Auth: the runbook activates the GCP service account via
  `gcloud auth activate-service-account`, and `apigee_common.sh` derives an
  OAuth access token via `gcloud auth print-access-token`.
