import {
  to = hcloud_floating_ip.prod
  id = "135642722"
}

resource "hcloud_floating_ip" "prod" {
  name          = "vuhom-prod"
  type          = "ipv4"
  home_location = var.location
  description   = "Vuhom production floating IP"
}

resource "hcloud_floating_ip_assignment" "prod" {
  floating_ip_id = hcloud_floating_ip.prod.id
  server_id      = hcloud_server.prod.id
}
