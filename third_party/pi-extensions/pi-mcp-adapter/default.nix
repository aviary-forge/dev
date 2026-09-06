# pi-mcp-adapter — https://www.npmjs.com/package/pi-mcp-adapter
#
# Pinned to the version currently installed ad-hoc via `pi install`; see
# versions.json and docs/pi-packaging-plan.md.
#
# The package's `prepack` script (tsc build) runs at publish time only; the
# npm tarball ships the built output. Nothing is skipped at install time.
#
# `@napi-rs/keyring` has platform-specific optional deps (@napi-rs/
# keyring-darwin-arm64 etc.); the npmDeps cache contains all platforms, so
# the hash is not platform-specific.
{
  dev,
  lib,
  ...
}:
let
  versions = builtins.fromJSON (builtins.readFile ../versions.json);
in
dev.nix.mkPiPackage {
  pname = "pi-mcp-adapter";
  version = versions.pi-mcp-adapter;
  # sha512 of the npm tarball, from registry.npmjs.org dist.integrity
  srcHash = "sha256-X3t5/hGGmZZ7HFJNi7ku5ZOdEIrNk0Is7q5+sqOWMIc=";
  npmDepsHash = "sha256-TQgQGQ3BWegALSBGqhbdg8IwppCz7mRiDuVHd11zcSc=";

  # The npm tarball ships no package-lock.json. The vendored lockfile was
  # generated with `npm install --package-lock-only --lockfile-version 3
  # --omit=peer`; peers are recorded as dev entries (pi injects its own
  # bundled copies via jiti module aliases at load time).
  postPatch = ''
    cp ${./package-lock.json} package-lock.json
  '';
}
