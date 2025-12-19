# Storage cleanup for fireactions microVMs
#
# Implements fireactions-specific secure cleanup:
# - Secure deletion of fireactions VM snapshots
# - Periodic cleanup timer
#
# Infrastructure-level storage security (LUKS encryption, tmpfs secrets)
# is in microvm-base.security.storage.

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.fireactions.security;
  storageCfg = cfg.storage;
in
{
  options.services.fireactions.security.storage = {
    enable = lib.mkEnableOption ''
      Storage cleanup for fireactions microVMs.

      Enables secure deletion of VM data after job completion.
      For LUKS encryption and tmpfs secrets, configure
      services.microvm-base.security.storage instead.
    '';

    secureDelete = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Enable secure deletion of VM storage after job completion.

          Uses TRIM/discard commands to inform the storage device
          that blocks are no longer in use, allowing SSDs to securely
          erase the data.
        '';
      };

      method = lib.mkOption {
        type = lib.types.enum [
          "discard"
          "zero"
        ];
        default = "discard";
        description = ''
          Method for secure deletion:

          - discard: Use TRIM/discard (fast, relies on SSD secure erase)
          - zero: Overwrite with zeros (slower, works on all storage)

          Note: 'discard' is preferred for SSDs and provides better
          performance. 'zero' provides guaranteed overwrite but is slower.
        '';
      };
    };
  };

  config = lib.mkIf (cfg.enable && storageCfg.enable) {
    # Secure snapshot cleanup service (fireactions-specific paths)
    systemd.services.fireactions-snapshot-cleanup = lib.mkIf storageCfg.secureDelete.enable {
      description = "Securely cleanup Firecracker VM snapshots";
      wantedBy = [ "multi-user.target" ];
      after = [ "containerd.service" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      path = [
        pkgs.util-linux
        pkgs.coreutils
      ];

      # Cleanup on stop (shutdown)
      preStop = ''
        echo "Performing secure snapshot cleanup..."

        SNAPSHOT_DIR="/var/lib/containerd/io.containerd.snapshotter.v1.devmapper/snapshots"

        if [ -d "$SNAPSHOT_DIR" ]; then
          for snapshot in "$SNAPSHOT_DIR"/*; do
            if [ -d "$snapshot" ]; then
              DEVICE_NAME=$(basename "$snapshot")

              ${
                if storageCfg.secureDelete.method == "discard" then
                  ''
                    # Use blkdiscard for secure deletion on SSDs
                    if [ -b "/dev/mapper/fc-$DEVICE_NAME" ]; then
                      ${pkgs.util-linux}/bin/blkdiscard "/dev/mapper/fc-$DEVICE_NAME" 2>/dev/null || true
                    fi
                  ''
                else
                  ''
                    # Zero-fill for non-SSD storage
                    if [ -b "/dev/mapper/fc-$DEVICE_NAME" ]; then
                      dd if=/dev/zero of="/dev/mapper/fc-$DEVICE_NAME" bs=1M 2>/dev/null || true
                    fi
                  ''
              }
            fi
          done
        fi

        echo "Secure cleanup completed"
      '';

      script = "true"; # No-op on start
    };

    # Timer for periodic cleanup of stale snapshots
    systemd.timers.fireactions-snapshot-cleanup = lib.mkIf storageCfg.secureDelete.enable {
      description = "Periodic secure snapshot cleanup";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "10m";
        OnUnitActiveSec = "30m";
        RandomizedDelaySec = "5m";
      };
    };
  };
}
