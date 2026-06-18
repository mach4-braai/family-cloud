output "server_id" {
  description = "Hetzner Cloud server ID."
  value       = hcloud_server.this.id
}

output "ipv4_address" {
  description = "Public IPv4 address. Point your DNS A record here."
  value       = hcloud_server.this.ipv4_address
}

output "ipv6_address" {
  description = "Public IPv6 address. Point your DNS AAAA record here (optional)."
  value       = hcloud_server.this.ipv6_address
}
