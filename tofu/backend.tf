# Tofu state backend — Hetzner Object Storage (S3-compatible, Ceph-backed).
#
# Bootstrap: the bucket `family-cloud-tfstate` must exist BEFORE `tofu init`.
# See PREREQUISITES.md §7 for the one-time manual bucket creation steps.
#
# Credentials are read from the `hetzner` AWS profile (~/.aws/credentials).
# That profile is populated from the Hetzner Object Storage access key + secret.

terraform {
  backend "s3" {
    bucket = "family-cloud-tfstate"
    key    = "prod/terraform.tfstate"

    # Dummy region — Hetzner OS ignores it but the AWS SDK requires a value.
    region = "eu-central-1"

    endpoints = {
      # Hetzner Object Storage endpoint for the fsn1 (Falkenstein) region.
      # Source: Hetzner Console → Object Storage → any bucket → "S3 endpoint".
      s3 = "https://fsn1.your-objectstorage.com"
    }

    profile = "hetzner"

    # Ceph-backed S3 requires path-style addressing.
    use_path_style = true

    # Disable AWS-specific validations that would fail against Hetzner.
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
  }
}
