locals {
  # Deterministic device path for the Hetzner Cloud Volume. The attribute
  # `hcloud_volume.linux_device` is only populated AFTER attachment, which
  # creates a dependency cycle with user_data. Constructing the path from the
  # volume ID sidesteps that — Hetzner always uses this convention.
  pgdata_volume_device = "/dev/disk/by-id/scsi-0HC_Volume_${hcloud_volume.pgdata.id}"

  cloud_init_rendered = templatefile("${path.module}/../scripts/cloud-init.yaml.tpl", {
    domain                   = var.domain
    postgres_password        = data.sops_file.secrets.data["postgres_password"]
    nextcloud_admin_password = data.sops_file.secrets.data["nextcloud_admin_password"]
    tailscale_authkey        = data.sops_file.secrets.data["tailscale_authkey"]
    s3_hostname              = var.s3_hostname
    s3_region_label          = var.s3_region_label
    s3_access_key            = data.sops_file.secrets.data["hcloud_s3_access_key"]
    s3_secret_key            = data.sops_file.secrets.data["hcloud_s3_secret_key"]
    s3_bucket_nextcloud      = aws_s3_bucket.nextcloud.bucket
    volume_device            = local.pgdata_volume_device
    docker_compose           = file("${path.module}/../docker/docker-compose.yml")
    caddyfile                = file("${path.module}/../docker/Caddyfile")
    nextcloud_config_php     = file("${path.module}/../docker/nextcloud-config/custom.config.php")
  })
}
