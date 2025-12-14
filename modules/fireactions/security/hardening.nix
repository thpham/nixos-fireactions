# Kernel and systemd hardening for Firecracker host
#
# Implements security best practices:
# - Restrictive kernel sysctls (dmesg, kptr, sysrq, etc.)
# - Network stack hardening (rp_filter, redirects, syncookies)
# - Optional SMT/hyperthreading disable for Spectre mitigation
# - Enhanced systemd service isolation

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.fireactions.security;
  hardeningCfg = cfg.hardening;
in
{
  options.services.fireactions.security.hardening = {
    sysctls = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Enable kernel sysctl hardening.

          Applies restrictive settings for:
          - Kernel pointer and dmesg access
          - SysRq key disable
          - BPF JIT hardening
          - Network stack protection
        '';
      };
    };

    disableHyperthreading = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Disable Simultaneous Multi-Threading (SMT/Hyperthreading).

        This mitigates Spectre-class side-channel attacks but reduces
        available vCPUs by approximately 50%.

        Recommended for shared/multi-tenant infrastructure where
        security is prioritized over performance.
      '';
    };

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
    # Kernel sysctl hardening
    boot.kernel.sysctl = lib.mkIf hardeningCfg.sysctls.enable {
      # Restrict kernel pointer exposure
      "kernel.kptr_restrict" = 2;

      # Restrict dmesg access to root
      "kernel.dmesg_restrict" = 1;

      # Disable magic SysRq key
      "kernel.sysrq" = 0;

      # Restrict perf_event access
      "kernel.perf_event_paranoid" = 3;

      # Disable unprivileged BPF
      "kernel.unprivileged_bpf_disabled" = 1;

      # Harden BPF JIT compiler
      "net.core.bpf_jit_harden" = 2;

      # Restrict unprivileged user namespaces (may break some containers)
      # "kernel.unprivileged_userns_clone" = 0;

      # Network stack hardening
      # Enable strict reverse path filtering (anti-spoofing)
      "net.ipv4.conf.all.rp_filter" = 1;
      "net.ipv4.conf.default.rp_filter" = 1;

      # Disable ICMP redirects (prevent MITM)
      "net.ipv4.conf.all.accept_redirects" = 0;
      "net.ipv4.conf.default.accept_redirects" = 0;
      "net.ipv4.conf.all.send_redirects" = 0;
      "net.ipv4.conf.default.send_redirects" = 0;
      "net.ipv6.conf.all.accept_redirects" = 0;
      "net.ipv6.conf.default.accept_redirects" = 0;

      # Disable source routing
      "net.ipv4.conf.all.accept_source_route" = 0;
      "net.ipv4.conf.default.accept_source_route" = 0;
      "net.ipv6.conf.all.accept_source_route" = 0;
      "net.ipv6.conf.default.accept_source_route" = 0;

      # Enable TCP SYN cookies (prevent SYN flood)
      "net.ipv4.tcp_syncookies" = 1;

      # Log martian packets (impossible source addresses)
      "net.ipv4.conf.all.log_martians" = 1;
      "net.ipv4.conf.default.log_martians" = 1;

      # Ignore ICMP broadcasts (prevent smurf attacks)
      "net.ipv4.icmp_echo_ignore_broadcasts" = 1;

      # Ignore bogus ICMP error responses
      "net.ipv4.icmp_ignore_bogus_error_responses" = 1;

      # Disable IPv6 router advertisements (if not needed)
      "net.ipv6.conf.all.accept_ra" = 0;
      "net.ipv6.conf.default.accept_ra" = 0;
    };

    # Boot parameters for SMT disable and CPU vulnerability mitigations
    boot.kernelParams = lib.mkIf hardeningCfg.disableHyperthreading [
      # Disable Simultaneous Multi-Threading
      "nosmt=force"

      # L1 Terminal Fault mitigation (full flush, force SMT disable)
      "l1tf=full,force"

      # Microarchitectural Data Sampling mitigation
      "mds=full,nosmt"

      # Speculative Store Bypass mitigation
      "spec_store_bypass_disable=on"

      # TSX Async Abort mitigation
      "tsx_async_abort=full,nosmt"
    ];

    # Enhanced systemd service hardening
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

    # Verify SMT is disabled when requested
    systemd.services.fireactions-verify-smt = lib.mkIf hardeningCfg.disableHyperthreading {
      description = "Verify SMT/Hyperthreading is disabled";
      wantedBy = [ "fireactions.service" ];
      before = [ "fireactions.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        SMT_ACTIVE=$(cat /sys/devices/system/cpu/smt/active 2>/dev/null || echo "unknown")
        if [ "$SMT_ACTIVE" = "1" ]; then
          echo "WARNING: SMT is still active despite nosmt=force kernel parameter"
          echo "This may indicate the CPU doesn't support SMT control or BIOS settings override"
          # Don't fail - just warn, as this may be expected on some hardware
        elif [ "$SMT_ACTIVE" = "0" ]; then
          echo "SMT is correctly disabled"
        else
          echo "Could not determine SMT status (value: $SMT_ACTIVE)"
        fi
      '';
    };
  };
}
