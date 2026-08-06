# -----------------------------------------------------------------------------
# gcp-cloud-loadbalancer-health -- Test Infrastructure
#
# Provisions a set of GCP Cloud Load Balancer fixtures covering the CodeBundle's
# detection scenarios:
#   1. healthy-http-lb     - Healthy external HTTP load balancer
#   2. healthy-https-lb    - HTTPS load balancer with a valid SSL certificate
#   3. expiring-cert-lb    - HTTPS load balancer with a certificate expiring
#                            within SSL_WARNING_DAYS (10 days)
#   4. unhealthy-backend   - Backend service whose members fail the health check
#
# A shared instance template + unmanaged instance groups keep this lean.
# -----------------------------------------------------------------------------

locals {
  suffix = var.resource_suffix
  tags   = ["lb-health-test"]
}

# -----------------------------------------------------------------------------
# Shared: healthy web instance template (serves HTTP on port 80)
# -----------------------------------------------------------------------------
resource "google_compute_instance_template" "web" {
  name         = "lb-health-web-${local.suffix}"
  machine_type = "e2-micro"

  disk {
    source_image = "debian-cloud/debian-12"
    auto_delete  = true
    boot         = true
  }

  network_interface {
    network    = var.network
    subnetwork = var.subnetwork != "" ? var.subnetwork : null
    access_config {}
  }

  metadata_startup_script = <<-EOT
    #!/bin/bash
    sudo apt-get update -y
    sudo apt-get install -y python3
    python3 -m http.server 80 --bind 0.0.0.0 &
  EOT

  tags = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_compute_firewall" "lb_health" {
  name    = "lb-health-allow-${local.suffix}"
  network = var.network

  allow {
    protocol = "tcp"
    ports    = ["80", "8080"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = local.tags
}

# -----------------------------------------------------------------------------
# Health checks
# -----------------------------------------------------------------------------
resource "google_compute_health_check" "http" {
  name = "lb-health-hc-http-${local.suffix}"

  http_health_check {
    port = 80
  }
}

resource "google_compute_health_check" "http_unhealthy" {
  name = "lb-health-hc-bad-${local.suffix}"

  http_health_check {
    # Points at a port the backends never serve -> all members unhealthy
    port = 8080
  }
}

# -----------------------------------------------------------------------------
# Scenario 1: healthy groups + backend services
# -----------------------------------------------------------------------------
resource "google_compute_instance_group_manager" "healthy" {
  name = "lb-health-ig-healthy-${local.suffix}"

  base_instance_name = "lb-health-web"
  zone               = var.zone

  version {
    instance_template = google_compute_instance_template.web.id
  }

  named_port {
    name = "http"
    port = 80
  }
}

resource "google_compute_backend_service" "healthy" {
  name        = "lb-health-bs-healthy-${local.suffix}"
  protocol    = "HTTP"
  port_name   = "http"
  timeout_sec = 30
  health_checks = [
    google_compute_health_check.http.id
  ]

  backend {
    group = google_compute_instance_group_manager.healthy.instance_group
  }
}

resource "google_compute_url_map" "http" {
  name            = "lb-health-urlmap-${local.suffix}"
  default_service = google_compute_backend_service.healthy.id
}

resource "google_compute_target_http_proxy" "http" {
  name    = "lb-health-proxy-http-${local.suffix}"
  url_map = google_compute_url_map.http.id
}

resource "google_compute_global_forwarding_rule" "http" {
  name       = "lb-health-fr-http-${local.suffix}"
  target     = google_compute_target_http_proxy.http.id
  port_range = "80"
  labels = {
    env       = "test"
    lifecycle = "deleteme"
    product   = "runwhen"
  }
}

# -----------------------------------------------------------------------------
# Scenario 2: HTTPS load balancer with a valid certificate
# -----------------------------------------------------------------------------
resource "google_compute_ssl_certificate" "valid" {
  name        = "lb-health-cert-valid-${local.suffix}"
  private_key = file("${path.module}/certs/lb-valid-key.pem")
  certificate = file("${path.module}/certs/lb-valid-cert.pem")
}

resource "google_compute_target_https_proxy" "https_valid" {
  name             = "lb-health-proxy-https-${local.suffix}"
  url_map          = google_compute_url_map.http.id
  ssl_certificates = [google_compute_ssl_certificate.valid.id]
}

resource "google_compute_global_forwarding_rule" "https_valid" {
  name       = "lb-health-fr-https-${local.suffix}"
  target     = google_compute_target_https_proxy.https_valid.id
  port_range = "443"
  labels = {
    env       = "test"
    lifecycle = "deleteme"
    product   = "runwhen"
  }
}

# -----------------------------------------------------------------------------
# Scenario 3: HTTPS load balancer with a certificate expiring within
#             SSL_WARNING_DAYS (10-day self-signed cert)
# -----------------------------------------------------------------------------
resource "google_compute_ssl_certificate" "expiring" {
  name        = "lb-health-cert-expiring-${local.suffix}"
  private_key = file("${path.module}/certs/lb-expiring-key.pem")
  certificate = file("${path.module}/certs/lb-expiring-cert.pem")
}

resource "google_compute_target_https_proxy" "https_expiring" {
  name             = "lb-health-proxy-https-exp-${local.suffix}"
  url_map          = google_compute_url_map.http.id
  ssl_certificates = [google_compute_ssl_certificate.expiring.id]
}

resource "google_compute_global_forwarding_rule" "https_expiring" {
  name       = "lb-health-fr-https-exp-${local.suffix}"
  target     = google_compute_target_https_proxy.https_expiring.id
  port_range = "443"
  labels = {
    env       = "test"
    lifecycle = "deleteme"
    product   = "runwhen"
  }
}

# -----------------------------------------------------------------------------
# Scenario 4: backend service whose members are unhealthy (health check port
#             never served -> get-health reports UNHEALTHY)
# -----------------------------------------------------------------------------
resource "google_compute_backend_service" "unhealthy" {
  name        = "lb-health-bs-unhealthy-${local.suffix}"
  protocol    = "HTTP"
  port_name   = "http"
  timeout_sec = 30
  health_checks = [
    google_compute_health_check.http_unhealthy.id
  ]

  backend {
    group = google_compute_instance_group_manager.healthy.instance_group
  }
}

resource "google_compute_url_map" "unhealthy" {
  name            = "lb-health-urlmap-bad-${local.suffix}"
  default_service = google_compute_backend_service.unhealthy.id
}

resource "google_compute_target_http_proxy" "unhealthy" {
  name    = "lb-health-proxy-bad-${local.suffix}"
  url_map = google_compute_url_map.unhealthy.id
}

resource "google_compute_global_forwarding_rule" "unhealthy" {
  name       = "lb-health-fr-bad-${local.suffix}"
  target     = google_compute_target_http_proxy.unhealthy.id
  port_range = "80"
  labels = {
    env       = "test"
    lifecycle = "deleteme"
    product   = "runwhen"
  }
}
