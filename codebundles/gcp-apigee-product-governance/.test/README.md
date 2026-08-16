# gcp-apigee-product-governance — Test Infrastructure

Four tiers. The credential-free ones gate every PR; the live tier and the
fixtures it depends on are human-triggered because they cost money and touch a
shared org.

| Tier | What it proves | Credentials | Command |
|---|---|---|---|
| **Offline** | Each check reports the defects it should, reports nothing on a healthy org, and the rule/templates/auth/naming stay as intended | none | `task test-offline` |
| **Render** | The templates actually render, and the org chain degrades instead of raising | none (needs `jinja2`, `pyyaml`) | `./render/run.sh` |
| **Structural** | Generation rules parse and match the schema | none | `task validate-generation-rules` |
| **Live** | The checks behave the same against real API responses | yes | `task test-live` |

## Render tier (`render/run.sh`)

Renders both templates through runwhen-local's exact jinja2 configuration —
`SandboxedEnvironment`, `trim_blocks`, `lstrip_blocks`, and a `CustomUndefined`
whose `__str__` returns a placeholder — then asserts on the output.

It exists because the offline tier *greps* the templates. Grepping catches a
regression whose shape is already known; it cannot catch the class.
`match_resource.resource.name` reads like a safe fallback and **raises**
instead, aborting the whole render. Rendering found that immediately; no amount
of grepping would have.

A render that raises is captured as a clean FAIL rather than a traceback —
raising is the failure mode under test, and a traceback would abort the
remaining cases and report nothing about them.

Without `jinja2`/`pyyaml` it **skips loudly** and says the templates were not
rendered. A tier that quietly reports success it did not earn is the exact
failure this work exists to prevent.

## Offline tier (`offline/run-offline-tests.sh`)

Runs every check script against recorded Apigee management API responses with
stubbed `curl`/`gcloud`. No network, no credentials, no cloud resources.

Every check is exercised **twice**: against a fixture broken in a known way (the
test fails if the check does not report it) and against a healthy fixture (the
test fails if the check reports anything). It also covers the states that are
easy to confuse:

- **cannot run** — every API call denied. Every check must emit
  `access_ok: false`, which is what makes the runbook raise a "could not run"
  issue. A check that returned an empty issue list *and* claimed success would
  let a blind run report perfect health.
- **no organization for this project** — also a failure, not a state. The
  generation rule gates on `gcp_apigee_organizations`, so an SLX exists only
  where an org is indexed; reaching this by direct invocation means the bundle
  was pointed at the wrong project. There is no `applicable` field and no
  not-applicable path — the case is deleted rather than handled, and the offline
  tier asserts the machinery stays gone.

Regression cases pin the specific bugs that shipped: `expiresAt: "-1"` meaning
*never expires* rather than *long expired*, the orphaned-product scan running
even when no app references anything, `expand=true` on the developer listing,
`includeCred=true` on the app listing, page-token following, a page token that
never advances, product names containing quotes and backslashes, and organization
resolution filtering on `projectId`.

### The stub rejects invalid parameter combinations

Fixtures encoding the right *response* are not enough — a stub that answers any
query it is handed will happily serve a request the real API refuses. That
happened: `pageSize` combined with `expand`/`includeCred`/`status` on
`apps.list` is a hard 400 from Apigee, and it survived the entire offline suite
before failing on a live org.

`stubs/curl` now returns 400 for the combinations the real API rejects:

| Endpoint | Rejected |
|---|---|
| `apps.list` | `pageSize`/`pageToken` alongside any of `expand`, `includeCred`, `status`, `keyStatus`, `rows`, `startKey`, `apiProduct`, `appType` |
| `developers.list` | `expand` alongside `count` or `startKey` |

Verified: reintroducing the `pageSize` bug now turns the offline suite red.
Add to this list whenever the API documents or demonstrates another mutually
exclusive combination — it is the cheapest place to catch that class of bug.

### Fixture provenance

Fixture field names, types and semantics come from the Apigee v1 discovery
document (`https://apigee.googleapis.com/$discovery/rest?version=v1`), **not**
from what the check scripts expect. Fixtures written from the implementation
encode its assumptions and pass while it is wrong. If a fixture is ever edited
to make a failing test pass, re-derive it from the discovery document first.

The fixtures deliberately reproduce the traps the real API sets: `expiresAt` as
an int64 **string** of epoch milliseconds with `-1` meaning non-expiring, the
lowercase `apiproduct` key inside `ApiProductRef`, list responses wrapped under
`apiProduct` / `app` / `developer`, and `nextPageToken` on the app listing.

