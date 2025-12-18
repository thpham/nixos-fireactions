{
  description = "Minimal GitHub Actions runners with nixos-fireactions";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-fireactions.url = "github:thpham/nixos-fireactions";
    nixos-fireactions.inputs.nixpkgs.follows = "nixpkgs";

    # For secrets management
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, nixos-fireactions, sops-nix, ... }: {
    nixosConfigurations.github-runner = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        # Include the fireactions module
        nixos-fireactions.nixosModules.fireactions

        # Include sops-nix for secrets
        sops-nix.nixosModules.sops

        # Main configuration
        ({ config, pkgs, ... }: {
          # ============================================
          # FIREACTIONS CONFIGURATION
          # ============================================
          services.fireactions = {
            enable = true;

            # GitHub App authentication (via secrets)
            github = {
              appIdFile = config.sops.secrets.github-app-id.path;
              appPrivateKeyFile = config.sops.secrets.github-app-key.path;
            };

            # Runner pools - adjust based on your server capacity
            pools = [{
              name = "default";
              maxRunners = 5;    # Maximum concurrent runners
              minRunners = 0;    # Runners spin up on demand

              # VM resources per runner
              machine = {
                vcpu = 2;        # vCPUs per VM
                memSizeMib = 2048; # RAM per VM (MB)
              };

              runner = {
                # CHANGE THIS: Your GitHub organization name
                organization = "YOUR-ORG-NAME";

                # Labels for workflow targeting
                labels = [
                  "self-hosted"
                  "fireactions"
                  "linux"
                  "x64"
                ];
              };
            }];

            # Logging
            logLevel = "info";

            # Metrics (Prometheus)
            metricsEnable = true;
            metricsAddress = "0.0.0.0:8081";
          };

          # ============================================
          # SECRETS CONFIGURATION
          # ============================================
          sops = {
            defaultSopsFile = ./secrets/secrets.yaml;
            age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

            secrets = {
              github-app-id = {};
              github-app-key = {};
            };
          };

          # ============================================
          # SYSTEM CONFIGURATION
          # ============================================

          # Enable KVM
          boot.kernelModules = [ "kvm-intel" "kvm-amd" ];
          virtualisation.libvirtd.enable = false; # We use Firecracker directly

          # Networking
          networking = {
            hostName = "github-runner";
            firewall = {
              enable = true;
              allowedTCPPorts = [
                22    # SSH
                8080  # Fireactions API
                8081  # Metrics
              ];
            };
          };

          # SSH access
          services.openssh = {
            enable = true;
            settings = {
              PasswordAuthentication = false;
              PermitRootLogin = "prohibit-password";
            };
          };

          # Add your SSH public key here
          users.users.root.openssh.authorizedKeys.keys = [
            # CHANGE THIS: Your SSH public key
            "ssh-ed25519 AAAA... your-key-here"
          ];

          # System packages
          environment.systemPackages = with pkgs; [
            htop
            vim
            curl
            jq
          ];

          system.stateVersion = "24.11";
        })
      ];
    };
  };
}
