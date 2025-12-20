# Runners workload profile
# Applied to hosts tagged with "github-runners"
# Enables fireactions with shared GitHub App credentials
#
# NOTE: Pool configuration comes from size profiles (fireactions-small/medium/large)
# This profile only enables the service and sets credentials
{ config, ... }:

{
  # Define sops secrets needed by fireactions
  # These map to keys in your secrets/secrets.yaml file
  sops.secrets = {
    "github-app-id" = {
      key = "github_app_id";
      mode = "0400";
      owner = "root";
      group = "root";
      restartUnits = [ "fireactions-config.service" ];
    };

    "github-app-key" = {
      key = "github_app_private_key";
      mode = "0400";
      owner = "root";
      group = "root";
      restartUnits = [ "fireactions-config.service" ];
    };
  };

  # Enable fireactions service
  services.fireactions = {
    enable = true;

    # GitHub App credentials
    github = {
      appIdFile = config.sops.secrets."github-app-id".path;
      appPrivateKeyFile = config.sops.secrets."github-app-key".path;
    };

    # Pools are defined by size profiles (small/medium/large)
    # If no size profile is used, you must define pools per-host
  };

  # Ensure containerd is available for runner images
  virtualisation.containerd.enable = true;
}
