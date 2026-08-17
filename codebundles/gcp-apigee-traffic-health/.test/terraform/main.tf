# -----------------------------------------------------------------------------
# gcp-apigee-traffic-health -- Test Infrastructure (Terraform stub)
#
# This bundle provisions NO Apigee resources, by design and by necessity:
#
#   - An Apigee X organization is one-per-project and takes ~45 minutes to
#     create; the shared test org is owned by the gcp-apigee-environment-health
#     sibling's bootstrap, and this bundle is a read-only guest on it.
#   - The signals this bundle reads are Cloud Monitoring time series, which
#     require live traffic through a runtime instance reachable only on a
#     private IP inside the peered VPC. Terraform cannot manufacture those.
#
# It therefore declares no cloud resources at all. It previously created a GCS
# bucket described in its own header as "inert by default and NOT required to
# run the mock tests" -- a resource whose only purpose was to be a placeholder,
# which `build-infra` would really create and `clean` would really destroy.
#
# What it does instead is state, in one machine-readable place, what a discovery
# run against the shared org is expected to produce, so that run has something
# to be checked against rather than being eyeballed. Same approach as
# gcp-apigee-proxy-health's stub.
#
# API enablement is deliberately absent. apigee.googleapis.com and
# monitoring.googleapis.com are enabled by the environment-health sibling, which
# owns them in its own state; claiming them here would put one GCP resource
# under two Terraform states, where whichever destroys first releases it.
# -----------------------------------------------------------------------------

# The backend is declared once, in backend.tf. A second `terraform` block here
# is a duplicate-backend error and `terraform init` refuses to run.
#
# The discovery ground truth this stub exists to publish lives in outputs.tf.