One fixture is a **recorded real response**: `GET /v1/organizations` against a
project where the Apigee API is not enabled returns a bare `{}` with no
`organizations` key at all. That is a different code path from "key present but
holding no matching entry", and both are covered.

### Proving the suite can fail

The suite has been verified to go red when each covered bug is reintroduced —
non-expiring keys treated as expired, the orphan guard restored, `expand=true`
dropped, `includeCred=true` dropped, and a failed fetch degraded to `{}`.

The alignment assertions were mutation-tested the same way: reverting the gate
to bare `project`, `qualifiers` to `["project"]`, dropping boolean mode from the
org chain, reaching through `match_resource.resource.name` (caught by the
**render** tier, with the exact `UndefinedError` the grep-based tier cannot
see), reverting the `scope` tag, gating the suite on the activation returncode,
and reverting task and issue titles to the project.

Restore with a file copy, never `git checkout --` — that reverts genuine changes
alongside the mutation. Confirm each mutation actually applied before trusting
its result: one that silently patched nothing read as a pass, and one that
*did* pass exposed a missing assertion rather than a working one.

Re-run this exercise after changing the check logic; a suite only ever observed
passing has demonstrated nothing.

## Live tier

The inner Apigee objects are created via the management REST API by
`fixtures/create_entitlement_fixtures.sh` — Terraform has no first-class
provider for them. `terraform/` only resolves the project/org binding and is not
applied by any task.

| Fixture | State it must be in | Check it is the known-positive for |
|---|---|---|
| `<suffix>-healthy-api` | manual approval, quota 1000 | — (healthy) |
| `<suffix>-auto-approve` | `approvalType: auto`, no quota | product check (sev 2 + 3) |
| `<suffix>-orphaned` | referenced by no app | orphaned check (sev 4) |
| `<suffix>-healthy-app` | key expiring in ~900 days | — (healthy) |
| `<suffix>-expiring-app` | key expiring in ~10 days | credential check (sev 3) |
| `<suffix>-empty-app` | **no** consumer key | orphaned check (sev 4) |
| `<suffix>-dangling-app` | key references a non-existent product | developer check (sev 3) — **may be unprovisionable, see below** |
| `<suffix>-auto-app` | consumes the auto-approve product | product check (sev 2) |
| `governance-<suffix>@example.com` | **inactive** while owning apps | developer check (sev 3) |

Several need more than a create call, and the script does the extra work and
then asserts the result:

- Apigee **auto-generates a consumer key** when a developer app is created, so
  `empty-app` has its key explicitly deleted. Without that step the
  "app has no consumer keys" check has no fixture at all.
- The developer is **set inactive** via `setDeveloperStatus` (`action=inactive`,
  `Content-Type: application/octet-stream`, returns 204). Creating a developer
  leaves it `active`, so without this step `developer_status_drift` has no
  fixture.

### The dangling reference may not be reachable at all

`dangling_product_ref` is the one known-positive this harness cannot reliably
provision.

The intuitive construction — create a transient product, attach it to a key,
delete the product — **does not work**. Apigee enforces referential integrity in
both directions and refuses the delete:

```
HTTP 400: Unable to delete ApiProduct as there are one or more apps associated with it.
```

The script instead attaches a non-existent product directly via
`UpdateDeveloperAppKey`, then reads the app back to see whether the reference
took. Whether that endpoint validates the product's existence is not documented,
so this is an attempt, not a guarantee.

If the reference is absent afterwards, the script says so prominently and
continues rather than failing:

```
! <suffix>-dangling-app does NOT reference a non-existent product.
  CONSEQUENCE: dangling_product_ref has OFFLINE COVERAGE ONLY.
```

That is a deliberate trade. Failing the whole run over one unprovisionable
fixture blocks the live tier entirely and costs live coverage of the other four
checks — a worse outcome than one known-positive being offline-only. It is
never silent: the run ends with a coverage summary naming every known-positive
as present or absent. Set `REQUIRE_DANGLING_FIXTURE=1` to make its absence
fatal.

If it turns out the state is genuinely unreachable through the public API, the
honest conclusion is that `dangling_product_ref` is offline-tested by design —
record that here rather than leaving the fixture looking merely broken.

The script ends with a ground-truth pass that reads every object back and fails
non-zero if any fixture is not in the state it claims. A "broken" fixture that
provisions healthy silently removes the only thing under test.

