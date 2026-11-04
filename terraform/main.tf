terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

############################
# Variables
############################

variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "Always Free e2-micro regions: us-west1, us-central1, us-east1"
  type        = string
  default     = "us-central1"

  validation {
    condition     = contains(["us-west1", "us-central1", "us-east1"], var.region)
    error_message = "Region must be us-west1, us-central1 or us-east1 to stay within the Always Free tier."
  }
}

variable "zone" {
  description = "Zone inside var.region. Null means <region>-a."
  type        = string
  default     = null

  validation {
    condition     = var.zone == null || can(regex("^(us-west1|us-central1|us-east1)-[a-z]$", var.zone))
    error_message = "Zone must be inside one of the free tier regions."
  }
}

variable "backup_bucket_name" {
  description = "Name of the Cloud Storage bucket for world backups. Null means <project_id>-minecraft-backups. If the bucket already exists, import it first (see the README)."
  type        = string
  default     = null

  validation {
    condition     = var.backup_bucket_name == null || can(regex("^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$", var.backup_bucket_name))
    error_message = "backup_bucket_name must be a valid Cloud Storage bucket name: 3-63 characters of lowercase letters, digits, dots, dashes or underscores, starting and ending with a letter or digit."
  }
}

variable "enable_external_ip" {
  description = "Attach external IPv4 address"
  type        = bool
  default     = true
}

variable "ssh_source_ranges" {
  description = "CIDRs allowed to SSH. Defaults to Google's IAP range; add <your-ip>/32 for direct SSH."
  type        = list(string)
  default     = ["35.235.240.0/20"]

  validation {
    condition     = length(var.ssh_source_ranges) > 0
    error_message = "ssh_source_ranges must contain at least one CIDR block."
  }

  validation {
    condition     = alltrue([for c in var.ssh_source_ranges : can(cidrhost(c, 0))])
    error_message = "Every entry in ssh_source_ranges must be a valid CIDR block, e.g. 203.0.113.7/32."
  }

  validation {
    condition     = !contains(var.ssh_source_ranges, "0.0.0.0/0") && !contains(var.ssh_source_ranges, "::/0")
    error_message = "ssh_source_ranges must not open SSH to the whole internet (0.0.0.0/0 or ::/0). Use the IAP range or specific /32 addresses."
  }
}

variable "require_os_login_2fa" {
  description = "Require 2-step verification for OS Login SSH sessions. Users need 2-step verification enabled on their Google account, or they will be locked out."
  type        = bool
  default     = false
}

variable "deletion_protection" {
  description = "Block deletion of the instance via API/Terraform."
  type        = bool
  default     = false
}

locals {
  zone               = coalesce(var.zone, "${var.region}-a")
  backup_bucket_name = coalesce(var.backup_bucket_name, "${var.project_id}-minecraft-backups")
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = local.zone
}

############################
# APIs
############################

resource "google_project_service" "apis" {
  for_each = toset([
    "compute.googleapis.com",
    "iam.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "storage.googleapis.com",
  ])

  service            = each.value
  disable_on_destroy = false
}

############################
# Static External IP Address
############################

resource "google_compute_address" "static_ip" {
  count = var.enable_external_ip ? 1 : 0

  name         = "minecraft-static-ip"
  address_type = "EXTERNAL"
  network_tier = "STANDARD"

  depends_on = [google_project_service.apis]
}

############################
# Identity & Service Account
############################

resource "google_service_account" "vm" {
  account_id   = "free-tier-vm"
  display_name = "free-tier-vm runtime"

  depends_on = [google_project_service.apis]
}

resource "google_project_iam_member" "vm_roles" {
  for_each = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.vm.email}"
}

############################
# Cloud Storage Backup Bucket
############################

resource "google_storage_bucket" "minecraft_backups" {
  name                        = local.backup_bucket_name
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true

  # Object versioning protects the Terraform state (backend.tf, prefix
  # "terraform/state") from accidental overwrites or deletion.
  versioning {
    enabled = true
  }

  # Only expire world backups. The Terraform state lives in this same bucket
  # and must never be aged out.
  lifecycle_rule {
    condition {
      age            = 30
      matches_prefix = ["backups/"]
    }
    action {
      type = "Delete"
    }
  }

  # With versioning on, deleting a backup only makes it noncurrent, so remove
  # noncurrent backup versions as well to keep storage within the free tier.
  lifecycle_rule {
    condition {
      with_state                 = "ARCHIVED"
      days_since_noncurrent_time = 1
      matches_prefix             = ["backups/"]
    }
    action {
      type = "Delete"
    }
  }

  # Keep only the 10 most recent previous versions of the Terraform state.
  lifecycle_rule {
    condition {
      with_state         = "ARCHIVED"
      num_newer_versions = 10
      matches_prefix     = ["terraform/state/"]
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_project_service.apis]
}

resource "google_storage_bucket_iam_member" "backup_uploader" {
  bucket = google_storage_bucket.minecraft_backups.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.vm.email}"
}

