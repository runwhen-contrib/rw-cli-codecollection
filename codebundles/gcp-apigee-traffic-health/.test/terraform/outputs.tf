# --- Discovery ground truth --------------------------------------------------
# Terraform provisions nothing for this bundle (see main.tf for why). What it
# can do is state, in one machine-readable place, what a discovery run against
# the shared Apigee org is expected to produce -- so that run has something to
# be checked against rather than being eyeballed.
#
# Keep these in step with ../../.runwhen/generation-rules/gcp-apigee-traffic-health.yaml.

output "project_id" {
  value = var.project_id
}

output "region" {
  value = var.region
}

output "discovery_expected_resource_type" {
  description = "The resource type the generation rule gates on. Discovery finding zero of these means the RunWhen Local image's registry predates Apigee support, not that the rule is wrong."
  value       = "gcp_apigee_organizations"
}

output "discovery_expected_slx_count" {
  description = "An Apigee org is one-per-project and the rule qualifies on the resource, so exactly one SLX is expected per project that has an org."
  value       = 1
}

output "discovery_expected_resource_path" {
  description = "gcp-hierarchy.yaml inserts project_id into the path only when `resource` is a qualifier, so a flattened gcp/<project> indicates the qualifier was reverted to [\"project\"]."
  value       = "gcp/${var.project_id}/<apigee-org>"
}
