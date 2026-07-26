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

# Upload drvmap artifacts.
# drvmap.json is the full snapshot (for future diffs).
# drvmap-changed.json is the changed subset (consumed by build steps).
if [[ -f pipeline/drvmap.json ]]; then
	buildkite-agent artifact upload pipeline/drvmap.json
fi
if [[ -f pipeline/drvmap-changed.json ]]; then
	buildkite-agent artifact upload pipeline/drvmap-changed.json
fi