`fixtures/delete_entitlement_fixtures.sh` verifies teardown by querying the
provider for anything still carrying the suffix, and exits non-zero if it finds
leftovers. This is a **shared** org: an abandoned product shows up as an
orphaned entitlement in every later run.

## Manual steps

These are deliberately not automated. For each: what to run, what it needs, and
what happens if you skip it.

### 1. Credential bootstrap — required before anything live

**Run:** create `.test/terraform/tf.secret`:

```bash
export TF_VAR_org_id="organizations/my-apigee-org"   # or APIGEE_ORG="my-apigee-org"
export TF_VAR_project_id="my-gcp-project"            # or GCP_PROJECT_ID="my-gcp-project"
export APIGEE_TEST_ENV="test"                        # an existing Apigee environment
export GOOGLE_APPLICATION_CREDENTIALS="/path/to/svc.json"
```

Also place the same key at `.test/gcp.json.secret` for RunWhen Local.

**Shared-organization contract.** All three Apigee bundles point at one Apigee X
organization (an org is one-per-project, so the environment bundle provisions it
and the others layer fixtures on top). `.test/terraform/tf.secret` is the
canonical location, matching the siblings, and `TF_VAR_org_id` /
`TF_VAR_project_id` are the canonical names — so one file can serve all three.

`load-credentials.sh` resolves every accepted spelling:

| Accepted | Notes |
|---|---|
| `.test/terraform/tf.secret` | canonical |
| `.test/tf.secret` | this bundle's original path; still works, warns |
| `TF_VAR_org_id` | `organizations/<org>` form |
| `APIGEE_ORG` | bare `<org>` form |

The `organizations/` prefix is stripped before use. The API paths this bundle
builds already carry that segment, so leaving it in yields
`organizations/organizations/<org>/…` and 404s every call — which scores the run
0 rather than producing a wrong answer, but breaks it outright.

An `APIGEE_ORG` or `GCP_PROJECT_ID` already exported in the shell still wins, but
if it disagrees with the file the loader says so. On a shared org a stale value
left over from another bundle's run would otherwise retarget this one silently.

**Needs:** a service account key. The harness authenticates *with* that key, so
it cannot be what creates it.

**If skipped:** `task build-infra`, `task test-live` and `task clean` all exit
non-zero with an explicit message. They do not silently continue.

### 2. The Apigee organization and environment

**Run:** create them in the GCP console, or via the environment bundle's
bootstrap.

**Needs:** an Apigee X org (one per project, provisioning-time limits) and an
environment named by `APIGEE_TEST_ENV`.

**If skipped:** `create_entitlement_fixtures.sh` fails its precondition check
with the name of the missing environment.

### 3. The live run

**Run:** `task build-infra && task test-live && task clean`

**Needs:** real spend and write access to the shared org.

**If skipped:** the offline tier still gates correctness. You lose confirmation
that real API responses match the recorded ones.

### Permissions by tier

| Tier | Role |
|---|---|
| Offline | none |
| Live checks | `roles/apigee.readOnlyAdmin` + `roles/apigee.analyticsViewer` |
| Fixture create/delete | `roles/apigee.admin` |

## Usage

```bash
cd .test

task test-offline               # no credentials needed
task validate-generation-rules  # needs curl, yq, ajv

# live path (needs tf.secret)
task build-infra
task test-live
task generate-rwl-config GCP_PROJECT_ID=my-gcp-project APIGEE_ORG=my-apigee-org RW_WORKSPACE=my-workspace
task run-rwl-discovery
task clean                      # verifies nothing with the suffix survives
```

`check-and-cleanup-terraform` is an alias for `check-and-cleanup-fixtures`, so a
cross-bundle cleanup loop can call one task name across all three Apigee
bundles. This bundle creates no Terraform resources — its fixtures are REST
objects — so `check-and-cleanup-fixtures` is the accurate name.

`task` (default) runs: test-offline → validate-generation-rules →
check-unpushed-commits → build-infra → generate-rwl-config → run-rwl-discovery.

## Requirements

- Offline tier: `bash`, `jq`
- Structural tier: `curl`, `yq`, `ajv`
- Live tier: `gcloud`, `curl`, `jq`, `docker`

`ajv` is absent from some devtools images, and `validate-generation-rules` exits
non-zero when it is. That is deliberate — a validator that warns and exits 0 is a
report, not a test — but it means `task default` stops there in such an image.
Run `task test-offline` directly to exercise the check logic, which needs only
`bash` and `jq`.

All shell scripts are `shellcheck -S style` clean and pass `bash -n`.
