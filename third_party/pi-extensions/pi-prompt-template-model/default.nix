# pi-prompt-template-model — https://www.npmjs.com/package/pi-prompt-template-model
#
# Pinned to the version currently installed ad-hoc via `pi install`; see
# versions.json and docs/pi-packaging-plan.md. Runtime dep (minimatch) is
# vendored into the package dir; peer deps are injected by pi at load time.
{
  dev,
  members,
  ...
}:
let
  versions = builtins.fromJSON (builtins.readFile ../versions.json);
in
dev.nix.mkPiPackage {
  pname = "pi-prompt-template-model";
  version = versions.pi-prompt-template-model;
  # sha256 of the npm tarball (`nix hash file --type sha256 --base64`)
  srcHash = "sha256-7BuVPL1f65LUiDpPA6C33iomsum88Vvm20B95idG1Vs=";
  npmDepsHash = "sha256-sBDbm92XLE3k4jV9GhIY9K374BILaD72R7WPdtdYMMw=";

  # The npm tarball ships no package-lock.json. The vendored lockfile was
  # generated with `npm install --package-lock-only --lockfile-version 3
  # --omit=peer`; peers are recorded as dev entries (pi injects its own
  # bundled copies via jiti module aliases at load time).
  postPatch = ''
    cp ${./package-lock.json} package-lock.json
  '';

  meta.owners = with members; [ denbeigh ];
}
