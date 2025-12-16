# Gitea Runners workload profile
# Applied to hosts tagged with "gitea-runners"
# Enables fireteact with Gitea instance credentials
#
# NOTE: Pool configuration should be defined per-host or via additional profiles
# This profile only enables the service and sets credential paths
{ config, ... }:

{
  # Enable fireteact service for Gitea Actions
  services.fireteact = {
    enable = true;
    kernelSource = "custom"; # Includes Docker bridge networking support

    # Gitea instance credentials
    # Secrets are managed by sops-nix (see deploy/secrets.nix)
    gitea = {
      # instanceUrl must be set per-host or via additional configuration
      # Example: instanceUrl = "https://gitea.example.com";

      # API token for dynamic runner registration
      # Token scope should match runnerScope (see secrets/secrets.yaml.example)
      apiTokenFile = config.sops.secrets."gitea-api-token".path;

      # Runner scope - SECURITY CONSIDERATION:
      # - "org" (default, recommended): Requires runnerOwner, write:organization token
      # - "repo" (most secure): Requires runnerOwner + runnerRepo, write:repository token
      # - "instance" (AVOID): Requires admin token - HIGH RISK if compromised!
      #
      # runnerScope = "org";     # Default - recommended for most use cases
      # runnerOwner = "my-org";  # Required for org/repo scope (set per-host)
      # runnerRepo = "my-repo";  # Required for repo scope only
    };

    # Example pool configuration (override per-host as needed)
    # pools = [{
    #   name = "default";
    #   maxRunners = 5;
    #   minRunners = 1;
    #   runner = {
    #     labels = [ "self-hosted" "fireteact" "linux" "x64" ];
    #     image = "ghcr.io/thpham/fireteact-images/gitea-runner:latest";
    #   };
    #   firecracker = {
    #     memSizeMib = 2048;
    #     vcpuCount = 2;
    #   };
    # }];
  };

  # Ensure containerd is available for runner images
  virtualisation.containerd.enable = true;
}
