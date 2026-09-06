locals {
  tailscale_aliases = ["bullshit", "jackett", "radarr", "sonarr", "prowlarr", "jellyfin", "transmission", "nix-cache"]
}

data "tailscale_devices" "aviary" {
  name_prefix = "aviary"
}

data "cloudflare_zone" "denbeigh_cloud" {
  filter = {
    name = "denbeigh.cloud"
  }
}

# All records on this zone must stay proxied = false (grey cloud):
# CF proxy breaks direct SSH and the nix binary cache's origin model.
resource "cloudflare_dns_record" "aviary_denbeigh_cloud" {
  zone_id = data.cloudflare_zone.denbeigh_cloud.id
  name    = "aviary"
  content = "51.81.46.167"
  type    = "A"
  ttl     = 3600
  proxied = false
}

resource "cloudflare_dns_record" "aviary_tailscale_denbeigh_cloud" {
  zone_id = data.cloudflare_zone.denbeigh_cloud.id
  name    = "aviary.tailscale"
  content = data.tailscale_devices.aviary.devices[0].addresses[0]
  type    = "A"
  ttl     = 3600
  proxied = false
}

resource "cloudflare_dns_record" "tailscale_denbeigh_cloud" {
  for_each = toset(local.tailscale_aliases)

  zone_id = data.cloudflare_zone.denbeigh_cloud.id
  name    = each.key
  content = "aviary.tailscale.denbeigh.cloud."
  type    = "CNAME"
  ttl     = 3600
  proxied = false
}
