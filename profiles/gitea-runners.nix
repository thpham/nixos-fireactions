# Gitea Runners workload profile
# Applied to hosts tagged with "gitea-runners"
# Enables fireteact with Gitea instance credentials
#
# NOTE: Pool configuration should be defined per-host or via additional profiles
# This profile only enables the service and sets credential paths
{ config, ... }:

{
  # Define sops secrets needed by fireteact
  # These map to keys in your secrets/secrets.yaml file
  sops.secrets = {
    "gitea-api-token" = {
      key = "gitea_api_token";
      mode = "0400";
      owner = "root";
      group = "root";
      restartUnits = [ "fireteact-config.service" ];
    };

    "gitea-instance-url" = {
      key = "gitea_instance_url";
      mode = "0400";
      owner = "root";
      group = "root";
      restartUnits = [ "fireteact-config.service" ];
    };

    "gitea-runner-owner" = {
      key = "gitea_runner_owner";
      mode = "0400";
      owner = "root";
      group = "root";
      restartUnits = [ "fireteact-config.service" ];
    };

    # Debug SSH key for VM access (optional but recommended)
    "debug-ssh-key" = {
      key = "debug_ssh_key";
      mode = "0400";
      owner = "root";
      group = "root";
      restartUnits = [ "fireteact-config.service" ];
    };

    # Uncomment if using repo scope:
    # "gitea-runner-repo" = {
    #   key = "gitea_runner_repo";
    #   mode = "0400";
    #   owner = "root";
    #   group = "root";
    #   restartUnits = [ "fireteact-config.service" ];
    # };
  };

  # Enable fireteact service for Gitea Actions
  services.fireteact = {
    enable = true;
    kernelSource = "custom"; # Includes Docker bridge networking support

    # Gitea instance credentials
    # Secrets are defined above in sops.secrets
    gitea = {
      # Instance URL from sops secret
      instanceUrlFile = config.sops.secrets."gitea-instance-url".path;

      # API token for dynamic runner registration
      apiTokenFile = config.sops.secrets."gitea-api-token".path;

      # Runner scope - SECURITY CONSIDERATION:
      # - "org" (default, recommended): Requires runnerOwner, write:organization token
      # - "repo" (most secure): Requires runnerOwner + runnerRepo, write:repository token
      # - "instance" (AVOID): Requires admin token - HIGH RISK if compromised!
      runnerScope = "org";

      # Runner owner from sops secret
      runnerOwnerFile = config.sops.secrets."gitea-runner-owner".path;

      # Runner repo from sops secret (required for repo scope only)
      # Uncomment and enable the secret above if using repo scope
      # runnerRepoFile = config.sops.secrets."gitea-runner-repo".path;
    };

    # Debug SSH key for VM access (allows SSH into running VMs for troubleshooting)
    debug.sshKeyFile = config.sops.secrets."debug-ssh-key".path;

    # Example pool configuration (override per-host as needed)
    # pools = [{
    #   name = "default";
    #   maxRunners = 5;
    #   minRunners = 1;
    #   runner = {
    #     labels = [ "self-hosted" "fireteact" "linux" "x64" ];
    #     image = "ghcr.io/thpham/fireactions-images/ubuntu-24.04-gitea:latest";
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
