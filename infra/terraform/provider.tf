terraform {
  # OpenTofu started at 1.6 (forked from Terraform 1.5).
  # This constraint accepts both OpenTofu and Terraform >= 1.6.
  required_version = ">= 1.6.0"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.0"
    }

    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }

    tailscale = {
      source  = "tailscale/tailscale"
      version = "~> 0.13"
    }

    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket = "denbeigh-terraform"
    key    = "terraform"
    region = "us-east-1"
  }
}

provider "digitalocean" {
  token = var.digitalocean_api_key
}

provider "aws" {
  region     = "us-west-2"
  access_key = var.aws_access_key_id
  secret_key = var.aws_secret_access_key
}

provider "tailscale" {
  api_key = var.tailscale_api_key
  tailnet = "denbeigh2000.github"
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
