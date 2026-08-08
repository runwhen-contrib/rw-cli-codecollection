# gcp-apigee-product-governance — Test Infrastructure

Tests discovery and template rendering for the
`gcp-apigee-product-governance` codebundle using the **shared, long-lived
Apigee X test organization** that the environment bundle's bootstrap owns.

## What the fixtures create

The inner Apigee objects (products, developers, apps) are created via the
management REST API by `fixtures/create_entitlement_fixtures.sh` — they are
**not** hand-deployed by Terraform (Apigee has no first-class Terraform provider
for these). Terraform in `terraform/` only resolves the project/org binding.

The fixtures deliberately include broken cases so every governance path is
exercised:

| Fixture | Purpose | Detected by |
|---|---|---|
| `<suffix>-healthy-api` (manual + quota) | Healthy product | (no issue) |
| `<suffix>-auto-approve` (auto + no quota) | Over-permissive product | product check (sev 2/3) |
| `<suffix>-orphaned` (no apps) | Orphaned product | orphaned check (sev 4) |
| `governance-<suffix>@example.com` | Active developer | — |
| `<suffix>-healthy-app` (long-dated key) | Healthy app/key | (no issue) |
| `<suffix>-expiring-app` (short-lived key) | Expiring consumer key | credential check (sev 3) |
| `<suffix>-empty-app` (no key) | No-consumer-key app | orphaned check (sev 4) |
| `<suffix>-dangling-app` (references missing product) | Dangling ref | developer check (sev 3) |
| `<suffix>-auto-app` (on auto-approve product) | Auto-approval consumption | product check (sev 2) |

Set consumer-key expiries to the state you want (already-expired vs expiring
within the window) either at key-creation time or via the Apigee console.

## Usage

```bash
cd .test

# 1. Credentials: create terraform/tf.secret with:
#    export APIGEE_ORG="my-apigee-org"
#    export GCP_PROJECT_ID="my-gcp-project"
#    export GOOGLE_APPLICATION_CREDENTIALS="/path/to/svc.json"
#    and place the same key at .test/gcp.json.secret for RunWhen Local

# 2. Provision fixtures
task build-infra

# 3. Generate config + run discovery + validate rules
task generate-rwl-config GCP_PROJECT_ID=my-gcp-project APIGEE_ORG=my-apigee-org RW_WORKSPACE=my-workspace
task run-rwl-discovery
task validate-generation-rules

# 4. Review rendered templates
ls output/workspaces/

# 5. Tear everything down
task clean
```

`task` (default) runs: check-unpushed-commits → build-infra →
generate-rwl-config → run-rwl-discovery → validate-generation-rules.

## Requirements

- `gcloud`, `curl`, `jq`, `docker`, `yq`, `ajv`
- A GCP service account with `roles/apigee.admin` (fixture creation) and
  `roles/apigee.readOnlyAdmin` / `roles/apigee.analyticsViewer` (for the checks)
  on the Apigee organization.
