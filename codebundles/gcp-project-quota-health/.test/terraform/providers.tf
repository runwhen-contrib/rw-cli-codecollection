provider "google" {
  project     = var.project_id
  region      = var.region
  credentials = var.credentials_file != "" && fileexists(var.credentials_file) ? file(var.credentials_file) : null
}
