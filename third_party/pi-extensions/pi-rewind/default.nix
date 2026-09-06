# @ayulab/pi-rewind — https://www.npmjs.com/package/@ayulab/pi-rewind
#
# Pinned to the version currently installed ad-hoc via `pi install`; see
# versions.json and docs/pi-packaging-plan.md. No dependencies or lifecycle
# scripts; plain JS loaded by pi directly.
{
  dev,
  lib,
  ...
}:
let
  versions = builtins.fromJSON (builtins.readFile ../versions.json);
in
dev.nix.mkPiPackage {
  pname = "pi-rewind";
  npmName = "@ayulab/pi-rewind";
  version = versions."@ayulab/pi-rewind";
  # sha512 of the npm tarball, from registry.npmjs.org dist.integrity
  srcHash = "sha256-Il3ptp06zr6fmOLJO/GrrVnmCBry0bQP3382QaxeoIY=";
  npmDepsHash = "sha256-BywhTGDrRB9lZcDIvSdamusnYxYVEJ0mertlmPrL0RM=";

  # The npm tarball ships no package-lock.json. The vendored lockfile was
  # generated with `npm install --package-lock-only --lockfile-version 3
  # --omit=peer`; peers are recorded as dev entries (pi injects its own
  # bundled copies via jiti module aliases at load time).
  postPatch = ''
    cp ${./package-lock.json} package-lock.json
  '';
}
