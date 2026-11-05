locals {
  zone               = coalesce(var.zone, "${var.region}-a")
  backup_bucket_name = coalesce(var.backup_bucket_name, "${var.project_id}-minecraft-backups")
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

#############################
# Cloud Storage Backup Bucket
############################

# Google-managed encryption is fine here. Customer-managed keys need Cloud KMS,
# which costs money and is out of scope for a free-tier hobby server.
#tfsec:ignore:google-storage-bucket-encryption-customer-key
resource "google_storage_bucket" "minecraft_backups" {
  name                        = local.backup_bucket_name
  location                    = var.bucket_location
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true

  # Prevents 409 conflict errors during rapid destroy/re-apply cycles
  lifecycle {
    prevent_destroy = false
    create_before_destroy = false
  }

  # Only expire world backups. Terraform state is now stored locally in Cloud Shell.
  lifecycle_rule {
    condition {
      age          = 30
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
      with_state                   = "ARCHIVED"
      days_since_noncurrent_time = 1
      matches_prefix               = ["backups/"]
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_project_service.apis]
}

resource "google_storage_bucket_iam_member" "backup_uploader" {
  bucket = google_storage_bucket.minecraft_backups.name
  role   = "roles/storage.objectAdmin"
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

  # The default is Google's IAP range, which is a public address block. The
  # ssh_source_ranges validation rejects 0.0.0.0/0 and ::/0.
  #tfsec:ignore:google-compute-no-public-ingress
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

  # A public game server must accept traffic from the whole internet, which is
  # the default. Narrow minecraft_source_ranges for a private server.
  #tfsec:ignore:google-compute-no-public-ingress
  source_ranges = var.minecraft_source_ranges
  target_tags   = ["minecraft"]

  depends_on = [google_project_service.apis]
}

############################
# Compute Instance
############################

# block-project-ssh-keys is set to "TRUE" in the metadata below. tfsec only
# recognises a boolean true there, so it reports a false positive.
#tfsec:ignore:google-compute-no-project-wide-ssh-keys
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

  # Google-managed disk encryption; customer-managed keys cost money (Cloud KMS).
  #tfsec:ignore:google-compute-vm-disk-encryption-customer-key
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

    # Players reach the server over the public internet, so it needs an external IP.
    #tfsec:ignore:google-compute-no-public-ip
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
    enable_secure_boot           = true
    enable_vtpm                  = true
    enable_integrity_monitoring = true
  }

  service_account {
    # Least privilege: only what the Ops Agent and the backup upload need. IAM
    # roles on the service account are still the real gate, but a narrow scope
    # limits what a stolen metadata token can reach.
    email  = google_service_account.vm.email
    scopes = ["logging-write", "monitoring-write", "storage-rw"]
  }

  metadata = {
    enable-oslogin           = "TRUE"
    enable-oslogin-2fa       = var.require_os_login_2fa ? "TRUE" : "FALSE"
    block-project-ssh-keys = "TRUE"
    serial-port-enable       = "FALSE"
    backup-bucket            = local.backup_bucket_name

    # Copied to /opt/minecraft by the startup script, so the repo's files are the
    # source of truth and no SSH session is needed to start the server.
    docker-compose-yml = file("${path.module}/../docker-compose.yml")
    allowlist-json     = file("${path.module}/../data/allowlist.json")
  }

  # Runs as root on every boot: hardens sshd, adds swap, installs Docker, writes
  # the server files from the metadata above, schedules backups and starts the
  # server. Kept in a real file so it can be linted and tested.
  metadata_startup_script = file("${path.module}/../scripts/startup.sh")

  depends_on = [
    google_project_service.apis,
    google_project_iam_member.vm_roles,
  ]
}