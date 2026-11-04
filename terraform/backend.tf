# Partial backend configuration. The bucket is read from minecraft.auto.tfvars
# and the prefix from backend.hcl by the init wrapper. Initialise with:
#   ./terraform-init.sh
terraform {
  backend "gcs" {}
}
