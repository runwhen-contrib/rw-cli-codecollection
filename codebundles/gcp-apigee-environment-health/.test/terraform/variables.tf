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

variable "network" {
  description = "VPC network peered with the Apigee runtime (the org's authorizedNetwork)"
  type        = string
  default     = "default"
}

variable "peering_prefix_length" {
  description = "Prefix length of the reserved Service Networking range. Apigee needs a non-overlapping /22 per runtime instance and this config provisions two, so /21 is the minimum that supports both."
  type        = number
  default     = 21

  validation {
    condition     = var.peering_prefix_length <= 21
    error_message = "A /22 holds only one Apigee instance and fails the second with RANGES_EXHAUSTED. Use a smaller prefix length (/21 or below) to cover both instances."
  }
}

variable "disable_vpc_peering" {
  description = "Set true for an org provisioned with disableVpcPeering; skips the reserved range and peering connection entirely"
  type        = bool
  default     = false
}
