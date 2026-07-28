provider "google" {
  credentials = file(var.service_account_key)
  project     = var.gcp_project_id
  region      = var.region
}