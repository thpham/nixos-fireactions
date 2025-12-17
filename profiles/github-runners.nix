# Runners workload profile
# Applied to hosts tagged with "runners"
# Enables fireactions with shared GitHub App credentials
#
# NOTE: Pool configuration comes from size profiles (small/medium/large)
# This profile only enables the service and sets credentials
{ config, ... }:

{
  # Enable fireactions service
  services.fireactions = {
    enable = true;
    kernelSource = "custom";

    # GitHub App credentials (shared across all runners)
    # Secrets are managed by sops-nix (see deploy/secrets.nix)
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
