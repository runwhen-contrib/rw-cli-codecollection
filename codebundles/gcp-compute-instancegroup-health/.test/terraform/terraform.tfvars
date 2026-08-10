region = "us-central1"
zone   = "us-central1-a"

# resource_suffix is deliberately not set here: a value in tfvars overrides
# TF_VAR_resource_suffix, which would defeat per-run suffixing and let two
# parallel runs of this bundle collide on the same resource names. The default
# in variables.tf applies when the environment does not set one.
