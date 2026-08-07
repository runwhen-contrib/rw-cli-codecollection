# Enable the APIs the CodeBundle depends on, and provision a read-only
# service account the bundle can authenticate with.

resource "google_project_service" "apigee" {
  project = var.project_id
  service = "apigee.googleapis.com"
}

resource "google_project_service" "monitoring" {
  project = var.project_id
  service = "monitoring.googleapis.com"
}

resource "google_service_account" "apigee_reader" {
  account_id   = "apigee-sec-reader-${var.resource_suffix}"
  display_name = "Apigee Security Config read-only reader (test)"
}

resource "google_project_iam_member" "apigee_read_only_admin" {
  project = var.project_id
  role    = "roles/apigee.readOnlyAdmin"
  member  = "serviceAccount:${google_service_account.apigee_reader.email}"
}

resource "google_project_iam_member" "monitoring_viewer" {
  project = var.project_id
  role    = "roles/monitoring.viewer"
  member  = "serviceAccount:${google_service_account.apigee_reader.email}"
}

resource "google_project_iam_member" "service_account_token_creator" {
  project = var.project_id
  role    = "roles/iam.serviceAccountTokenCreator"
  member  = "serviceAccount:${google_service_account.apigee_reader.email}"
}
