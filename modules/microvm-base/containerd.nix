# microvm-base/containerd.nix - Shared containerd + devmapper setup
#
# Provides containerd with devmapper snapshotter for Firecracker block devices

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.microvm-base;
in
{
  config = lib.mkIf (cfg.enable && cfg.containerd.enable) {
    #
    # containerd Configuration
    #

    virtualisation.containerd = {
      enable = true;
      settings = {
        version = 2;
        plugins."io.containerd.grpc.v1.cri" = {
          sandbox_image = "pause:3.9";
        };
        # Configure devmapper snapshotter for Firecracker
        plugins."io.containerd.snapshotter.v1.devmapper" = {
          root_path = "/var/lib/containerd/devmapper";
          pool_name = "containerd-pool";
          base_image_size = "10GB";
          async_remove = true;
        };
      };
    };

    # Add required tools to containerd's PATH for devmapper snapshotter
    # - util-linux: blkdiscard for TRIM/discard (required by containerd plugins)
    # - lvm2: dmsetup for device mapper operations
    # - thin-provisioning-tools: thin_check, thin_repair for thin pools
    # - e2fsprogs: mkfs.ext4 for formatting snapshot volumes
    systemd.services.containerd.path = [
      pkgs.util-linux
      pkgs.lvm2
      pkgs.thin-provisioning-tools
      pkgs.e2fsprogs
    ];

    #
    # Devmapper Setup Services
    #

    # Setup devmapper thin-pool for containerd (required for Firecracker)
    systemd.services.containerd-devmapper-setup = {
      description = "Setup devmapper thin-pool for containerd";
      wantedBy = [ "containerd.service" ];
      before = [ "containerd.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [
        pkgs.util-linux
        pkgs.lvm2
        pkgs.thin-provisioning-tools
      ];
      script = ''
        set -euo pipefail

        POOL_DIR="/var/lib/containerd/devmapper"
        DATA_FILE="$POOL_DIR/data"
        META_FILE="$POOL_DIR/metadata"

        # Skip if pool already exists
        if dmsetup status containerd-pool &>/dev/null; then
          echo "containerd-pool already exists"
          exit 0
        fi

        mkdir -p "$POOL_DIR"

        # Create sparse files for thin-pool
        if [ ! -f "$DATA_FILE" ]; then
          truncate -s ${cfg.containerd.thinPoolSize} "$DATA_FILE"
        fi
        if [ ! -f "$META_FILE" ]; then
          truncate -s 200M "$META_FILE"
        fi

        # Setup loop devices
        DATA_DEV=$(losetup --find --show "$DATA_FILE")
        META_DEV=$(losetup --find --show "$META_FILE")

        # Get sizes in 512-byte sectors
        DATA_SIZE=$(blockdev --getsize "$DATA_DEV")
        META_SIZE=$(blockdev --getsize "$META_DEV")

        # Create thin-pool
        # Format: start length thin-pool metadata_dev data_dev data_block_size low_water_mark
        dmsetup create containerd-pool --table "0 $DATA_SIZE thin-pool $META_DEV $DATA_DEV 128 32768 1 skip_block_zeroing"

        echo "containerd-pool created successfully"
      '';
    };

    # Cleanup devmapper on shutdown
    systemd.services.containerd-devmapper-cleanup = {
      description = "Cleanup devmapper thin-pool for containerd";
      wantedBy = [ "multi-user.target" ];
      after = [ "containerd.service" ];
      path = [ pkgs.lvm2 ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStop = pkgs.writeShellScript "devmapper-cleanup" ''
          dmsetup remove containerd-pool || true
        '';
      };
      script = "true"; # No-op on start
    };
  };
}
