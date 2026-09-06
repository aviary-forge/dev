#!/usr/bin/env bash
# One-shot migration helper for denbeigh.cloud (DO -> Cloudflare).
#
# Usage (from infra/terraform/ or anywhere):
#   CF_API_TOKEN=... ./import-denbeigh-cloud.sh            # emit + run imports
#   CF_API_TOKEN=... ./import-denbeigh-cloud.sh --dry-run  # just print commands
#   CF_API_TOKEN=... ./import-denbeigh-cloud.sh --plan     # imports, then tofu plan
#
# Requires: curl, jq, tofu (on PATH). The token needs Zone:DNS:Edit + Zone:Read
# on denbeigh.cloud (the cloudflareApiToken secret qualifies).

set -euo pipefail

: "${CF_API_TOKEN:?CF_API_TOKEN must be set}"
DRY_RUN=0
RUN_PLAN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --plan) RUN_PLAN=1 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

api() {
  curl -sfS -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json" "$1"
}

zone_json="$(api "https://api.cloudflare.com/client/v4/zones?name=denbeigh.cloud")"
zone_id="$(jq -r '.result[0].id // empty' <<<"$zone_json")"
if [[ -z "$zone_id" ]]; then
  echo "ERROR: zone denbeigh.cloud not found (check token scopes)" >&2
  exit 1
fi
echo "zone: denbeigh.cloud ($zone_id)"

# Fetch all records (paginated).
records="$(jq -n '[ ]')"; page=1
while :; do
  p="$(api "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?per_page=100&page=$page")"
  records="$(jq -c --argjson p "$(jq '.result' <<<"$p")" '. + $p' <<<"$records")"
  total_pages="$(jq -r '.result_info.total_pages // 1' <<<"$p")"
  [[ "$page" -ge "$total_pages" ]] && break
  page=$((page + 1))
done

echo "--- live records in zone ---"
jq -r '.[] | "\(.type)\t\(.name)\t\(.content)\t\(.id)"' <<<"$records"

# terraform resource address <- (type, fqdn) matchers.
match() { # $1=type $2=name(fqdn) ; echoes resource address or empty
  case "$1:$2" in
    A:bruce.denbeigh.cloud)                          echo "cloudflare_dns_record.bruce_denbeigh_cloud" ;;
    A:bruce.tailscale.denbeigh.cloud)                echo "cloudflare_dns_record.bruce_tailscale_denbeigh_cloud" ;;
    CNAME:*.denbeigh.cloud)                          echo "cloudflare_dns_record.tailscale_denbeigh_cloud[\"${2%.denbeigh.cloud}\"]" ;;
    *)                                               echo "" ;;
  esac
}

echo "--- import commands ---"
declare -a cmds=()
matched_ids=()
while IFS=$'\t' read -r rtype rname rcontent rid; do
  [[ "$rtype" == "NS" && "$rname" == "denbeigh.cloud" ]] && continue  # apex NS: not terraform-owned
  addr="$(match "$rtype" "$rname")"
  if [[ -z "$addr" ]]; then
    echo "# NOT terraform-managed (leave as-is / note in dashboard): $rtype $rname $rcontent $rid"
    continue
  fi
  matched_ids+=("$rid")
  cmds+=("$addr $zone_id:$rid")
done < <(jq -rt '.[] | "\(.type)\t\(.name)\t\(.content)\t\(.id)"' <<<"$records")

if [[ ${#cmds[@]} -eq 0 ]]; then
  echo "nothing to import" >&2
else
  for c in "${cmds[@]}"; do echo "tofu import $c"; done

  if [[ $DRY_RUN -eq 0 ]]; then
    echo "--- running imports ---"
    for c in "${cmds[@]}"; do
      # shellcheck disable=SC2086
      if ! tofu import $c 2>/tmp/tf-import-err.$$; then
        # v5 id format varies by provider version; retry with slash separator.
        addr="${c% *}"
        zid="${c#* }"; zid="${zid%%:*}"
        echo "colon form failed, retrying as $addr $zone_id-slash-format" >&2
        # shellcheck disable=SC2086
        tofu import "$addr" "$zone_id/${c##*:}" || {
          echo "BOTH import forms failed for $addr — see /tmp/tf-import-err.$$" >&2
          cat /tmp/tf-import-err.$$ >&2
          exit 1
        }
      fi
      rm -f /tmp/tf-import-err.$$
    done
    echo "imports complete"
  fi
fi

if [[ $RUN_PLAN -eq 1 && $DRY_RUN -eq 0 ]]; then
  echo "--- tofu plan ---"
  TF_VAR_cloudflare_api_token="$CF_API_TOKEN" tofu plan
else
  echo "next: tofu plan (expect zero changes for denbeigh.cloud once imports land)"
fi