############################
# Network & Firewalls
############################

resource "google_compute_firewall" "ssh" {
  name        = "free-tier-vm-allow-ssh"
  description = "SSH to free-tier-vm (IAP by default)"
  network     = "default"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = var.ssh_source_ranges
  target_tags   = ["ssh"]

  depends_on = [google_project_service.apis]
}

resource "google_compute_firewall" "minecraft" {
  name        = "free-tier-vm-allow-minecraft"
  description = "Allow Minecraft Bedrock traffic (TCP/UDP 19132, 19133, and UDP ports 19140-19150)"
  network     = "default"

  allow {
    protocol = "tcp"
    ports    = ["19132"]
  }

  allow {
    protocol = "udp"
    ports    = ["19132", "19133", "19140-19150"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["minecraft"]

  depends_on = [google_project_service.apis]
}

############################
# Compute Instance
############################

resource "google_compute_instance" "free_tier_vm" {
  name         = "free-tier-vm"
  machine_type = "e2-micro"
  zone         = local.zone
  tags         = ["ssh", "minecraft"]

  deletion_protection       = var.deletion_protection
  allow_stopping_for_update = true

  labels = {
    env  = "personal"
    tier = "free"
  }

  boot_disk {
    auto_delete = true

    initialize_params {
      image = "debian-cloud/debian-12"
      size  = 30
      type  = "pd-standard"
    }
  }

  network_interface {
    network = "default"

    dynamic "access_config" {
      for_each = var.enable_external_ip ? [1] : []
      content {
        nat_ip       = google_compute_address.static_ip[0].address
        network_tier = "STANDARD"
      }
    }
  }

  scheduling {
    on_host_maintenance = "MIGRATE"
    automatic_restart   = true
    preemptible         = false
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  service_account {
    email  = google_service_account.vm.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    enable-oslogin         = "TRUE"
    enable-oslogin-2fa     = var.require_os_login_2fa ? "TRUE" : "FALSE"
    block-project-ssh-keys = "TRUE"
    serial-port-enable     = "FALSE"
    backup-bucket          = local.backup_bucket_name
  }

  metadata_startup_script = <<-EOT
    #!/bin/bash
    set -eu

    # 0. Harden sshd. OS Login handles authentication, so password and root
    #    logins are never needed. Keyboard-interactive is left alone because
    #    OS Login 2FA uses it. The config is validated before sshd reloads.
    install -d -m 0755 /etc/ssh/sshd_config.d
    printf '%s\n' \
      'PermitRootLogin no' \
      'PasswordAuthentication no' \
      'PermitEmptyPasswords no' \
      'X11Forwarding no' \
      'AllowAgentForwarding no' \
      'MaxAuthTries 3' \
      'LoginGraceTime 30' \
      > /etc/ssh/sshd_config.d/10-hardening.conf
    if sshd -t; then
      systemctl reload ssh
    else
      rm -f /etc/ssh/sshd_config.d/10-hardening.conf
    fi

    # 1. 1 GB Swap creation
    if [ ! -f /swapfile ]; then
      fallocate -l 1G /swapfile
      chmod 600 /swapfile
      mkswap /swapfile
      swapon /swapfile
      echo '/swapfile none swap sw 0 0' >> /etc/fstab
    elif ! swapon --show | grep -q /swapfile; then
      swapon /swapfile
    fi

    # 2. Install Docker & Unattended Upgrades
    apt-get update -qq
    apt-get install -y -qq unattended-upgrades ca-certificates curl gnupg

    if ! command -v docker &> /dev/null; then
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      chmod a+r /etc/apt/keyrings/docker.gpg

      echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
        $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null

      apt-get update -qq
      apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi

    # 3. Install Google Cloud Ops Agent
    if ! dpkg -s google-cloud-ops-agent >/dev/null 2>&1; then
      curl -sSO https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh
      bash add-google-cloud-ops-agent-repo.sh --also-install
    fi
  EOT

  depends_on = [
    google_project_service.apis,
    google_project_iam_member.vm_roles,
  ]
}

############################
# Outputs
############################

output "instance_name" {
  value = google_compute_instance.free_tier_vm.name
}

output "static_external_ip" {
  description = "Static IP assigned to the Minecraft VM"
  value       = one(google_compute_address.static_ip[*].address)
}

output "backup_bucket_name" {
  description = "Name of the GCS bucket for world backups"
  value       = google_storage_bucket.minecraft_backups.name
}

output "ssh_command_iap" {
  description = "SSH through IAP"
  value       = "gcloud compute ssh ${google_compute_instance.free_tier_vm.name} --zone ${local.zone} --project ${var.project_id} --tunnel-through-iap"
}