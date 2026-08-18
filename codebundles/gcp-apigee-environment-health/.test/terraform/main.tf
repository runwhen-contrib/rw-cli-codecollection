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

# --- Runtime instances -------------------------------------------------------
# Apigee X runtime instances live at the org level. They consume the reserved
# peering range, which `task bootstrap-prerequisites` establishes before the
# organization exists -- so by the time this state can be applied at all, the
# peering is already in place and there is nothing here to depend on.
#
# The destroy ordering the old depends_on bought is now enforced the other way
# round, and more strongly: destroy-prerequisites REFUSES to remove the peering
# while the organization still exists, and deleting the organization deletes
# these instances with it.
resource "google_apigee_instance" "primary" {
  provider   = google-beta
  name       = "apigee-inst-primary-${local.suffix}"
  org_id     = var.org_id
  location   = var.region
}

resource "google_apigee_instance" "secondary" {
  provider   = google-beta
  name       = "apigee-inst-secondary-${local.suffix}"
  org_id     = var.org_id
  location   = var.instance_region
}

# --- Environments ------------------------------------------------------------
resource "google_apigee_environment" "healthy" {
  provider   = google-beta
  name       = "apigee-env-healthy-${local.suffix}"
  org_id     = var.org_id
}

# Scenario 2: environment with NO instance attachment
resource "google_apigee_environment" "unattached" {
  provider   = google-beta
  name       = "apigee-env-unattached-${local.suffix}"
  org_id     = var.org_id
}

# --- Instance attachments ----------------------------------------------------
# healthy env is attached to both primary and secondary instances (failover-OK)
resource "google_apigee_instance_attachment" "healthy_primary" {
  provider   = google-beta
  instance_id = google_apigee_instance.primary.id
  environment = google_apigee_environment.healthy.name
}

resource "google_apigee_instance_attachment" "healthy_secondary" {
  provider   = google-beta
  instance_id = google_apigee_instance.secondary.id
  environment = google_apigee_environment.healthy.name
}

# --- Environment groups + attachments ---------------------------------------
# Scenario 1: healthy envgroup with a routed hostname attached to the healthy env
resource "google_apigee_envgroup" "healthy" {
  provider = google-beta
  name     = "apigee-group-healthy-${local.suffix}"
  org_id   = var.org_id
  hostnames = ["api-example.${local.suffix}.example.com"]
}

resource "google_apigee_envgroup_attachment" "healthy" {
  provider     = google-beta
  envgroup_id  = google_apigee_envgroup.healthy.id
  environment  = google_apigee_environment.healthy.name
}

# Scenario 3: orphan envgroup with NO attachment
resource "google_apigee_envgroup" "orphan" {
  provider = google-beta
  name     = "apigee-group-orphan-${local.suffix}"
  org_id   = var.org_id
  hostnames = ["orphan-${local.suffix}.example.com"]
}

# --- Target servers ----------------------------------------------------------
# Scenario 1: enabled, resolvable target server
resource "google_apigee_target_server" "healthy" {
  provider           = google-beta
  name               = "apigee-ts-healthy-${local.suffix}"
  env_id             = google_apigee_environment.healthy.id
  host               = "www.google.com"
  port               = 443
  is_enabled         = true
  protocol           = "HTTP"
}

# Scenario 5a: disabled target server
resource "google_apigee_target_server" "disabled" {
  provider           = google-beta
  name               = "apigee-ts-disabled-${local.suffix}"
  env_id             = google_apigee_environment.healthy.id
  host               = "www.google.com"
  port               = 443
  is_enabled         = false
  protocol           = "HTTP"
}

# Scenario 5b: target server pointing at a non-resolving host
resource "google_apigee_target_server" "dangling" {
  provider           = google-beta
  name               = "apigee-ts-dangling-${local.suffix}"
  env_id             = google_apigee_environment.healthy.id
  host               = "no-such-host-${local.suffix}.invalid"
  port               = 443
  is_enabled         = true
  protocol           = "HTTP"
}
