output "project_id" {
  description = "Project holding the DMS test resources."
  value       = var.project_id
}

output "dms_location" {
  description = "DMS region - pass this to the robots as GCP_DMS_LOCATION."
  value       = var.dms_location
}

output "source_instance" {
  description = "Source Cloud SQL instance name."
  value       = google_sql_database_instance.source.name
}

output "source_public_ip" {
  description = "Public IP of the source Cloud SQL instance."
  value       = google_sql_database_instance.source.public_ip_address
}

output "source_connection_profile" {
  description = "Full resource name of the DMS source connection profile."
  value       = google_database_migration_service_connection_profile.source.name
}

output "destination_connection_profile" {
  description = "Full resource name of the DMS destination connection profile."
  value       = google_database_migration_service_connection_profile.destination.name
}

output "destination_instance" {
  description = "Cloud SQL instance DMS created as the migration destination."
  value       = google_database_migration_service_connection_profile.destination.cloudsql[0].cloud_sql_id
}

output "migration_job_id" {
  description = "Short migration job ID - ground truth for DMS_JOB_NAMES."
  value       = google_database_migration_service_migration_job.cdc.migration_job_id
}

output "migration_job_name" {
  description = "Full resource name of the migration job."
  value       = google_database_migration_service_migration_job.cdc.name
}

output "migration_job_state" {
  description = "State of the migration job as of the last apply."
  value       = google_database_migration_service_migration_job.cdc.state
}

output "dms_static_ips" {
  description = "DMS egress IPs allowlisted on the source instance."
  value       = local.dms_static_ips
}

output "destination_outgoing_ip" {
  description = "Destination instance egress IP allowlisted on the source (required for CDC)."
  value       = local.destination_outgoing_ip
}
