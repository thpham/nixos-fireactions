# Systemd service hardening for fireactions
#
# Implements enhanced systemd service isolation:
# - System call filtering
# - Memory execution restrictions
# - Address family restrictions
# - Namespace restrictions
#
# Host-level hardening (sysctls, SMT disable) is in microvm-base.security.

{
  config,
  lib,
  ...
}:

let
  cfg = config.services.fireactions.security;
  hardeningCfg = cfg.hardening;
in
{
  options.services.fireactions.security.hardening = {
    systemdHardening = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Enable enhanced systemd service hardening for fireactions.

          Adds additional isolation beyond the base service config:
          - System call filtering
          - Memory execution restrictions
          - Address family restrictions
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Enhanced systemd service hardening for fireactions
    systemd.services.fireactions.serviceConfig = lib.mkIf hardeningCfg.systemdHardening.enable {
      # System call filtering - allow only necessary syscall groups
      SystemCallFilter = [
        "@system-service"
        "@mount"
        "@network-io"
        "@privileged"
        "~@obsolete"
      ];
      SystemCallArchitectures = "native";

      # Memory protection
      MemoryDenyWriteExecute = true;

      # Personality restrictions
      LockPersonality = true;

      # Restrict address families to required ones
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
        "AF_NETLINK"
      ];

      # Restrict namespace creation (except network for VMs)
      RestrictNamespaces = "~user pid ipc";

      # Protect clock and kernel resources
      ProtectClock = true;
      ProtectKernelLogs = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      ProtectControlGroups = true;
      ProtectProc = "invisible";

      # Restrict realtime scheduling
      RestrictRealtime = true;

      # Restrict SUID/SGID execution
      RestrictSUIDSGID = true;

      # Private /dev with only needed devices
      PrivateDevices = false; # Need /dev/kvm access

      # Remove all capabilities not explicitly needed
      # Note: CAP_SYS_ADMIN and CAP_NET_ADMIN are added in main module
      SecureBits = "noroot-locked";
    };
  };
}
