# resource_suffix is intentionally NOT set here: values in terraform.tfvars take
# precedence over TF_VAR_resource_suffix, which would pin every run to the same
# resource names and make concurrent or repeated test runs collide. Override it
# per run via `export TF_VAR_resource_suffix=<unique>` (see variables.tf for the
# default).
region = "us-central1"
