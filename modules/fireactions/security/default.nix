# Security hardening module for Firecracker microVM infrastructure
#
# This module provides defense-in-depth security for the fireactions runner:
# - Kernel hardening (sysctls, boot parameters)
# - Network isolation (VM-to-VM blocking, metadata protection)
# - Storage security (encryption, secure deletion)
#
# Note: Firecracker's jailer was considered but removed due to NixOS
# incompatibility (dynamic linking requires /nix/store in chroot).
# Firecracker's KVM-based VM isolation is the primary security boundary.
#
# Enable with: services.fireactions.security.enable = true
# Or use the security-hardened profile for recommended defaults.

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.fireactions.security;
  fireactionsCfg = config.services.fireactions;
in
{
  imports = [
    ./hardening.nix
    ./network.nix
    ./storage.nix
  ];

  options.services.fireactions.security = {
    enable = lib.mkEnableOption ''
      Security hardening for Firecracker microVMs.

      This enables a comprehensive security layer including:
      - Kernel hardening (restrictive sysctls)
      - Network isolation (VM-to-VM blocking)
      - Storage security (secure deletion)

      Individual features can be fine-tuned via sub-options.
      For maximum security, also enable:
      - security.storage.encryption.enable (data-at-rest encryption)
      - security.hardening.disableHyperthreading (Spectre mitigation)
    '';
  };

  config = lib.mkIf (fireactionsCfg.enable && cfg.enable) {
    # Warnings for security considerations
    warnings =
      lib.optional (!cfg.hardening.disableHyperthreading) ''
        Hyperthreading (SMT) is enabled. For maximum security against Spectre-class
        attacks on shared infrastructure, consider setting:
          services.fireactions.security.hardening.disableHyperthreading = true
        Note: This reduces vCPU count by 50%.
      '';
  };
}
