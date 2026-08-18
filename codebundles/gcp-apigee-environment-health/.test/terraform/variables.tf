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

# --- Substrate variables -----------------------------------------------------
# network, create_network, peering_prefix_length and disable_vpc_peering are no
# longer read by anything in this configuration: the resources they described
# moved to .test/apigee_prerequisites.sh, which reads them from the environment
# as TF_VAR_network, TF_VAR_create_network and so on.
#
# They stay DECLARED here on purpose. tf.secret sets them, and Terraform emits a
# warning for every variable a tfvars file or TF_VAR_ environment variable sets
# without a matching declaration -- so deleting these would trade four unused
# declarations for four warnings on every plan, and would break the single
# tf.secret that both this configuration and the prerequisites script read.
variable "network" {
  description = "VPC network peered with the Apigee runtime (the org's authorizedNetwork). Created by Terraform when create_network is true, otherwise expected to already exist."
  type        = string
  default     = "default"
}

variable "create_network" {
  description = "Create the VPC network named by var.network instead of expecting it to exist. Leave false to use the project's auto-created `default` network. The network is a prerequisite bound to the org's authorizedNetwork, so it is applied by bootstrap-prerequisites and is not per-run."
  type        = bool
  default     = false
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
