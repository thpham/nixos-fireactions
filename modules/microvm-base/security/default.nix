# Security hardening module for shared microVM infrastructure
#
# This module provides host-level security hardening that benefits
# all Firecracker-based runner technologies (fireactions, fireteact, etc.):
# - Kernel hardening (sysctls, boot parameters)
# - Storage security (LUKS encryption, secure deletion, tmpfs secrets)
#
# Technology-specific security (e.g., network isolation rules) remains
# in the respective runner modules.
#
# Enable with: services.microvm-base.security.enable = true
# Or use the security-hardened profile for recommended defaults.

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.microvm-base.security;
  baseCfg = config.services.microvm-base;
in
{
  imports = [
    ./hardening.nix
    ./storage.nix
  ];

  options.services.microvm-base.security = {
    enable = lib.mkEnableOption ''
      Shared security hardening for microVM infrastructure.

      This enables host-level security features that benefit all
      Firecracker-based runner technologies:
      - Kernel sysctl hardening
      - CPU vulnerability mitigations (optional SMT disable)
      - Storage encryption (optional LUKS)
      - Secure deletion of VM data
      - Tmpfs for sensitive runtime data

      Individual features can be fine-tuned via sub-options.
      For maximum security, also enable:
      - security.hardening.disableHyperthreading (Spectre mitigation)
      - security.storage.encryption.enable (data-at-rest encryption)
    '';
  };

  config = lib.mkIf (baseCfg.enable && cfg.enable) {
    # Warnings for security considerations
    warnings = lib.optional (!cfg.hardening.disableHyperthreading) ''
      microvm-base: Hyperthreading (SMT) is enabled. For maximum security
      against Spectre-class attacks on shared infrastructure, consider:
        services.microvm-base.security.hardening.disableHyperthreading = true
      Note: This reduces vCPU count by 50%.
    '';
  };
}
