# Storage security for microVM infrastructure
#
# Implements secure storage handling at the infrastructure level:
# - LUKS encryption for containerd devmapper (both data and metadata)
# - Ephemeral key option for maximum security
# - Tmpfs mount for sensitive runtime data (keys, credentials)
# - Secure deletion configuration for containerd
#
# Security model:
# - Both thin-pool data AND metadata are LUKS encrypted
# - Prevents any storage pattern analysis from leaked metadata
# - Ephemeral keys regenerated each boot (defense in depth)
#
# These settings benefit all Firecracker-based runner technologies.
# Runner-specific cleanup timers remain in the respective modules.

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.microvm-base.security;
  storageCfg = cfg.storage;
  baseCfg = config.services.microvm-base;

  # Pool name for devmapper - must match containerd config in ../containerd.nix
  poolName = "containerd-pool";
in
{
  options.services.microvm-base.security.storage = {
    enable = lib.mkEnableOption ''
      Storage security enhancements for microVM infrastructure.

      Enables secure handling of containerd devmapper storage used by
      all Firecracker-based runners. Optionally enables LUKS encryption
      for data-at-rest protection.
    '';

    encryption = {
      enable = lib.mkEnableOption ''
        LUKS encryption for the containerd devmapper storage pool.

        Encrypts both data AND metadata at rest, protecting against:
        - Physical disk theft
        - Residual data exposure after VM deletion
        - Offline attacks on storage media
        - Storage pattern analysis via metadata inspection

        Uses an ephemeral key generated at boot (stored in tmpfs, lost on reboot).
        This is ideal for Firecracker VMs since:
        - VMs are ephemeral by design
        - The devmapper thin-pool is recreated on each boot anyway
        - No key management complexity
        - Fresh encryption key on each boot = defense in depth

        Encryption parameters:
        - Cipher: AES-XTS-PLAIN64 with 512-bit key
        - Hash: SHA-512 for header integrity
        - PBKDF: Argon2id (256MB memory, 4 threads)
      '';
    };

    secureDelete = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Enable secure deletion support for VM storage.

          Configures containerd devmapper to use TRIM/discard commands,
          allowing SSDs to securely erase data when blocks are freed.
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

    tmpfsSecrets = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Mount a dedicated tmpfs for sensitive runtime data.

          Provides a secure location for:
          - Encryption keys (if ephemeral)
          - Temporary credentials
          - Other sensitive data that should never touch disk
        '';
      };

      size = lib.mkOption {
        type = lib.types.str;
        default = "64M";
        description = "Size of the tmpfs secrets mount";
      };

      path = lib.mkOption {
        type = lib.types.str;
        default = "/run/microvm-base/secrets";
        description = "Path for the tmpfs secrets mount";
      };
    };
  };

  config = lib.mkIf (cfg.enable && storageCfg.enable) {
    # Add cryptsetup to system packages when encryption is enabled (for verification)
    environment.systemPackages = lib.mkIf storageCfg.encryption.enable [
      pkgs.cryptsetup
    ];

    # Tmpfs mount for sensitive data
    fileSystems.${storageCfg.tmpfsSecrets.path} = lib.mkIf storageCfg.tmpfsSecrets.enable {
      device = "tmpfs";
      fsType = "tmpfs";
      options = [
        "size=${storageCfg.tmpfsSecrets.size}"
        "mode=0700"
        "uid=0"
        "gid=0"
        "noswap"
        "nodev"
        "nosuid"
        "noexec"
      ];
    };

    # Enhanced devmapper setup with optional LUKS encryption
    systemd.services.containerd-devmapper-setup = lib.mkIf storageCfg.encryption.enable {
      serviceConfig = {
        # Need cryptsetup for LUKS operations
        ExecSearchPath = [ "${pkgs.cryptsetup}/bin" ];
      };
      # All packages used in the script must be in path to ensure closure includes them
      path = [
        pkgs.cryptsetup
        pkgs.lvm2
        pkgs.util-linux
        pkgs.coreutils
      ];

      # Override the script to add LUKS layer
      # NOTE: Uses PATH-relative commands (not ${pkgs.*}/bin/) to avoid store path mismatches
      # when building on target with different nixpkgs. The required packages are in the service's path.
      script = lib.mkForce ''
        set -euo pipefail

        POOL_DIR="/var/lib/containerd/devmapper"
        DATA_FILE="$POOL_DIR/data"
        META_FILE="$POOL_DIR/metadata"
        LUKS_DATA_NAME="containerd-data-crypt"
        LUKS_META_NAME="containerd-meta-crypt"
        KEY_FILE="${storageCfg.tmpfsSecrets.path}/storage.key"

        # Skip if pool already exists
        if dmsetup status containerd-pool &>/dev/null; then
          echo "containerd-pool already exists"
          exit 0
        fi

        mkdir -p "$POOL_DIR"

        # Create sparse files if they don't exist
        if [ ! -f "$DATA_FILE" ]; then
          truncate -s ${baseCfg.containerd.thinPoolSize} "$DATA_FILE"
        fi
        if [ ! -f "$META_FILE" ]; then
          truncate -s 200M "$META_FILE"
        fi

        # Generate ephemeral encryption key (new key each boot)
        # Same key used for both data and metadata (both ephemeral)
        if [ ! -f "$KEY_FILE" ]; then
          mkdir -p "$(dirname "$KEY_FILE")"
          chmod 700 "$(dirname "$KEY_FILE")"
          head -c 32 /dev/urandom > "$KEY_FILE"
          chmod 400 "$KEY_FILE"
          echo "Generated ephemeral encryption key"
        fi

        # Setup loop devices
        DATA_LOOP=$(losetup --find --show "$DATA_FILE")
        META_LOOP=$(losetup --find --show "$META_FILE")

        # Function to format LUKS container
        # Args: $1 = loop device, $2 = description
        format_luks() {
          local loop_dev="$1"
          local desc="$2"
          echo "Initializing LUKS encryption on $desc..."
          cryptsetup luksFormat \
            --batch-mode \
            --type luks2 \
            --cipher aes-xts-plain64 \
            --key-size 512 \
            --hash sha512 \
            --pbkdf argon2id \
            --pbkdf-memory 262144 \
            --pbkdf-parallel 4 \
            "$loop_dev" \
            "$KEY_FILE"
          echo "LUKS encryption initialized on $desc"
        }

        # Function to open or recreate LUKS container
        # Args: $1 = loop device, $2 = luks name, $3 = description, $4 = file path, $5 = size
        open_or_recreate_luks() {
          local loop_dev="$1"
          local luks_name="$2"
          local desc="$3"
          local file_path="$4"
          local size="$5"

          if cryptsetup isLuks "$loop_dev" 2>/dev/null; then
            echo "LUKS header found on $desc, attempting to open..."
            if ! cryptsetup open \
                 --type luks2 \
                 "$loop_dev" \
                 "$luks_name" \
                 --key-file "$KEY_FILE" 2>/dev/null; then
              echo "Failed to open $desc LUKS - key mismatch (stale ephemeral key)"
              echo "Wiping and re-creating $desc LUKS container..."

              # Detach loop, wipe file, reattach
              losetup -d "$loop_dev"
              truncate -s 0 "$file_path"
              truncate -s "$size" "$file_path"
              loop_dev=$(losetup --find --show "$file_path")
              format_luks "$loop_dev" "$desc"
              cryptsetup open \
                --type luks2 \
                "$loop_dev" \
                "$luks_name" \
                --key-file "$KEY_FILE"
              # Return new loop device path
              echo "$loop_dev"
              return
            fi
            echo "LUKS container opened for $desc"
          else
            format_luks "$loop_dev" "$desc"
            cryptsetup open \
              --type luks2 \
              "$loop_dev" \
              "$luks_name" \
              --key-file "$KEY_FILE"
            echo "LUKS container opened for $desc"
          fi
          echo "$loop_dev"
        }

        # Check if we need to wipe (key mismatch on either data or metadata)
        # Also track if metadata needs zeroing (fresh LUKS requires zeroed metadata for thin-pool)
        NEEDS_WIPE=false
        NEEDS_ZERO_META=false
        if cryptsetup isLuks "$DATA_LOOP" 2>/dev/null; then
          if ! cryptsetup open --test-passphrase --type luks2 "$DATA_LOOP" --key-file "$KEY_FILE" 2>/dev/null; then
            NEEDS_WIPE=true
          fi
        else
          # Fresh data device - will need metadata zeroed too
          NEEDS_ZERO_META=true
        fi
        if cryptsetup isLuks "$META_LOOP" 2>/dev/null; then
          if ! cryptsetup open --test-passphrase --type luks2 "$META_LOOP" --key-file "$KEY_FILE" 2>/dev/null; then
            NEEDS_WIPE=true
          fi
        else
          # Fresh metadata device - needs zeroing for thin-pool
          NEEDS_ZERO_META=true
        fi

        if [ "$NEEDS_WIPE" = true ]; then
          echo "Key mismatch detected - wiping both data and metadata..."
          NEEDS_ZERO_META=true  # Wiped metadata needs zeroing
          # Clear containerd's state since we're wiping the pool
          echo "Clearing containerd state (snapshots lost due to LUKS wipe)..."
          rm -f /var/lib/containerd/devmapper/*.db || true
          rm -rf /var/lib/containerd/io.containerd.metadata.v1.bolt || true

          # Detach loops and wipe files
          losetup -d "$DATA_LOOP" || true
          losetup -d "$META_LOOP" || true
          truncate -s 0 "$DATA_FILE"
          truncate -s 0 "$META_FILE"
          truncate -s ${baseCfg.containerd.thinPoolSize} "$DATA_FILE"
          truncate -s 200M "$META_FILE"
          DATA_LOOP=$(losetup --find --show "$DATA_FILE")
          META_LOOP=$(losetup --find --show "$META_FILE")
        fi

        # Open or create data LUKS
        if ! cryptsetup status "$LUKS_DATA_NAME" &>/dev/null; then
          if cryptsetup isLuks "$DATA_LOOP" 2>/dev/null; then
            cryptsetup open --type luks2 "$DATA_LOOP" "$LUKS_DATA_NAME" --key-file "$KEY_FILE"
            echo "Data LUKS container opened"
          else
            format_luks "$DATA_LOOP" "data file"
            cryptsetup open --type luks2 "$DATA_LOOP" "$LUKS_DATA_NAME" --key-file "$KEY_FILE"
            echo "Data LUKS container created and opened"
          fi
        fi

        # Open or create metadata LUKS
        if ! cryptsetup status "$LUKS_META_NAME" &>/dev/null; then
          if cryptsetup isLuks "$META_LOOP" 2>/dev/null; then
            cryptsetup open --type luks2 "$META_LOOP" "$LUKS_META_NAME" --key-file "$KEY_FILE"
            echo "Metadata LUKS container opened"
          else
            format_luks "$META_LOOP" "metadata file"
            cryptsetup open --type luks2 "$META_LOOP" "$LUKS_META_NAME" --key-file "$KEY_FILE"
            echo "Metadata LUKS container created and opened"
          fi
        fi

        # Get sizes in 512-byte sectors (use encrypted data device size)
        DATA_SIZE=$(blockdev --getsize "/dev/mapper/$LUKS_DATA_NAME")

        # Zero metadata device if fresh (thin-pool requires zeroed metadata to initialize)
        # This is needed because LUKS-encrypted empty space appears as random data
        if [ "$NEEDS_ZERO_META" = true ]; then
          echo "Zeroing metadata device for thin-pool initialization..."
          dd if=/dev/zero of="/dev/mapper/$LUKS_META_NAME" bs=1M status=progress 2>/dev/null || true
          echo "Metadata device zeroed"
        fi

        # Create thin-pool with BOTH data and metadata encrypted
        dmsetup create containerd-pool \
          --table "0 $DATA_SIZE thin-pool /dev/mapper/$LUKS_META_NAME /dev/mapper/$LUKS_DATA_NAME 128 32768 1 skip_block_zeroing"

        echo "containerd-pool created with full LUKS encryption (data + metadata)"
      '';
    };

    # Enhanced cleanup with LUKS close when encryption is enabled
    # NOTE: Uses PATH-relative commands to avoid store path mismatches
    # This override replaces the base service's ExecStop to add cryptsetup close
    systemd.services.containerd-devmapper-cleanup = lib.mkIf storageCfg.encryption.enable {
      # Add cryptsetup to path for LUKS cleanup
      path = lib.mkForce [
        pkgs.lvm2
        pkgs.cryptsetup
      ];
      # Use mkForce on serviceConfig to properly override the base service's ExecStop
      serviceConfig = lib.mkForce {
        Type = "oneshot";
        RemainAfterExit = true;
        # Use PATH-relative commands - packages are in service's path
        # Close both data and metadata LUKS containers
        ExecStop = pkgs.writeShellScript "devmapper-luks-cleanup" ''
          dmsetup remove containerd-pool || true
          cryptsetup close containerd-data-crypt || true
          cryptsetup close containerd-meta-crypt || true
        '';
      };
    };

    # Configure containerd to use discard
    virtualisation.containerd.settings.plugins."io.containerd.snapshotter.v1.devmapper" =
      lib.mkIf storageCfg.secureDelete.enable
        {
          discard_blocks = true;
        };

    #
    # Secure snapshot cleanup service (shared across all runner technologies)
    #
    systemd.services.microvm-snapshot-cleanup = lib.mkIf storageCfg.secureDelete.enable {
      description = "Securely cleanup microVM thin-provisioned snapshots";
      wantedBy = [ "multi-user.target" ];
      after = [ "containerd.service" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      path = [
        pkgs.util-linux
        pkgs.lvm2
        pkgs.coreutils
      ];

      # Cleanup on stop (shutdown)
      preStop = ''
        echo "Performing secure snapshot cleanup for ${poolName}..."

        # Find all snapshot devices for this pool
        for device in /dev/mapper/${poolName}-snap-*; do
          if [ -b "$device" ]; then
            DEVICE_NAME=$(basename "$device")
            echo "Cleaning snapshot: $DEVICE_NAME"

            ${
              if storageCfg.secureDelete.method == "discard" then
                ''
                  # Use blkdiscard for secure deletion on SSDs
                  ${pkgs.util-linux}/bin/blkdiscard "$device" 2>/dev/null || true
                ''
              else
                ''
                  # Zero-fill for non-SSD storage
                  dd if=/dev/zero of="$device" bs=1M status=none 2>/dev/null || true
                ''
            }
          fi
        done

        echo "Secure snapshot cleanup completed"
      '';

      script = "true"; # No-op on start
    };

    # Timer for periodic cleanup of stale snapshots
    systemd.timers.microvm-snapshot-cleanup = lib.mkIf storageCfg.secureDelete.enable {
      description = "Periodic secure snapshot cleanup for microVMs";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "10m";
        OnUnitActiveSec = "30m";
        RandomizedDelaySec = "5m";
      };
    };
  };
}
