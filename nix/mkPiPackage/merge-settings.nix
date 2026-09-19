# Activation-time merge helper for ~/.pi/agent/settings.json.
#
# pi rewrites settings.json in place at runtime (locked read-modify-write in
# pi-coding-agent's dist/core/settings-manager.js — it stores mutable state
# like lastChangelogVersion and defaultProvider there), so home-manager must
# not manage the whole file: it would clobber pi's runtime edits on every
# activation. Instead, run this script during HM activation; it surgically
# updates only the keys we manage:
#
#   packages: drop the REMOVE_JSON entries (the ad-hoc "npm:..." sources
#             replaced by nix packages), drop stale nix store-path entries
#             that no longer match a declared package (derivation hash
#             changed on rebuild/version bump — the old path would otherwise
#             linger forever and conflict with the new one at extension load
#             time), then append every PACKAGES_JSON entry exactly once.
#             Existing object-form entries (pi package filters) are left
#             untouched.
#   skills:   replaced wholesale with SKILLS_JSON when non-empty.
#
# All other keys (lastChangelogVersion, defaultProvider, theme, ...) are
# preserved as-is. The file is only written if the result differs.
#
# Environment:
#   SETTINGS_FILE  path to settings.json (treated as {} if missing)
#   PACKAGES_JSON  JSON array of package source strings (nix store paths)
#   REMOVE_JSON    JSON array of package source strings ("npm:...") to drop
#   SKILLS_JSON    JSON array of skill paths, or [] to leave skills untouched
#
# Note: PACKAGES_JSON entries are matched by exact string equality, so a
# package whose derivation hash changes produces a different source string;
# the old store path is pruned and the new one appended. All declared
# entries always end up present exactly once.
{ pkgs }:
pkgs.writeShellScript "pi-merge-settings" ''
  set -euo pipefail

  : "''${SETTINGS_FILE:?SETTINGS_FILE must be set}"
  : "''${PACKAGES_JSON:?PACKAGES_JSON must be set}"
  REMOVE_JSON="''${REMOVE_JSON:-[]}"
  SKILLS_JSON="''${SKILLS_JSON:-[]}"

  if [ ! -f "$SETTINGS_FILE" ]; then
    # no settings yet — start from an empty document; the merge only sets
    # the keys we manage, pi fills in the rest at runtime
    mkdir -p "$(dirname "$SETTINGS_FILE")"
    printf '{}\n' > "$SETTINGS_FILE"
  fi

  tmp="$(mktemp "$(dirname "$SETTINGS_FILE")/.pi-settings-XXXXXX.json")"
  trap 'rm -f "$tmp"' EXIT

  jq --argjson pkgs "$PACKAGES_JSON" \
     --argjson rm "$REMOVE_JSON" \
     --argjson skills "$SKILLS_JSON" \
     '
    . as $root
    | .packages =
        ( (($root.packages // [])
           # Keep an entry only if it is an object (pi package filters,
           # never touched) or a string that is neither a superseded ad-hoc
           # npm entry ($rm) nor a nix store path — strings under /nix/store
           # are pruned wholesale and re-added from the declared list below,
           # which kills stale hashes and collapses duplicates. NB: the
           # element must be bound with `as` — inside `$rm | index(.)`, `.`
           # rebinds to $rm itself and index() would match the array in
           # itself.
           | map(select(
               (type == "object")
               or (. as $p
                   | ($rm | index($p)) == null
                     and ($p | startswith("/nix/store/") | not)))))
           # append the declared entries, deduped, in declaration order
           + (reduce $pkgs[] as $p
                ([]; if (. | index($p)) == null then . + [ $p ] else . end)))
    | (if ($skills | length) > 0 then .skills = $skills else . end)
  ' "$SETTINGS_FILE" > "$tmp"

  if ! cmp -s "$tmp" "$SETTINGS_FILE"; then
    chmod 644 "$tmp"
    mv "$tmp" "$SETTINGS_FILE"
  fi
''
