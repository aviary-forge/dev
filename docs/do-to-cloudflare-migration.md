# Migration: DigitalOcean → Cloudflare (denbeigh.cloud)

**Status:** zone cutover has been triggered by hand (registrar NS change to
Cloudflare). Everything below the DNS layer — terraform, nix, secrets — still
references DigitalOcean and needs to be migrated.

This document is written to be picked up by an agent (or a human) later, with
enough context to finish the migration without re-deriving the inventory.

---

## Background

`denbeigh.cloud` was the only zone still authoritative on DigitalOcean.
`denb.ee` was already managed via the Cloudflare terraform provider. The DO
account is **DNS-only**: there are no droplets, volumes, load balancers, or any
other DO resources anywhere in this repo. Removing DO therefore reduces to:

1. The zone cutover (already triggered — verify it completed).
2. Porting the `denbeigh.cloud` records from the `digitalocean` provider to the
   `cloudflare` provider in terraform.
3. Switching the ACME DNS-01 challenge on `aviary` (host `bruce`) from lego's
   `digitalocean` provider to `cloudflare`.
4. Swapping the DO API age secret for a Cloudflare API token secret.
5. Deleting the DO provider from the nix-wrapped opentofu config, and closing
   the DO account.

Managed services on `denbeigh.cloud` that depend on DNS + ACME and **must keep
working** after the migration:

- `bruce.denbeigh.cloud` → `23.145.80.211` (A, static — this is the aviary host)
- `bruce.tailscale.denbeigh.cloud` → tailscale device address (A, dynamic via
  the `tailscale` terraform provider)
- `<alias>.denbeigh.cloud` CNAMEs → `bruce.tailscale.denbeigh.cloud.` for:
  `jackett`, `radarr`, `sonarr`, `prowlarr`, `jellyfin`, `transmission`,
  `nix-cache`
- `nix-cache.denbeigh.cloud` — nginx vhost on aviary serving the nix binary
  cache (`systems/configs/aviary.nix`, `users/denbeigh/modules/*/use-nix-cache.nix`
  hardcode the URL and public key; the hostname itself must not change)
- `sfo.denbeigh.cloud` — `systems/darwin/builder.nix` and
  `users/denbeigh/modules/nixos/standard.nix` reference this hostname
- ACME certs for the above are provisioned **on-host** via lego DNS-01, so
  cert issuance breaks if the DNS provider credentials stop working. Records
  should be created DNS-only (grey cloud / `proxied = false`) to keep direct
  origin traffic and existing cert flow intact.

---

## Step 0 — Verify the zone cutover completed

The zone cutover was done out-of-band. Before touching terraform, verify:

```sh
dig NS denbeigh.cloud +short
# Expect Cloudflare nameservers (e.g. <name>.ns.cloudflare.com.), NOT
# ns1-3.digitalocean.com.
```

- [ ] NS delegation returns Cloudflare nameservers
- [ ] `dig A bruce.denbeigh.cloud`, `dig CNAME nix-cache.denbeigh.cloud` etc.
      resolve correctly through the new authoritative servers
- [ ] All pre-existing records were carried over. Terraform only managed a
      subset — enumerate the full record set (Cloudflare dashboard → zone →
      DNS, or the API) and compare against what was live on DO before the
      cutover. Watch for: TXT records (SPF/DKIM/verification), MX, SRV,
      CAA, anything not in the old `dns.denbeigh.cloud.tf`.

If any record is missing, recreate it in the Cloudflare dashboard first —
record parity matters more than terraform ownership.

---

## Step 1 — Create the Cloudflare API token (host credential)

Aviary needs a token for two potential consumers:

1. **ACME DNS-01 (lego)** — required now. Needs `Zone : DNS : Edit` on zone
   `denbeigh.cloud`. (Optionally also `denb.ee` if future services on that
   zone need certs.)
2. **cfdyndns (DDNS client)** — already wired up in nix but currently
   commented out, and its secret (`cfdyndnsApiToken.age`) is disabled pending
   key rotation. Same token works.

Create a scoped API token in the Cloudflare dashboard, then add the age secret:

- Encrypt the token into `secrets/cloudflareApiToken.age`:

  ```sh
  cd secrets
  nix run .#agenix -e cloudflareApiToken.age   # or however secrets are edited here
  ```

  Paste the raw token only (no trailing newline surprises — lego reads the
  whole file).
