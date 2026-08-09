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
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -uo pipefail
      SVC=cr-broken-${var.resource_suffix}

      # This deploy is EXPECTED to fail: the container command does not exist, so
      # the revision never passes its startup probe. `|| true` absorbs that.
      gcloud run deploy "$SVC" \
        --project=${var.project_id} \
        --region=${var.region} \
        --image=us-docker.pkg.dev/cloudrun/container/hello \
        --service-account=${var.service_account_email} \
        --max-instances=2 \
        --command="bogus-does-not-exist" \
        --args="" \
        --quiet || true

      # ...but the service itself must exist, otherwise the deploy failed for some
      # other reason and this scenario would be silently missing from the suite.
      if ! gcloud run services describe "$SVC" \
           --project=${var.project_id} --region=${var.region} >/dev/null 2>&1; then
        echo "ERROR: $SVC was not created; the broken-service scenario is missing." >&2
        exit 1
      fi
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
# `--no-traffic` is rejected when *creating* a service, so this is a three-step
# deploy: create the service normally (revision 1 becomes Ready and serves 100%),
# deploy a second revision with --no-traffic, then pin 100% of traffic back to
# revision 1. The result is a Ready service whose latest ready revision serves 0%
# of traffic -- exercising the serving and rollout detection paths.
#
# Deliberately NOT suffixed with `|| true`: if this scenario cannot be built the
# apply must fail loudly rather than leave the test suite silently covering less
# than it claims.
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
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      SVC=cr-latest0-${var.resource_suffix}

      # 1. Create the service. The first revision becomes Ready and serves 100%.
      gcloud run deploy "$SVC" \
        --project=${var.project_id} \
        --region=${var.region} \
        --image=us-docker.pkg.dev/cloudrun/container/hello \
        --service-account=${var.service_account_email} \
        --max-instances=3 \
        --quiet

      # 2. Record it -- this is the revision traffic gets pinned to in step 4.
      FIRST_REV=$(gcloud run services describe "$SVC" \
        --project=${var.project_id} --region=${var.region} \
        --format='value(status.latestReadyRevisionName)')
      if [ -z "$FIRST_REV" ]; then
        echo "ERROR: $SVC has no ready revision after create; cannot build the latest-0% scenario." >&2
        exit 1
      fi

      # 3. Deploy a second revision with no traffic (valid only on an existing service).
      gcloud run deploy "$SVC" \
        --project=${var.project_id} \
        --region=${var.region} \
        --image=us-docker.pkg.dev/cloudrun/container/hello \
        --service-account=${var.service_account_email} \
        --max-instances=3 \
        --set-env-vars=REVISION_MARKER=v2 \
        --no-traffic \
        --quiet

      # 4. Pin all traffic to revision 1, leaving the latest ready revision at 0%.
      gcloud run services update-traffic "$SVC" \
        --project=${var.project_id} --region=${var.region} \
        --to-revisions="$FIRST_REV=100" --quiet
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
  project            = var.project_id
  service            = "run.googleapis.com"
  disable_on_destroy = false
}
