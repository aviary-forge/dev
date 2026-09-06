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
  # sha512 of the npm tarball, from registry.npmjs.org dist.integrity
  srcHash = "sha256-Ahc67gDkGsxGV3oee4OlULSBGgzADRe3svK2xNYV82w=";
  npmDepsHash = "sha256-/aen9BURRdRkMRJCOUlg0v60inwxi49Qi5rAz/u2IBY=";

  # The npm tarball ships no package-lock.json. The vendored lockfile was
  # generated with `npm install --package-lock-only --lockfile-version 3
  # --omit=peer`; peers are recorded as dev entries (pi injects its own
  # bundled copies via jiti module aliases at load time).
  postPatch = ''
    cp ${./package-lock.json} package-lock.json
  '';

  meta.owners = with members; [ denbeigh ];
}
