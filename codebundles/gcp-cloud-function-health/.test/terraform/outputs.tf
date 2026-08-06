output "healthy_function_name" {
  value = google_cloudfunctions_function.healthy_function.name
}

output "healthy_function_gen2_name" {
  value = google_cloudfunctions2_function.healthy_function_gen2.name
}

output "failing_function_name" {
  value = "failing-function-${var.resource_suffix}"
}

output "failing_function_gen2_name" {
  value = "failing-function-gen2-${var.resource_suffix}"
}

output "project_id" {
  value = var.project_id
}

output "region" {
  value = var.region
}
