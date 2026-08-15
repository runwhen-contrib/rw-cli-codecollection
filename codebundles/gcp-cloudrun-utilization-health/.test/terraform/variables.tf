variable "project_id" {
  description = "GCP project ID where Cloud Run services are provisioned."
  type        = string
}

variable "region" {
  description = "GCP region where Cloud Run services are provisioned."
  type        = string
  default     = "us-central1"
}

variable "credentials_file" {
  description = "Path to the GCP service account JSON. Empty uses ADC."
  type        = string
  default     = ""
}

variable "service_healthy_name" {
  description = "Name of the healthy Cloud Run service fixture."
  type        = string
  default     = "healthy-service-test001"
}

variable "service_unbounded_name" {
  description = "Name of the unbounded-max-instances Cloud Run service fixture."
  type        = string
  default     = "unbounded-service-test001"
}

variable "service_mininstances_name" {
  description = "Name of the min-instances Cloud Run service fixture."
  type        = string
  default     = "mininstances-service-test001"
}

variable "service_lowconcurrency_name" {
  description = "Name of the low-concurrency Cloud Run service fixture."
  type        = string
  default     = "lowconcurrency-service-test001"
}
