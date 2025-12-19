# Fireglab - NixOS module for GitLab CI runners using Firecracker microVMs
#
# Module structure:
# - default.nix (this file): Entry point, option definitions
# - services.nix: systemd services and system configuration
#
# Usage:
#   services.fireglab.enable = true;
#   services.fireglab.gitlab.instanceUrl = "https://gitlab.example.com";
#   services.fireglab.pools = [ { name = "default"; ... } ];

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.fireglab;

  # Import custom packages
  fireglabPkg = pkgs.callPackage ../../pkgs/fireglab.nix { };

  # Pool configuration type (for GitLab runners)
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
          default = "fireglab-runner";
          description = "Runner name prefix";
        };

        image = lib.mkOption {
          type = lib.types.str;
          default = "ghcr.io/thpham/fireactions-images/ubuntu-24.04-gitlab:latest";
          description = "OCI image for the runner (must include gitlab-runner)";
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

        tags = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [
            "self-hosted"
            "fireglab"
            "linux"
          ];
          description = "Tags for the runner (used for job matching in GitLab)";
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
    # Note: microvm-base and registry-cache are imported separately by hosts/default.nix
    # as foundation and caching layers respectively
    # Fireglab-specific modules
    ./services.nix
  ];

  #
  # Option Definitions
  #

  options.services.fireglab = {
    enable = lib.mkEnableOption "Fireglab GitLab CI runner manager";

    package = lib.mkOption {
      type = lib.types.package;
      default = fireglabPkg;
      description = "The fireglab package to use";
    };

    configFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to a custom fireglab configuration file.
        If set, this overrides all other configuration options.
      '';
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/fireglab";
      description = "Directory for fireglab data (kernels, rootfs, etc.)";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "root";
      description = ''
        User account under which fireglab runs.
        Default is root because fireglab needs access to:
        - containerd socket for image management
        - KVM for microVM creation
        - Network namespaces for VM networking
      '';
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "root";
      description = "Group under which fireglab runs";
    };

    # Server configuration
    bindAddress = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0:8084";
      description = "Address for the fireglab server to bind to";
    };

    logLevel = lib.mkOption {
      type = lib.types.enum [
        "debug"
        "info"
        "warn"
        "error"
      ];
      default = "info";
      description = "Log level for fireglab";
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
      default = "127.0.0.1:8085";
      description = "Address for the metrics endpoint";
    };

    # Debug configuration (matches fireactions structure)
    debug = {
      sshKeyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "SSH public key file for VM debugging access";
      };
    };

    # GitLab configuration
    gitlab = {
      instanceUrl = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "GitLab instance URL (e.g., https://gitlab.example.com)";
        example = "https://gitlab.example.com";
      };

      instanceUrlFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Path to a file containing the GitLab instance URL.
          Takes precedence over instanceUrl if both are set.
          This should be a secret file managed by sops-nix.
        '';
      };

      accessToken = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          GitLab Personal Access Token with create_runner scope.
          Use accessTokenFile for production (secrets management).

          Token requirements by runner type:
          - instance_type: Admin access required
          - group_type: Owner role on the group
          - project_type: Maintainer role on the project

          Fireglab uses this to dynamically create runners via
          POST /api/v4/user/runners API.
        '';
      };

      accessTokenFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Path to a file containing the GitLab Personal Access Token.
          Takes precedence over accessToken if both are set.
          This should be a secret file managed by sops-nix.
        '';
      };

      runnerType = lib.mkOption {
        type = lib.types.enum [
          "instance_type"
          "group_type"
          "project_type"
        ];
        default = "group_type";
        description = ''
          Type of runner to create (affects token requirements):

          - "group_type" (recommended): Group-level runners
            Requires: groupId, token with Owner role on the group
            Risk: Medium - compromise affects one group

          - "project_type" (most secure): Project-level runners
            Requires: projectId, token with Maintainer role on the project
            Risk: Low - compromise affects one project

          - "instance_type" (avoid in production): Global instance runners
            Requires: Admin access token
            Risk: HIGH - compromise affects entire GitLab instance
        '';
      };

      groupId = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        description = ''
          GitLab Group ID for group_type runners.
          Required when runnerType is "group_type".
        '';
        example = 123;
      };

      groupIdFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Path to a file containing the GitLab Group ID.
          Takes precedence over groupId if both are set.
          This should be a secret file managed by sops-nix.
        '';
      };

      projectId = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        description = ''
          GitLab Project ID for project_type runners.
          Required when runnerType is "project_type".
        '';
        example = 456;
      };

      projectIdFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Path to a file containing the GitLab Project ID.
          Takes precedence over projectId if both are set.
          This should be a secret file managed by sops-nix.
        '';
      };
    };

    # DEPRECATED: Kernel configuration moved to microvm-base
    # Use services.microvm-base.kernel.* instead
    kernelSource = lib.mkOption {
      type = lib.types.enum [
        "upstream"
        "custom"
        "nixpkgs"
      ];
      default = "upstream";
      visible = false;
      description = ''
        DEPRECATED: Use services.microvm-base.kernel.source instead.
        Kernel configuration is now shared across all runner technologies.
      '';
    };

    kernelVersion = lib.mkOption {
      type = lib.types.str;
      default = "6.1.141";
      visible = false;
      description = "DEPRECATED: Use services.microvm-base.kernel.version instead.";
    };

    kernelPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.linuxPackages_6_12.kernel;
      visible = false;
      description = "DEPRECATED: Use services.microvm-base.kernel.package instead.";
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
        default = "fireglab0";
        description = "Name of the bridge interface for microVMs (separate from fireactions/fireteact)";
      };

      subnet = lib.mkOption {
        type = lib.types.str;
        default = "10.202.0.0/24";
        description = "Subnet for microVM networking (separate from fireactions 10.200.0.0/24 and fireteact 10.201.0.0/24)";
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
          || cfg.pools == [ ]  # Allow empty pools (service enabled but not yet configured)
          || (
            cfg.pools != [ ]
            && (cfg.gitlab.instanceUrl != null || cfg.gitlab.instanceUrlFile != null)
            && (cfg.gitlab.accessToken != null || cfg.gitlab.accessTokenFile != null)
          );
        message = "Either configFile must be set, or pools, gitlab.instanceUrl/instanceUrlFile, and gitlab.accessToken/accessTokenFile must be configured";
      }
      {
        # Only check groupId/projectId when pools are configured (not just enabled)
        assertion =
          cfg.pools == [ ]  # Skip check if no pools configured yet
          || cfg.gitlab.runnerType == "instance_type"
          || (
            cfg.gitlab.runnerType == "group_type"
            && (cfg.gitlab.groupId != null || cfg.gitlab.groupIdFile != null)
          )
          || (
            cfg.gitlab.runnerType == "project_type"
            && (cfg.gitlab.projectId != null || cfg.gitlab.projectIdFile != null)
          );
        message = "groupId/groupIdFile is required for group_type runners; projectId/projectIdFile is required for project_type runners";
      }
    ];
  };
}
