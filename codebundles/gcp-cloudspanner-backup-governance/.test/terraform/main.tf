terraform {
  required_version = ">= 1.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 4.60"
    }
  }
  backend "local" {}
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# -----------------------------------------------------------------------------
# Test Scenario 1: protected_database
# A small regional Spanner instance with a database that has deletion
# protection enabled, an adequate PITR window, and a fresh backup created
# alongside it. Expected issues: 0.
# -----------------------------------------------------------------------------
resource "google_spanner_instance" "protected_instance" {
  name             = "protected-instance-${var.resource_suffix}"
  config           = "regional-${var.region}"
  display_name     = "Protected Spanner Instance"
  processing_units = 100

  labels = {
    env       = "test"
    lifecycle = "deleteme"
    product   = "runwhen"
    scenario  = "protected_database"
  }
}

resource "google_spanner_database" "protected_database" {
  instance  = google_spanner_instance.protected_instance.name
  name      = "protected_db_${var.resource_suffix}"

  # deletion_protection is a Terraform-only guard against `terraform destroy`;
  # it must stay false here so `task clean` can tear the test database down.
  deletion_protection = false

  # enable_drop_protection maps to the real API field (enableDropProtection)
  # that this CodeBundle's check_deletion_protection.sh inspects.
  enable_drop_protection = true

  version_retention_period = "3d"

  ddl = [
    "CREATE TABLE Items (ItemId INT64 NOT NULL, ItemName STRING(1024), CreatedAt TIMESTAMP) PRIMARY KEY (ItemId)",
  ]
}

resource "google_spanner_backup" "protected_backup" {
  instance    = google_spanner_instance.protected_instance.name
  database    = google_spanner_database.protected_database.name
  name        = "protected-backup-${var.resource_suffix}"
  expire_time = timeadd(timestamp(), "720h") # 30 days from creation

  lifecycle {
    ignore_changes = [expire_time]
  }
}

# -----------------------------------------------------------------------------
# Test Scenario 2: unprotected_database
# A regional Spanner instance with a database that has deletion protection
# disabled and no backup at all. version_retention_period is set to an
# adequate window so only the backup-recency and deletion-protection checks
# are exercised. Expected issues: 2 (severities 2, 3).
# -----------------------------------------------------------------------------
resource "google_spanner_instance" "unprotected_instance" {
  name             = "unprotected-instance-${var.resource_suffix}"
  config           = "regional-${var.region}"
  display_name     = "Unprotected Spanner Instance"
  processing_units = 100

  labels = {
    env       = "test"
    lifecycle = "deleteme"
    product   = "runwhen"
    scenario  = "unprotected_database"
  }
}

resource "google_spanner_database" "unprotected_database" {
  instance = google_spanner_instance.unprotected_instance.name
  name     = "unprotected_db_${var.resource_suffix}"

  deletion_protection    = false
  enable_drop_protection = false

  version_retention_period = "3d"

  ddl = [
    "CREATE TABLE Events (EventId INT64 NOT NULL, Payload STRING(MAX), CreatedAt TIMESTAMP) PRIMARY KEY (EventId)",
  ]
}
