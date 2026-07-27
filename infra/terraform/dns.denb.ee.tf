locals {
  nfs_ipv4 = "208.94.117.103"
  nfs_ipv6 = "2607:ff18:80::3bb4"
}

data "cloudflare_zone" "denb_ee" {
  filter = {
    name = "denb.ee"
  }
}

resource "cloudflare_dns_record" "www_denb_ee" {
  zone_id = data.cloudflare_zone.denb_ee.id
  name    = "www"
  content = "denb.ee"
  type    = "CNAME"
  ttl     = 3600
}

resource "cloudflare_dns_record" "wikirace_denb_ee" {
  zone_id = data.cloudflare_zone.denb_ee.id
  name    = "wikirace"
  content = local.nfs_ipv4
  type    = "A"
  ttl     = 3600
}

resource "cloudflare_dns_record" "pre_wikirace_denb_ee" {
  zone_id = data.cloudflare_zone.denb_ee.id
  name    = "pre.wikirace"
  content = local.nfs_ipv4
  type    = "A"
  ttl     = 3600
}

resource "cloudflare_dns_record" "wikirace_ipv6_denb_ee" {
  zone_id = data.cloudflare_zone.denb_ee.id
  name    = "wikirace"
  content = local.nfs_ipv6
  type    = "AAAA"
  ttl     = 3600
}

resource "cloudflare_dns_record" "pre_wikirace_ipv6_denb_ee" {
  zone_id = data.cloudflare_zone.denb_ee.id
  name    = "pre.wikirace"
  content = local.nfs_ipv6
  type    = "AAAA"
  ttl     = 3600
}

resource "cloudflare_dns_record" "autodiscover_denb_ee" {
  zone_id = data.cloudflare_zone.denb_ee.id
  name    = "autodiscover"
  content = "autodiscover.outlook.com"
  type    = "CNAME"
  ttl     = 3600
}

resource "cloudflare_dns_record" "mail_denb_ee" {
  zone_id  = data.cloudflare_zone.denb_ee.id
  name     = "@"
  content  = "denb-ee.mail.protection.outlook.com."
  type     = "MX"
  priority = 30
  ttl      = 3600
}

resource "cloudflare_dns_record" "mail_denb_ee_txt1" {
  zone_id = data.cloudflare_zone.denb_ee.id
  name    = "@"
  content = "v=spf1 include:spf.protection.outlook.com -all"
  type    = "TXT"
  ttl     = 3600
}

resource "cloudflare_dns_record" "mail_denb_ee_txt2" {
  zone_id = data.cloudflare_zone.denb_ee.id
  name    = "@"
  content = "MS=ms46764552"
  type    = "TXT"
  ttl     = 3600
}
