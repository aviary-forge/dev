# @juicesharp/rpiv-ask-user-question — https://www.npmjs.com/package/@juicesharp/rpiv-ask-user-question
#
# Pinned to the version currently installed ad-hoc via `pi install`; see
# versions.json and docs/pi-packaging-plan.md. Runtime deps (@juicesharp/
# rpiv-config, typebox) are vendored into the package dir; peer deps are
# injected by pi at load time.
{
  dev,
  members,
  ...
}:
let
  versions = builtins.fromJSON (builtins.readFile ../versions.json);
in
dev.nix.mkPiPackage {
  pname = "rpiv-ask-user-question";
  npmName = "@juicesharp/rpiv-ask-user-question";
  version = versions."@juicesharp/rpiv-ask-user-question";
  # sha512 of the npm tarball, from registry.npmjs.org dist.integrity
  srcHash = "sha256-pUpjND7EIVW+HsfE0b2/icQcFp/xAtQ2s2D9s24GJuE=";
  npmDepsHash = "sha256-W7HEqLHsWprVmJRkIZUMRJjpvP8fUpMwa1oMhh+qdsw=";

  # The npm tarball ships no package-lock.json. The vendored lockfile was
  # generated with `npm install --package-lock-only --lockfile-version 3
  # --omit=peer`; peers are recorded as dev entries (pi injects its own
  # bundled copies via jiti module aliases at load time).
  postPatch = ''
    cp ${./package-lock.json} package-lock.json
  '';

  meta.owners = with members; [ denbeigh ];
}
