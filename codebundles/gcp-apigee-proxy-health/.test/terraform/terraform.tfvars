# Deliberately (almost) empty. Two values that look like they belong here do not:
#
# project_id
#   Every sibling GCP bundle supplies it through TF_VAR_project_id from
#   .test/terraform/tf.secret, so a real project is named once, by the operator.
#   A placeholder here would be silently *used* by `terraform apply` and target
#   a project that does not exist.
#
# resource_suffix
#   MUST NOT be set here. A value in terraform.tfvars OVERRIDES TF_VAR_* -- the
#   env var sits lower in Terraform's precedence chain -- so pinning it here
#   made Terraform report "test001" while load-credentials.sh resolved a
#   different suffix and the fixtures were created under that. The
#   discovery_expected_* outputs then named proxies that were never created,
#   which is exactly what those outputs exist to prevent.
#
#   The default lives in variables.tf ("test001"), and load-credentials.sh
#   exports TF_VAR_resource_suffix so Terraform and the fixture scripts always
#   agree. Set FIXTURE_SUFFIX (or TF_VAR_resource_suffix) in tf.secret to
#   override it per run.
#
# Optional: grant the bundle's service account the roles it needs to run.
# apigee_service_account = "apigee-health@YOUR-PROJECT.iam.gserviceaccount.com"
