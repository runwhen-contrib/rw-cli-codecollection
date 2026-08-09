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
#    export TF_VAR_org_id="organizations/my-apigee-org"   # organizations/{org} form
#    export TF_VAR_region="us-west1"
#    export TF_VAR_instance_region="us-central1"
#    export TF_VAR_resource_suffix="test001"
#    # only used by bootstrap-prerequisites:
#    export APIGEE_NETWORK="default"                      # VPC to peer with
#    # export APIGEE_DISABLE_VPC_PEERING="true"           # skip peering entirely
#    and place the same key at .test/gcp.json.secret for RunWhen Local / alias import

# 2. One-time per project: APIs, peering range, Apigee org (see Prerequisites)
task bootstrap-prerequisites

# 3. Provision fixtures (org must already exist)
task build-infra

# 4. Import the keystore alias fixtures
task import-keystore-alias

# 5. Generate config + run discovery + validate rules
task generate-rwl-config GCP_PROJECT_ID=my-gcp-project RW_WORKSPACE=my-workspace
task run-rwl-discovery
task validate-generation-rules

# 6. Review rendered templates
ls output/workspaces/

# 7. Tear down the fixtures (NOT the org/peering -- see Prerequisites)
task clean
```

`TF_VAR_org_id` must be in `organizations/{org}` form: that is what the
`google_apigee_*` resources expect. Anywhere a bare name is needed the harness
strips the prefix itself.

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

## Service networking range sizing

`main.tf` provisions **two** runtime instances (`primary` in `var.region`,
`secondary` in `var.instance_region`) so the regional-failover fixture has two
regions to span. Apigee needs a non-overlapping **/22 per instance**, so the
reserved service-networking range must cover both — a single `/21`, or two
separate `/22` reservations.

Reserving only one `/22` provisions the first instance and then fails the
second with:

```
service networking config invalid: failed precondition: reserve additional IP
ranges in service networking as there is insufficient IP space to launch a new
Apigee instance: RANGES_EXHAUSTED
```

That leaves a **single-instance** org, in which the "no regional failover"
finding is a correct observation about the topology that actually exists — but
the two-instance failover fixture has not been exercised as intended. Check the
reserved range before treating that particular result as meaningful.

## Prerequisites (one-time per project)

`terraform apply` fails on the first `google_apigee_*` resource unless three
things already exist. `task bootstrap-prerequisites` creates all three and is
idempotent, so it is safe to re-run:

1. **APIs enabled** — `apigee`, `apigeeconnect`, `servicenetworking`
2. **Peering range reserved and connected** — a `/21` by default, per the range
   sizing above (skipped entirely when `APIGEE_DISABLE_VPC_PEERING=true`)
3. **The Apigee organization** — created as `billingType: EVALUATION`, which is
   free and sufficient for every fixture here

```bash
task bootstrap-prerequisites
```

The equivalent by hand, if you would rather not run the task:

```bash
gcloud services enable apigee.googleapis.com apigeeconnect.googleapis.com \
    servicenetworking.googleapis.com --project=$PROJECT

gcloud compute addresses create apigee-peering --global --prefix-length=21 \
    --purpose=VPC_PEERING --network=$NETWORK --project=$PROJECT
gcloud services vpc-peerings connect --service=servicenetworking.googleapis.com \
    --ranges=apigee-peering --network=$NETWORK --project=$PROJECT

curl -s -X POST -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H "Content-Type: application/json" \
  "https://apigee.googleapis.com/v1/organizations?parent=projects/$PROJECT" \
  -d '{"name":"'$PROJECT'","analyticsRegion":"us-west1","runtimeType":"CLOUD",
       "billingType":"EVALUATION","authorizedNetwork":"'$NETWORK'"}'
```

`gcloud alpha apigee` is deliberately not used: it needs a component install
that is not present in the `codecollection-devtools` image.

### Why this is not part of `default` or `clean`

The Apigee org is **long-lived and shared** across the whole Apigee bundle
family, and only one org is permitted per GCP project. If the APIs, peering
range and org were ordinary Terraform resources in `main.tf`, `task clean` in
this bundle would destroy infrastructure that sibling bundles depend on. So
`bootstrap-prerequisites` is opt-in, `clean` tears down only this bundle's
fixtures, and removing the prerequisites is a deliberate manual act.

Org creation takes roughly **4 minutes** for an EVALUATION org. The slow part is
runtime instance provisioning in `build-infra`, which takes 30-45+ minutes per
instance on first apply.

## Requirements

- `terraform`, `gcloud`, `docker`, `jq`, `yq`, `ajv`, `curl`, `openssl`
- For the **fixtures** (`build-infra` onward): a GCP service account with
  `roles/apigee.admin`, `roles/apigee.runtimeAdmin` and
  `roles/apigee.analyticsAdmin` on the test project — enough for the inner
  Apigee resources Terraform creates and the bundle's read-only checks.
- For **`bootstrap-prerequisites`**: more than the roles above. Enabling APIs
  needs `roles/serviceusage.serviceUsageAdmin`, reserving the range and
  connecting peering needs `roles/compute.networkAdmin`, and creating the
  organization needs `roles/apigee.admin` plus project-level rights that in
  practice mean `roles/owner`. This step is expected to be run by a human with
  elevated access, not by CI.
