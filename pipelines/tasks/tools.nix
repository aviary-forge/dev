{ dev, ... }:

# Tools built during the build-tools step of the static pipeline.
# Only include what's actually used by pipeline-gen and the generated steps.
with dev.pipelines.tasks;
[
  ci-orchestrator
  pre-build
  build-step
]
