# Initial NixOS configuration for nixos-anywhere deployment
# Includes disko for disk partitioning (applied only during first install)
# For fleet updates, Colmena uses base.nix directly (without disko)
{ modulesPath, ... }:

{
  imports = [
    # Shared configuration (boot, network, SSH)
    ./base.nix

    # Disk partitioning - ONLY for initial deployment
    ./disko.nix

    # Hardware detection modules
    (modulesPath + "/installer/scan/not-detected.nix")
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

}
