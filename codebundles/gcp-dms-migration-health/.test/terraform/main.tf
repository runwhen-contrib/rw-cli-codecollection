terraform {
  required_version = ">= 1.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 4.0"
    }
    http = {
      source  = "hashicorp/http"
      version = ">= 3.0"
    }
  }
  backend "local" {}
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# DMS reaches a public source database from a fixed set of regional egress IPs.
# They must be allowlisted on the source instance or the job fails with
# CONNECTION_FAILURE / "i/o timeout". Fetch them at plan time rather than
# hardcoding, since the set is regional and can change.
data "google_client_config" "current" {}

data "http" "dms_static_ips" {
  url = "https://datamigration.googleapis.com/v1/projects/${var.project_id}/locations/${var.dms_location}:fetchStaticIps"

  request_headers = {
    Authorization = "Bearer ${data.google_client_config.current.access_token}"
  }

  depends_on = [google_project_service.datamigration]
}

locals {
  dms_static_ips = try(jsondecode(data.http.dms_static_ips.response_body).staticIps, [])

  labels = {
    env       = "test"
    lifecycle = "deleteme"
    product   = "runwhen"
  }
}

# -----------------------------------------------------------------------------
# APIs. disable_on_destroy = false on purpose: this is a shared sandbox project
# and tearing down this harness must never switch an API off for anyone else.
# -----------------------------------------------------------------------------
resource "google_project_service" "datamigration" {
  project            = var.project_id
  service            = "datamigration.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "sqladmin" {
  project            = var.project_id
  service            = "sqladmin.googleapis.com"
  disable_on_destroy = false
}

# -----------------------------------------------------------------------------
# Source database - a small Cloud SQL MySQL instance.
# binary_log_enabled is REQUIRED for DMS continuous (CDC) replication, and
# Cloud SQL only allows binary logs when backups are enabled.
# -----------------------------------------------------------------------------
resource "google_sql_database_instance" "source" {
  name                = "dms-source-${var.resource_suffix}"
  project             = var.project_id
  region              = var.region
  database_version    = var.mysql_version
  deletion_protection = false

  depends_on = [google_project_service.sqladmin]

  # The destination instance's egress IP is appended to the allowlist after
  # creation (see null_resource.authorize_destination_egress), which Terraform
  # would otherwise revert on the next apply.
  lifecycle {
    ignore_changes = [settings[0].ip_configuration[0].authorized_networks]
  }

  settings {
    tier              = var.source_tier
    availability_type = "ZONAL"
    disk_size         = var.disk_size_gb
    disk_type         = "PD_SSD"
    user_labels       = local.labels

    backup_configuration {
      enabled            = true
      binary_log_enabled = true
      start_time         = "02:00"
    }

    ip_configuration {
      ipv4_enabled = true

      dynamic "authorized_networks" {
        for_each = toset(local.dms_static_ips)
        content {
          name  = "dms-${replace(authorized_networks.value, ".", "-")}"
          value = "${authorized_networks.value}/32"
        }
      }
    }
  }
}

resource "google_sql_database" "app" {
  name     = "appdb"
  project  = var.project_id
  instance = google_sql_database_instance.source.name
}

# DMS authenticates as this user to read the binlog stream.
resource "google_sql_user" "migration" {
  name     = "dms_migration"
  project  = var.project_id
  instance = google_sql_database_instance.source.name
  host     = "%"
  password = var.db_password
}

# -----------------------------------------------------------------------------
# DMS source connection profile. cloud_sql_id tells DMS the source is a Cloud
# SQL instance in this project, so it can wire up connectivity itself instead of
# needing the outbound static IP allowlisted on a public endpoint.
# -----------------------------------------------------------------------------
resource "google_database_migration_service_connection_profile" "source" {
  location              = var.dms_location
  project               = var.project_id
  connection_profile_id = "dms-source-profile-${var.resource_suffix}"
  display_name          = "DMS source (${var.resource_suffix})"
  labels                = local.labels

  mysql {
    cloud_sql_id = google_sql_database_instance.source.name
    host         = google_sql_database_instance.source.public_ip_address
    port         = 3306
    username     = google_sql_user.migration.name
    password     = var.db_password
  }

  depends_on = [google_project_service.datamigration]
}

# -----------------------------------------------------------------------------
# DMS destination connection profile. Creating a CLOUDSQL-type profile is what
# provisions the destination Cloud SQL instance - source_id points back at the
# source profile so DMS can size and configure it to match.
# -----------------------------------------------------------------------------
resource "google_database_migration_service_connection_profile" "destination" {
  location              = var.dms_location
  project               = var.project_id
  connection_profile_id = "dms-dest-profile-${var.resource_suffix}"
  display_name          = "DMS destination (${var.resource_suffix})"
  labels                = local.labels

  cloudsql {
    settings {
      source_id         = google_database_migration_service_connection_profile.source.name
      tier              = var.destination_tier
      edition           = "ENTERPRISE"
      database_version  = var.mysql_version
      data_disk_size_gb = var.disk_size_gb
      data_disk_type    = "PD_SSD"
      zone              = "${var.region}-a"
      root_password     = var.db_password
      activation_policy = "ALWAYS"
      user_labels       = local.labels

      ip_config {
        enable_ipv4 = true
        require_ssl = false
      }
    }
  }
}

# -----------------------------------------------------------------------------
# The migration job itself. type = CONTINUOUS gives a full dump followed by CDC,
# which is what exercises the bundle's replication-lag dimension.
# -----------------------------------------------------------------------------
resource "google_database_migration_service_migration_job" "cdc" {
  location         = var.dms_location
  project          = var.project_id
  migration_job_id = "dms-job-${var.resource_suffix}"
  display_name     = "DMS CDC job (${var.resource_suffix})"
  labels           = local.labels

  type          = "CONTINUOUS"
  source        = google_database_migration_service_connection_profile.source.name
  destination   = google_database_migration_service_connection_profile.destination.name
  desired_state = var.migration_desired_state

  static_ip_connectivity {}
}

# -----------------------------------------------------------------------------
# For MySQL CDC the destination Cloud SQL instance connects to the source as a
# replica, so the SOURCE must allowlist the DESTINATION's outgoing IP - the DMS
# static IPs alone are not enough (the job fails with CONNECTION_FAILURE /
# "i/o timeout"). That IP only exists once the destination profile has built the
# instance, and folding it back into google_sql_database_instance.source would
# create a dependency cycle, so it is patched in as a follow-up step.
# -----------------------------------------------------------------------------
data "google_sql_database_instance" "destination" {
  name    = google_database_migration_service_connection_profile.destination.cloudsql[0].cloud_sql_id
  project = var.project_id
}

locals {
  destination_outgoing_ip = one([
    for ip in data.google_sql_database_instance.destination.ip_address :
    ip.ip_address if ip.type == "OUTGOING"
  ])

  source_authorized_ips = concat(
    [for ip in local.dms_static_ips : "${ip}/32"],
    local.destination_outgoing_ip == null ? [] : ["${local.destination_outgoing_ip}/32"],
  )
}

resource "null_resource" "authorize_destination_egress" {
  triggers = {
    instance = google_sql_database_instance.source.name
    ips      = join(",", local.source_authorized_ips)
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      gcloud auth activate-service-account --key-file="$GOOGLE_APPLICATION_CREDENTIALS" --quiet
      gcloud sql instances patch ${google_sql_database_instance.source.name} \
        --project=${var.project_id} --quiet \
        --authorized-networks=${join(",", local.source_authorized_ips)}
    EOT
  }
}
