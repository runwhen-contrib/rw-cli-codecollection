# -----------------------------------------------------------------------------
# gcp-apigee-proxy-health -- Test Infrastructure (Terraform stubs)
#
# The Apigee proxy fixtures are created by .test/bootstrap_apigee_fixtures.sh via
# the Management REST API (proxy deployment is not well handled by Terraform).
# The shared Apigee X test org/environments are owned by the environment-health
# sibling bundle's bootstrap. This stub keeps the terraform layout consistent
# with sibling bundles and validates IAM/provider wiring for the test project.
# -----------------------------------------------------------------------------

# The backend is declared once, in backend.tf. A second `terraform` block here
# is a duplicate-backend error and `terraform init` refuses to run.

resource "google_project_iam_member" "apigee_test_sa" {
  count  = var.apigee_service_account == "" ? 0 : 1
  project = var.project_id
  role   = "roles/apigee.readOnlyAdmin"
  member = "serviceAccount:${var.apigee_service_account}"
}

resource "google_project_iam_member" "apigee_test_sa_analytics" {
  count  = var.apigee_service_account == "" ? 0 : 1
  project = var.project_id
  role   = "roles/apigee.analyticsViewer"
  member = "serviceAccount:${var.apigee_service_account}"
}

output "project_id" {
  value = var.project_id
}

# --- Discovery ground truth --------------------------------------------------
# Terraform cannot provision the Apigee fixtures themselves (an Apigee X org is
# one-per-project and takes ~45 minutes; proxies are uploaded as zipped bundles
# over the REST API). What it can do is state, in one machine-readable place,
# what bootstrap_apigee_fixtures.sh is expected to create -- so a discovery run
# has something to be checked against instead of being eyeballed.
#
# Keep these in step with bootstrap_apigee_fixtures.sh.

output "resource_suffix" {
  description = "Suffix every fixture carries. Teardown asserts nothing bearing it survives."
  value       = var.resource_suffix
}

output "discovery_expected_proxies" {
  description = "API proxies the fixture bootstrap creates; discovery must find exactly these."
  value = [
    "${var.resource_suffix}-proxy-healthy",
    "${var.resource_suffix}-proxy-drift",
    "${var.resource_suffix}-proxy-failed",
    "${var.resource_suffix}-proxy-orphaned",
  ]
}

output "discovery_expected_findings" {
  description = "Fixture name -> the finding that proxy must produce. A fixture that provisions healthy silently removes the only thing under test."
  value = {
    "${var.resource_suffix}-proxy-healthy"  = "none"
    "${var.resource_suffix}-proxy-drift"    = "revision drift across environments"
    "${var.resource_suffix}-proxy-failed"   = "deployment in ERROR state"
    "${var.resource_suffix}-proxy-orphaned" = "not deployed to any environment"
  }
}
