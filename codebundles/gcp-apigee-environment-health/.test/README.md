# gcp-apigee-environment-health — Test Infrastructure

Tests discovery and template rendering for the `gcp-apigee-environment-health`
codebundle. Only one Apigee org is permitted per GCP project, and provisioning
takes 30-45+ minutes, so the org is a **long-lived shared** Apigee X test
organization shared across the Apigee bundle family. Terraform manages only the
inner resources; org creation is gated behind a manual bootstrap step that CI
never touches.

## What the fixtures create

`terraform/` provisions inner Apigee resources inside the shared org, covering
both healthy and broken states:

| Fixture | Type | State | Scenario |
|---|---|---|---|
| `apigee-env-healthy-*` | environment | healthy | ACTIVE env attached to two instances |
| `apigee-env-unattached-*` | environment | broken | env with **no** instance attachment (2) |
| `apigee-group-healthy-*` | envgroup | healthy | envgroup with routed hostname + attachment |
| `apigee-group-orphan-*` | envgroup | broken | envgroup with **no** attachment (3) |
| `apigee-inst-primary/secondary-*` | instances | healthy | two runtime instances |
| `apigee-ts-healthy-*` | target server | healthy | enabled, resolvable |
| `apigee-ts-disabled-*` | target server | broken | disabled (5a) |
| `apigee-ts-dangling-*` | target server | broken | non-resolving host (5b) |

Keystore/truststore aliases have **no Terraform resource**. The
`import-keystore-alias` task creates the healthy env's `default` keystore
(Apigee does not provision one implicitly) and then imports a valid (365-day)
and a short-dated (10-day) self-signed cert into it via the Apigee REST API,
covering the `expiring_keystore_cert` scenario (4). The task fails loudly if
either step does not land — a silently empty keystore makes the cert dimension
score a meaningless `1.0`.

## Usage

```bash
cd .test

# 1. Credentials: create terraform/tf.secret with:
#    export GOOGLE_APPLICATION_CREDENTIALS="/path/to/svc.json"
#    export TF_VAR_project_id="my-gcp-project"
#    export TF_VAR_org_id="my-apigee-org"
#    export TF_VAR_region="us-west1"
#    export TF_VAR_instance_region="us-central1"
#    export TF_VAR_resource_suffix="test001"
#    and place the same key at .test/gcp.json.secret for RunWhen Local / alias import

# 2. Provision fixtures (org must already exist)
task build-infra

# 3. Import the keystore alias fixtures
task import-keystore-alias

# 4. Generate config + run discovery + validate rules
task generate-rwl-config GCP_PROJECT_ID=my-gcp-project RW_WORKSPACE=my-workspace
task run-rwl-discovery
task validate-generation-rules

# 5. Review rendered templates
ls output/workspaces/

# 6. Tear everything down
task clean
```

`task` (default) runs the full flow: check-unpushed-commits → build-infra →
import-keystore-alias → generate-rwl-config → run-rwl-discovery →
validate-generation-rules.

## After a failed or interrupted apply

Apigee instance creation is a long-running operation. If `terraform apply` loses
connectivity while polling it (DNS failure, dropped HTTP/2 connection), the
instance can still finish creating server-side while never being recorded in
Terraform state. `terraform destroy` then walks straight past a **billable**
runtime instance.

Always reconcile before assuming a destroy was sufficient:

```bash
terraform state list | grep google_apigee_instance
curl -fsS -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  "https://apigee.googleapis.com/v1/organizations/${ORG}/instances" | jq -r '.instances[].name'
```

Import anything present in the org but missing from state, then destroy:

```bash
terraform import google_apigee_instance.secondary \
  organizations/${ORG}/instances/apigee-inst-secondary-${SUFFIX}
```

## Bootstrap note

The long-lived shared Apigee org is created once manually (never by CI) using
`gcloud apigee operations` / the Apigee provisioning flow. All bundles in the
Apigee family share this org via the `.test` Taskfile. The runtime instance +
environment provisioning here takes 30-45+ minutes on first apply.

## Requirements

- `terraform`, `gcloud`, `docker`, `jq`, `yq`, `ajv`, `curl`, `openssl`
- GCP service account with `roles/apigee.admin`, `roles/apigee.runtimeAdmin`,
  and `roles/apigee.analyticsAdmin` on the test project (used by Terraform to
  create the Apigee inner resources and by the bundle for read-only checks)
