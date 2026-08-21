terraform {
  required_version = ">= 1.5.0"
}

# -----------------------------------------------------------------------------
# Test "infrastructure" for gcp-artifact-registry-spend-analysis
#
# This CodeBundle reads Artifact Registry / Container Registry spend from a GCP
# BigQuery billing export. Billing export is configured at the billing-account
# (organization) level and its historical rows cannot be synthesized by
# terraform, so there is nothing meaningful to provision here.
#
# Instead, the harness is pointed at a real, existing billing export table via
# `tf.secret` (see .test/README.md):
#
#   export GCP_BILLING_EXPORT_TABLE="<billing-project>.<dataset>.gcp_billing_export_v1_XXXXXX"
#
# `task build-infra` runs this (no-op) terraform and then verifies that the
# configured table is actually readable with the supplied credentials.
# This file keeps the standard .test/terraform layout in place for future
# fixture work.
# -----------------------------------------------------------------------------
