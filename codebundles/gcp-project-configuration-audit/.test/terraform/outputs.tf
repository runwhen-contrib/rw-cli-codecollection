output "project_id" {
  description = "GCP project ID under audit"
  value       = var.project_id
}

output "org_policy_issue_expected" {
  description = "Whether the public bucket access org-policy violation scenario was provisioned"
  value       = var.org_id != "" ? "org_policy_violation_expected" : "no_org_scenario"
}
