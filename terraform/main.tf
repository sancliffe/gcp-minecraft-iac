resource "google_service_account" "minecraft_sa" {
  account_id   = "minecraft-server-sa"
  display_name = "Minecraft Server Dedicated Service Account"
}

resource "google_storage_bucket_iam_member" "backup_bucket_access" {
  bucket = var.backup_bucket_name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.minecraft_sa.email}"
}

resource "google_compute_instance" "minecraft_server" {
  name         = "minecraft-server-instance"
  machine_type = var.machine_type
  zone         = var.zone

  tags = ["minecraft-server", "iap-ssh"]

  boot_disk {
    initialize_params {
      image = "cos-cloud/cos-stable"
      size  = var.disk_size_gb
      type  = "pd-balanced"
    }
  }

  network_interface {
    network    = var.network_name
    subnetwork = var.subnetwork_name
    # Public IP omitted or left dynamic only if needed; IAP preferred for SSH
    access_config {
      // Ephemeral public IP for game traffic (TCP 25565), secured via firewall
    }
  }

  scheduling {
    automatic_restart   = false
    on_host_maintenance = "TERMINATE"
    provisioning_model  = "SPOT"
    instance_termination_action = "STOP"
  }

  service_account {
    email  = google_service_account.minecraft_sa.email
    scopes = ["https://www.googleapis.com/auth/devstorage.read_write", "https://www.googleapis.com/auth/logging.write"]
  }

  metadata = {
    user-data = templatefile("${path.module}/cloud-init.yaml", {
      backup_bucket = var.backup_bucket_name
    })
  }
}