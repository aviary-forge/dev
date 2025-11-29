{ dev, ... }:

with dev.pipelines.tasks; [
  fetch-parent-targets
  pre-build
  post-build
  build
]
