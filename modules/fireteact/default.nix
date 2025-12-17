# Fireteact - NixOS module for Gitea Actions runners using Firecracker microVMs
#
# Module structure:
# - default.nix (this file): Entry point, option definitions
# - services.nix: systemd services and system configuration
#
# Usage:
#   services.fireteact.enable = true;
#   services.fireteact.gitea.instanceUrl = "https://gitea.example.com";
#   services.fireteact.pools = [ { name = "default"; ... } ];

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.fireteact;

  # Import custom packages
  fireteactPkg = pkgs.callPackage ../../pkgs/fireteact.nix { };

  # Pool configuration type (similar to fireactions but for Gitea)
  poolType = lib.types.submodule {
    options = {
      name = lib.mkOption {
        type = lib.types.str;
        description = "Name of the runner pool";
      };

      maxRunners = lib.mkOption {
        type = lib.types.int;
        default = 10;
        description = "Maximum number of runners in this pool";
      };

      minRunners = lib.mkOption {
        type = lib.types.int;
        default = 1;
        description = "Minimum number of runners in this pool";
      };

      runner = {
        name = lib.mkOption {
          type = lib.types.str;
          default = "fireteact-runner";
          description = "Runner name prefix";
        };

        image = lib.mkOption {
          type = lib.types.str;
          default = "ghcr.io/thpham/fireactions-images/ubuntu-24.04-gitea:latest";
          description = "OCI image for the runner (must include act_runner)";
        };

        imagePullPolicy = lib.mkOption {
          type = lib.types.enum [
            "Always"
            "IfNotPresent"
            "Never"
          ];
          default = "IfNotPresent";
          description = "Image pull policy";
        };

        labels = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [
            "self-hosted"
            "fireteact"
            "linux"
          ];
          description = "Labels for the runner (used for job matching in Gitea)";
        };
      };

      firecracker = {
        memSizeMib = lib.mkOption {
          type = lib.types.int;
          default = 2048;
          description = "Memory size in MiB for the microVM";
        };

        vcpuCount = lib.mkOption {
          type = lib.types.int;
          default = 2;
          description = "Number of vCPUs for the microVM";
        };

        kernelArgs = lib.mkOption {
          type = lib.types.str;
          default = "console=ttyS0 reboot=k panic=1 pci=off";
          description = "Kernel command line arguments";
        };

        metadata = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = { };
          description = ''
            Additional metadata to pass to the Firecracker VM via MMDS.
            This is accessible from within the VM at http://169.254.169.254/
          '';
        };
      };
    };
  };
