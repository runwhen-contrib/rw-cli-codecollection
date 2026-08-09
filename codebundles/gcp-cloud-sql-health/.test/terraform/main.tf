terraform {
  required_version = ">= 1.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
  }
  backend "local" {}
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# -----------------------------------------------------------------------------
# Test Scenario 1: healthy_instance
# Adequately provisioned, private IP only, backups + point-in-time recovery
# (via MySQL binary logging) enabled, SSL enforced, minimal IAM.
# Expected: no issues -> health score 1.0.
# -----------------------------------------------------------------------------
resource "google_sql_database_instance" "healthy" {
  name                = "healthy-${var.resource_suffix}"
  project             = var.project_id
  region              = var.region
  database_version    = "MYSQL_8_0"
  deletion_protection = false

  settings {
    tier              = "db-custom-2-7680"
    availability_type = "ZONAL"

    ip_configuration {
      ipv4_enabled    = false
      private_network = var.private_network
      ssl_mode        = "ENCRYPTED_ONLY"
    }

    backup_configuration {
      enabled    = true
      start_time = "02:00"
      # MySQL enables point-in-time recovery through binary logging.
      # (point_in_time_recovery_enabled is Postgres/SQL Server only.)
      binary_log_enabled = true
    }

    maintenance_window {
      day  = 1
      hour = 3
    }

    user_labels = {
      env       = "test"
      lifecycle = "deleteme"
      product   = "runwhen"
    }
  }
}

resource "google_sql_user" "healthy_user" {
  name     = "healthuser"
  instance = google_sql_database_instance.healthy.name
  host     = "%"
  password = var.db_password
}

# -----------------------------------------------------------------------------
# Test Scenario 2: publicly_exposed_instance
# Public IPv4 enabled, SSL not enforced (sslMode ALLOW_UNENCRYPTED_AND_ENCRYPTED),
# undersized tier (1 vCPU), point-in-time recovery disabled.
# Expected issues: Sev4 public exposure, Sev3 no-SSL, Sev2 undersized tier, Sev2 PITR.
#
# NOTE: a public-IAM scenario (allUsers / allAuthenticatedUsers bound to a
# roles/cloudsql.* role) is intentionally NOT provisioned here. The sandbox org
# enforces the Domain Restricted Sharing policy, which rejects public IAM
# members ("Policy members must be of the form <type>:<value>"). The IAM check
# in check_instance_iam.sh still runs against the live project IAM policy, so it
# validates cleanly; the positive-detection path must be exercised in a project
# without that org constraint.
# -----------------------------------------------------------------------------
resource "google_sql_database_instance" "exposed" {
  name                = "exposed-${var.resource_suffix}"
  project             = var.project_id
  region              = var.region
  database_version    = "POSTGRES_15"
  deletion_protection = false

  settings {
    tier              = "db-custom-1-3840"
    availability_type = "ZONAL"

    ip_configuration {
      ipv4_enabled = true
      ssl_mode     = "ALLOW_UNENCRYPTED_AND_ENCRYPTED"
      authorized_networks {
        name  = "narrow-range"
        value = "203.0.113.0/24"
      }
    }

    backup_configuration {
      enabled = true
    }

    user_labels = {
      env       = "test"
      lifecycle = "deleteme"
      product   = "runwhen"
    }
  }
}
