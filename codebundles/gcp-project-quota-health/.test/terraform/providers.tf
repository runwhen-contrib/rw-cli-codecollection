provider "google" {
  project     = var.project_id
  region      = var.region
  credentials = fileexists(var.credentials_file) ? file(var.credentials_file) : null
}