in
{
  imports = [
    ./services.nix
  ];

  #
  # Option Definitions
  #

  options.services.fireteact = {
    enable = lib.mkEnableOption "Fireteact Gitea Actions runner manager";

    package = lib.mkOption {
      type = lib.types.package;
      default = fireteactPkg;
      description = "The fireteact package to use";
    };


    configFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to a custom fireteact configuration file.
        If set, this overrides all other configuration options.
      '';
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/fireteact";
      description = "Directory for fireteact data (kernels, rootfs, etc.)";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "root";
      description = ''
        User account under which fireteact runs.
        Default is root because fireteact needs access to:
        - containerd socket for image management
        - KVM for microVM creation
        - Network namespaces for VM networking
      '';
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "root";
      description = "Group under which fireteact runs";
    };

    # Server configuration
    bindAddress = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0:8082";
      description = "Address for the fireteact server to bind to (note: different port from fireactions)";
    };

    logLevel = lib.mkOption {
      type = lib.types.enum [
        "debug"
        "info"
        "warn"
        "error"
      ];
      default = "info";
      description = "Log level for fireteact";
    };

    debugMode = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable debug mode";
    };

    # Metrics configuration
    metricsEnable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable Prometheus metrics endpoint";
    };

    metricsAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1:8083";
      description = "Address for the metrics endpoint (note: different port from fireactions)";
    };

    # Debug configuration (matches fireactions structure)
    debug = {
      sshKeyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "SSH public key file for VM debugging access";
      };
    };

    # Gitea configuration
    gitea = {
      instanceUrl = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Gitea instance URL (e.g., https://gitea.example.com)";
        example = "https://gitea.example.com";
      };

      instanceUrlFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Path to a file containing the Gitea instance URL.
          Takes precedence over instanceUrl if both are set.
          This should be a secret file managed by sops-nix.
        '';
      };

      apiToken = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Gitea API token with runner management permissions.
          Use apiTokenFile for production (secrets management).

          The token needs 'admin' scope for instance-level runners,
          or appropriate org/repo permissions for scoped runners.

          Fireteact uses this to dynamically request per-runner
          registration tokens via the Gitea API.
        '';
      };

      apiTokenFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Path to a file containing the Gitea API token.
          Takes precedence over apiToken if both are set.
          This should be a secret file managed by sops-nix.
        '';
      };

      runnerScope = lib.mkOption {
        type = lib.types.enum [ "instance" "org" "repo" ];
        default = "org";
        description = ''
          Scope for runner registration (affects security and token requirements):

          - "org" (recommended): Organization-level runners
            Requires: runnerOwner, token with write:organization scope
            Risk: Medium - compromise affects one organization

          - "repo" (most secure): Repository-level runners
            Requires: runnerOwner + runnerRepo, token with write:repository scope
            Risk: Low - compromise affects one repository

          - "instance" (avoid in production): Global instance runners
            Requires: Site Admin token (dangerous!)
            Risk: HIGH - compromise affects entire Gitea instance
        '';
      };

      runnerOwner = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Owner name for org or repo scope.
          Required when runnerScope is "org" or "repo".
        '';
        example = "my-org";
      };

      runnerOwnerFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Path to a file containing the runner owner name.
          Takes precedence over runnerOwner if both are set.
          This should be a secret file managed by sops-nix.
        '';
      };

      runnerRepo = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Repository name for repo scope.
          Required when runnerScope is "repo".
        '';
        example = "my-repo";
      };

      runnerRepoFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Path to a file containing the runner repository name.
          Takes precedence over runnerRepo if both are set.
          This should be a secret file managed by sops-nix.
        '';
      };
    };

    # Kernel configuration (shared with fireactions)
    kernelSource = lib.mkOption {
      type = lib.types.enum [
        "upstream"
        "custom"
        "nixpkgs"
      ];
      default = "upstream";
      description = ''
        Source for the guest kernel:
        - "upstream": Pre-built Firecracker CI kernels (minimal, fast boot)
        - "custom": Nix-built minimal kernel with Docker bridge networking support
        - "nixpkgs": Full NixOS kernel package (largest, most features)
      '';
    };

    kernelVersion = lib.mkOption {
      type = lib.types.str;
      default = "6.1.141";
      description = "Kernel version when using upstream kernels";
    };

    kernelPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.linuxPackages_6_12.kernel;
      description = "Kernel package to use when kernelSource is 'nixpkgs'";
    };

    # Pool configuration
    pools = lib.mkOption {
      type = lib.types.listOf poolType;
      default = [ ];
      description = "List of runner pools to configure";
    };

    # Networking configuration
    networking = {
      bridgeName = lib.mkOption {
        type = lib.types.str;
        default = "fireteact0";
        description = "Name of the bridge interface for microVMs (separate from fireactions)";
      };

      subnet = lib.mkOption {
        type = lib.types.str;
        default = "10.201.0.0/24";
        description = "Subnet for microVM networking (separate from fireactions 10.200.0.0/24)";
      };

      externalInterface = lib.mkOption {
        type = lib.types.str;
        default = "eth0";
        description = "External network interface for NAT masquerading";
      };
    };
  };

  #
  # Assertions
  #

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion =
          cfg.configFile != null
          || (cfg.pools != [ ] && (cfg.gitea.instanceUrl != null || cfg.gitea.instanceUrlFile != null) && (cfg.gitea.apiToken != null || cfg.gitea.apiTokenFile != null));
        message = "Either configFile must be set, or pools, gitea.instanceUrl/instanceUrlFile, and gitea.apiToken/apiTokenFile must be configured";
      }
      {
        assertion =
          cfg.gitea.runnerScope == "instance"
          || (cfg.gitea.runnerScope == "org" && (cfg.gitea.runnerOwner != null || cfg.gitea.runnerOwnerFile != null))
          || (cfg.gitea.runnerScope == "repo" && (cfg.gitea.runnerOwner != null || cfg.gitea.runnerOwnerFile != null) && (cfg.gitea.runnerRepo != null || cfg.gitea.runnerRepoFile != null));
        message = "runnerOwner/runnerOwnerFile is required for org scope; runnerOwner/runnerOwnerFile and runnerRepo/runnerRepoFile are required for repo scope";
      }
    ];
  };
}
