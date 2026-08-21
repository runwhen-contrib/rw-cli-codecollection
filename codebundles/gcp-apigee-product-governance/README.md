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
organization from an unreadable one.

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
freshness for a real Apigee management API bill — around 9 calls per cycle per
organization.

Nothing is lost diagnostically. The runbook runs the same five scripts and
reports every finding the SLI used to score; the SLI only ever counted the
issues these scripts already produce.

`sli.robot` is deliberately retained and still exercised by the offline tier.
Reintroducing the SLI means restoring `- type: sli` to the generation rule and
its template — a two-line change, not a rewrite. Now that the rule gates on
`gcp_apigee_organizations` the poll only lands where Apigee is actually in use,
so the cost argument is much weaker than it was; reintroduce it once the scoring
model has been validated against real orgs.

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
The offline tier asserts the wiring is present for every task and has been
verified to fail if it is removed.

## The SLX is anchored on the Apigee organization

The generation rule gates on `gcp_apigee_organizations`, so an SLX is created
only where an organization is actually indexed — one per org, and an Apigee org
is one-per-project.

That deletes a whole class of problem rather than handling it. This bundle used
to gate on bare `project`, which generated an SLX for every indexed project in
the workspace, most of which have no Apigee at all; the runtime "no Apigee here"
special-casing existed purely to stop those going red. Both are gone. A project
with no organization can no longer produce an SLX, and reaching that state by
direct invocation is reported as the error it is.

`qualifiers: ["resource"]` — not `["project"]` — anchors the SLX on the org.
runwhen-local's `gcp-hierarchy.yaml` inserts `project_id` into the path only
when `resource` is a qualifier, so `["resource"]` yields `gcp/<project>/<org>`,
the real containment hierarchy, while `["project"]` flattens it to
`gcp/<project>` and never names the org. Not both: the SLX name is built from
the qualifier values and an Apigee org is named after its project, so listing
both renders `<project>-<project>-<bundle>-<hash>`.

Consequently **every surface names the org** — task titles, task tags, issue
titles, the SLX alias, the taskset description, and the `scope` tag. The one
deliberate exception is the issue raised *because the organization could not be
determined*, where the project is the only identifier that exists.

### How APIGEE_ORG is resolved

The matched resource **is** the organization, so its name is known at render
time and both templates resolve it identically:

```jinja
{% set _res = match_resource.resource | default({}, true) %}
{% set apigee_org = custom.apigee_org | default(_res.name, true) | default(qualifiers.resource, true) | default(match_resource.name, true) | default('', true) %}
```

Two things in that expression are load-bearing, and both caused real silent
defects in the sibling bundle:

- **Every `default` is in boolean mode (the `, true`).** Plain `default()`
  substitutes only for an *undefined* value, never an empty one, so a
  workspaceInfo declaring `apigee_org: ""` renders `APIGEE_ORG` empty and skips
  every fallback. Same trap as jq's `//`, which also falls through on `false`.
- **`_res` is materialised before its fields are read.** runwhen-local's
  `CustomUndefined` subclasses plain `jinja2.Undefined`, whose `__getattr__`
  **raises** — so `match_resource.resource.name` inline aborts the *entire
  render* with `UndefinedError` whenever `.resource` is absent, instead of
  falling through. Defaulting the intermediate to `{}` keeps every attribute
  access on a real mapping.

`qualifiers.resource` is in the chain because `gcp-tags.yaml` renders the
`resource_name` tag from that same expression; sharing the source is what stops
the tag and the config value naming different things.

A run-time lookup remains for direct invocation only, and selects the org by
matching the response's own `projectId` — the list endpoint is
credential-scoped, so taking the first entry can report on another project's
org. See "Which organization a project reports on" below.

## Authentication gates on the token, not the activation

Three steps, in order:

1. **Activation, tolerant** (`|| true`). The runner may already carry a usable
   identity via workload identity, making a failed activation cosmetic — which
   is why every other GCP bundle here suffixes it the same way. Gating the suite
   on this call's exit code took a whole live run down in the sibling bundle,
   with every task NOT RUN.
2. **Key-shape probe**, emitting one of `KEY_JSON` / `KEY_NOT_JSON` /
   `KEY_EMPTY` / `KEY_MISSING`. gcloud's *"Missing required argument [ACCOUNT]
   ... .p12 keys"* does **not** mean the key is a p12 — it means `json.load()`
   failed and gcloud guessed. That one message covers three different things to
   go fix, the usual being a base64-encoded key stored without decoding. The
   probe emits only the sentinel; no byte of the key is echoed, logged or put in
   an issue.
