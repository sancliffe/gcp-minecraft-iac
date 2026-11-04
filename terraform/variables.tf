variable "project_id" {
  type        = string
  description = "Google Cloud Project ID"
}

variable "region" {
  type        = string
  default     = "us-central1"
}

variable "zone" {
  type        = string
  default     = "us-central1-a"
}

variable "machine_type" {
  type        = string
  default     = "e2-medium"
}

variable "disk_size_gb" {
  type        = number
  default     = 50
}

variable "backup_bucket_name" {
  type        = string
  description = "GCS bucket name for world backups"
}

variable "network_name" {
  type    = string
  default = "default"
}

variable "subnetwork_name" {
  type    = string
  default = "default"
}