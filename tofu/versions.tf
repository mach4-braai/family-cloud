# OpenTofu + provider version pinning.
#
# The `aws` provider is used purely as an S3 client against Hetzner Object Storage.
# No actual AWS resources are created by this project.

terraform {
  required_version = ">= 1.8.0"

  required_providers {
    # Hetzner Cloud — VPS, volume, firewall, etc.
    # https://github.com/hetznercloud/terraform-provider-hcloud
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.6"
    }

    # AWS provider — used only as an S3 client against Hetzner Object Storage.
    # https://github.com/hashicorp/terraform-provider-aws
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.43"
    }

    # SOPS — decrypts secrets/family-cloud.enc.yaml at plan/apply time.
    # https://github.com/carlpett/terraform-provider-sops
    sops = {
      source  = "carlpett/sops"
      version = "~> 1.4"
    }
  }
}
