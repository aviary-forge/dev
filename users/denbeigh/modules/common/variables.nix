{ lib, ... }:

let
  inherit (lib) mkOption types;
in
{
  # Persona values for the universal modules (modules/). These are
  # denbeigh's cache and remote-build credentials; the option definitions
  # live in the modules themselves.
  config = {
    dev.denbeigh.nix-cache = {
      url = "https://nix-cache.denbeigh.cloud";
      publicKey = "nix-cache.denbeigh.cloud-1:UeYPpNKlT8gTl7jRqOb+hawFbI5B20pPfSUbpWvSe9U=";
    };

    dev.denbeigh.remoteBuildPublicKeys = [
      "remote-build:gmaC+UE4JxbR6wcMtuZ6WZF0nL1Jh2D3REY9zdwZFWg="
    ];
  };

  options.dev.denbeigh.machine = {
    hostname = mkOption {
      type = types.str;
      description = ''
        Hostname of the machine.
      '';
    };

    work = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether this machine will be used for "work" purposes.
      '';
    };

    location =
      let
        defaultTimezone = "UTC";

        coordinatesShape = {
          options = {
            latitude = mkOption {
              type = types.float;
            };

            longitude = mkOption {
              type = types.float;
            };

            description = ''
              Coordinates of the machine.
              Currently only used for redshift.

              redshift will be disabled on graphical machines where this is not
              provided.
            '';
          };
        };
      in
      mkOption {
        type = types.submodule {
          options = {
            timezone = mkOption {
              default = defaultTimezone;
              type = types.str;
            };
            coordinates = mkOption {
              type = types.nullOr (types.submodule coordinatesShape);
              default = null;
            };
          };
        };
        default = {
          timezone = defaultTimezone;
        };
      };

  };
}
