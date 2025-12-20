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
    # Runner-specific secrets are defined in their respective profiles:
    # - profiles/github-runners.nix (github-app-id, github-app-key)
    # - profiles/gitlab-runners.nix (gitlab-access-token, gitlab-instance-url, etc.)
    # - profiles/gitea-runners.nix (gitea-registration-token, gitea-instance-url, etc.)
    secrets = {
      # Debug SSH key for VM access (used by dev profile for all runner types)
      "debug-ssh-key" = {
        key = "debug_ssh_key";
        mode = "0400";
        owner = "root";
        group = "root";
        # Restart all config services to regenerate cloud-init user-data
        restartUnits = [
          "fireactions-config.service"
          "fireteact-config.service"
          "fireglab-config.service"
        ];
      };

    };
  };
}
