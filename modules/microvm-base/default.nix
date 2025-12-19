# microvm-base - Shared infrastructure for Firecracker microVM technologies
#
# This module provides:
# - Bridge network registry and generation
# - DNSmasq (DHCP + DNS) for all registered bridges
# - containerd + devmapper thin-pool setup
# - CNI plugins installation
# - Shared kernel configuration for Firecracker microVMs
#
# Technologies like fireactions, fireteact, and future fireglab
# register their bridges here and consume shared infrastructure.
#
# Usage:
#   services.microvm-base.enable = true;
#   services.microvm-base.kernel.source = "custom";  # upstream|custom|nixpkgs
#   services.microvm-base.bridges.mytech = {
#     bridgeName = "mytech0";
#     subnet = "10.202.0.0/24";
#   };

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.microvm-base;

  # Import kernel packages
  firecrackerKernelUpstream = pkgs.callPackage ../../pkgs/firecracker-kernel.nix {
    kernelVersion = cfg.kernel.version;
  };
  firecrackerKernelCustom = pkgs.callPackage ../../pkgs/firecracker-kernel-custom.nix { };

  # Kernel path derivation - shared by all runner technologies
  kernelPath =
    if cfg.kernel.source == "upstream" then
      "${firecrackerKernelUpstream}/vmlinux"
    else if cfg.kernel.source == "custom" then
      "${firecrackerKernelCustom}/vmlinux"
    else if cfg.kernel.source == "nixpkgs" then
      if pkgs.stdenv.hostPlatform.isx86_64 then
        "${cfg.kernel.package.dev}/vmlinux"
      else
        "${cfg.kernel.package.out}/${pkgs.stdenv.hostPlatform.linux-kernel.target}"
    else
      throw "Invalid kernel.source: ${cfg.kernel.source}";

  # Bridge network type
  bridgeType = lib.types.submodule {
    options = {
      bridgeName = lib.mkOption {
        type = lib.types.str;
        description = "Name of the bridge interface";
      };

      subnet = lib.mkOption {
        type = lib.types.str;
        description = "Subnet in CIDR notation (e.g., 10.200.0.0/24)";
      };

      externalInterface = lib.mkOption {
        type = lib.types.str;
        default = "eth0";
        description = "External interface for NAT";
      };
    };
  };

  # Helper to parse subnet and extract network info
  parseSubnet =
    subnet:
    let
      parts = lib.splitString "/" subnet;
      networkAddr = lib.head parts;
      mask = lib.elemAt parts 1;
      octets = lib.splitString "." networkAddr;
      prefix = "${lib.elemAt octets 0}.${lib.elemAt octets 1}.${lib.elemAt octets 2}";
    in
    {
      network = networkAddr;
      mask = mask;
      prefix = prefix;
      gateway = "${prefix}.1";
      dhcpStart = "${prefix}.2";
      dhcpEnd = "${prefix}.254";
      netmask = if mask == "24" then "255.255.255.0" else "255.255.255.0";
    };

  # Import custom packages
  tcRedirectTapPkg = pkgs.callPackage ../../pkgs/tc-redirect-tap.nix { };

