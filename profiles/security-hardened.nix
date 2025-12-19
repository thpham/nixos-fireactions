# Security-hardened profile for Firecracker runner infrastructure
#
# Enables comprehensive security hardening for all runner technologies:
#
# Shared security (microvm-base.security):
# - Kernel sysctls and boot parameter hardening
# - Storage security (LUKS encryption, secure deletion)
# - Tmpfs for sensitive runtime data
#
# Fireactions-specific security (fireactions.security):
# - Network isolation (VM-to-VM blocking, metadata protection)
# - Systemd service hardening
# - Secure snapshot cleanup
#
# Note: Firecracker's KVM-based VM isolation is the primary security boundary.
# The jailer was considered but removed due to NixOS incompatibility
# (dynamic linking requires /nix/store access inside chroot).
#
# For maximum security, also consider:
# - services.microvm-base.security.hardening.disableHyperthreading = true

{ config, lib, ... }:

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

  #
  # Fireactions-specific security (only if fireactions is enabled)
  #
  services.fireactions.security = lib.mkIf config.services.fireactions.enable {
    enable = true;

    # Systemd service hardening (low risk, always enable)
    hardening.systemdHardening.enable = true;

    # Network isolation (medium risk, recommended)
    network = {
      enable = true;
      blockVmToVm = true;
      blockCloudMetadata = true;
      rateLimitConnections = 100;
      allowedHostPorts = [
        53 # DNS
        67 # DHCP
        3128 # Squid HTTP proxy
        3129 # Squid HTTPS proxy
        5000 # Zot registry
      ];
    };

    # Storage cleanup (fireactions-specific)
    storage = {
      enable = true;
      secureDelete = {
        enable = true;
        method = "discard";
      };
    };
  };

  # Future: Fireteact-specific security when implemented
  # services.fireteact.security = lib.mkIf config.services.fireteact.enable { ... };
}
