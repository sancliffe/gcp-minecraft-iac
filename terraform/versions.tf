terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }

  # The remote state backend is declared once, in backend.tf. Declaring it here
  # as well is a "Duplicate backend configuration" error.
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = local.zone
}
