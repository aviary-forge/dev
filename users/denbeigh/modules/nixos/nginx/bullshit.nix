import ./service.nix
{
  name = "bullshit";
  backend = "http://localhost:7741";
  tailscale = true;
}
