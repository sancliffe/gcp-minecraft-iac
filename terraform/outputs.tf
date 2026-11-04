output "instance_name" {
  value = google_compute_instance.minecraft_server.name
}

output "instance_ip" {
  value = google_compute_instance.minecraft_server.network_interface[0].access_config[0].nat_ip
}

output "connect_via_iap_command" {
  value = "gcloud compute ssh ${google_compute_instance.minecraft_server.name} --zone=${var.zone} --tunnel-through-iap"
}