in
{
  imports = [
    ./containerd.nix
    ./dnsmasq.nix
    ./cni.nix
    ./bridge.nix
    ./security
  ];

  options.services.microvm-base = {
    enable = lib.mkEnableOption "shared microVM infrastructure";

    bridges = lib.mkOption {
      type = lib.types.attrsOf bridgeType;
      default = { };
      description = ''
        Bridge networks registered by runner technologies.
        Each technology (fireactions, fireteact, etc.) registers its bridge here.
      '';
      example = lib.literalExpression ''
        {
          fireactions = {
            bridgeName = "fireactions0";
            subnet = "10.200.0.0/24";
          };
          fireteact = {
            bridgeName = "fireteact0";
            subnet = "10.201.0.0/24";
          };
        }
      '';
    };

    dns = {
      upstreamServers = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "8.8.8.8"
          "1.1.1.1"
        ];
        description = "Upstream DNS servers for VMs";
      };
    };

    containerd = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable containerd with devmapper snapshotter";
      };

      thinPoolSize = lib.mkOption {
        type = lib.types.str;
        default = "20G";
        description = "Size of the devmapper thin-pool data file";
      };
    };

    # Kernel configuration for Firecracker microVMs
    # This is shared by all runner technologies (fireactions, fireteact, etc.)
    kernel = {
      source = lib.mkOption {
        type = lib.types.enum [
          "upstream"
          "custom"
          "nixpkgs"
        ];
        default = "upstream";
        description = ''
          Which kernel to use for Firecracker microVMs:
          - "upstream": Pre-built Firecracker CI kernels (fastest boot, ~150ms)
          - "custom": Nix-built kernel with Docker bridge support
          - "nixpkgs": Full NixOS kernel package (slower boot, ~300-500ms)
        '';
      };

      version = lib.mkOption {
        type = lib.types.str;
        default = "6.1.141";
        description = "Kernel version when using upstream source";
      };

      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.linuxPackages_6_12.kernel;
        description = "Kernel package to use when source is 'nixpkgs'";
      };

      args = lib.mkOption {
        type = lib.types.str;
        default = "console=ttyS0 reboot=k panic=1 pci=off";
        description = "Kernel command line arguments for microVMs";
      };
    };

    # Internal computed values for downstream consumers
    _internal = {
      bridges = lib.mkOption {
        type = lib.types.attrsOf lib.types.attrs;
        internal = true;
        readOnly = true;
        default = lib.mapAttrs (
          name: bridge:
          parseSubnet bridge.subnet
          // {
            inherit (bridge) bridgeName externalInterface;
          }
        ) cfg.bridges;
        description = "Parsed bridge configurations with computed values";
      };

      tcRedirectTapPkg = lib.mkOption {
        type = lib.types.package;
        internal = true;
        readOnly = true;
        default = tcRedirectTapPkg;
        description = "tc-redirect-tap package for CNI";
      };

      allBridgeNames = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        internal = true;
        readOnly = true;
        default = lib.mapAttrsToList (_: b: b.bridgeName) cfg.bridges;
        description = "List of all registered bridge names";
      };

      allSubnets = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        internal = true;
        readOnly = true;
        default = lib.mapAttrsToList (_: b: b.subnet) cfg.bridges;
        description = "List of all registered subnets";
      };

      # Kernel path for Firecracker microVMs - consumed by runner technologies
      kernelPath = lib.mkOption {
        type = lib.types.path;
        internal = true;
        readOnly = true;
        default = kernelPath;
        description = "Path to the vmlinux kernel image for Firecracker";
      };

      kernelArgs = lib.mkOption {
        type = lib.types.str;
        internal = true;
        readOnly = true;
        default = cfg.kernel.args;
        description = "Kernel command line arguments";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Assertions
    assertions = [
      {
        assertion = cfg.bridges != { };
        message = "microvm-base.bridges must have at least one bridge registered when enabled";
      }
    ];

    #
    # Boot Configuration
    #

    # Ensure KVM is available
    boot.kernelModules = [
      "kvm-intel"
      "kvm-amd"
    ];

    # Enable IP forwarding for microVM networking
    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = 1;
      "net.ipv4.conf.all.forwarding" = 1;
    };

    # Ensure /dev/kvm is accessible
    services.udev.extraRules = ''
      KERNEL=="kvm", GROUP="kvm", MODE="0660"
    '';

    #
    # System Packages
    #

    environment.systemPackages = [
      pkgs.firecracker
      pkgs.containerd
      pkgs.runc
      pkgs.cni-plugins
      tcRedirectTapPkg
      pkgs.lvm2
      pkgs.thin-provisioning-tools
    ];

    #
    # Directory Setup
    #

    systemd.tmpfiles.rules = [
      # Network namespace directory for Firecracker VMs
      "d /run/netns 0755 root root -"
      # CNI plugins directory (standard path used by CNI libraries)
      "d /opt/cni/bin 0755 root root -"
      # CNI cache directory
      "d /var/lib/cni 0755 root root -"
    ];

    #
    # NAT Configuration (per-bridge)
    #

    # Enable NAT for all registered bridges
    networking.nat = {
      enable = lib.mkDefault true;
      internalInterfaces = lib.mapAttrsToList (_: b: b.bridgeName) cfg.bridges;
      internalIPs = lib.mapAttrsToList (_: b: b.subnet) cfg.bridges;
      # Use the first bridge's external interface as default
      externalInterface = lib.mkDefault (
        let
          firstBridge = lib.head (lib.attrValues cfg.bridges);
        in
        firstBridge.externalInterface
      );
    };
  };
}
