# -----------------------------------------------------------------------------
# gcp-apigee-proxy-health -- Test Infrastructure (Terraform stubs)
#
# The Apigee proxy fixtures are created by .test/bootstrap_apigee_fixtures.sh via
# the Management REST API (proxy deployment is not well handled by Terraform).
# The shared Apigee X test org/environments are owned by the environment-health
# sibling bundle's bootstrap. This stub keeps the terraform layout consistent
# with sibling bundles and validates IAM/provider wiring for the test project.
# -----------------------------------------------------------------------------

terraform {
  backend "local" {}
}

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
