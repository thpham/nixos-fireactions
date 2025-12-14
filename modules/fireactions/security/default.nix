# Security hardening module for Firecracker microVM infrastructure
#
# This module provides defense-in-depth security for the fireactions runner:
# - Kernel hardening (sysctls, boot parameters)
# - Network isolation (VM-to-VM blocking, metadata protection)
# - Storage security (encryption, secure deletion)
# - Jailer integration (chroot, UID isolation, seccomp)
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
    ./jailer.nix
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
      - security.jailer.enable (process isolation)
      - security.storage.encryption.enable (data-at-rest encryption)
      - security.hardening.disableHyperthreading (Spectre mitigation)
    '';
  };

  config = lib.mkIf (fireactionsCfg.enable && cfg.enable) {
    # Assertions to validate security configuration
    assertions = [
      {
        assertion = cfg.jailer.enable -> cfg.network.enable;
        message = "Jailer integration requires network isolation to be enabled for proper netns handling";
      }
    ];

    # Warnings for security considerations
    warnings =
      lib.optional (!cfg.hardening.disableHyperthreading) ''
        Hyperthreading (SMT) is enabled. For maximum security against Spectre-class
        attacks on shared infrastructure, consider setting:
          services.fireactions.security.hardening.disableHyperthreading = true
        Note: This reduces vCPU count by 50%.
      ''
      ++ lib.optional (!cfg.jailer.enable) ''
        Jailer integration is disabled. Firecracker VMs run without chroot isolation.
        Consider enabling: services.fireactions.security.jailer.enable = true
      '';
  };
}
