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
  # sha256 of the npm tarball (`nix hash file --type sha256 --base64`)
  srcHash = "sha256-5jhoZPqgH/vbmAWGoU36eo0G/WyG1fsJcMra+GycUtg=";
  npmDepsHash = "sha256-V+VvOkHn8BhpjyznqNWj+3ol3RFyjSsqkYAInG/PLdE=";

  # The npm tarball ships no root package-lock.json. The vendored lockfile
  # was generated with `npm install --package-lock-only --lockfile-version 3
  # --omit=peer`; peers are recorded as dev entries (pi injects its own
  # bundled copies via jiti module aliases at load time).
  postPatch = ''
    cp ${./package-lock.json} package-lock.json
  '';

  meta.owners = with members; [ denbeigh ];
}
