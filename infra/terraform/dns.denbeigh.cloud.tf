locals {
  tailscale_aliases = ["jackett", "radarr", "sonarr", "prowlarr", "jellyfin", "transmission", "nix-cache"]
}

data "tailscale_devices" "bruce" {
  name_prefix = "bruce"
}

data "cloudflare_zone" "denbeigh_cloud" {
  filter = {
    name = "denbeigh.cloud"
  }
}

# All records on this zone must stay proxied = false (grey cloud):
# CF proxy breaks direct SSH and the nix binary cache's origin model.
resource "cloudflare_dns_record" "bruce_denbeigh_cloud" {
  zone_id = data.cloudflare_zone.denbeigh_cloud.id
  name    = "bruce"
  content = "23.145.80.211"
  type    = "A"
  ttl     = 3600
  proxied = false
}

resource "cloudflare_dns_record" "bruce_tailscale_denbeigh_cloud" {
  zone_id = data.cloudflare_zone.denbeigh_cloud.id
  name    = "bruce.tailscale"
  content = data.tailscale_devices.bruce.devices[0].addresses[0]
  type    = "A"
  ttl     = 3600
  proxied = false
}

resource "cloudflare_dns_record" "tailscale_denbeigh_cloud" {
  for_each = toset(local.tailscale_aliases)

  zone_id = data.cloudflare_zone.denbeigh_cloud.id
  name    = each.key
  content = "bruce.tailscale.denbeigh.cloud."
  type    = "CNAME"
  ttl     = 3600
  proxied = false
}
