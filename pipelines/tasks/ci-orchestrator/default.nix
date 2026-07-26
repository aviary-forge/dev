# Pipeline task: build the ci-orchestrator Rust binary.
#
# The binary is built by the shared crane workspace (dev.rust.ci).
# This task just exposes it under pipelines.tasks so the static
# pipeline's build-tools step can reference it.

{ dev, ... }:

dev.rust.ci
