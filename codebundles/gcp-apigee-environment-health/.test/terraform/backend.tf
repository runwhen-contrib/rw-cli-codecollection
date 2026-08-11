terraform {
  required_version = ">= 1.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 4.0"
    }
    # Every Apigee resource in main.tf uses the beta provider; declare it
    # explicitly rather than relying on Terraform's implicit resolution.
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 4.0"
    }
  }
  backend "local" {}
}
