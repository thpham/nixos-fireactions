# GitLab Runners workload profile
# Applied to hosts tagged with "gitlab-runners"
# Enables fireglab with GitLab instance credentials
#
# NOTE: Pool configuration should be defined per-host or via additional profiles
# This profile only enables the service and sets credential paths
{ config, ... }:

{
  # Define sops secrets needed by fireglab
  # These map to keys in your secrets/secrets.yaml file
  sops.secrets = {
    "gitlab-access-token" = {
      key = "gitlab_access_token";
      mode = "0400";
      owner = "root";
      group = "root";
      restartUnits = [ "fireglab-config.service" ];
    };

    "gitlab-instance-url" = {
      key = "gitlab_instance_url";
      mode = "0400";
      owner = "root";
      group = "root";
      restartUnits = [ "fireglab-config.service" ];
    };

    # Debug SSH key for VM access (optional but recommended)
    "debug-ssh-key" = {
      key = "debug_ssh_key";
      mode = "0400";
      owner = "root";
      group = "root";
      restartUnits = [ "fireglab-config.service" ];
    };

    # Group ID for group_type runners (default runner type)
    "gitlab-group-id" = {
      key = "gitlab_group_id";
      mode = "0400";
      owner = "root";
      group = "root";
      restartUnits = [ "fireglab-config.service" ];
    };

    # Project ID for project_type runners (optional)
    # Uncomment if using project_type scope:
    # "gitlab-project-id" = {
    #   key = "gitlab_project_id";
    #   mode = "0400";
    #   owner = "root";
    #   group = "root";
    #   restartUnits = [ "fireglab-config.service" ];
    # };
  };

  # Enable fireglab service for GitLab CI
  services.fireglab = {
    enable = true;

    # GitLab instance credentials
    # Secrets are defined above in sops.secrets
    gitlab = {
      # Instance URL from sops secret
      instanceUrlFile = config.sops.secrets."gitlab-instance-url".path;

      # Personal Access Token with create_runner scope
      accessTokenFile = config.sops.secrets."gitlab-access-token".path;

      # Runner type - determines scope of runners:
      # - "instance_type": Instance-wide runners (requires admin PAT)
      # - "group_type": Group runners (requires Owner role + groupId)
      # - "project_type": Project runners (requires Maintainer role + projectId)
      runnerType = "group_type";

      # Group ID from sops secret (required for group_type)
      groupIdFile = config.sops.secrets."gitlab-group-id".path;

      # For project_type, uncomment and enable the project-id secret above:
      # projectIdFile = config.sops.secrets."gitlab-project-id".path;
    };

    # Debug SSH key for VM access (allows SSH into running VMs for troubleshooting)
    debug.sshKeyFile = config.sops.secrets."debug-ssh-key".path;

    # Example pool configuration (override per-host as needed)
    # pools = [{
    #   name = "default";
    #   maxRunners = 5;
    #   minRunners = 1;
    #   runner = {
    #     tags = [ "self-hosted" "fireglab" "linux" "x64" ];
    #     image = "ghcr.io/thpham/fireactions-images/ubuntu-24.04-gitlab:latest";
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
