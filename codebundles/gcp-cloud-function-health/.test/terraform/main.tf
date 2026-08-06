terraform {
  required_version = ">= 1.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 4.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.0"
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
# Shared: bucket holding the function source archives
# -----------------------------------------------------------------------------
resource "google_storage_bucket" "function_source" {
  name                        = "cf-health-src-${var.project_id}-${var.resource_suffix}"
  location                    = var.region
  force_destroy               = true
  uniform_bucket_level_access = true

  labels = {
    env       = "test"
    lifecycle = "deleteme"
    product   = "runwhen"
  }
}

# -----------------------------------------------------------------------------
# Test Scenario 1: healthy_function (gen1, deploys cleanly, stays ACTIVE)
# -----------------------------------------------------------------------------
data "archive_file" "healthy" {
  type        = "zip"
  source_dir  = "${path.module}/src/healthy"
  output_path = "${path.module}/.build/healthy.zip"
}

resource "google_storage_bucket_object" "healthy" {
  name   = "healthy-${data.archive_file.healthy.output_md5}.zip"
  bucket = google_storage_bucket.function_source.name
  source = data.archive_file.healthy.output_path
}

resource "google_cloudfunctions_function" "healthy_function" {
  name                  = "healthy-function-${var.resource_suffix}"
  description           = "Healthy test function (gen1, ACTIVE)"
  runtime               = "nodejs20"
  available_memory_mb   = 128
  source_archive_bucket = google_storage_bucket.function_source.name
  source_archive_object = google_storage_bucket_object.healthy.name
  trigger_http          = true
  entry_point           = "helloWorld"
  region                = var.region

  labels = {
    env       = "test"
    lifecycle = "deleteme"
    product   = "runwhen"
  }
}

# -----------------------------------------------------------------------------
# Test Scenario 2: healthy_function_gen2 (gen2, deploys cleanly, stays ACTIVE)
# -----------------------------------------------------------------------------
resource "google_cloudfunctions2_function" "healthy_function_gen2" {
  name        = "healthy-function-gen2-${var.resource_suffix}"
  description = "Healthy test function (gen2, ACTIVE)"
  location    = var.region

  build_config {
    runtime     = "nodejs20"
    entry_point = "helloWorld"
    source {
      storage_source {
        bucket = google_storage_bucket.function_source.name
        object = google_storage_bucket_object.healthy.name
      }
    }
  }

  service_config {
    max_instance_count = 1
    available_memory   = "128Mi"
  }

  labels = {
    env       = "test"
    lifecycle = "deleteme"
    product   = "runwhen"
  }
}

# -----------------------------------------------------------------------------
# Test Scenario 3: failing_function (gen1, build breaks, stays FAILED)
#
# Terraform's google_cloudfunctions_function would fail the whole apply on a
# broken build, so this is deployed via gcloud in a null_resource with the
# error tolerated -- the function is left behind in a non-ACTIVE state.
# -----------------------------------------------------------------------------
resource "null_resource" "failing_function" {
  depends_on = [google_storage_bucket.function_source]

  triggers = {
    project_id      = var.project_id
    region          = var.region
    resource_suffix = var.resource_suffix
    source_hash     = sha256(join("", [for f in fileset("${path.module}/src/broken", "**") : filesha256("${path.module}/src/broken/${f}")]))
  }

  provisioner "local-exec" {
    command = <<-EOT
      gcloud functions deploy failing-function-${var.resource_suffix} \
        --project=${var.project_id} \
        --region=${var.region} \
        --gen1 \
        --runtime=nodejs20 \
        --source=${path.module}/src/broken \
        --entry-point=brokenHandler \
        --trigger-http \
        --quiet || true
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      gcloud functions delete failing-function-${self.triggers.resource_suffix} \
        --project=${self.triggers.project_id} \
        --region=${self.triggers.region} \
        --quiet || true
    EOT
  }
}

# -----------------------------------------------------------------------------
# Test Scenario 4: failing_function_gen2 (gen2, build breaks, stays FAILED)
# -----------------------------------------------------------------------------
resource "null_resource" "failing_function_gen2" {
  depends_on = [google_storage_bucket.function_source]

  triggers = {
    project_id      = var.project_id
    region          = var.region
    resource_suffix = var.resource_suffix
    source_hash     = sha256(join("", [for f in fileset("${path.module}/src/broken", "**") : filesha256("${path.module}/src/broken/${f}")]))
  }

  provisioner "local-exec" {
    command = <<-EOT
      gcloud functions deploy failing-function-gen2-${var.resource_suffix} \
        --project=${var.project_id} \
        --region=${var.region} \
        --gen2 \
        --runtime=nodejs20 \
        --source=${path.module}/src/broken \
        --entry-point=brokenHandler \
        --trigger-http \
        --quiet || true
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      gcloud functions delete failing-function-gen2-${self.triggers.resource_suffix} \
        --project=${self.triggers.project_id} \
        --region=${self.triggers.region} \
        --gen2 \
        --quiet || true
    EOT
  }
}
