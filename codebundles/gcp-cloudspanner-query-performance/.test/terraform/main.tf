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
# Test Scenario 1: healthy_workload
# A small regional Spanner instance with a single READY database and a simple
# table. `generate-load` (Taskfile) issues a handful of fast, single-row
# SELECT statements against it -- well under every threshold. Expected
# issues: 0.
# -----------------------------------------------------------------------------
resource "google_spanner_instance" "healthy_workload" {
  name             = "healthy-workload-${var.resource_suffix}"
  config           = "regional-${var.region}"
  display_name     = "Healthy Query Workload"
  processing_units = 100

  labels = {
    env       = "test"
    lifecycle = "deleteme"
    product   = "runwhen"
    scenario  = "healthy_workload"
  }
}

resource "google_spanner_database" "healthy_workload" {
  instance            = google_spanner_instance.healthy_workload.name
  name                = "healthy_db_${var.resource_suffix}"
  deletion_protection = false

  ddl = [
    "CREATE TABLE Items (ItemId INT64 NOT NULL, ItemName STRING(1024), CreatedAt TIMESTAMP) PRIMARY KEY (ItemId)",
  ]
}

# -----------------------------------------------------------------------------
# Test Scenario 2: contended_workload
# A regional Spanner instance with a single READY database and a
# single-row "Counters" table. `generate-load` (Taskfile) fires many
# concurrent UPDATE statements at the same row to force lock waits and
# commit aborts -- Terraform alone only provisions the shape, it does not
# generate traffic. See ../.test/README.md. Expected issues: 2
# (severities 2, 3), from lock_contention and transaction_aborts.
# -----------------------------------------------------------------------------
resource "google_spanner_instance" "contended_workload" {
  name             = "contended-workload-${var.resource_suffix}"
  config           = "regional-${var.region}"
  display_name     = "Contended Query Workload"
  processing_units = 100

  labels = {
    env       = "test"
    lifecycle = "deleteme"
    product   = "runwhen"
    scenario  = "contended_workload"
  }
}

resource "google_spanner_database" "contended_workload" {
  instance            = google_spanner_instance.contended_workload.name
  name                = "contended_db_${var.resource_suffix}"
  deletion_protection = false

  ddl = [
    "CREATE TABLE Counters (Id INT64 NOT NULL, Value INT64) PRIMARY KEY (Id)",
  ]
}