3. **Token probe, strict.** `gcloud auth print-access-token` is the gate: it
   asserts the capability every downstream call depends on, rather than the
   mechanism that usually supplies it. On failure it raises a severity-1 issue
   carrying the key shape and both stderr streams, then fails the suite.

holds across task names, tags and issues, matching the sibling bundles. The
organization name still appears in issue `details`.

## Issues are org-level, not per-resource

The SLX is generated **per organization**, so it does not represent one app or
one product. Issues follow: each describes an org-level *condition*, and every
resource exhibiting it is an occurrence of that one issue.

Three apps referencing missing products produce **one** issue, not three:

```
title:   Developer apps reference non-existent API products in org `acme-apis`
actual:  3 dangling reference(s) across app(s): app-a, app-b, app-c
details: 3 credential association(s) in org `acme-apis` point at API products
         that no longer exist. ...

         Affected apps:
           - `app-a` -- the credential issued 2026-01-23 references missing product `ghost-1`
           - `app-b` -- the credential issued 2026-01-23 references missing product `ghost-2`
           - `app-c` -- the credential issued 2026-01-23 references missing product `ghost-1`
```

Each issue also carries machine-readable fields: `affected_count`, and `apps`,
`products` or `developers` as applicable.

**The title names neither a resource nor a count.** Both change as the affected
set changes, and a changing title is a new issue to the platform — losing
deduplication and age tracking, exactly as a live countdown would. A configured
threshold *is* allowed in a title (`expire within 30 days`) because it only
changes when someone changes the configuration.

Long lists are capped in `details` at 50 entries and in `actual` at 10, with the
full count always stated, so an org with hundreds of orphaned products stays
readable.

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

**Secrets are stripped at fetch, not at write.** `apigee_redact` removes
credential material from every listing the moment it is retrieved, so it never
reaches a shell variable, a report, an issue field or an on-disk artifact —
including the discovery snapshot. Redacting only where data is written would
leave every future consumer one mistake away from leaking it.

| Removed | Why |
|---|---|
| `consumerKey` | For `VerifyAPIKey` products this **is** the credential |
| `consumerSecret` | The OAuth client secret |
| `attributes` (products, developers, credentials) | Free-form key/values with no schema — operators do stash secrets there |

Kept because the checks need them and none is secret: `name`, `appId`,
`developerId`, `status`, `issuedAt`, `expiresAt`, `apiProducts`, `scopes`.
Nothing in this bundle reads a consumer key; if a future check genuinely needs
one, fetch it in that check rather than widening the filter.

The offline tier sweeps every artifact each check produces — issues, sidecars,
snapshot, stdout and stderr — for planted credential values, and is verified to
fail if redaction is removed or narrowed.

No script uses `curl -v`/`--trace`, so the bearer token is never written to
logs, and the token itself is never echoed.

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
- **Discovering the organization needs Cloud Asset Inventory.**
  `gcp_apigee_organizations` reaches the indexer through runwhen-local's
  resource-type overrides (CAI asset type `apigee.googleapis.com/Organization`),
  and those land in the **generic** tier. In a workspace without CAI enabled
  nothing matches the gate and no SLX is generated at all. The failure mode is
  silence rather than a wrong answer — but it is silence, so confirm CAI is on
  before concluding the bundle does not apply.

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

Two credential-free tiers gate every change:

```sh
./.test/offline/run.sh    # check logic + static assertions
./.test/render/run.sh                   # renders the templates for real
```

**Offline** runs every check against recorded API responses — no credentials, no
network — and adds static assertions over the generation rule, both templates,
the auth block and the naming. It strips comments before matching: the rule and
the templates explain these traps in prose that contains the very strings being
searched for, so matching the whole file passes even when the code is reverted.

**Render** exists because the offline tier *greps* the templates. Grepping
catches a regression whose shape is already known; it cannot catch the class.
`match_resource.resource.name` reads like a safe fallback and raises instead —
rendering found that immediately, and no amount of grepping would have. It needs
`jinja2` and `pyyaml`, and **skips loudly** when they are absent rather than
reporting a success it did not earn.

Every assertion in both tiers has been mutation-tested: the defect it guards was
reintroduced and the tier confirmed to go red. See `.test/README.md`.
