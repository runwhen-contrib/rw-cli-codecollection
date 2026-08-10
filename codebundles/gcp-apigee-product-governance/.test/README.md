# gcp-apigee-product-governance — Test Infrastructure

Three tiers. The offline tier gates every PR; the live tier and the fixtures it
depends on are human-triggered because they cost money and touch a shared org.

| Tier | What it proves | Credentials | Command |
|---|---|---|---|
| **Offline** | Each check reports the defects it should, and reports nothing on a healthy org | none | `task test-offline` |
| **Structural** | Generation rules parse and match the schema | none | `task validate-generation-rules` |
| **Live** | The checks behave the same against real API responses | yes | `task test-live` |

## Offline tier (`offline/run-offline-tests.sh`)

Runs every check script against recorded Apigee management API responses with
stubbed `curl`/`gcloud`. No network, no credentials, no cloud resources.

Every check is exercised **twice**: against a fixture broken in a known way (the
test fails if the check does not report it) and against a healthy fixture (the
test fails if the check reports anything). It also covers the states that are
easy to confuse:

- **cannot run** — every API call denied. Every check must emit
  `access_ok: false` so the SLI scores that dimension 0. A check that returned
  an empty issue list *and* claimed success would let a blind run report perfect
  health.
- **not applicable** — the organization list is readable but this project has no
  Apigee organization. This must score healthy, not red: the bundle is generated
  for every GCP project and most projects do not use Apigee.

Regression cases pin the specific bugs that shipped: `expiresAt: "-1"` meaning
*never expires* rather than *long expired*, the orphaned-product scan running
even when no app references anything, `expand=true` on the developer listing,
`includeCred=true` on the app listing, page-token following, a page token that
never advances, product names containing quotes and backslashes, and organization
resolution filtering on `projectId`.

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

### Proving the suite can fail

The suite has been verified to go red when each covered bug is reintroduced —
non-expiring keys treated as expired, the orphan guard restored, `expand=true`
dropped, `includeCred=true` dropped, a failed fetch degraded to `{}`, and an
unreadable organization list treated as "no Apigee here". Re-run that exercise
after changing the check logic; a suite only ever observed passing has
demonstrated nothing.

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
| `<suffix>-dangling-app` | key references a deleted product | developer check (sev 3) |
| `<suffix>-auto-app` | consumes the auto-approve product | product check (sev 2) |

Two of these need more than a create call, and the script does the extra work
and then asserts the result:

- Apigee **auto-generates a consumer key** when a developer app is created, so
  `empty-app` has its key explicitly deleted. Without that step the
  "app has no consumer keys" check has no fixture at all.
- Apigee **validates the product list** at app-creation time, so `dangling-app`
  is attached to a real `<suffix>-transient` product which is then deleted,
  leaving the reference dangling.

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

**Run:** create `.test/tf.secret`:

```bash
export APIGEE_ORG="my-apigee-org"
export GCP_PROJECT_ID="my-gcp-project"
export APIGEE_TEST_ENV="test"        # an existing Apigee environment
export GOOGLE_APPLICATION_CREDENTIALS="/path/to/svc.json"
```

Also place the same key at `.test/gcp.json.secret` for RunWhen Local.

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

`task` (default) runs: test-offline → validate-generation-rules →
check-unpushed-commits → build-infra → generate-rwl-config → run-rwl-discovery.

## Requirements

- Offline tier: `bash`, `jq`
- Structural tier: `curl`, `yq`, `ajv`
- Live tier: `gcloud`, `curl`, `jq`, `docker`
