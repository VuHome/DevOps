variable "hcloud_token" {
  type      = string
  sensitive = true
}

variable "s3_access_key" {
  type      = string
  sensitive = true
}

variable "s3_secret_key" {
  type      = string
  sensitive = true
}

variable "server_type" {
  type    = string
  default = "cx43"
}

variable "location" {
  type    = string
  default = "fsn1"
}

variable "server_image" {
  type    = string
  default = "ubuntu-24.04"
}
