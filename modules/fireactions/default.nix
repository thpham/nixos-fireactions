# Fireactions - NixOS module for GitHub Actions runners using Firecracker microVMs
#
# Module structure:
# - default.nix (this file): Entry point, option definitions
# - services.nix: systemd services and system configuration
# - registry-cache.nix: Zot/Squid registry caching (optional)
# - security/: Security hardening submodule (optional)
#
# Usage:
#   services.fireactions.enable = true;
#   services.fireactions.pools = [ { name = "default"; ... } ];

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.fireactions;

  # Import our custom packages
  fireactionsPkg = pkgs.callPackage ../../pkgs/fireactions.nix { };

  # Pool configuration type
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
          default = "runner";
          description = "Runner name prefix";
        };

        image = lib.mkOption {
          type = lib.types.str;
          default = "ghcr.io/thpham/fireactions-images/ubuntu-24.04-github:latest";
          description = "OCI image for the runner";
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

        organization = lib.mkOption {
          type = lib.types.str;
          description = "GitHub organization name";
        };

        groupId = lib.mkOption {
          type = lib.types.nullOr lib.types.int;
          default = null;
          description = "GitHub runner group ID";
        };

        labels = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [
            "self-hosted"
            "fireactions"
          ];
          description = "Labels for the runner";
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
            Metadata to pass to the Firecracker VM via MMDS.
            This is accessible from within the VM at http://169.254.169.254/
            Cloud-init can use this for CA certificates and DNS configuration.
          '';
          example = lib.literalExpression ''
            {
              "user-data" = "...cloud-config yaml...";
            }
          '';
        };
      };
    };
  };
in
{
  imports = [
    ./services.nix
    ./registry-cache.nix
    ./security
  ];

  #
  # Option Definitions
  #

  options.services.fireactions = {
    enable = lib.mkEnableOption "Fireactions GitHub Actions runner manager";

    package = lib.mkOption {
      type = lib.types.package;
      default = fireactionsPkg;
      description = "The fireactions package to use";
    };

    configFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to a custom fireactions configuration file.
        If set, this overrides all other configuration options.
      '';
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/fireactions";
      description = "Directory for fireactions data (kernels, rootfs, etc.)";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "root";
      description = ''
        User account under which fireactions runs.
        Default is root because fireactions needs access to:
        - containerd socket for image management
        - KVM for microVM creation
        - Network namespaces for VM networking
      '';
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "root";
      description = "Group under which fireactions runs";
    };

    # Server configuration
    bindAddress = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0:8080";
      description = "Address for the fireactions server to bind to";
    };

    # Basic authentication
    basicAuth = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable basic authentication for the API";
      };

      users = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = ''
          Basic auth users as { username = "password"; }.
          WARNING: Passwords are stored in the Nix store. Use secrets management for production.
        '';
        example = {
          admin = "secret";
        };
      };
    };

    logLevel = lib.mkOption {
      type = lib.types.enum [
        "debug"
        "info"
        "warn"
        "error"
      ];
      default = "info";
      description = "Log level for fireactions";
    };

    debug = lib.mkOption {
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
      default = "127.0.0.1:8081";
      description = "Address for the metrics endpoint";
    };

    # GitHub configuration
    github = {
      appId = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        description = "GitHub App ID (use appIdFile for secrets management)";
      };

      appIdFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Path to a file containing the GitHub App ID.
          Takes precedence over appId if both are set.
          This should be a secret file managed by sops-nix.
        '';
      };

      appPrivateKeyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Path to a file containing the GitHub App private key.
          This should be a secret file, not stored in the Nix store.
        '';
      };
    };

    # Kernel configuration
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
        - "custom": Nix-built minimal kernel with Docker bridge networking support (recommended for Docker workflows)
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
        default = "fireactions0";
        description = "Name of the bridge interface for microVMs";
      };

      subnet = lib.mkOption {
        type = lib.types.str;
        default = "10.200.0.0/24";
        description = "Subnet for microVM networking";
      };

      externalInterface = lib.mkOption {
        type = lib.types.str;
        default = "eth0";
        description = "External network interface for NAT masquerading (e.g., eth0, ens3)";
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
          || (cfg.pools != [ ] && (cfg.github.appId != null || cfg.github.appIdFile != null));
        message = "Either configFile must be set, or both pools and github.appId/appIdFile must be configured";
      }
    ];
  };
}
