# -----------------------------------------------------------------------------
# Test Scenario 1: healthy_group
# A managed instance group backed by an autoscaler with a reachable target
# size. This group should pass member health, autoscaling, and (with OS Config
# enabled) patch/utilisation checks.
# -----------------------------------------------------------------------------
resource "google_compute_network" "ig_health_net" {
  name                    = "ig-health-net-${var.resource_suffix}"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"

  labels = {
    env       = "test"
    lifecycle = "deleteme"
    product   = "runwhen"
  }
}

resource "google_compute_subnetwork" "ig_health_subnet" {
  name          = "ig-health-subnet-${var.resource_suffix}"
  network       = google_compute_network.ig_health_net.id
  ip_cidr_range = "10.0.1.0/24"
  region        = var.region

  labels = {
    env       = "test"
    lifecycle = "deleteme"
    product   = "runwhen"
  }
}

resource "google_compute_instance_template" "ig_health_template" {
  name         = "ig-health-template-${var.resource_suffix}"
  machine_type = "e2-micro"

  disk {
    source_image = "debian-cloud/debian-12"
    auto_delete  = true
    boot         = true
  }

  network_interface {
    network    = google_compute_network.ig_health_net.id
    subnetwork = google_compute_subnetwork.ig_health_subnet.id
  }

  labels = {
    env       = "test"
    lifecycle = "deleteme"
    product   = "runwhen"
  }
}

resource "google_compute_instance_group_manager" "ig_healthy" {
  name               = "${var.instance_group_name_healthy}-${var.resource_suffix}"
  zone               = var.zone
  base_instance_name = "ig-healthy-vm"

  version {
    instance_template = google_compute_instance_template.ig_health_template.id
  }

  target_size = 2

  auto_healing_policies {
    health_check      = google_compute_health_check.ig_health_check.id
    initial_delay_sec = 300
  }

  named_port {
    name = "http"
    port = 80
  }

  labels = {
    env       = "test"
    lifecycle = "deleteme"
    product   = "runwhen"
  }
}

resource "google_compute_health_check" "ig_health_check" {
  name               = "ig-health-check-${var.resource_suffix}"
  check_interval_sec = 5
  timeout_sec        = 5

  tcp_health_check {
    port = 80
  }
}

resource "google_compute_autoscaler" "ig_healthy_autoscaler" {
  name   = "ig-healthy-autoscaler-${var.resource_suffix}"
  zone   = var.zone
  target = google_compute_instance_group_manager.ig_healthy.id

  autoscaling_policy {
    max_replicas    = 5
    min_replicas    = 2
    cooldown_period = 60

    cpu_utilization {
      target = 0.6
    }
  }
}

# -----------------------------------------------------------------------------
# Test Scenario 2: degraded_members
# An unmanaged instance group left empty, so the member-health and summary
# checks flag the group as having no (healthy) members.
# -----------------------------------------------------------------------------
resource "google_compute_instance_group" "ig_degraded" {
  name        = "${var.instance_group_name_degraded}-${var.resource_suffix}"
  description = "Unmanaged instance group with no members (degraded scenario)"
  zone        = var.zone
  network     = google_compute_network.ig_health_net.id

  labels = {
    env       = "test"
    lifecycle = "deleteme"
    product   = "runwhen"
  }
}
