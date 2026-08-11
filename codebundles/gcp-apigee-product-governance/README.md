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

## Discovery runs in suite setup, not as a task

Enumerating API products, developers and apps happens in `Suite Initialization`,
not as a task of its own. It raises no finding an operator would act on that a
check does not already raise, and a task is a unit of operator attention.

The gain is what happens when the organization cannot be read. As a task, every
check then failed on the same root cause — five red entries for one denied
credential. In setup it is **one** severity-2 issue naming the reason, and the
checks are not attempted.

Setup aborts on two conditions: the organization is unreadable, or discovery
left no status file at all — because without it there is no way to tell an empty
organization from an unreadable one. A project with **no** Apigee organization
is neither; setup logs that and the checks run and report nothing.

## Tasks Overview

Four tasks, each reporting findings no other can.

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

Also raises `developer_list_truncated` when the organization has more developers
than a single expanded listing returns, so a partially-evaluated organization
never reads as a fully-checked one.

## Runbook only — no SLI

This bundle ships a **runbook and no SLI**. The checks score configuration
drift, which moves on human timescales, so an interval poll bought little
freshness for a real Apigee management API bill — 9 calls per cycle against a
project with an organization, 4 against one without, multiplied by every
project because the generation rule still over-generates.

Nothing is lost diagnostically. The runbook runs the same five scripts and
reports every finding the SLI used to score; the SLI only ever counted the
issues these scripts already produce.

`sli.robot` is deliberately retained and still exercised by the offline tier.
Reintroducing the SLI means restoring `- type: sli` to the generation rule and
its template — a two-line change, not a rewrite. Prefer doing that after the
rule gates on `gcp_apigee_organizations`, so the poll only lands on projects
that actually run Apigee.

## How failure is reported

Each check writes a `<prefix>_status.json` sidecar carrying `access_ok`, and
three states are kept distinct:

| State | Issues file | `access_ok` | What the runbook reports |
|---|---|---|---|
| Ran, found nothing | `[]` | `true` | nothing — genuinely clean |
| Ran, found problems | populated | `true` | each finding |
| **Could not read the API** | `[]` | `false` | a severity-2 "could not run" issue |

That third row is the one that matters. A check which cannot reach the API
writes an **empty** issues array, so reading only the issues file would make a
blind check indistinguishable from a clean one. The runbook's
`Report Access Failure` keyword reads the sidecar for every task and raises an
issue naming the reason.

This used to be the SLI's job — it scored such a dimension 0. With no SLI, the
runbook consumes the sidecar itself, so the signal has a consumer either way.
The offline tier asserts the wiring is present for all five tasks and has been
verified to fail if it is removed.

## Projects without Apigee

**INTERIM behaviour.** The generation rule matches every GCP project, so this
bundle also runs against projects that have never used Apigee. There, the
runbook reports **no findings** and says so explicitly:

    Not applicable: the Apigee organization list is readable and contains no
    organization for this project.

That is correct by vacuity — there is no entitlement surface to be unhealthy.
A clean run therefore means *either* "the entitlement layer is well governed"
*or* "there is no entitlement layer here"; the discovery task's output and the
`applicable` field in each `<prefix>_status.json` distinguish them.

The safety of that rests entirely on **never confusing "no Apigee here" with
"could not find out"**:

| Situation | Determination | Result |
|---|---|---|
| Organizations list returns 200, no org for this project | definite absence | `applicable=false`, no issue raised |
| 403/404 whose body says `SERVICE_DISABLED`, `has not been used in project`, `accessNotConfigured`, or `API has not been used` | definite absence — the API was never enabled, so no org can exist | `applicable=false`, no issue raised |
| Plain `PERMISSION_DENIED`, network error, unparseable body, any other status | **failure to determine** | severity-2 issue raised |

`applicable=false` is only ever set on a definite answer, never on a failed
lookup, so this cannot resurrect the healthy-while-blind reporting the bundle
was fixed to remove. The absence match is deliberately narrow — **do not widen it to
include bare `PERMISSION_DENIED`**; that would make an under-permissioned
service account report every project as empty and score 1.0. The offline tier
has an assertion specifically to catch that (scenario H), and it has been
verified to go red under exactly that mutation.

This whole mechanism is designed to be **deleted**, not maintained. Once the
indexer exposes `gcp_apigee_organizations` the generation rule gates on it, the
SLX only exists where an organization is indexed, and absence can no longer
occur. Search the bundle for `INTERIM` to find every site to remove.

## Issue hygiene

Two properties the offline tier enforces, both verified to fail if broken.

**No credential material in issue fields.** For products using `VerifyAPIKey`
the consumer key *is* the credential, not merely an identifier, and issue titles
propagate furthest — dashboards, notifications, chat. Credentials are therefore
identified by their **issue date**, which is non-secret and stable for the life
of the key:

```
Consumer key issued 2026-01-23 on app `payments-api` expires within 30 days
```

Note the discovery snapshot (`entitlements_discovery.json`) still holds the raw
API response, including full consumer keys and secrets. It is a working-
directory artifact rather than a reported field, but treat it as sensitive if
artifacts are ever persisted or uploaded.

**Titles are stable between runs.** A title carrying a live countdown changes
every day, so the platform sees a brand-new issue each run — no deduplication,
no age tracking, and a fresh alert daily for one unchanged problem. Titles name
the configured warning *window*; the live countdown lives in `details` and
`actual`, which are expected to reflect current state.

Everything interpolated into a title is either a resource name, a configured
threshold, or a resource's own state — never a timestamp, count, or duration
derived from the moment of the run.

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
  `developerId`). Hitting the cap raises a `developer_list_truncated` issue
  (severity 3) from the developer-status check. The developers that *were*
  returned are still analysed and their findings still reported — the list is
  incomplete, not unreadable, so `access_ok` stays true. Dangling-reference
  findings are unaffected: they derive from the app list, which does paginate.
- **SLX generation is project-scoped.** The generation rule matches every GCP
  project because the indexer exposes no Apigee resource type — the GCP resource
  catalog is generated from CloudQuery's table list, which has no Apigee tables,
  so `gcp_apigee_organizations` has to be added through runwhen-local's
  resource-type overrides (CAI asset type
  `apigee.googleapis.com/Organization`). Projects without Apigee still get an
  SLX; see "Projects without Apigee" above for how they score and how to filter
  them out. Note those override-derived types land in the **generic** tier, so
  they are only discoverable in workspaces with Cloud Asset Inventory enabled.

## Notes

- Respect management API rate limits: the scripts use org-wide endpoints and
  honor the `APIPRODUCTS` / `DEVELOPER_APPS` filters. They do not build heavy
  analytics queries -- the sibling proxy bundle owns analytics depth.
- Listings are paginated with `startKey` for both apps and products (`rows` and
  `count` respectively), plus a page cap and a non-advancing-cursor guard. The
  newer `pageSize`/`pageToken` parameters are NOT used: the real API rejects
  them alongside `expand`/`includeCred`/`status`, which this bundle requires.
  A looping server response fails the listing rather than spinning until the
  task timeout.
- Auth: the runbook activates the GCP service account via
  `gcloud auth activate-service-account`, and `apigee_common.sh` derives an
  OAuth access token via `gcloud auth print-access-token`. The activation is not
  suffixed with `|| true`: if it fails, every API call fails and that must
  surface as a failed dimension rather than a perfect score.

## Testing

`.test/offline/run-offline-tests.sh` runs the whole check suite against recorded
API responses with no credentials and no network. See `.test/README.md`.
