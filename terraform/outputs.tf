output "instance_name" {
  value       = google_compute_instance.minecraft_server.name
  description = "Name of the deployed Compute Engine instance"
}

output "instance_public_ip" {
  value       = google_compute_instance.minecraft_server.network_interface[0].access_config[0].nat_ip
  description = "Public IP address for server connections"
}

output "iap_ssh_command" {
  value       = "gcloud compute ssh ${google_compute_instance.minecraft_server.name} --zone=${var.zone} --tunnel-through-iap"
  description = "GCloud CLI command to SSH via Identity-Aware Proxy"
}