# project_id is NOT set here. Every sibling GCP bundle supplies it through
# TF_VAR_project_id from .test/terraform/tf.secret, so that a real project is
# named once, by the operator. A placeholder like "my-gcp-project" here would
# be silently *used* by `terraform apply` and target a project that does not
# exist.
#
# Optional: grant the bundle's service account the roles it needs to run.
# apigee_service_account = "apigee-health@YOUR-PROJECT.iam.gserviceaccount.com"
