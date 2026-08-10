# project_id is NOT set here. Every sibling GCP bundle supplies it through
# TF_VAR_project_id from .test/terraform/tf.secret, so that a real project is
# named once, by the operator. A placeholder like "my-gcp-project" here would
# be silently *used* by `terraform apply` and target a project that does not
# exist.
#
# resource_suffix keeps this bundle's fixtures distinct from the sibling
# Apigee bundles' fixtures in the SHARED Apigee organization. Override it per
# run (TF_VAR_resource_suffix / RESOURCE_SUFFIX) to run concurrently.
resource_suffix = "test001"

# Optional: grant the bundle's service account the roles it needs to run.
# apigee_service_account = "apigee-health@YOUR-PROJECT.iam.gserviceaccount.com"
