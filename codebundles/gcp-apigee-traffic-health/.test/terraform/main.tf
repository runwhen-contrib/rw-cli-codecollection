# -----------------------------------------------------------------------------
# gcp-apigee-traffic-health -- Test Infrastructure (optional scaffold)
#
# Apigee X organizations and their runtime traffic cannot be created via the
# standard `google` provider, and realistic time series require live traffic.
# The deterministic test strategy for this bundle therefore relies on the
# mock fixtures under ../mock (see validate-all-tests.sh).
#
# This Terraform is provided as a buildable scaffold for optional future work:
# it provisions a GCS bucket that operators may use to stage mock Cloud
# Monitoring exports for integration testing. It is inert by default and is NOT
# required to run the mock tests.
# -----------------------------------------------------------------------------

resource "google_storage_bucket" "apigee_mock_data" {
  name          = "apigee-traffic-health-${var.resource_suffix}"
  location      = var.region
  force_destroy = true

  uniform_bucket_level_access = true

  labels = {
    env       = "test"
    lifecycle = "deleteme"
    product   = "runwhen"
  }
}
