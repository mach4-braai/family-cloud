# Input variables for the root module.
#
# Non-secret values are set in `terraform.tfvars` (gitignored — use tfvars.example as template).
# Secret values are read from `secrets/family-cloud.enc.yaml` via the SOPS provider (see main.tf).

variable "hcloud_location" {
  description = "Hetzner Cloud location code. fsn1 = Falkenstein (Germany)."
  type        = string
  default     = "fsn1"
}

variable "server_type" {
  description = "Hetzner Cloud server type. CX22 is the MVP size (2 vCPU Intel, 4GB, 40GB NVMe)."
  type        = string
  default     = "cx22"
}

variable "server_name" {
  description = "Hostname of the Hetzner server."
  type        = string
  default     = "family-cloud"
}

variable "server_image" {
  description = "Base image for the server. Pinned to Debian 12 for cloud-init compatibility."
  type        = string
  default     = "debian-12"
}

variable "volume_size_gb" {
  description = "Size of the Hetzner Cloud Volume mounted at /mnt/pgdata (Postgres data)."
  type        = number
  default     = 20
}

variable "domain" {
  description = "Public FQDN for Nextcloud. A record must be set manually at the DNS provider."
  type        = string
  default     = "stow.mcgeer.dev"
}

variable "operator_ssh_pubkey" {
  description = "SSH public key (contents, not path) of the human operator. Added to hcloud_ssh_key."
  type        = string
  # No default — must be supplied in terraform.tfvars.
}

variable "s3_region_label" {
  description = "Label used in Hetzner Object Storage bucket configuration. Cosmetic — Hetzner endpoint is fsn1."
  type        = string
  default     = "eu-central"
}

variable "s3_hostname" {
  description = "Hetzner Object Storage hostname (no scheme). URL is built as https://<hostname>."
  type        = string
  default     = "fsn1.your-objectstorage.com"
}
