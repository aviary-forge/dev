variable "aws_access_key_id" {
  description = "AWS access key ID for S3 backend and Route53"
  type        = string
  sensitive   = true
  nullable    = false
}

variable "aws_secret_access_key" {
  description = "AWS secret access key for S3 backend and Route53"
  type        = string
  sensitive   = true
  nullable    = false
}

variable "tailscale_api_key" {
  description = "Tailscale API key for device discovery"
  type        = string
  sensitive   = true
  nullable    = false
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token for managing DNS records"
  type        = string
  sensitive   = true
  nullable    = false
}
