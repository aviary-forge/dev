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
  # sha512 of the npm tarball, from registry.npmjs.org dist.integrity
  srcHash = "sha256-HYm9McpjzM2CpclQzAQ7ypnhfkZk33/ZnxaFmgRCJ58=";
  npmDepsHash = "sha256-yPdMCmEyV+TZqipz5eC8cA8k6f5FIVJovR0fUkyhBoc=";

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
