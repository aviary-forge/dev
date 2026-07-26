# This file makes the directory discoverable by readTree.
# The actual derivation lives in python/default.nix via the shared workspace.
{ dev, ... }:
dev.python.hello-python
