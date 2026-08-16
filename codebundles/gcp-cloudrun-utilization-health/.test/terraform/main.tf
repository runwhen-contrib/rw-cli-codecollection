terraform {
  backend "local" {}
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  credentials = var.credentials_file != "" ? var.credentials_file : null
}

locals {
  common_labels = {
    "env"       = "test"
    "lifecycle" = "deleteme"
    "product"   = "runwhen"
  }
}

# -----------------------------------------------------------------------------
# Healthy Cloud Run service -- bounded max instances, default (sane) concurrency,
# no min instances, baseline CPU/memory allocation. Should produce no issues for
# the concurrency/scaling config check.
# -----------------------------------------------------------------------------
resource "google_cloud_run_service" "healthy" {
  name     = var.service_healthy_name
  location = var.region
  project  = var.project_id
  metadata {
    labels = local.common_labels
  }
  template {
    metadata {
      annotations = {
        "autoscaling.knative.dev/maxScale" = "5"
        "autoscaling.knative.dev/minScale" = "0"
      }
    }
    spec {
      container_concurrency = 80
      containers {
        image = "us-docker.pkg.dev/cloudrun/container/hello"
        resources {
          limits = {
            cpu    = "1"
            memory = "256Mi"
          }
        }
      }
    }
  }
  traffic {
    percent = 100
  }
}

# -----------------------------------------------------------------------------
# Unbounded max instances service -- no autoscaling.knative.dev/maxScale set.
# Flags an unbounded-scaling cost risk.
# -----------------------------------------------------------------------------
resource "google_cloud_run_service" "unbounded" {
  name     = var.service_unbounded_name
  location = var.region
  project  = var.project_id
  metadata {
    labels = local.common_labels
  }
  template {
    metadata {
      annotations = {
        "autoscaling.knative.dev/minScale" = "0"
      }
    }
    spec {
      container_concurrency = 80
      containers {
        image = "us-docker.pkg.dev/cloudrun/container/hello"
        resources {
          limits = {
            cpu    = "2"
            memory = "512Mi"
          }
        }
      }
    }
  }
  traffic {
    percent = 100
  }
}

# -----------------------------------------------------------------------------
# Min-instances service -- keeps an instance warm. Flags idle-warming cost risk
# (and is a candidate for the under-utilized check).
# -----------------------------------------------------------------------------
resource "google_cloud_run_service" "mininstances" {
  name     = var.service_mininstances_name
  location = var.region
  project  = var.project_id
  metadata {
    labels = local.common_labels
  }
  template {
    metadata {
      annotations = {
        "autoscaling.knative.dev/maxScale" = "2"
        "autoscaling.knative.dev/minScale" = "1"
      }
    }
    spec {
      container_concurrency = 80
      containers {
        image = "us-docker.pkg.dev/cloudrun/container/hello"
        resources {
          limits = {
            cpu    = "1"
            memory = "256Mi"
          }
        }
      }
    }
  }
  traffic {
    percent = 100
  }
}

# -----------------------------------------------------------------------------
# Low-concurrency service -- container_concurrency set well below the sane
# threshold. Flags a very-low-concurrency cost issue.
# -----------------------------------------------------------------------------
resource "google_cloud_run_service" "lowconcurrency" {
  name     = var.service_lowconcurrency_name
  location = var.region
  project  = var.project_id
  metadata {
    labels = local.common_labels
  }
  template {
    metadata {
      annotations = {
        "autoscaling.knative.dev/maxScale" = "5"
        "autoscaling.knative.dev/minScale" = "0"
      }
    }
    spec {
      container_concurrency = 5
      containers {
        image = "us-docker.pkg.dev/cloudrun/container/hello"
        resources {
          limits = {
            cpu    = "1"
            memory = "256Mi"
          }
        }
      }
    }
  }
  traffic {
    percent = 100
  }
}
