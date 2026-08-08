variable "project_id" {
  description = "GCP project that owns the (long-lived) Apigee X organization"
  type        = string
}

variable "org_id" {
  description = "Apigee X organization name (organizations/{org}); provisioned by a manual bootstrap step, not by Terraform"
  type        = string
}

variable "region" {
  description = "Region where the Apigee runtime instance is provisioned"
  type        = string
  default     = "us-west1"
}

variable "resource_suffix" {
  description = "Suffix appended to resource names to avoid collisions across test runs"
  type        = string
  default     = "test001"
}

variable "instance_region" {
  description = "Region for the second Apigee runtime instance (failover posture testing)"
  type        = string
  default     = "us-central1"
}
