# mkPiPackage: build a pi (pi-coding-agent) package from an npm tarball as a
# directory loadable by pi as a local-path package.
#
# pi supports loading packages directly from disk: a local path in the
# `packages` list of ~/.pi/agent/settings.json is loaded in place without
# copying. So we do not need to reproduce pi's npm-install semantics
# (~/.pi/agent/npm/node_modules + dependency resolution): each derivation
# produces a pi-package-shaped directory with its runtime `node_modules`
# vendored in, and the home-manager module writes the store path straight
# into settings.json.
#
# The vendored node_modules are load-bearing: pi loads extensions with
# node/jiti, so import resolution from the package dir must work for
# transitive runtime deps (e.g. pi-subagents' @earendil-works/chord import).
# Peer dependencies (typebox, @earendil-works/pi-ai, pi-tui, pi-coding-agent,
# pi-agent-core) must NOT be vendored: pi injects its own bundled copies via
# jiti virtual modules/aliases, per the pi packages documentation.
#
# See docs/pi-packaging-plan.md for the full packaging plan.
{
  dev,
  pkgs,
  lib,
  ...
}@args:
let
  # npm registry tarball URL; the tarball basename strips the scope for
  # scoped packages (e.g. @ayulab/pi-rewind -> pi-rewind-0.4.6.tgz)
  tarballUrl =
    name: version:
    let
      base = lib.last (lib.splitString "/" name);
    in
    "https://registry.npmjs.org/${name}/-/${base}-${version}.tgz";

  mkPiPackage =
    {
      pname,
      version,
      # npm name; differs from pname for scoped packages
      npmName ? pname,
      # hash of the npm tarball (sri form), unless an explicit src is given
      srcHash ? lib.fakeHash,
      src ? pkgs.fetchurl {
        url = tarballUrl npmName version;
        hash = srcHash;
      },
      # npm name as pi references it in settings.json; used by the
      # settings-merge helper to drop the ad-hoc "npm:..." entry when the nix
      # package is declared instead
      npmSourceString ? "npm:${npmName}",
      npmInstallFlags ? [
        # peers are injected by pi at load time (see header); do not install
        # them into the vendored node_modules
        "--omit=peer"
        # also skip dev dependencies: with --omit=peer lock generation the
        # peers are recorded as dev entries, and npm ci installs dev deps by
        # default — which the deps cache intentionally does not contain
        "--omit=dev"
      ],
      ...
    }@pkgArgs:
    let
      pkg = pkgs.buildNpmPackage (
        builtins.removeAttrs pkgArgs [
          "npmName"
          "npmSourceString"
          "srcHash"
        ]
        // {
          inherit
            pname
            version
            src
            npmInstallFlags
            ;

          # extensions ship raw TS sources that pi loads itself; no build step
          dontNpmBuild = pkgArgs.dontNpmBuild or true;

          installPhase = ''
            runHook preInstall

            # Ship prod-only node_modules inside the package dir: pi resolves
            # the extension's imports from the package dir itself. npm ci
            # installs the full lock graph (peers are recorded as dev entries),
            # so prune everything not required at runtime. --omit=peer matters
            # here: without it prune re-resolves peer deps and tries to fetch
            # them into the offline cache (npm ci skipped them via
            # npmInstallFlags), which fails with ENOTCACHED.
            npm prune --omit=dev --omit=peer --no-save

            mkdir -p $out/lib
            cp -r . $out/lib/pi-package

            runHook postInstall
          '';

          passthru = (pkgArgs.passthru or { }) // {
            # NB: must be a concrete eval-time store path ("${pkg}") — a
            # `placeholder "out"` here only resolves inside a derivation
            # build, so consumers toJSON-ing it (the settings-merge
            # activation script) would see every package collapse to the
            # *consumer's* out path.
            piPackageDir = "${pkg}/lib/pi-package";
            inherit npmSourceString;
          };
        }
      );
    in
    pkg;
in
# Callable attrset via __functor: //mkPiPackage stays callable while
# exposing the settings merge helper as //mkPiPackage.mergeSettings.
# readTree merges child attrs into this node, which requires an attrset.
{
  __functor = _: mkPiPackage;
  mergeSettings = import ./merge-settings.nix { inherit pkgs; };
}