- Register it in `secrets/secrets.nix`:

  ```nix
  "cloudflareApiToken.age" = key [ systems.aviary ];
  ```

- Keep `digitalOceanAPIKey.age` in place until Step 5 (aviary still references
  it until the nix switch flips).

---

## Step 2 — Terraform: port `denbeigh.cloud` records

Files in scope (all under `infra/terraform/`):

### 2a. `dns.denbeigh.cloud.tf`

Replace the entire DO block with cloudflare resources. The tailscale device
data source stays. Current content being replaced:

```hcl
data "digitalocean_domain" "denbeigh_cloud" { name = "denbeigh.cloud" }
resource "digitalocean_record" "denbeigh_cloud_ns_{1,2,3}" { ... }   # apex NS -> DO ns servers
resource "digitalocean_record" "bruce_denbeigh_cloud"         { ... } # A  bruce -> 23.145.80.211
resource "digitalocean_record" "bruce_tailscale_denbeigh_cloud" { ... }
resource "digitalocean_record" "tailscale_denbeigh_cloud" (for_each over aliases) { ... }
```

New shape (v5 provider, matching the style already used in
`dns.denb.ee.tf`):

```hcl
data "cloudflare_zone" "denbeigh_cloud" {
  filter = { name = "denbeigh.cloud" }
}

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
```

**Delete the apex NS records outright** — they pointed at the DO nameservers
and are meaningless post-cutover. Cloudflare does not allow apex NS records to
be created via API anyway.

**Important:** because the records already exist in the Cloudflare zone
(created during cutover), a plain `tofu apply` would try to *create*
duplicates and collide with the imported set. Two options:

- **Preferred:** import each existing record into state so terraform adopts
  them, then keep values in sync going forward:

  ```sh
  cd infra/terraform
  tofu import cloudflare_dns_record.bruce_denbeigh_cloud <zone_id>/<record_id>
  # record ids from the Cloudflare API / dashboard URL
  ```

  Note the v5 provider's import ID format is `<zone_id>:<record_id>` in some
  versions — check `tofu import cloudflare_dns_record ... -h` output and
  provider docs.
- **Fallback:** remove matching records from the CF dashboard right before
  `tofu apply` recreates them. Only safe for records that are terraform-owned
  and low-churn; never for records not in the .tf files.

Either way, run `tofu plan` and confirm the plan is **only** the expected
adopt/create set — nothing else in the `denb.ee` zone should be touched.

### 2b. `provider.tf`

Remove:

```hcl
digitalocean = { source = "digitalocean/digitalocean", version = "~> 2.0" }
...
provider "digitalocean" { token = var.digitalocean_api_key }
```

### 2c. `variables.tf`

Remove `variable "digitalocean_api_key"`. If the token was supplied via
`TF_VAR_digitalocean_api_key` / a var file / environment (check how `tofu
plan` is run locally — see `infra/terraform/default.nix` devShell), remove it
from that source too. Also check `secrets/terraform.age` — it likely contains
the DO token among the provider variables; strip the DO entry when convenient.

### 2d. State cleanup

After a successful apply with the provider removed:

```sh
tofu state list | grep digitalocean   # should be empty
```

If any `digitalocean_*` entries linger, `tofu state rm` them. The backend is
S3 (`denbeigh-terraform` bucket) — no local state involved.

---

## Step 3 — Nix: drop the DO provider from the opentofu wrappers

