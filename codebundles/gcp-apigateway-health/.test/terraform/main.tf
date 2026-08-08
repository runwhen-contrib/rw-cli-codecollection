# -----------------------------------------------------------------------------
# gcp-apigateway-health -- Test Infrastructure
#
# Provisions a set of GCP API Gateway fixtures (BETA resources -> google-beta
# provider) covering both healthy and deliberately broken scenarios:
#
#   1. healthy-gateway  - Api/ApiConfig/Gateway all ACTIVE, gateway pointed at
#                         the newest config, managed service enabled, gateway
#                         service account holds run.invoker on the backend.
#   2. dangling-backend  - ApiConfig (+ gateway) referencing a Cloud Run address
#                          that does not exist. NOTE: this does NOT produce a
#                          FAILED ApiConfig -- see the scenario 2 block below.
#   3. missing-invoker   - Gateway whose service account is NOT bound to
#                          roles/run.invoker on the backing Cloud Run service
#                          -> every request to that route 403s.
#   4. config-drift      - A newer ACTIVE ApiConfig exists but the gateway is
#                          left pinned to the older config.
# -----------------------------------------------------------------------------

locals {
  suffix      = var.resource_suffix
  suffix_dash = replace(var.resource_suffix, "/[^a-zA-Z0-9]/", "-")

  # Services this fixture set cannot provision without. On a project that has
  # never used API Gateway these are all disabled, and the first
  # google_api_gateway_api fails immediately.
  required_services = [
    "apigateway.googleapis.com",
    "servicemanagement.googleapis.com",
    "servicecontrol.googleapis.com",
    "run.googleapis.com",
    "monitoring.googleapis.com",
    "logging.googleapis.com",
  ]
}

# -----------------------------------------------------------------------------
# API enablement
#
# disable_on_destroy = false so that `terraform destroy` does not disable a
# service the project may have been using before this harness ran.
# -----------------------------------------------------------------------------
resource "google_project_service" "required" {
  for_each = toset(local.required_services)

  project = var.project_id
  service = each.value

  disable_on_destroy         = false
  disable_dependent_services = false
}

# -----------------------------------------------------------------------------
# Backend Cloud Run services
# -----------------------------------------------------------------------------
resource "google_cloud_run_service" "backend" {
  name     = "apigw-backend-${local.suffix_dash}"
  location = var.region
  project  = var.project_id

  depends_on = [google_project_service.required]

  template {
    spec {
      containers {
        image = "us-docker.pkg.dev/cloudrun/container/hello"
      }
    }
  }

  traffic {
    percent         = 100
    latest_revision = true
  }
}

resource "google_cloud_run_service" "backend_noinvoke" {
  name     = "apigw-backend-noinv-${local.suffix_dash}"
  location = var.region
  project  = var.project_id

  depends_on = [google_project_service.required]

  template {
    spec {
      containers {
        image = "us-docker.pkg.dev/cloudrun/container/hello"
      }
    }
  }

  traffic {
    percent         = 100
    latest_revision = true
  }
}

# -----------------------------------------------------------------------------
# Scenario 1: healthy API + config + gateway on 'backend'
# -----------------------------------------------------------------------------
resource "google_api_gateway_api" "healthy" {
  provider = google-beta
  api_id   = "apigw-healthy-${local.suffix_dash}"
  project  = var.project_id

  depends_on = [google_project_service.required]
}

resource "google_api_gateway_api_config" "healthy" {
  provider      = google-beta
  api           = google_api_gateway_api.healthy.api_id
  api_config_id = "apigw-cfg-healthy-${local.suffix_dash}"
  project       = var.project_id

  openapi_documents {
    document {
      path     = "spec.yaml"
      contents = base64encode(templatefile("${path.module}/specs/healthy.yaml", {
        api_name    = google_api_gateway_api.healthy.api_id
        backend_url = google_cloud_run_service.backend.status[0].url
      }))
    }
  }
}

