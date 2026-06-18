# hetzner-server module — one VPS + firewall + volume attachment + reverse DNS.
#
# Intentional scope: this module owns the *machine*. S3 buckets, SSH key, and
# the Cloud Volume itself live at the root (root owns the durable data
# resources; the module owns the disposable compute).

resource "hcloud_firewall" "this" {
  name = var.server_name

  # HTTP — Let's Encrypt HTTP-01 challenge and Caddy HTTP→HTTPS redirect.
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "80"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # HTTPS — Nextcloud public traffic.
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "443"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # Note: port 22 (SSH) is intentionally NOT exposed to the public internet.
  # Admin SSH happens via Tailscale SSH, which tunnels over outbound UDP 41641 —
  # no inbound listener required. If you need break-glass SSH before Tailscale
  # bootstraps, temporarily add an inbound rule here restricted to your /32.
}

resource "hcloud_server" "this" {
  name         = var.server_name
  server_type  = var.server_type
  image        = var.server_image
  location     = var.location
  ssh_keys     = [var.ssh_key_id]
  firewall_ids = [hcloud_firewall.this.id]
  user_data    = var.cloud_init

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  # TODO(post-first-deploy): uncomment once initial iteration is stable.
  # lifecycle {
  #   prevent_destroy = true
  # }
}

resource "hcloud_volume_attachment" "pgdata" {
  volume_id = var.volume_id
  server_id = hcloud_server.this.id
  automount = false # cloud-init owns the mount (see scripts/cloud-init.yaml.tpl)
}

resource "hcloud_rdns" "ipv4" {
  server_id  = hcloud_server.this.id
  ip_address = hcloud_server.this.ipv4_address
  dns_ptr    = var.domain
}

resource "hcloud_rdns" "ipv6" {
  server_id  = hcloud_server.this.id
  ip_address = hcloud_server.this.ipv6_address
  dns_ptr    = var.domain
}
