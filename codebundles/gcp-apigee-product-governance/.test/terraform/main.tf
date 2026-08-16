# -----------------------------------------------------------------------------
# The Apigee entitlement fixtures (products/developers/apps) are NOT created by
# Terraform -- they are created via the management REST API in the shared
# long-lived test org (see ../fixtures/*.sh) because Terraform has no
# first-class provider for these inner objects. Terraform here only resolves the
# Apigee org bound to the project so the fixtures script can be pointed at it.
#
# The terraform{} and provider{} blocks live in providers.tf. Declaring them
# here as well is a duplicate-configuration error that fails `terraform init`.
# -----------------------------------------------------------------------------

data "google_project" "project" {
  project_id = var.project_id
}

locals {
  # google_project.id is the Terraform resource ID ("projects/<id>"), not the
  # project identifier. Apigee organizations are named after the bare project ID.
  apigee_org = var.apigee_org != "" ? var.apigee_org : data.google_project.project.project_id
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
