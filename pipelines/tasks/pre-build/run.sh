#!/usr/bin/env bash
set -ueo pipefail

# Generate the pipeline using the Rust orchestrator.
# This replaces the old fetch-parent-targets + nix-build pattern with
# double nix-instantiate + drvPath diffing.

echo "--- Generating pipeline with ci-orchestrator"
mkdir -p pipeline
ci-orchestrator pipeline-gen --output pipeline/pipeline.json

# Upload the generated pipeline to Buildkite.
if [[ -f pipeline/pipeline.json ]]; then
  buildkite-agent pipeline upload pipeline/pipeline.json
fi

# Upload drvmap as an artifact for future builds to diff against.
if [[ -f pipeline/drvmap.json ]]; then
  buildkite-agent artifact upload pipeline/drvmap.json
fi
