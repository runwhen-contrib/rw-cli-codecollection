output "healthy_vm_name" {
  value = google_compute_instance.healthy.name
}

output "unhealthy_stopped_vm_name" {
  value = google_compute_instance.unhealthy.name
}

output "grouped_vm_name" {
  value = google_compute_instance.grouped.name
}

output "discovery_expected_standalone_vms" {
  description = "Names that gcp-compute-vm-health should discover as standalone (grouped-vm excluded)."
  value       = [google_compute_instance.healthy.name, google_compute_instance.unhealthy.name]
}
