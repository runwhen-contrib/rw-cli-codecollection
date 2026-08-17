# -----------------------------------------------------------------------------
# gcp-apigee-security-config -- Test Infrastructure
#
# This bundle is a read-only GUEST on a shared Apigee X organization. An Apigee
# org is one-per-project, so it is provisioned by the
# gcp-apigee-environment-health sibling's bootstrap and outlives `task clean`
# here.
#
# API ENABLEMENT IS DELIBERATELY ABSENT.
#
# apigee.googleapis.com and monitoring.googleapis.com are already managed by
# gcp-apigee-environment-health/.test/terraform (google_project_service.required,
# over local.required_apis). Declaring them here too put ONE GCP resource under
# TWO Terraform states in the same project: whichever applied second adopted it,
# and whichever destroyed first released it.
#
# That was not theoretical. `disable_on_destroy` defaults to true, and
# `task clean` runs `terraform destroy -auto-approve`, so tearing down this
# bundle would have attempted to DISABLE apigee.googleapis.com while a live
# organization, a runtime instance and three sibling bundles' fixtures depended
# on it. The sibling states the rule directly:
#
#   disable_on_destroy is false on purpose: the organization is NOT managed by
#   Terraform and outlives `task clean`, and disabling the Apigee API underneath
#   a live org is unsafe.
#
# Resolved by dropping the ownership claim rather than by keeping it with
# disable_on_destroy = false: this bundle never needed to enable anything, and
# single ownership is a stronger guarantee than two states that agree not to
# destroy. environment-health's bootstrap is the documented prerequisite (see
# ../README.md), which is the same arrangement gcp-apigee-proxy-health uses.
# -----------------------------------------------------------------------------

# The backend is declared once, in backend.tf. A second `terraform` block here
# is a duplicate-backend error and `terraform init` refuses to run.

resource "google_service_account" "apigee_reader" {
  account_id   = "apigee-sec-reader-${var.resource_suffix}"
  display_name = "Apigee Security Config read-only reader (test)"
}

resource "google_project_iam_member" "apigee_read_only_admin" {
  project = var.project_id
  role    = "roles/apigee.readOnlyAdmin"
  member  = "serviceAccount:${google_service_account.apigee_reader.email}"
}

resource "google_project_iam_member" "monitoring_viewer" {
  project = var.project_id
  role    = "roles/monitoring.viewer"
  member  = "serviceAccount:${google_service_account.apigee_reader.email}"
}

# A key for the reader, so `.test/README.md` step 3 refers to something that
# exists. Previously the README told operators to "export the service account
# key produced for the reader" while no key resource was ever declared.
#
# The private key lands in Terraform state, which is why this is opt-in: set
# create_reader_key = false and mint one out of band with
# `gcloud iam service-accounts keys create` if the state backend is not a place
# a credential may live.
resource "google_service_account_key" "apigee_reader" {
  count              = var.create_reader_key ? 1 : 0
  service_account_id = google_service_account.apigee_reader.name
}

# There is deliberately no roles/iam.serviceAccountTokenCreator binding.
#
# It was granted PROJECT-WIDE, which permits impersonating every service account
# in the project -- including the ones the sibling bundles use. Nothing in this
# bundle impersonates anything: every script calls `gcloud auth
# print-access-token` on its own identity. readOnlyAdmin + monitoring.viewer are
# what the checks actually need.
