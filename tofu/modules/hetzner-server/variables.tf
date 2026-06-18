variable "server_name" {
  description = "Hostname of the Hetzner server."
  type        = string
}

variable "server_type" {
  description = "Hetzner Cloud server type slug (e.g. cx22, cx32, cpx31)."
  type        = string
}

variable "server_image" {
  description = "Base image slug (e.g. debian-12)."
  type        = string
}

variable "location" {
  description = "Hetzner location code (e.g. fsn1)."
  type        = string
}

variable "volume_id" {
  description = "ID of the hcloud_volume to attach to the server (created at root, see tofu/main.tf)."
  type        = string
}

variable "domain" {
  description = "Public FQDN for Nextcloud. Used for reverse DNS."
  type        = string
}

variable "ssh_key_id" {
  description = "ID of the hcloud_ssh_key to attach to the server (passed in from root)."
  type        = number
}

variable "cloud_init" {
  description = "Rendered cloud-init user_data (YAML as a string)."
  type        = string
}
