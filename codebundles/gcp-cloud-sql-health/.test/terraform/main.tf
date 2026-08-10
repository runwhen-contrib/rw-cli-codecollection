terraform {
  required_version = ">= 1.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 4.0"
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
# Adequately provisioned, private IP only, backups + PITR enabled, minimal IAM.
# -----------------------------------------------------------------------------
resource "google_sql_database_instance" "healthy" {
  name             = "healthy-${var.resource_suffix}"
  project          = var.project_id
  region           = var.region
  database_version = "MYSQL_8_0"
  deletion_protection = false

  settings {
    tier              = "db-custom-2-7680"
    availability_type = "ZONAL"

    ip_configuration {
      ipv4_enabled    = false
      private_network = var.private_network
      require_ssl     = true
    }

    backup_configuration {
      enabled                        = true
      start_time                     = "02:00"
      point_in_time_recovery_enabled = true
    }

    maintenance_window {
      day  = 1
      hour = 3
    }
  }

  labels = {
    env       = "test"
    lifecycle = "deleteme"
    product   = "runwhen"
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
# Public IPv4 enabled, SSL not enforced, over-broad IAM binding.
# Expected issues: [4 (public), 3 (SSL), 3 (IAM)].
# -----------------------------------------------------------------------------
resource "google_sql_database_instance" "exposed" {
  name             = "exposed-${var.resource_suffix}"
  project          = var.project_id
  region           = var.region
  database_version = "POSTGRES_15"
  deletion_protection = false

  settings {
    tier              = "db-custom-1-3840"
    availability_type = "ZONAL"

    ip_configuration {
      ipv4_enabled = true
      require_ssl  = false
      authorized_networks {
        name  = "narrow-range"
        value = "192.168.0.0/24"
      }
    }

    backup_configuration {
      enabled = true
    }
  }

  labels = {
    env       = "test"
    lifecycle = "deleteme"
    product   = "runwhen"
  }
}

resource "google_project_iam_binding" "exposed_public" {
  project = var.project_id
  role    = "roles/cloudsql.editor"
  members = [
    "allAuthenticatedUsers",
  ]
}
