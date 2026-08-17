project_id      = "my-test-project"
region          = "us-central1"
resource_suffix = "test"
# service_account should be set (via tf.secret / TF_VAR_service_account) to an
# email that has composer.worker and GKE roles.
service_account  = ""
