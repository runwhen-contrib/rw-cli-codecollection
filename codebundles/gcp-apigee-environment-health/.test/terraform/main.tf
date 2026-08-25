# -----------------------------------------------------------------------------
# gcp-apigee-environment-health -- Test Infrastructure
#
# Terraform manages the project APIs, the Service Networking range, and the
# inner Apigee resources: environments, environment groups + attachments,
# runtime instances + attachments, and target servers.
#
# It does NOT create the Apigee organization -- there is no Terraform resource
# for that, and only one org is permitted per GCP project. Org creation is a
# manual bootstrap step (`task bootstrap-prerequisites`) that CI never touches.
#
# Fixtures deliberately include broken cases matching the design spec:
#   1. healthy_org            - ACTIVE env attached to an instance, an envgroup
#                               with a routed hostname, valid certs, reachable
#                               enabled target server
#   2. unattached env         - environment with NO instance attachment
#   3. orphan envgroup        - environment group with NO attachment / no hostname
#   4. expiring keystore cert - keystore alias with a short-dated certificate
#   5. dangling target        - target server disabled / unresolvable host
#
# Keystore/truststore aliases have no Terraform resource; they are imported via
# the Apigee REST API by the `import-keystore-alias` Taskfile task.
# -----------------------------------------------------------------------------

locals {
  suffix = var.resource_suffix
}
# --- Prerequisites -----------------------------------------------------------
# NOT HERE ANY MORE, and deliberately so.
#
# The enabled APIs, the peered VPC, the reserved Service Networking range and
# the peering connection used to be Terraform resources in this file. That made
# this bundle the owner of substrate the other four Apigee bundles sit on, and
# every one of them a silent guest: run gcp-apigee-proxy-health against a fresh
# project and its fixtures 404, because nothing in that bundle creates the org
# they hang off.
#
# They could not simply be copied into the other four, because five Terraform
# states cannot each `create` the same VPC, address and peering -- the second
# errors "already exists", since Terraform converges within a state and does
# not adopt what another state owns. That is the same shape as the two-states-
# one-API problem fixed in #733, and the reason a stray `terraform destroy`
# here used to take out substrate the siblings depended on (#745).
#
# Expressed as check-then-create over gcloud/REST there is no state to own, so
# the identical block lives in all five bundles:
#
#     .test/apigee_prerequisites.sh      (byte-identical, drift-checked by `task ci`)
#     task bootstrap-prerequisites
#     task destroy-prerequisites
#
# What remains in this file is only this bundle's OWN fixtures, which is what
# the rest of the family already looked like.

# --- Runtime instance and environments ---------------------------------------
# NOT HERE ANY MORE either, and for the same reason as the prerequisites above.
#
# `google_apigee_instance.primary`, both `google_apigee_environment` resources
# and the `healthy_primary` attachment moved into apigee_prerequisites.sh. They
# are SUBSTRATE, not this bundle's fixtures, because an EVALUATION organization
# is hard-capped:
#
#     the number of environments cannot exceed 2 for TRIAL subscription
#     the number of instance cannot exceed the limit 1
#
# Two environment slots and one instance slot, shared by five bundles. A capped
# resource is inherently shared, and a shared resource cannot belong to one
# bundle's fixtures -- four of the five need these environments and none of them
# could create its own even if it wanted to. Keeping them here made the other
# four silent guests of this bundle, exactly as the org did before C8.
#
# THE SUBSTRATE CONTRACT, and the invariant that
# `apigee-env-unattached-*` being unattached is a FIXTURE rather than a defect,
# are stated in apigee_prerequisites.sh. Read that before changing this.
#
# What remains below is only what this bundle genuinely owns: envgroups,
# envgroup attachments and target servers. All are uncapped and suffixed, so
# every bundle could have its own if it needed one.

locals {
  # The substrate environment, referenced by name rather than by resource. The
  # id form is deterministic -- organizations/{org}/environments/{name} -- so
  # nothing here needs a data source or a remote state lookup.
  healthy_env_name = "apigee-env-healthy-${local.suffix}"
  healthy_env_id   = "${var.org_id}/environments/apigee-env-healthy-${local.suffix}"
}

# The SECOND runtime instance is opt-in and defaults to off.
#
# It cannot be applied on an EVALUATION organization at all -- the instance cap
# is 1, so `terraform apply` failed on it every time, which is why this
# configuration had never completed end to end on an eval org. It is kept as a
# fixture for the multi-region failover dimension on a PAID organization, where
# it is meaningful; set enable_secondary_instance = true there.
resource "google_apigee_instance" "secondary" {
  count = var.enable_secondary_instance ? 1 : 0

  provider = google-beta
  name     = "apigee-inst-secondary-${local.suffix}"
  org_id   = var.org_id
  location = var.instance_region
}

resource "google_apigee_instance_attachment" "healthy_secondary" {
  count = var.enable_secondary_instance ? 1 : 0

  provider    = google-beta
  instance_id = google_apigee_instance.secondary[0].id
  environment = local.healthy_env_name
}

# --- Environment groups + attachments ---------------------------------------
# Scenario 1: healthy envgroup with a routed hostname attached to the healthy env
resource "google_apigee_envgroup" "healthy" {
  provider  = google-beta
  name      = "apigee-group-healthy-${local.suffix}"
  org_id    = var.org_id
  hostnames = ["api-example.${local.suffix}.example.com"]
}

resource "google_apigee_envgroup_attachment" "healthy" {
  provider    = google-beta
  envgroup_id = google_apigee_envgroup.healthy.id
  environment = local.healthy_env_name
}

# Scenario 3: orphan envgroup with NO attachment
resource "google_apigee_envgroup" "orphan" {
  provider  = google-beta
  name      = "apigee-group-orphan-${local.suffix}"
  org_id    = var.org_id
  hostnames = ["orphan-${local.suffix}.example.com"]
}

# --- Target servers ----------------------------------------------------------
# Scenario 1: enabled, resolvable target server
resource "google_apigee_target_server" "healthy" {
  provider   = google-beta
  name       = "apigee-ts-healthy-${local.suffix}"
  env_id     = local.healthy_env_id
  host       = "www.google.com"
  port       = 443
  is_enabled = true
  protocol   = "HTTP"
}

# Scenario 5a: disabled target server
resource "google_apigee_target_server" "disabled" {
  provider   = google-beta
  name       = "apigee-ts-disabled-${local.suffix}"
  env_id     = local.healthy_env_id
  host       = "www.google.com"
  port       = 443
  is_enabled = false
  protocol   = "HTTP"
}

# Scenario 5b: target server pointing at a non-resolving host
resource "google_apigee_target_server" "dangling" {
  provider   = google-beta
  name       = "apigee-ts-dangling-${local.suffix}"
  env_id     = local.healthy_env_id
  host       = "no-such-host-${local.suffix}.invalid"
  port       = 443
  is_enabled = true
  protocol   = "HTTP"
}
