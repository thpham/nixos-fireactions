# Common configuration for all cloud images
#
# This module contains shared configuration for all fireactions cloud images:
# - Fireactions module and production profiles
# - Common boot settings (kernel 6.12)
# - Cloud-init module configuration
# - Networking and firewall
# - System packages
# - Bootstrap scripts for runtime configuration
# - Disk layout
#
# Platform-specific images (azure.nix, qcow2.nix) import this and add their specifics.
{
  config,
  lib,
  pkgs,
  ...
}:

{
  imports = [
    # Import the fireactions module
    ../modules/fireactions
    # Production-ready profiles
    ../profiles/security-hardened.nix
    ../profiles/registry-cache.nix
    ../profiles/prod.nix
  ];

  #
  # Boot Configuration (common settings)
  #

  boot.kernelPackages = pkgs.linuxPackages_6_12;
  boot.growPartition = true;

  boot.kernelParams = [
    "mem_alloc_profiling=off" # Suppress slab extension warnings on 6.12+
  ];

  #
  # Cloud-init Module Configuration (common modules)
  #
  # Platform-specific datasources are configured in azure.nix/qcow2.nix
  #

  services.cloud-init = {
    enable = true;
    network.enable = true;
    settings = {
      cloud_init_modules = [
        "migrator"
        "seed_random"
        "bootcmd"
        "write-files"
        "growpart"
        "resizefs"
        "disk_setup"
        "mounts"
        "set_hostname"
        "update_hostname"
        "update_etc_hosts"
        "ca-certs"
        "users-groups"
        "ssh"
      ];

      cloud_config_modules = [
        "ssh-import-id"
        "locale"
        "set-passwords"
        "ntp"
        "timezone"
        "runcmd"
      ];

      cloud_final_modules = [
        "scripts-vendor"
        "scripts-per-once"
        "scripts-per-boot"
        "scripts-per-instance"
        "scripts-user"
        "ssh-authkey-fingerprints"
        "keys-to-console"
        "final-message"
      ];
    };
  };

  #
  # Networking
  #

  networking = {
    hostName = ""; # Let cloud-init set hostname
    useDHCP = true;
    firewall = {
      enable = true;
      allowedTCPPorts = [
        22 # SSH
        8080 # Fireactions API
        8081 # Metrics
      ];
    };
  };

  #
  # Fireactions Module Configuration
  #
  # Base configuration comes from imported profiles:
  # - security-hardened.nix: Kernel/network/storage security
  # - registry-cache.nix: Zot + Squid caching
  # - prod.nix: Production logging and metrics
  #
  # Pools are configured at runtime via bootstrap script from cloud-init user-data.
  #

  services.fireactions = {
    enable = true;
    # Empty pools - configured at runtime by bootstrap script
    pools = [ ];
    # Use a placeholder config file that bootstrap will override
    configFile = "/run/fireactions/config.yaml";
    # Kernel: use custom kernel with Docker bridge networking support
    kernelSource = "custom";
    # Metrics: expose on all interfaces for Prometheus scraping
    metricsAddress = "0.0.0.0:8081";
    # Networking defaults
    networking = {
      bridgeName = "fireactions0";
      subnet = "10.200.0.0/24";
      externalInterface = "eth0";
    };
  };

  #
  # System Packages
  #

  environment.systemPackages = with pkgs; [
    vim
    git
    curl
    wget
    htop
    tmux
    jq
    dig
    tcpdump
  ];

  #
  # Fireactions Bootstrap Scripts (from images/src/)
  #
  # Called by cloud-init to configure fireactions from user-data.
  # Scripts are shared across cloud images for maintainability.
  #

  environment.etc."fireactions/bootstrap.sh" =
    let
      # Use custom kernel (matches kernelSource = "custom" above)
      firecrackerKernelPkg = pkgs.callPackage ../pkgs/firecracker-kernel-custom.nix { };
      pythonWithYaml = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);

      # Registry cache configuration for generate-config.py
      registryCacheCfg = config.services.fireactions.registryCache;
      registryCacheEnabled = registryCacheCfg.enable && registryCacheCfg.zot.enable;

      # Convert mirrors to JSON format for the Python script
      mirrorsJson = builtins.toJSON (
        lib.mapAttrs (_name: mirror: { url = mirror.url; }) registryCacheCfg.zot.mirrors
      );
    in
    {
      mode = "0755";
      text = ''
        #!/usr/bin/env bash
        # Wrapper that sets environment and calls the shared bootstrap script
        export KERNEL_PATH="${firecrackerKernelPkg}/vmlinux"
        export PYTHON_WITH_YAML="${pythonWithYaml}/bin/python3"

        # Registry cache configuration (from profiles/registry-cache.nix)
        # These are used by generate-config.py to inject containerd/BuildKit/Docker config
        export REGISTRY_CACHE_ENABLED="${if registryCacheEnabled then "true" else "false"}"
        export REGISTRY_CACHE_GATEWAY="${registryCacheCfg._internal.gateway}"
        export ZOT_PORT="${toString registryCacheCfg._internal.zotPort}"
        export ZOT_MIRRORS='${mirrorsJson}'

        exec /etc/fireactions/bootstrap-impl.sh "$@"
      '';
    };

  # The actual bootstrap implementation (shared script)
  environment.etc."fireactions/bootstrap-impl.sh" = {
    mode = "0755";
    source = ./src/bootstrap.sh;
  };

  # Python config generator (shared script)
  environment.etc."fireactions/generate-config.py" = {
    mode = "0755";
    source = ./src/generate-config.py;
  };

  #
  # Disk Configuration
  #

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
    autoResize = true;
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-label/ESP";
    fsType = "vfat";
  };

  system.stateVersion = "25.11";
}
