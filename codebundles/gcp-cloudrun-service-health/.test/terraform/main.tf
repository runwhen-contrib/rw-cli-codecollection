terraform {
  required_version = ">= 1.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 4.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.0"
    }
  }
  backend "local" {}
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# -----------------------------------------------------------------------------
# Test Scenario 1: healthy_service (Ready, latest revision serving 100%)
# -----------------------------------------------------------------------------
resource "google_cloud_run_service" "healthy" {
  name     = "cr-healthy-${var.resource_suffix}"
  location = var.region

  template {
    spec {
      containers {
        image = "us-docker.pkg.dev/cloudrun/container/hello"
        resources {
          limits = {
            cpu    = "1"
            memory = "256Mi"
          }
        }
      }
      service_account_name = var.service_account_email
    }

    metadata {
      annotations = {
        "autoscaling.knative.dev/maxScale" = "5"
      }
    }
  }

  traffic {
    percent         = 100
    latest_revision = true
  }

  metadata {
    annotations = {
      "run.googleapis.com/ingress" = "all"
    }
    labels = {
      env       = "test"
      lifecycle = "deleteme"
      product   = "runwhen"
    }
  }

  depends_on = [google_project_service.run_api]
}

# -----------------------------------------------------------------------------
# Test Scenario 2: broken_service (never Ready -- bad container startup)
#
# A broken container causes the revision to fail startup and never reach Ready.
# Deployed via gcloud in a null_resource so the overall apply still succeeds.
# -----------------------------------------------------------------------------
resource "null_resource" "broken_service" {
  depends_on = [google_project_service.run_api]

  triggers = {
    project_id      = var.project_id
    region          = var.region
    resource_suffix = var.resource_suffix
    sa_email        = var.service_account_email
  }

  provisioner "local-exec" {
    command = <<-EOT
      gcloud run deploy cr-broken-${var.resource_suffix} \
        --project=${var.project_id} \
        --region=${var.region} \
        --image=us-docker.pkg.dev/cloudrun/container/hello \
        --service-account=${var.service_account_email} \
        --max-instances=2 \
        --command="bogus-does-not-exist" \
        --args="" \
        --quiet || true
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      gcloud run services delete cr-broken-${self.triggers.resource_suffix} \
        --project=${self.triggers.project_id} \
        --region=${self.triggers.region} \
        --quiet || true
    EOT
  }
}

# -----------------------------------------------------------------------------
# Test Scenario 3: latest0_service (Ready but latest revision serves 0%)
#
# Deploy the service, then pin 100% traffic to a specific (earlier) revision so
# the latest ready revision receives 0% of traffic -- exercising the serving and
# rollout detection paths.
# -----------------------------------------------------------------------------
resource "null_resource" "latest0_service" {
  depends_on = [google_project_service.run_api]

  triggers = {
    project_id      = var.project_id
    region          = var.region
    resource_suffix = var.resource_suffix
    sa_email        = var.service_account_email
  }

  provisioner "local-exec" {
    command = <<-EOT
      gcloud run deploy cr-latest0-${var.resource_suffix} \
        --project=${var.project_id} \
        --region=${var.region} \
        --image=us-docker.pkg.dev/cloudrun/container/hello \
        --service-account=${var.service_account_email} \
        --max-instances=3 \
        --no-traffic \
        --quiet || true
      # Re-acquire and pin all traffic to the just-created (non-latest) revision.
      REV=$(gcloud run revisions list --service=cr-latest0-${var.resource_suffix} \
        --region=${var.region} --project=${var.project_id} \
        --format='value(metadata.name)' --limit=1 2>/dev/null | head -n1)
      if [ -n "$REV" ]; then
        gcloud run services update-traffic cr-latest0-${var.resource_suffix} \
          --region=${var.region} --project=${var.project_id} \
          --to-revisions="$REV=100" --quiet || true
      fi
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      gcloud run services delete cr-latest0-${self.triggers.resource_suffix} \
        --project=${self.triggers.project_id} \
        --region=${self.triggers.region} \
        --quiet || true
    EOT
  }
}

resource "google_project_service" "run_api" {
  project = var.project_id
  service = "run.googleapis.com"
  disable_on_destroy = false
}
