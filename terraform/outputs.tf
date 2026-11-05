output "minecraft_address" {
  description = "Address to enter in Minecraft Bedrock (Play, Servers, Add Server): IP and port. Null when enable_external_ip is false."
  value       = var.enable_external_ip ? "${google_compute_address.static_ip[0].address}:19132" : null
}

output "static_external_ip" {
  description = "Static IP assigned to the Minecraft VM"
  value       = one(google_compute_address.static_ip[*].address)
}

output "instance_name" {
  description = "Name of the deployed Compute Engine instance"
  value       = google_compute_instance.free_tier_vm.name
}

output "backup_bucket_name" {
  description = "Name of the GCS bucket for world backups and Terraform state"
  value       = google_storage_bucket.minecraft_backups.name
}

output "server_image" {
  description = "Container image the VM runs (repository and tag)"
  value       = var.server_image
}

output "ssh_command_iap" {
  description = "SSH through IAP"
  value       = "gcloud compute ssh ${google_compute_instance.free_tier_vm.name} --zone ${local.zone} --project ${var.project_id} --tunnel-through-iap"
}
