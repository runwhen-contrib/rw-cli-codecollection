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
# Test scenario: healthy_org
# An Apigee organization that is receivable by the bundle. The bundle checks
# deployment coverage, deployment health, revision state, and runtime status,
# so an org with at least one environment is required for discovery.
# -----------------------------------------------------------------------------
resource "google_apigee_organization" "test_org" {
  project_id              = var.project_id
  display_name            = "runwhen-apigee-health-test"
  analytics_region        = var.region
  authorized_network      = var.network_id
  runtime_type            = "CLOUD"
  billing_type            = "EVALUATION"
  retention               = "MINIMUM"
}

resource "google_apigee_environment" "test_env" {
  org_id      = google_apigee_organization.test_org.id
  name        = "test-env-${var.resource_suffix}"
  description = "Test environment for gcp-apigee-proxy-health bundle"
  display_name = "runwhen-test-env"
  type        = "APIPROXY"

  depends_on = [google_apigee_organization.test_org]
}

resource "google_apigee_environment" "empty_env" {
  org_id      = google_apigee_organization.test_org.id
  name        = "empty-env-${var.resource_suffix}"
  description = "Test environment with no deployments (should be flagged for coverage)"
  display_name = "runwhen-empty-env"
  type        = "APIPROXY"

  depends_on = [google_apigee_organization.test_org]
}
