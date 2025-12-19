# Security hardening module for fireactions runner
#
# This module provides fireactions-specific security:
# - Network isolation (VM-to-VM blocking, metadata protection)
# - Systemd service hardening
# - Secure snapshot cleanup
#
# Host-level security (sysctls, LUKS encryption, SMT disable) is now
# provided by the shared microvm-base.security module which benefits
# all Firecracker-based runner technologies.
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
      Security hardening for fireactions runner.

      This enables fireactions-specific security including:
      - Network isolation (VM-to-VM blocking)
      - Systemd service hardening
      - Secure snapshot cleanup

      Host-level security (sysctls, LUKS, SMT) is provided by
      microvm-base.security, which is automatically enabled when
      this option is enabled.

      Individual features can be fine-tuned via sub-options.
    '';
  };

  config = lib.mkIf (fireactionsCfg.enable && cfg.enable) {
    # Note: Host-level security (sysctls, LUKS, SMT) is now in microvm-base.security
    # Enable it via: services.microvm-base.security.enable = true
    # Or use the security-hardened profile which enables both
  };
}
