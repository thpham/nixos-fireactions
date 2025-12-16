# sops-nix secrets configuration
# Decrypts secrets from secrets/secrets.yaml at activation time
{ ... }:

{
  # sops-nix configuration
  sops = {
    # Default secrets file (relative to flake root)
    defaultSopsFile = ../secrets/secrets.yaml;

    # Use age for decryption (derived from SSH host key)
    age = {
      # Automatically derive age key from SSH host key
      sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

      # Where to store the derived age key
      keyFile = "/var/lib/sops-nix/key.txt";

      # Generate key file during activation if missing
      generateKey = true;
    };

    # Define secrets that will be decrypted to /run/secrets/
    secrets = {
      # GitHub App ID for fireactions
      "github-app-id" = {
        # Path in secrets.yaml: github_app_id
        key = "github_app_id";

        # Permissions
        mode = "0400";
        owner = "root";
        group = "root";

        # Restart fireactions when secret changes
        restartUnits = [ "fireactions-config.service" ];
      };

      # GitHub App private key for fireactions
      "github-app-key" = {
        # Path in secrets.yaml: github_app_private_key
        key = "github_app_private_key";

        # Permissions
        mode = "0400";
        owner = "root";
        group = "root";

        # Restart fireactions when secret changes
        restartUnits = [ "fireactions-config.service" ];
      };

      # Debug SSH key for VM access (optional, used by dev profile)
      "debug-ssh-key" = {
        # Path in secrets.yaml: debug_ssh_key
        key = "debug_ssh_key";

        # Permissions
        mode = "0400";
        owner = "root";
        group = "root";

        # Restart fireactions-config to regenerate cloud-init user-data
        restartUnits = [ "fireactions-config.service" ];
      };

      # Gitea API token for fireteact (dynamic runner registration)
      "gitea-api-token" = {
        # Path in secrets.yaml: gitea_api_token
        key = "gitea_api_token";

        # Permissions
        mode = "0400";
        owner = "root";
        group = "root";

        # Restart fireteact-config when secret changes
        restartUnits = [ "fireteact-config.service" ];
      };
    };
  };
}
