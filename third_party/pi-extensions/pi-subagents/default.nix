# pi-subagents — https://www.npmjs.com/package/pi-subagents
#
# Pinned to the version currently installed ad-hoc via `pi install`; see
# versions.json and docs/pi-packaging-plan.md.
#
# Runtime deps (pi-server -> chord/pi-agent-core/pi-protocol, jiti, undici,
# yaml, acorn, typebox) are vendored into the package dir with hoisting
# semantics intact — pi-subagents imports @earendil-works/chord from the
# hoisted tree, so this is load-bearing (plan section 5).
#
# No lifecycle scripts in the package; nothing skipped.
#
# NOTE: the generated lock records the dev-only `file:./test/fixtures/
# pi-coding-agent-shim` link (peer recorded as dev); npm ci --omit=dev skips
# it, and the shim directory is not shipped in the npm tarball.
{
  dev,
  lib,
  ...
}:
let
  versions = builtins.fromJSON (builtins.readFile ../versions.json);
in
dev.nix.mkPiPackage {
  pname = "pi-subagents";
  version = versions.pi-subagents;
  # sha512 of the npm tarball, from registry.npmjs.org dist.integrity
  srcHash = "sha256-F3XRWVcimWJUuqKEP2sH9Ye8gRWIkGnLLLU2nf6UqNQ=";
  npmDepsHash = "sha256-kXb4UoPdCU/iVsbEEW6FjcRTGWkdpBeT8jc2JbyREWk=";

  # The npm tarball ships no package-lock.json. The vendored lockfile was
  # generated with `npm install --package-lock-only --lockfile-version 3
  # --omit=peer`; peers are recorded as dev entries (pi injects its own
  # bundled copies via jiti module aliases at load time).
  postPatch = ''
    cp ${./package-lock.json} package-lock.json
  '';
}