- `infra/terraform/default.nix`:
  - remove `providers.providers.digitalocean.digitalocean` from the
    `pkgs.opentofu.withPlugins` list
  - update the devShell `shellHook` echo ("Providers: cloudflare, digitalocean,
    aws, tailscale" → drop digitalocean)
- `third_party/terraform/default.nix`: no DO-specific content, but verify
  nothing else references the DO provider
- The `validated` derivation runs `tofu init -backend=false` + `tofu validate`
  in checkPhase — this will catch a stale `required_providers` list. Run:

  ```sh
  nix build .#...terraform...validated   # or however it's invoked in CI
  ```

---

## Step 4 — Nix: switch ACME DNS-01 to Cloudflare on aviary

`systems/configs/aviary.nix`, `services.dev.reverse-proxy.acme`:

```nix
acme = {
  enable = true;
  email = "denbeigh+letsencrypt@denbeighstevens.com";
  dnsProvider = "cloudflare";                       # was: "digitalocean"
  credentialFiles = {
    "CF_DNS_API_TOKEN_FILE" = config.age.secrets.cloudflareApiToken.path;
  };
};
```

And in the `age.secrets` block of the same file, replace:

```nix
digitalOceanKey = { file = dev.secrets."digitalOceanAPIKey.age"; };
```

with:

```nix
cloudflareApiToken = { file = dev.secrets."cloudflareApiToken.age"; };
```

`systems/modules/nixos/reverse-proxy/default.nix` needs no functional change —
it passes `dnsProvider`/`credentialFiles` through to `security.acme.defaults`
— but update the docstrings/examples that use `digitalocean` /
`DO_AUTH_TOKEN_FILE` to use `cloudflare` / `CF_DNS_API_TOKEN_FILE` so future
readers aren't pointed at the old provider.

While here, optionally: the commented-out `cfdyndns` block in aviary can be
re-enabled (it's a Cloudflare DDNS client, `records = [ "aviary.denbeigh.cloud" ]`).
It's out of scope for the DO removal — leave a note, don't silently enable.

### Deployment ordering

The nix switch and the terraform apply are independent (lego talks to
Cloudflare's API directly, not through terraform), but sequence matters for
cert continuity:

1. Cloudflare token created + secret in place + aviary config switched
2. `nixos-rebuild switch` (or the usual deploy path) on aviary
3. Force a cert renewal to prove the new provider works **before** the DO
   token/account is gone:

   ```sh
   sudo systemctl restart acme-*.service   # or lego --force-renewal per cert
   ```

4. Only then proceed to terraform state cleanup and DO account closure.

Rollback note: if renewal fails with the CF token (scope typo etc.), the DO
token still works until the zone is fully severed from DO — the NS delegation
is already moved, but DO credentials are only useless for DNS-01 after the
zone is gone from DO, so **do not delete the DO zone or account until a
successful CF-based renewal is observed.**

---

## Step 5 — Teardown

- [ ] `tofu state` clean of `digitalocean_*` entries (Step 2d)
- [ ] `grep -ri digitalocean --include='*.nix' --include='*.tf' .` (excluding
      `node_modules`, `users/denbeigh/*/_build`, `third_party/` vendored stuff)
      returns only: the reverse-proxy docstrings if you skipped that, and
      `secrets/digitalOceanAPIKey.age`
- [ ] Delete `secrets/digitalOceanAPIKey.age` and its entry in
      `secrets/secrets.nix` (only after Step 4's successful renewal)
- [ ] `users/denbeigh/modules/nixos/terraform.nix`: stale TODO comment about
      DO — either delete the module (it's a non-functional stub: the
      `apply-terraform` script just exits 1) or at minimum update the comment
- [ ] Verify nothing else consumed the DO token (search shell history, CI
      config, `~/.config/doctl` — none found in the repo)
- [ ] In the DigitalOcean console: confirm the `denbeigh.cloud` zone is no
      longer needed (delegation moved), then delete the zone and close the
      account
- [ ] Final DNS verification: `dig` all the managed hostnames, run a full
      `nixos-rebuild` on aviary, exercise the nix cache
      (`nix store info` against `https://nix-cache.denbeigh.cloud`)

---

## Gotchas checklist

- **Proxied records break the nix cache / SSH.** Everything on this zone must
  stay `proxied = false` (grey cloud). CF proxy would break
  `ssh-ng://nix-copy-receiver@bruce.denbeigh.cloud` (port 22) and the nix
  cache's direct-to-origin model.
- **v5 provider import ID format** — `cloudflare_dns_record` import IDs are
  `<zone_id>:<record_id>` in v5 (colon-separated), unlike v4's slash format.
  Verify against the installed provider version.
- **TTL minimums** — Cloudflare may clamp TTLs; 3600 is fine.
- **`data.tailscale_devices.bruce`** — the tailscale provider and its
  `tailscale_api_key` var are unaffected; keep them.
- **Record parity** — the old `.tf` files never covered everything live in the
  DO zone (no MX/TXT for `denbeigh.cloud` in terraform at all). Any records
  imported at cutover that aren't terraform-managed are now dashboard-managed;
  that's acceptable, but note it somewhere so nobody assumes terraform owns
  the full zone.
- **Secrets edit procedure** — this repo uses agenix
  (`secrets/secrets.nix` maps age files to ssh public keys). Re-encrypting
  requires the aviary host key's private counterpart to be present where
  editing happens (age file re-encryption only needs public keys; decryption
  of the *old* DO secret isn't needed for the new CF token).
