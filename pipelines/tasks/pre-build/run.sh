set -ue

# Attempt to fetch a target map from a parent commit on trunk,
# except on builds of trunk itself.
if [ "${BUILDKITE_BRANCH}" != "trunk" ]; then
  fetch-parent-targets
fi

PIPELINE_ARGS=()
if [[ -f tmp/parent-target-map.json ]]; then
  PIPELINE_ARGS=("--arg" "parentTargetMap" "tmp/parent-target-map.json")
fi

nix-build --option restrict-eval true\
  --include "dev=$${PWD}" \
  --include "store=/nix/store" \
  --allowed-uris 'https://' \
  -A pipelines.tasks.build \
  -o pipeline --show-trace "${PIPELINE_ARGS[@]}"

# Steps need to be uploaded in reverse order because pipeline
# upload prepends instead of appending.
find pipeline -name "build-chunk-*.json" | sort -r | while read -r chunk; do
  buildkite-agent pipeline upload "$chunk"
done

buildkite-agent artifact upload "pipeline/*"
