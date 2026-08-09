# gcp-apigee-environment-health — Test Infrastructure

Tests discovery and template rendering for the `gcp-apigee-environment-health`
codebundle. Only one Apigee X org is permitted per GCP project and Terraform has
no resource to create one, so org creation is a manual bootstrap step that CI
never touches — see [Prerequisites](#prerequisites-one-time-per-project).
Everything else, including the APIs and the Service Networking range the org
depends on, is managed by Terraform.

The org is intended to be reused by any future Apigee bundles in this
collection, since the one-per-project limit makes a dedicated org per bundle
impossible. No such sibling bundles exist yet.

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
#    export TF_VAR_network="default"                      # VPC to peer with
#    # export TF_VAR_disable_vpc_peering="true"           # skip peering entirely
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

# 7. Tear down everything Terraform manages (NOT the org -- see Prerequisites)
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

Three things must exist before the Apigee fixtures can be created. Two are
ordinary Terraform resources in `main.tf`; the third is not.

| Prerequisite | Managed by |
|---|---|
| APIs: `apigee`, `apigeeconnect`, `servicenetworking` | `google_project_service.required` |
| Reserved `/21` range + Service Networking connection | `google_compute_global_address` + `google_service_networking_connection` |
| The Apigee **organization** | manual — see below |

```bash
task bootstrap-prerequisites
```

That task applies only the prerequisite resources, then creates the org and
polls it to `ACTIVE`. It is idempotent, so it is safe to re-run.

### Why the org is still manual

Terraform has no resource for creating an Apigee X organization, and only one
org is permitted per GCP project. That creates an ordering problem: the rest of
`main.tf` cannot be applied until the org exists, but the APIs and peering must
exist before the org can be created. `bootstrap-prerequisites` resolves it by
applying just the prerequisite subset first:

```bash
terraform apply -target=google_project_service.required \
                -target=google_compute_global_address.apigee_peering \
                -target=google_service_networking_connection.apigee
```

then creating the org over REST (`billingType: EVALUATION`, which is free and
sufficient for every fixture here) and waiting for `ACTIVE` — roughly **4
minutes**. After that a normal `task build-infra` applies the rest.

`gcloud alpha apigee` is deliberately not used: it needs a component install
that is not present in the `codecollection-devtools` image.

### What `task clean` does and does not remove

`terraform destroy` removes the fixtures, the peering connection and the
reserved range. It does **not**:

- **Disable the APIs.** `google_project_service.required` sets
  `disable_on_destroy = false`, because the organization is not managed by
  Terraform and outlives `clean`; disabling the Apigee API underneath a live
  org is unsafe. Disable them by hand as part of deleting the org.
- **Delete the organization.** Deleting it is a deliberate manual act:

  ```bash
  curl -X DELETE -H "Authorization: Bearer $(gcloud auth print-access-token)" \
    "https://apigee.googleapis.com/v1/organizations/${ORG}"
  ```

Destroy order matters: both runtime instances `depends_on` the Service
Networking connection, so Terraform tears the instances down before the peering
they sit on. Deleting the peering while instances still exist will fail.

Org creation takes roughly **4 minutes** for an EVALUATION org. The slow part is
runtime instance provisioning in `build-infra`, which takes 30-45+ minutes per
instance on first apply.

## What this harness does NOT do

`.test` is not self-sufficient on a bare GCP project. Everything below must
exist or be done by hand; nothing here creates it.

**Before the first run:**

1. **A GCP project with billing enabled.** Not created by anything here.
2. **A VPC network.** `main.tf` references
   `projects/{project}/global/networks/{var.network}` but does not create it.
   The auto-created `default` network satisfies this; a custom network, or a
   project whose `default` was deleted, needs one made first.
3. **A service account and its JSON key**, placed at *both*
   `terraform/tf.secret` (as `GOOGLE_APPLICATION_CREDENTIALS`) and
   `.test/gcp.json.secret` (read by RunWhen Local at `/shared/gcp.json.secret`).
   No task generates or copies these.
4. **IAM grants on that service account** — see Requirements below. The
   prerequisite step needs more than the fixture step does.
5. **Commit and push your changes.** `check-unpushed-commits` fails the run
   otherwise, because RunWhen Local discovery clones the branch from the
   remote rather than reading your working tree.

**During the run:**

6. **`GCP_PROJECT_ID` must be passed to `generate-rwl-config`** — it has no
   default: `task generate-rwl-config GCP_PROJECT_ID=my-project`.
7. **Docker, plus passwordless `sudo`.** `run-rwl-discovery` runs
   `sudo rm -rf output` and starts the `runwhen-local` container.
8. **Network egress.** `validate-generation-rules` fetches its JSON schema from
   raw.githubusercontent.com at run time.
9. **`RW_WORKSPACE` / `RW_API_URL` / `RW_PAT`** — only for the optional
   `upload-slxs` / `delete-slxs` tasks against a real RunWhen Platform
   workspace. Not needed for local discovery and validation.

**After the run — `task clean` does not do these:**

10. **Delete the Apigee organization** (see above for the `curl -X DELETE`).
11. **Disable the three APIs**, deliberately, via `disable_on_destroy = false`.
12. **Release the reserved range if the org outlives it** — `terraform destroy`
    removes the range and connection it created, but if you deleted state or
    an apply was interrupted, reconcile by hand as described above.

Keeping `TF_VAR_resource_suffix` distinct per run is what makes concurrent or
repeated runs safe; every fixture name is built from it.

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
