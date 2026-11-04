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
