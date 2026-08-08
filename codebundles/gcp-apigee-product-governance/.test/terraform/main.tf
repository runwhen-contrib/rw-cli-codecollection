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
}

# -----------------------------------------------------------------------------
# The Apigee entitlement fixtures (products/developers/apps) are NOT created by
# Terraform -- they are created via the management REST API in the shared
# long-lived test org (see ../fixtures/*.sh) because Terraform has no first-class
# provider for these inner objects. Terraform here only resolves the Apigee org
# bound to the project so the fixtures script can be pointed at it.
# -----------------------------------------------------------------------------
data "google_project" "project" {
  project_id = var.project_id
}

locals {
  apigee_org = var.apigee_org != "" ? var.apigee_org : data.google_project.project.id
}

output "gcp_project_id" {
  value = var.project_id
}

output "apigee_org" {
  value = local.apigee_org
}

output "fixture_suffix" {
  value = var.resource_suffix
}
