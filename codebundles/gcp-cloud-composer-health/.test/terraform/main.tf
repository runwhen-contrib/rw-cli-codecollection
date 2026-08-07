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
# Test Scenario 1: healthy_environment
# A Composer 2 environment on a current LTS Airflow image that reaches RUNNING
# and should produce no environment-state or configuration issues.
# -----------------------------------------------------------------------------
resource "google_composer_environment" "composer_healthy" {
  name   = "composer-healthy-${var.resource_suffix}"
  region = var.region
  project = var.project_id

  config {
    software_config {
      image_version = "composer-2-airflow-2"
    }

    node_config {
      service_account = var.service_account
    }

    workloads_config {
      scheduler {
        count = 2
      }
      worker {
        count = 2
      }
      web_server {
        count = 1
      }
    }
  }

  labels = {
    env       = "test"
    lifecycle = "deleteme"
    product   = "runwhen"
  }
}

# -----------------------------------------------------------------------------
# Test Scenario 2: outdated_environment
# A Composer 1 environment on a deprecated image -- should be flagged by the
# configuration task as outdated / non-LTS.
# -----------------------------------------------------------------------------
resource "google_composer_environment" "composer_outdated" {
  name   = "composer-outdated-${var.resource_suffix}"
  region = var.region
  project = var.project_id

  config {
    software_config {
      image_version = "composer-1.20.0-airflow-1.10.15"
    }

    node_config {
      service_account = var.service_account
    }
  }

  labels = {
    env       = "test"
    lifecycle = "deleteme"
    product   = "runwhen"
  }
}
