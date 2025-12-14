# Security-hardened profile for Firecracker runner infrastructure
#
# Enables comprehensive security hardening:
# - Kernel sysctls and systemd hardening
# - Network isolation (VM-to-VM blocking, metadata protection)
# - Storage security (secure deletion)
#
# Jailer integration is disabled by default (requires additional testing).
# Enable with: services.fireactions.security.jailer.enable = true
#
# For maximum security, also consider:
# - services.fireactions.security.storage.encryption.enable = true
# - services.fireactions.security.hardening.disableHyperthreading = true

{ config, lib, ... }:

{
  services.fireactions.security = {
    enable = true;

    # Kernel and systemd hardening (low risk, always enable)
    hardening = {
      sysctls.enable = true;
      systemdHardening.enable = true;
      # Hyperthreading: Keep enabled by default for performance
      # Set to true for maximum security (50% vCPU reduction)
      disableHyperthreading = false;
    };

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

    # Jailer integration (high risk, disabled by default)
    # Enable after testing in your environment:
    jailer = {
      enable = false;
      # uidRangeStart = 100000;
      # uidRangeEnd = 165535;
      # chrootBaseDir = "/srv/jailer";
    };
  };
}
