# The substrate environments and the primary runtime instance are no longer
# Terraform resources -- apigee_prerequisites.sh owns them, because an
# EVALUATION org's caps make them shared across all five bundles. Their names
# are still published here, because callers read these outputs to learn what to
# target and the names are deterministic from the suffix.
#
# Deriving them from local.suffix rather than dropping the outputs keeps the
# contract in one shape: whatever consumes `healthy_environment` gets the same
# answer it always did.
output "healthy_environment" {
  value = local.healthy_env_name
}

output "unattached_environment" {
  value = "apigee-env-unattached-${local.suffix}"
}

output "primary_instance" {
  value = "apigee-inst-primary-${local.suffix}"
}

# Empty unless enable_secondary_instance is set: an EVALUATION organization is
# capped at one runtime instance, so on the default path there is no second one
# to name.
output "secondary_instance" {
  value = one(google_apigee_instance.secondary[*].name)
}

output "healthy_envgroup" {
  value = google_apigee_envgroup.healthy.name
}

output "orphan_envgroup" {
  value = google_apigee_envgroup.orphan.name
}
