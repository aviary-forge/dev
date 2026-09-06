# context-mode — https://www.npmjs.com/package/context-mode
#
# Pinned to the version currently installed ad-hoc via `pi install`; see
# versions.json and docs/pi-packaging-plan.md.
#
# Note: the plan expected nixpkgs to provide context-mode, but the pinned
# nixpkgs (nixos-26.05 @ c5c4a43) has no context-mode attribute, so we build
# it here with the same mkPiPackage machinery as the other extensions.
#
# The npm tarball ships prebuilt bundles (build/, *.bundle.mjs) and a `pi`
# manifest, so no build step is needed — the package dir is pi-package
# shaped as-is. Runtime deps (better-sqlite3 with a native binding, plus
# turndown/zod/etc.) are vendored into the package dir; better-sqlite3's
# binding is compiled by buildNpmPackage's implicit `npm rebuild` step.
#
# The package's postinstall script does no build work — it is Windows shim
# repair, Claude-Code plugin-registry healing, and better-sqlite3
# self-healing, all of which mutate $HOME and are wrong (and impossible) in
# a nix build. buildNpmPackage's --ignore-scripts skip is correct here;
# the native binding is produced by `npm rebuild` instead.
{
  dev,
  members,
  ...
}:
let
  versions = builtins.fromJSON (builtins.readFile ../versions.json);
in
dev.nix.mkPiPackage {
  pname = "context-mode";
  version = versions.context-mode;
  # sha512 of the npm tarball, from registry.npmjs.org dist.integrity
  srcHash = "sha256-CcQeTPd7IVZsdrjqL9vX89gjBV/uLwLCFm/Vu1ddryw=";
  npmDepsHash = "sha256-xw3S4BORNY5GHc2U89V46YBJT4eUDzLmK9uRnhuFg8A=";

  # The npm tarball ships no package-lock.json. The vendored lockfile was
  # generated with `npm install --package-lock-only --lockfile-version 3
  # --omit=peer`.
  postPatch = ''
    cp ${./package-lock.json} package-lock.json
  '';

  meta.owners = with members; [ denbeigh ];
}
