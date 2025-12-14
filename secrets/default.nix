{ dev, ... }:

dev.nix.mkSecrets ./. (import ./secrets.nix)
