let
  humans = {
    denbeigh = {
      lucifer = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBrWuq0cLFKo4KKLYKF/SG3U/6/7U0o7JDHDeJOwadAf";
    };
  };

  systems = {
    aviary = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJqsSG1f2odzVng/PAtN2Mz9j8a6igIL371gMyuMf+3b";
  };

  key = keys: { publicKeys = keys; };
in
{
  "buildkite-agent-token.age" = key [ systems.aviary ];
  "buildkite-graphql-token.age" = key [ systems.aviary ];
  "buildkite-ssh-private-key.age" = key [ systems.aviary ];
  "tailscaleAuthKey.age" = key [ systems.aviary ];
  "digitalOceanAPIKey.age" = key [ systems.aviary ];
  # "cfdyndnsApiToken.age" = key [ systems.aviary ];  # disabled: key rotation
  "terraform.age" = key [ systems.aviary ];
  "fontDeployKey.age" = key [ systems.aviary ];
}
