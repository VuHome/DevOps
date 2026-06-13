terraform {
  required_version = ">= 1.5"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.49"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket = "vuhom-tfstate"
    key    = "prod/terraform.tfstate"
    region = "fsn1"
    endpoints = {
      s3 = "https://fsn1.your-objectstorage.com"
    }
    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    use_path_style              = true
  }
}

provider "hcloud" {
  token = var.hcloud_token
}

provider "aws" {
  access_key = var.s3_access_key
  secret_key = var.s3_secret_key
  region     = "fsn1"

  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  skip_region_validation      = true

  endpoints {
    s3 = "https://fsn1.your-objectstorage.com"
  }
}