resource "google_cloud_run_service_iam_member" "healthy_invoker" {
  location = google_cloud_run_service.backend.location
  project  = google_cloud_run_service.backend.project
  service  = google_cloud_run_service.backend.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

resource "google_api_gateway_gateway" "healthy" {
  provider    = google-beta
  api_config  = google_api_gateway_api_config.healthy.id
  gateway_id  = "apigw-gw-healthy-${local.suffix_dash}"
  project     = var.project_id
  region      = var.region
}

# -----------------------------------------------------------------------------
# Scenario 2: dangling backend -- the config references a Cloud Run address that
# does not exist.
#
# This scenario was originally written to produce an ApiConfig in state FAILED.
# It does not: API Gateway accepts a syntactically valid spec whose backend host
# does not resolve, so the config settles ACTIVE. (A spec malformed enough to be
# rejected fails the create call outright, which errors terraform rather than
# leaving a FAILED resource behind -- so a FAILED ApiConfig cannot be
# provisioned reliably here at all.)
#
# What it *does* give us is a genuine dangling-backend fixture for
# check_backends.sh -- but only if a Gateway exists to reach the config, since
# that check iterates gateways. Hence the gateway below.
#
# check_states.sh's FAILED branch is covered offline instead, by
# .test/offline/run_offline_checks.sh, which feeds it a synthetic inventory.
# -----------------------------------------------------------------------------
resource "google_api_gateway_api" "broken" {
  provider = google-beta
  api_id   = "apigw-broken-${local.suffix_dash}"
  project  = var.project_id

  depends_on = [google_project_service.required]
}

resource "google_api_gateway_api_config" "broken" {
  provider      = google-beta
  api           = google_api_gateway_api.broken.api_id
  api_config_id = "apigw-cfg-broken-${local.suffix_dash}"
  project       = var.project_id

  openapi_documents {
    document {
      path     = "spec.yaml"
      contents = base64encode(templatefile("${path.module}/specs/broken.yaml", {
        api_name = google_api_gateway_api.broken.api_id
      }))
    }
  }
}

# Gateway for the dangling-backend config, so check_backends.sh can actually
# reach it (that check walks gateways, not configs).
resource "google_api_gateway_gateway" "broken" {
  provider   = google-beta
  api_config = google_api_gateway_api_config.broken.id
  gateway_id = "apigw-gw-broken-${local.suffix_dash}"
  project    = var.project_id
  region     = var.region
}

# -----------------------------------------------------------------------------
# Scenario 3: Gateway whose service account is missing run.invoker
# -----------------------------------------------------------------------------
resource "google_api_gateway_api" "noinv" {
  provider = google-beta
  api_id   = "apigw-noinv-${local.suffix_dash}"
  project  = var.project_id

  depends_on = [google_project_service.required]
}

resource "google_api_gateway_api_config" "noinv" {
  provider      = google-beta
  api           = google_api_gateway_api.noinv.api_id
  api_config_id = "apigw-cfg-noinv-${local.suffix_dash}"
  project       = var.project_id

  openapi_documents {
    document {
      path     = "spec.yaml"
      contents = base64encode(templatefile("${path.module}/specs/healthy.yaml", {
        api_name    = google_api_gateway_api.noinv.api_id
        backend_url = google_cloud_run_service.backend_noinvoke.status[0].url
      }))
    }
  }
}

# NOTE: intentionally NO google_cloud_run_service_iam_member of
# roles/run.invoker for this gateway -> check_invoker_binding.sh must flag it.
resource "google_api_gateway_gateway" "noinv" {
  provider   = google-beta
  api_config = google_api_gateway_api_config.noinv.id
  gateway_id = "apigw-gw-noinv-${local.suffix_dash}"
  project    = var.project_id
  region     = var.region
}

# -----------------------------------------------------------------------------
# Scenario 4: config drift -- a newer ACTIVE config exists but the gateway is
# pinned to the older one
# -----------------------------------------------------------------------------
resource "google_api_gateway_api" "drift" {
  provider = google-beta
  api_id   = "apigw-drift-${local.suffix_dash}"
  project  = var.project_id

  depends_on = [google_project_service.required]
}

resource "google_api_gateway_api_config" "drift_v1" {
  provider      = google-beta
  api           = google_api_gateway_api.drift.api_id
  api_config_id = "apigw-cfg-drift-v1-${local.suffix_dash}"
  project       = var.project_id

  openapi_documents {
    document {
      path     = "spec.yaml"
      contents = base64encode(templatefile("${path.module}/specs/healthy.yaml", {
        api_name    = google_api_gateway_api.drift.api_id
        backend_url = google_cloud_run_service.backend.status[0].url
      }))
    }
  }
}

# Gateway pinned to v1...
resource "google_api_gateway_gateway" "drift" {
  provider   = google-beta
  api_config = google_api_gateway_api_config.drift_v1.id
  gateway_id = "apigw-gw-drift-${local.suffix_dash}"
  project    = var.project_id
  region     = var.region
}

# ...while a newer v2 ACTIVE config exists that the gateway is never pointed at.
#
# GCP serializes ApiConfig creation per Api and CANCELS an in-flight older
# create when a newer one supersedes it. Creating v1 and v2 in parallel makes
# v1 fail with "canceled due to a superseding API Config", which also takes out
# the gateway that depends on it -- so this whole scenario silently fails to
# materialize. depends_on forces v1 to settle before v2 starts.
resource "google_api_gateway_api_config" "drift_v2" {
  provider      = google-beta
  api           = google_api_gateway_api.drift.api_id
  api_config_id = "apigw-cfg-drift-v2-${local.suffix_dash}"
  project       = var.project_id

  depends_on = [
    google_api_gateway_api_config.drift_v1,
    google_api_gateway_gateway.drift,
  ]

  openapi_documents {
    document {
      path     = "spec.yaml"
      contents = base64encode(templatefile("${path.module}/specs/healthy.yaml", {
        api_name    = google_api_gateway_api.drift.api_id
        backend_url = google_cloud_run_service.backend.status[0].url
      }))
    }
  }
}
