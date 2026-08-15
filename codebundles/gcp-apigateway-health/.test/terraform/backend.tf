terraform {
  required_version = ">= 1.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 5.0"
    }
    # Used to let a newly created Api's managed service become bindable before
    # we try to enable it -- see google_project_service.managed in main.tf.
    time = {
      source  = "hashicorp/time"
      version = ">= 0.9"
    }
  }
  backend "local" {}
}
