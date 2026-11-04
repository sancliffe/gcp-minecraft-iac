output "instance_name" {
  description = "Name of the deployed Compute Engine instance"
  value       = google_compute_instance.free_tier_vm.name
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
