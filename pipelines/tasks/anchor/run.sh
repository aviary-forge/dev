#!/usr/bin/env bash

set -euo pipefail

gcroot_path="$(nix-build -A ci.gcroot)"

gcroot-manager --artifact-path "$gcroot_path"
