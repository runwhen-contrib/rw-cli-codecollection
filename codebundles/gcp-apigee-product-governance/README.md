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
dimension). Flags these for housekeeping (severity 4).

If the Analytics cross-reference cannot run — missing `roles/apigee.analyticsViewer`,
unreadable environments, or partial stats — the unused-app scan is skipped and
that skip is itself reported as a severity-4 issue naming the reason. It is not
silently dropped: a permanently broken analytics permission would otherwise read
as "no unused apps" forever.

### Check Apigee Developer Status and Dangling References

Flags developers that are breached/blocked/inactive while their apps remain
active, and apps that reference API products that no longer exist or have been
taken down (severity 3), so access-control drift is caught.

## How the health score treats failure

The SLI averages four binary dimensions. A dimension scores 1 only when its
check **ran successfully and found nothing**. Three states are kept distinct:

| State | Issue count | Dimension score |
|---|---|---|
| Ran, found nothing | 0 | 1 |
| Ran, found problems | > 0 | 0 |
| Could not read the Apigee API | −1 | 0 |

Each check writes a `<prefix>_status.json` sidecar carrying `access_ok`. The SLI
gates on it per dimension, so a run that could not read anything scores 0 across
the board instead of reporting perfect health. An issue count of −1 in a
sub-metric means "could not run", not "clean".

A project with **no Apigee organization at all** is a fourth state and is scored
healthy, not red. Resolution distinguishes "the organization list was readable
and contained nothing for this project" (nothing to govern) from "the
organization list was unreadable" (unknown, scores 0).

## Known limitations

- **Revoked apps and revoked keys are out of scope.** The `apps.list` endpoint
  defaults `status` and `keyStatus` to `approved`. The bundle sets
  `status=approved` explicitly so the filter is visible in the request rather
  than implied, but credentials revoked inside an approved app are not
  enumerated, so a dangling reference held only by a revoked key is not
  reported. Expiry checking is unaffected — a revoked key needs no rotation.
- **Developer listings cap at 1000.** `developers.list` rejects `expand` when
  combined with `count`/`startKey`, and the expanded form is required (without
  it the response carries email addresses only, with no `status` or
  `developerId`). Hitting the cap is reported as an issue and marks the
  dimension unreadable rather than analysing a partial organization silently.
- **SLX generation is project-scoped.** The generation rule matches every GCP
  project because the discovery indexer exposes no Apigee-specific resource
  type. Projects without Apigee therefore get an SLX; it scores healthy and
  raises nothing, but it is still an extra SLX. Scope it to an Apigee resource
  type if the indexer gains one.

## Notes

- Respect management API rate limits: the scripts use org-wide endpoints and
  honor the `APIPRODUCTS` / `DEVELOPER_APPS` filters. They do not build heavy
  analytics queries -- the sibling proxy bundle owns analytics depth.
- Listings are paginated (`pageToken` for apps, `startKey` for products) with a
  page cap and a non-advancing-cursor guard, so a looping server response fails
  the listing instead of spinning until the task timeout.
- Auth: the runbook activates the GCP service account via
  `gcloud auth activate-service-account`, and `apigee_common.sh` derives an
  OAuth access token via `gcloud auth print-access-token`. The activation is not
  suffixed with `|| true`: if it fails, every API call fails and that must
  surface as a failed dimension rather than a perfect score.

## Testing

`.test/offline/run-offline-tests.sh` runs the whole check suite against recorded
API responses with no credentials and no network. See `.test/README.md`.
