# Wrapped pi-coding-agent for background/async subagent children.
#
# pi-subagents' async runner resolves @earendil-works/{chord,pi-server,...}
# by walking up from pi's own package root to sibling node_modules dirs
# (runner-aliases.ts: findHostPeerPackageDir). The ad-hoc ~/.pi/agent/npm
# install hoists chord/pi-server next to the npm-installed pi; the nixpkgs
# pi-monorepo build ships neither, so background children fail with
# "does not provide @earendil-works/chord, ...".
#
# This wrapper reproduces the hoisted layout. It must COPY pi's tree rather
# than symlink it: the runner resolves piPackageRoot via realpathSync(argv[1])
# (async-execution.ts), which would follow a symlink back to the read-only
# nixpkgs store path whose ancestors contain no peers. With a real copy, the
# peers sit in the sibling node_modules/ where findHostPeerPackageDir finds
# them. Sources are our pi-subagents derivation's vendored tree — same
# versions as the working ad-hoc install: chord 0.85.1, pi-server 0.85.0.
# It also sets PI_SUBAGENTS_PI_CODING_AGENT_PACKAGE_ROOT for consumers that
# honor it.
#
# NOTE: this is the host agent itself, not a pi extension package — do not
# put it in programs.pi-coding-agent.myPackages; use `package` instead.
{
  dev,
  pkgs,
  lib,
  ...
}:

let
  piTree = "${pkgs.pi-coding-agent}/lib/node_modules/pi-monorepo";
  subagentsModules = "${dev.third_party.pi-extensions.pi-subagents}/lib/pi-package/node_modules";
  peers = [
    "chord"
    "pi-server"
    "pi-protocol"
    "pi-telemetry"
  ];
in
pkgs.runCommand "pi-coding-agent-host-${pkgs.pi-coding-agent.version}"
  {
    nativeBuildInputs = [ pkgs.makeBinaryWrapper ];
    passthru.piTree = piTree;
    meta = pkgs.pi-coding-agent.meta // {
      description = "${
        pkgs.pi-coding-agent.meta.description or "pi coding agent"
      } (with async-runner peer packages)";
    };
  }
  ''
    mkdir -p $out/lib/node_modules/@earendil-works $out/bin

    # Real copy (not a symlink): see header comment about realpathSync.
    cp -R ${piTree} $out/lib/node_modules/pi-monorepo
    chmod -R u+w $out/lib/node_modules/pi-monorepo
    for peer in ${lib.escapeShellArgs peers}; do
      ln -s ${subagentsModules}/@earendil-works/$peer \
        $out/lib/node_modules/@earendil-works/$peer
    done

    makeWrapper ${pkgs.nodejs}/bin/node $out/bin/pi \
      --add-flags "$out/lib/node_modules/pi-monorepo/dist/cli.js" \
      --set PI_SUBAGENTS_PI_CODING_AGENT_PACKAGE_ROOT "$out/lib/node_modules/pi-monorepo"
  ''
