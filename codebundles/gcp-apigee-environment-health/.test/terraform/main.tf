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

  required_apis = [
    "apigee.googleapis.com",
    "apigeeconnect.googleapis.com",
    "servicenetworking.googleapis.com",
  ]

  # one() yields null when create_network is false, so this resolves to the
  # pre-existing network without indexing a zero-count resource.
  network_link = coalesce(
    one(google_compute_network.apigee[*].self_link),
    "projects/${var.project_id}/global/networks/${var.network}"
  )
}

# --- Prerequisites -----------------------------------------------------------
# These must exist before the Apigee organization itself can be created, so
# `task bootstrap-prerequisites` applies just this subset (via -target), then
# creates the org, and only afterwards is a full apply possible.
#
# disable_on_destroy is false on purpose: the organization is NOT managed by
# Terraform and outlives `task clean`, and disabling the Apigee API underneath
# a live org is unsafe. Disabling the APIs is part of manual org teardown.
resource "google_project_service" "required" {
  for_each = toset(local.required_apis)

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# The VPC the Apigee runtime peers with. Deliberately NOT suffixed per run:
# the org's authorizedNetwork is bound at creation and can only be changed
# while no runtime instances exist, so the network shares the org's lifetime
# rather than an individual test run's.
#
# Defaults to off, which uses the project's existing (usually auto-created)
# `default` network. Set create_network on a project that has no usable one.
resource "google_compute_network" "apigee" {
  count = var.create_network ? 1 : 0

  project                 = var.project_id
  name                    = var.network
  auto_create_subnetworks = true

  depends_on = [google_project_service.required]
}

# Reserved range for Service Networking. Apigee needs a non-overlapping /22 per
# runtime instance, and this config provisions two, so the default is a /21.
resource "google_compute_global_address" "apigee_peering" {
  count = var.disable_vpc_peering ? 0 : 1

  project       = var.project_id
  name          = "apigee-peering-${local.suffix}"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = var.peering_prefix_length
  network       = local.network_link

  depends_on = [google_project_service.required]
}

resource "google_service_networking_connection" "apigee" {
  count = var.disable_vpc_peering ? 0 : 1

  network                 = local.network_link
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.apigee_peering[0].name]

  depends_on = [google_project_service.required]
}

# --- Runtime instances -------------------------------------------------------
# Apigee X runtime instances live at the org level. They consume the reserved
# peering range, so depending on the connection also fixes the destroy order:
# instances are torn down before the peering they sit on.
resource "google_apigee_instance" "primary" {
  provider   = google-beta
  name       = "apigee-inst-primary-${local.suffix}"
  org_id     = var.org_id
  location   = var.region

  depends_on = [google_service_networking_connection.apigee]
}

resource "google_apigee_instance" "secondary" {
  provider   = google-beta
  name       = "apigee-inst-secondary-${local.suffix}"
  org_id     = var.org_id
  location   = var.instance_region

  depends_on = [google_service_networking_connection.apigee]
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
