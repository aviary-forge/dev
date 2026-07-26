{ dev, ... }:

with dev.pipelines.tasks; [
  ci-orchestrator
  pre-build
  post-build
  build
]
