#!/usr/bin/env bash
set -ueo pipefail

# Per-system build step: downloads the changed drvmap, runs the
# orchestrator (which handles nix-store --realise, log parsing,
# annotation posting, and results file writing), then uploads
# the results artifact for the post-build step.
#
# NIX_SYSTEM is set by the pipeline step's env.

echo "--- Downloading changed drvmap for $NIX_SYSTEM"
buildkite-agent artifact download 'pipeline/drvmap-changed.json' .

echo "--- Building changed targets for $NIX_SYSTEM"
ci-orchestrator build --drvmap-file pipeline/drvmap-changed.json

echo "--- Uploading results artifact"
buildkite-agent artifact upload 'pipeline/results-*.json' || true
