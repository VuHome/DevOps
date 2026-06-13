output "floating_ip" {
  value       = hcloud_floating_ip.prod.ip
  description = "Production server public IP — vuhom.com A records point here"
}

output "server_private_ip" {
  value = "10.0.0.2"
}

output "domains" {
  value = {
    root = "vuhom.com"
    api  = "api.vuhom.com"
    www  = "www.vuhom.com"
  }
}

output "s3_endpoint" {
  value = "https://fsn1.your-objectstorage.com"
}

output "s3_buckets" {
  value = local.buckets
}
