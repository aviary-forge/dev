# pi-intercom — https://www.npmjs.com/package/pi-intercom
#
# Pinned to the version currently installed ad-hoc via `pi install`; see
# versions.json and docs/pi-packaging-plan.md. Runtime deps (tsx) are
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
  pname = "pi-intercom";
  version = versions.pi-intercom;
  # sha256 of the npm tarball (`nix hash file --type sha256 --base64`)
  srcHash = "sha256-c6SNvA4ecu8+fLvOjvbFnID4lvp+Sq1GhDuBuef5V1Y=";
  npmDepsHash = "sha256-giQOJewFJ/bZpV0ugadncGjY8sgW60nEtE+hVv3MbU0=";

  # The npm tarball ships no package-lock.json. The vendored lockfile was
  # generated with `npm install --package-lock-only --lockfile-version 3
  # --omit=peer`, so peers (typebox, @earendil-works/*) are recorded in the
  # lock but not installed — pi injects its own bundled copies via jiti
  # module aliases at load time.
  postPatch = ''
    cp ${./package-lock.json} package-lock.json
  '';

  meta.owners = with members; [ denbeigh ];
}
