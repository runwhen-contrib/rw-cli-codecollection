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
# A small regional Spanner instance (minimum processing units) with a single
# READY database, low CPU/storage. Expected issues: 0.
# -----------------------------------------------------------------------------
resource "google_spanner_instance" "healthy_instance" {
  name             = "healthy-instance-${var.resource_suffix}"
  config           = "regional-${var.region}"
  display_name     = "Healthy Spanner Instance"
  processing_units = 100

  labels = {
    env       = "test"
    lifecycle = "deleteme"
    product   = "runwhen"
    scenario  = "healthy_instance"
  }
}

resource "google_spanner_database" "healthy_database" {
  instance            = google_spanner_instance.healthy_instance.name
  name                = "healthy_db_${var.resource_suffix}"
  deletion_protection = false

  ddl = [
    "CREATE TABLE Items (ItemId INT64 NOT NULL, ItemName STRING(1024), CreatedAt TIMESTAMP) PRIMARY KEY (ItemId)",
  ]
}

# -----------------------------------------------------------------------------
# Test Scenario 2: overloaded_instance
# Instance intentionally provisioned at the minimum processing-unit tier
# (100 PU == 0.1 node-equivalent), which yields a small derived storage limit
# (~410 GB at the default 4096 GB/node). Loading test data close to that
# derived limit -- or driving sustained high-priority CPU load against it --
# is expected to push the instance above the CPU_UTILIZATION_THRESHOLD and/or
# STORAGE_UTILIZATION_THRESHOLD. See ../.test/README.md for how to exercise
# this scenario against a live project. Expected issues: 2 (severities 2, 3).
# -----------------------------------------------------------------------------
resource "google_spanner_instance" "overloaded_instance" {
  name             = "overloaded-instance-${var.resource_suffix}"
  config           = "regional-${var.region}"
  display_name     = "Overloaded Spanner Instance"
  processing_units = 100

  labels = {
    env       = "test"
    lifecycle = "deleteme"
    product   = "runwhen"
    scenario  = "overloaded_instance"
  }
}

resource "google_spanner_database" "overloaded_database" {
  instance            = google_spanner_instance.overloaded_instance.name
  name                = "overloaded_db_${var.resource_suffix}"
  deletion_protection = false

  ddl = [
    "CREATE TABLE Events (EventId INT64 NOT NULL, Payload STRING(MAX), CreatedAt TIMESTAMP) PRIMARY KEY (EventId)",
  ]
}
