data "sops_file" "secrets" {
  source_file = "${path.module}/../secrets/family-cloud.enc.yaml"
}

provider "hcloud" {
  token = data.sops_file.secrets.data["hcloud_token"]
}

# The aws provider is used solely as an S3 client against Hetzner Object Storage.
# skip_* flags disable AWS-specific APIs (STS, IMDS, region list) that Hetzner
# does not implement. No real AWS resources are created.
provider "aws" {
  region  = "eu-central-1"
  profile = "hetzner"

  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
  skip_requesting_account_id  = true

  s3_use_path_style = true

  endpoints {
    s3 = "https://${var.s3_hostname}"
  }
}

resource "hcloud_ssh_key" "operator" {
  name       = "operator"
  public_key = var.operator_ssh_pubkey
}

# Postgres data volume. Lives at the root (not in the server module) because
# cloud-init needs to render the deterministic device path
# (/dev/disk/by-id/scsi-0HC_Volume_<id>) into user_data at plan time. The
# server module would introduce a dependency cycle: module.user_data would
# depend on the module's volume.id which depends on the module being created.
resource "hcloud_volume" "pgdata" {
  name     = "${var.server_name}-pgdata"
  size     = var.volume_size_gb
  location = var.hcloud_location
  format   = "ext4"

  # TODO(post-first-deploy): uncomment once initial iteration is stable.
  # See PLAN.md §7.1 — losing this volume means losing the Postgres DB.
  # lifecycle {
  #   prevent_destroy = true
  # }
}

# --- S3 buckets -------------------------------------------------------------

# Primary object storage — every Nextcloud user file lives here.
resource "aws_s3_bucket" "nextcloud" {
  bucket = "family-cloud-data"

  # TODO(post-first-deploy): uncomment. Losing this bucket = losing every file.
  # lifecycle {
  #   prevent_destroy = true
  # }
}

resource "aws_s3_bucket_versioning" "nextcloud" {
  bucket = aws_s3_bucket.nextcloud.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "nextcloud" {
  bucket = aws_s3_bucket.nextcloud.id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

module "server" {
  source = "./modules/hetzner-server"

  server_name   = var.server_name
  server_type   = var.server_type
  server_image  = var.server_image
  location      = var.hcloud_location
  volume_id     = hcloud_volume.pgdata.id
  domain        = var.domain
  ssh_key_id    = hcloud_ssh_key.operator.id
  cloud_init    = local.cloud_init_rendered
}
