# @juicesharp/rpiv-todo — https://www.npmjs.com/package/@juicesharp/rpiv-todo
#
# Pinned to the version currently installed ad-hoc via `pi install`; see
# versions.json and docs/pi-packaging-plan.md. Runtime deps (@juicesharp/
# rpiv-config, typebox) are vendored into the package dir; peer deps are
# injected by pi at load time.
{
  dev,
  lib,
  ...
}:
let
  versions = builtins.fromJSON (builtins.readFile ../versions.json);
in
dev.nix.mkPiPackage {
  pname = "rpiv-todo";
  npmName = "@juicesharp/rpiv-todo";
  version = versions."@juicesharp/rpiv-todo";
  # sha512 of the npm tarball, from registry.npmjs.org dist.integrity
  srcHash = "sha256-OTEF+deOO+q9yKJGIXUeu7ZzbO9H5tMukZ6un6hlJVU=";
  npmDepsHash = "sha256-YBQulGTmivlTRNOIPdustZz8xj6xyocSkgqIlurgntk=";

  # The npm tarball ships no package-lock.json. The vendored lockfile was
  # generated with `npm install --package-lock-only --lockfile-version 3
  # --omit=peer`; peers are recorded as dev entries (pi injects its own
  # bundled copies via jiti module aliases at load time).
  postPatch = ''
    cp ${./package-lock.json} package-lock.json
  '';
}
