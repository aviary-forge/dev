set -ueo pipefail

buildkite-agent artifact download 'pipeline/*' .

find ./pipeline -name 'release-chunk-*.json' | tac | while read -r chunk; do
  buildkite-agent pipeline upload "$chunk"
done
