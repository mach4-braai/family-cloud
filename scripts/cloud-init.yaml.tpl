#cloud-config
# Rendered by OpenTofu templatefile(). Produces the user_data for the
# family-cloud VPS. Template variables come from tofu/cloud-init.tf.
#
# Layout on the Hetzner Cloud Volume (mounted at /mnt/data):
#   /mnt/data/pgdata        - Postgres data directory (bind-mounted to the db container)
#   /mnt/data/nextcloud-tmp - upload_tmp_dir for Nextcloud (files >80MB buffer here)
#
# The two directories MUST be siblings, not parent/child. Postgres initdb fails
# if the data dir is non-empty; a nextcloud-tmp subdirectory would trigger that.

package_update: true
package_upgrade: true

packages:
  - ca-certificates
  - curl
  - gnupg
  - cron
  - jq

write_files:
  - path: /opt/family-cloud/.env
    owner: root:root
    permissions: '0600'
    content: |
      POSTGRES_PASSWORD=${postgres_password}
      NEXTCLOUD_ADMIN_PASSWORD=${nextcloud_admin_password}
      DOMAIN=${domain}
      S3_BUCKET=${s3_bucket_nextcloud}
      S3_ACCESS_KEY=${s3_access_key}
      S3_SECRET_KEY=${s3_secret_key}
      S3_HOSTNAME=${s3_hostname}
      S3_REGION=${s3_region_label}

  - path: /opt/family-cloud/docker-compose.yml
    owner: root:root
    permissions: '0644'
    content: |
      ${indent(6, docker_compose)}

  - path: /opt/family-cloud/Caddyfile
    owner: root:root
    permissions: '0644'
    content: |
      ${indent(6, caddyfile)}

  - path: /opt/family-cloud/nextcloud-config/custom.config.php
    owner: root:root
    permissions: '0644'
    content: |
      ${indent(6, nextcloud_config_php)}

runcmd:
  # Mount the Hetzner Cloud Volume. Device path is deterministic — passed in
  # from the module output rather than discovered via /dev/disk/by-id magic.
  - mkdir -p /mnt/data
  - mount -o discard,defaults ${volume_device} /mnt/data
  - echo "${volume_device} /mnt/data ext4 defaults,nofail,discard 0 2" >> /etc/fstab

  # Carve out sibling directories on the volume.
  # pgdata MUST stay empty-on-first-boot so Postgres initdb succeeds.
  - mkdir -p /mnt/data/pgdata
  - mkdir -p /mnt/data/nextcloud-tmp
  - chown -R 33:33 /mnt/data/nextcloud-tmp

  # Docker.
  - curl -fsSL https://get.docker.com | sh
  - systemctl enable --now docker

  # Tailscale — SSH via tailnet, no public port 22.
  - curl -fsSL https://tailscale.com/install.sh | sh
  - tailscale up --authkey=${tailscale_authkey} --ssh --advertise-tags=tag:family-cloud --hostname=family-cloud

  # Bring up the stack.
  - cd /opt/family-cloud && docker compose --env-file .env up -d
