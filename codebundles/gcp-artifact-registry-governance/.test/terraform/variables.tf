variable "project_id" {
  description = "GCP project ID for test Artifact Registry resources"
  type        = string
}

variable "region" {
  description = "Primary Artifact Registry location"
  type        = string
  default     = "us-central1"
}

variable "codebundle" {
  description = "CodeBundle name prefix for test resources"
  type        = string
  default     = "gar-gov"
}

variable "tags" {
  description = "Tags applied to test resources"
  type        = map(string)
  default = {
    purpose    = "codebundle-test"
    codebundle = "gcp-artifact-registry-governance"
  }
}
