output "server_ipv4" {
  description = "Set an A record at Squarespace DNS: stow.mcgeer.dev → this IP."
  value       = module.server.ipv4_address
}

output "server_ipv6" {
  description = "Optional AAAA record target."
  value       = module.server.ipv6_address
}

output "nextcloud_bucket" {
  description = "Bucket holding Nextcloud file data (objectstore)."
  value       = aws_s3_bucket.nextcloud.bucket
}

output "dns_instructions" {
  description = "Manual DNS steps required after apply."
  value       = <<-EOT

    ─── Manual DNS step ───
    Squarespace → DNS settings for mcgeer.dev → add:
      Host:  stow
      Type:  A
      Value: ${module.server.ipv4_address}
      TTL:   300

    Optional AAAA:
      Host:  stow
      Type:  AAAA
      Value: ${module.server.ipv6_address}
      TTL:   300
  EOT
}
