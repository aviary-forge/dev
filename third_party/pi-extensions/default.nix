# Declaratively packaged pi extensions, deployed via home-manager as
# local-path packages (see docs/pi-packaging-plan.md).
#
# Versions in versions.json are pinned to what is currently installed ad-hoc
# in ~/.pi/agent/npm/node_modules so that "what I have today" is exactly
# reproducible. When bumping a version: update versions.json, then the
# tarball srcHash + npmDepsHash of the corresponding derivation.
#
# readTree exposes each subdirectory as //third_party/pi-extensions/<name>;
# this aggregator intentionally returns an empty set (children are merged in
# automatically).
#
# NOTE: pi-coding-agent-host is not an extension — it is a wrapped host agent
# (adds the async-runner peer packages the nixpkgs build lacks); use it as
# programs.pi-coding-agent.package, never in myPackages.
_:

# statix: `_` avoids an empty-pattern warning; readTree passes args we do not use here
{ }
