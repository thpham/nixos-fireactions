# Security-hardened profile for Firecracker runner infrastructure
#
# Enables host-level security hardening via microvm-base.security:
# - Kernel sysctls and boot parameter hardening
# - Storage security (LUKS encryption, secure deletion, snapshot cleanup)
# - Tmpfs for sensitive runtime data
#
# Runner-specific security (network isolation, systemd hardening) is now
# built-in to each runner module and always enabled:
# - fireactions: services.nix includes nftables rules and systemd hardening
# - fireteact: (future) will include similar built-in security
#
# Firecracker's KVM-based VM isolation is the primary security boundary.
# The jailer was considered but removed due to NixOS incompatibility
# (dynamic linking requires /nix/store access inside chroot).
#
# For maximum security, also consider:
# - services.microvm-base.security.hardening.disableHyperthreading = true

{ ... }:

{
  #
  # Shared security (host-level, benefits all runners)
  #
  services.microvm-base.security = {
    enable = true;

    # Kernel and host hardening (low risk, always enable)
    hardening = {
      sysctls.enable = true;
      # Hyperthreading: Keep enabled by default for performance
      # Set to true for maximum security (50% vCPU reduction)
      disableHyperthreading = false;
    };

    # Storage security (medium risk, recommended)
    storage = {
      enable = true;
      secureDelete = {
        enable = true;
        method = "discard"; # Use TRIM for SSDs
      };
      tmpfsSecrets.enable = true;
      # LUKS encryption enabled by default for security-hardened profile
      # Uses ephemeral key (new random key each boot) - ideal since Firecracker
      # VMs and devmapper storage are ephemeral anyway
      encryption.enable = true;
    };
  };

  # Note: Runner-specific security (network isolation, systemd hardening)
  # is now built-in to each runner module and always enabled when the
  # runner is enabled. No additional configuration needed here.
}
