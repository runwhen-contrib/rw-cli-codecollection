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

# No alias: every beta resource here references `provider = google-beta`, i.e.
# the default google-beta provider. With `alias = "beta"` this block configured
# a provider nothing referenced, so terraform silently fell back to an
# implicitly-configured google-beta and the project/region below did nothing.
provider "google-beta" {
  project = var.project_id
  region  = var.region
}
