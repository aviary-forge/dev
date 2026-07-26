# CI orchestrator — readTree entry point.
#
# This file exists so readTree can discover the tools/ci path.
# The actual binary is built separately (nix-build -A rust.ci or via
# the crane workspace).  We can't build it here because doing so
# during readTree's fixpoint construction would cause a cycle
# (pkgs.craneLib ← nixpkgs overlay ← dev.third_party.nix ← dev).
#
# Consumers should reference the workspace output at dev.rust.ci
# or build via `nix-build -A pipelines.tasks.ci-orchestrator`.
{ ... }:

# Thin placeholder — the real binary is at dev.rust.ci.
#
# To use in pipeline steps:
#   "$(nix-build -A rust.ci)/bin/ci-orchestrator"
{
  __readTreeChildrenOverride = { };
}
