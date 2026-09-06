# @plannotator/pi-extension — https://www.npmjs.com/package/@plannotator/pi-extension
#
# Pinned to the version currently installed ad-hoc via `pi install`; see
# versions.json and docs/pi-packaging-plan.md.
#
# The package's `build` script (copy plannotator.html/review-editor.html from
# the ../hook workspace + vendor.sh) runs via prepublishOnly at publish time;
# the npm tarball already ships the built html files, so no build step is
# needed here. `pi.extensions` is "./" — pi loads the package dir itself.
{
  dev,
  members,
  ...
}:
let
  versions = builtins.fromJSON (builtins.readFile ../versions.json);
in
dev.nix.mkPiPackage {
  pname = "plannotator";
  npmName = "@plannotator/pi-extension";
  version = versions."@plannotator/pi-extension";
  # sha512 of the npm tarball, from registry.npmjs.org dist.integrity
  srcHash = "sha256-CWVh8GXbiJEjrnaQ/DRBtbQEBeZpSzQvFdH8Aj/iLjo=";
  npmDepsHash = "sha256-Xyq/hGMiB8kKWP39yQBXdXkRfSC/2/oBO9iBQ7HkBx8=";

  # The npm tarball ships no root package-lock.json. The vendored lockfile
  # was generated with `npm install --package-lock-only --lockfile-version 3
  # --omit=peer`; peers are recorded as dev entries (pi injects its own
  # bundled copies via jiti module aliases at load time).
  postPatch = ''
    cp ${./package-lock.json} package-lock.json
  '';

  meta.owners = with members; [ denbeigh ];
}
