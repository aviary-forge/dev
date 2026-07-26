# CI orchestrator — readTree entry point.
#
# The binary is built by the shared crane workspace (rust/default.nix)
# and exposed at dev.rust.ci. This file exists only so readTree can
# discover the tools/ci path. We can't access `dev` during import
# (circular dependency during fixpoint construction), so we return a
# placeholder that the workspace build overrides.
#
# At runtime, consumers should reference `dev.rust.ci` directly.
{ ... }:

# Placeholder — the real binary is at dev.rust.ci.
# This file's only job is to exist so readTree doesn't skip this directory.
{
  __readTreeChildrenOverride = { };
}
