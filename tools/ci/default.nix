# CI orchestrator — readTree entry point.
#
# The real binary is at dev.rust.ci (built via the crane workspace).
# Returning it directly here causes an infinite recursion during
# readTree's fixpoint.  Instead the ci attrset in the repo root
# injects it as a synthetic target so it shows as `tools/ci`.
_:

{
  __readTreeChildrenOverride = { };
}
