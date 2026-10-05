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
  # sha256 of the npm tarball (`nix hash file --type sha256 --base64`)
  srcHash = "sha256-9AeJNjjxiTo3MERPRntO3Bkkzy0gauWE91JeHoroYPY=";
  npmDepsHash = "sha256-O8J5sLWUO3PtrO8tD2NZrrCPiwjt/r5vSfEdBAJbw/Q=";

  # The npm tarball ships no package-lock.json. The vendored lockfile was
  # generated with `npm install --package-lock-only --lockfile-version 3
  # --omit=peer`; peers are recorded as dev entries (pi injects its own
  # bundled copies via jiti module aliases at load time).
  postPatch = ''
    cp ${./package-lock.json} package-lock.json
  '';

  meta.owners = with members; [ denbeigh ];
}
