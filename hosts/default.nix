# Colmena hive generator
# Reads registry.json and generates configurations for all registered hosts
# Applies tag-based profiles from ../profiles/
{
  nixpkgs,
  disko,
  sops-nix,
  self,
}:

let
  # Import nixpkgs for default system
  pkgs = import nixpkgs { system = "x86_64-linux"; };
  lib = pkgs.lib;

  # Read the host registry
  registryPath = ./registry.json;
  registry =
    if builtins.pathExists registryPath then
      builtins.fromJSON (builtins.readFile registryPath)
    else
      { };

  # Import profile system
  profileSystem = import ../profiles { inherit lib; };

  # Provider-specific configurations
  # Keys must match "provider" field in registry.json
  providerModules = {
    # DigitalOcean (use "do" in registry.json)
    do = [
      ../deploy/digitalocean.nix
      { networking.hostName = lib.mkForce ""; } # Let cloud-init set it
      { disko.devices.disk.disk1.device = "/dev/vda"; }
      # DigitalOcean uses ens3 as the external interface (not eth0)
      { services.fireactions.networking.externalInterface = "ens3"; }
      { services.fireteact.networking.externalInterface = "ens3"; }
      { services.fireglab.networking.externalInterface = "ens3"; }
    ];

    # Hetzner Cloud/Dedicated
    hetzner = [
      { disko.devices.disk.disk1.device = "/dev/sda"; }
    ];

    # Generic cloud VM (virtio disk)
    generic = [
      { disko.devices.disk.disk1.device = "/dev/vda"; }
    ];

    # NVMe-based systems
    nvme = [
      { disko.devices.disk.disk1.device = "/dev/nvme0n1"; }
    ];

    # Bare metal with SATA/SAS
    baremetal = [
      { disko.devices.disk.disk1.device = "/dev/sda"; }
    ];
  };

  # Check if per-host config exists (escape hatch)
  hostConfigExists = name: builtins.pathExists (./. + "/${name}.nix");

  # Generate colmena node configuration for each host
  mkNode =
    name: hostDef:
    let
      hostTags = hostDef.tags or [ ];
      # Get profile modules for this host's tags
      tagProfiles = profileSystem.getProfilesForTags hostTags;
    in
    {
      # Colmena deployment settings
      deployment = {
        targetHost = hostDef.hostname;
        targetUser = hostDef.targetUser or "root";
        buildOnTarget = hostDef.buildOnTarget or true;
        tags = hostTags;
      };

      # NixOS configuration via imports
      # Order matters: later imports can override earlier ones
      imports = [
        # Hardware detection and VM guest support (critical for boot!)
        # Uses modulesPath to import NixOS hardware modules
        (
          { modulesPath, ... }:
          {
            imports = [
              (modulesPath + "/installer/scan/not-detected.nix")
              (modulesPath + "/profiles/qemu-guest.nix")
            ];
          }
        )

        # Core modules (infrastructure)
        disko.nixosModules.disko
        sops-nix.nixosModules.sops

        # Foundation layer (shared bridges, containerd, DNSmasq, CNI)
        self.nixosModules.microvm-base

        # Standalone caching layer (works with any runner)
        self.nixosModules.registry-cache

        # Runner technologies
        self.nixosModules.fireactions
        self.nixosModules.fireteact
        self.nixosModules.fireglab

        # Disk layout config (generates fileSystems/boot.loader from disko)
        # Actual partitioning only happens during nixos-anywhere initial deploy
        ../deploy/disko.nix

        # Base config (boot, network, SSH)
        ../deploy/base.nix

        # Secrets management (sops-nix)
        ../deploy/secrets.nix

        # Provider-specific modules (override disk device)
      ]
      ++ (providerModules.${hostDef.provider} or providerModules.generic)
      ++ [

        # Tag-based profiles (applied in alphabetical order)
      ]
      ++ tagProfiles
      ++ [

        # Per-host config (escape hatch for truly unique configurations)
      ]
      ++ lib.optional (hostConfigExists name) (./. + "/${name}.nix")
      ++ [

        # Safety module - always last, cannot be overridden
        {
          services.openssh.enable = lib.mkForce true;
          services.openssh.settings.PermitRootLogin = lib.mkDefault "prohibit-password";
          networking.firewall.allowedTCPPorts = [ 22 ];
          networking.hostName = lib.mkDefault name;
        }
      ];
    };

in
{
  # Colmena meta configuration
  meta = {
    nixpkgs = pkgs;

    # Per-node nixpkgs based on target system, with our overlay for custom packages
    nodeNixpkgs = lib.mapAttrs (
      _name: hostDef:
      import nixpkgs {
        system = hostDef.system;
        overlays = [ self.overlays.default ];
      }
    ) registry;

    specialArgs = { inherit self; };
  };

  # Default configuration for all hosts
  defaults =
    { ... }:
    {
      deployment.buildOnTarget = lib.mkDefault true;
    };
}
# Merge with generated nodes
// lib.mapAttrs mkNode registry
