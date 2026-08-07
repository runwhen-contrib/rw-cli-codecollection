terraform {
  required_version = ">= 1.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 4.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# -----------------------------------------------------------------------------
# Shared network pieces used by the test VMs
# -----------------------------------------------------------------------------
resource "google_compute_network" "vpc" {
  name                    = "gcp-vm-health-vpc-${var.resource_suffix}"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnet" {
  name          = "gcp-vm-health-subnet-${var.resource_suffix}"
  network       = google_compute_network.vpc.id
  region        = var.region
  ip_cidr_range = "10.0.0.0/24"
}

resource "google_compute_firewall" "allow_ssh" {
  name    = "gcp-vm-health-allow-ssh-${var.resource_suffix}"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  target_tags   = ["ssh"]
  source_ranges = ["0.0.0.0/0"]
}

# -----------------------------------------------------------------------------
# Test Scenario 1: healthy_vm
# A RUNNING standalone VM that should pass all checks.
# -----------------------------------------------------------------------------
resource "google_compute_instance" "healthy" {
  name         = "healthy-vm-${var.resource_suffix}"
  machine_type = "e2-micro"
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.id
    access_config {}
  }

  tags = ["ssh"]

  metadata = {
    enable-guest-attributes = "true"
  }

  labels = {
    env       = "test"
    lifecycle = "deleteme"
    product   = "runwhen"
  }

  depends_on = [google_compute_firewall.allow_ssh]
}

# -----------------------------------------------------------------------------
# Test Scenario 2: unhealthy_vm (simulates a VM that is not running)
# A STOPPED standalone VM that the uptime / summary checks should flag as a
# non-RUNNING (degraded) VM.
# -----------------------------------------------------------------------------
resource "google_compute_instance" "unhealthy" {
  name           = "stopped-vm-${var.resource_suffix}"
  machine_type   = "e2-micro"
  zone           = var.zone
  desired_status = "STOPPED"

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.id
  }

  labels = {
    env       = "test"
    lifecycle = "deleteme"
    product   = "runwhen"
  }
}

# -----------------------------------------------------------------------------
# Test Scenario 3: grouped_vm (exclusion check)
# A VM that belongs to an unmanaged instance group. The bundle MUST exclude
# this VM from standalone discovery so that no SLX is generated for it.
# -----------------------------------------------------------------------------
resource "google_compute_instance" "grouped" {
  name         = "grouped-vm-${var.resource_suffix}"
  machine_type = "e2-micro"
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.id
  }

  labels = {
    env       = "test"
    lifecycle = "deleteme"
    product   = "runwhen"
  }
}

resource "google_compute_instance_group" "grouped_ig" {
  name        = "grouped-ig-${var.resource_suffix}"
  zone        = var.zone
  instances   = [google_compute_instance.grouped.id]
  description = "Unmanaged instance group containing a VM that should be excluded from standalone VM discovery."

  named_port {
    name = "http"
    port = 80
  }
}

# -----------------------------------------------------------------------------
# Outputs used by tests / operator guidance
# -----------------------------------------------------------------------------
output "healthy_vm_name" {
  value = google_compute_instance.healthy.name
}

output "unhealthy_stopped_vm_name" {
  value = google_compute_instance.unhealthy.name
}

output "grouped_vm_name" {
  value = google_compute_instance.grouped.name
}

output "discovery_expected_standalone_vms" {
  description = "Names that gcp-compute-vm-health should discover as standalone (grouped-vm excluded)."
  value       = [google_compute_instance.healthy.name, google_compute_instance.unhealthy.name]
}
