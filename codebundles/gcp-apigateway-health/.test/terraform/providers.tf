# -----------------------------------------------------------------------------
# NOTE: google_api_gateway_api / google_api_gateway_api_config /
# google_api_gateway_gateway are BETA-only resources and therefore MUST use the
# google-beta provider. Do NOT copy the plain 'google' provider from a
# neighbouring GCP bundle.
# -----------------------------------------------------------------------------

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  alias   = "beta"
  project = var.project_id
  region  = var.region
}
