output "project_id" {
  value = var.project_id
}

output "region" {
  value = var.region
}

output "healthy_api" {
  value = google_api_gateway_api.healthy.api_id
}

output "healthy_gateway" {
  value = google_api_gateway_gateway.healthy.gateway_id
}

output "broken_api_config" {
  value = google_api_gateway_api_config.broken.api_config_id
}

output "dangling_backend_gateway" {
  value = google_api_gateway_gateway.broken.gateway_id
}

output "drift_gateway" {
  value = google_api_gateway_gateway.drift.gateway_id
}

output "missing_invoker_gateway" {
  value = google_api_gateway_gateway.noinv.gateway_id
}

output "drift_api" {
  value = google_api_gateway_api.drift.api_id
}

output "backend_url" {
  value = google_cloud_run_service.backend.status[0].url
}

output "gateway_service_account" {
  value = google_service_account.gateway.email
}

output "managed_services" {
  value = {
    healthy = google_api_gateway_api.healthy.managed_service
    broken  = google_api_gateway_api.broken.managed_service
    noinv   = google_api_gateway_api.noinv.managed_service
    drift   = google_api_gateway_api.drift.managed_service
  }
}
