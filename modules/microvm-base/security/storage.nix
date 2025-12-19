# Storage security for microVM infrastructure
#
# Implements secure storage handling at the infrastructure level:
# - LUKS encryption for containerd devmapper data-at-rest protection
# - Ephemeral key option for maximum security
# - Tmpfs mount for sensitive runtime data (keys, credentials)
# - Secure deletion configuration for containerd
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

        Encrypts all VM disk data at rest, protecting against:
        - Physical disk theft
        - Residual data exposure after VM deletion
        - Offline attacks on storage media

        Uses an ephemeral key generated at boot (stored in tmpfs, lost on reboot).
        This is ideal for Firecracker VMs since:
        - VMs are ephemeral by design
        - The devmapper thin-pool is recreated on each boot anyway
        - No key management complexity
        - Fresh encryption key on each boot = defense in depth
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
        LUKS_NAME="containerd-data-crypt"
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
        if [ ! -f "$KEY_FILE" ]; then
          mkdir -p "$(dirname "$KEY_FILE")"
          chmod 700 "$(dirname "$KEY_FILE")"
          head -c 32 /dev/urandom > "$KEY_FILE"
          chmod 400 "$KEY_FILE"
          echo "Generated ephemeral encryption key"
        fi

        # Setup loop device for data file
        DATA_LOOP=$(losetup --find --show "$DATA_FILE")

        # Function to format LUKS
        format_luks() {
          echo "Initializing LUKS encryption on data file..."
          cryptsetup luksFormat \
            --batch-mode \
            --type luks2 \
            --cipher aes-xts-plain64 \
            --key-size 512 \
            --hash sha256 \
            --pbkdf argon2id \
            --pbkdf-memory 262144 \
            --pbkdf-parallel 4 \
            "$DATA_LOOP" \
            "$KEY_FILE"
          echo "LUKS encryption initialized"
        }

        # Check if LUKS is already set up on data file
        if cryptsetup isLuks "$DATA_LOOP" 2>/dev/null; then
          echo "LUKS header found, attempting to open with current key..."
          # Try to open with current ephemeral key
          if ! cryptsetup open \
               --type luks2 \
               "$DATA_LOOP" \
               "$LUKS_NAME" \
               --key-file "$KEY_FILE" 2>/dev/null; then
            echo "Failed to open LUKS - key mismatch (stale ephemeral key from previous boot)"
            echo "Wiping and re-creating LUKS container with new ephemeral key..."

            # Clear containerd's state since we're wiping the pool
            # This forces containerd to re-pull images on next start
            echo "Clearing containerd state (snapshots lost due to LUKS wipe)..."
            # Clear devmapper plugin's metadata databases (not the sparse data/metadata files)
            rm -f /var/lib/containerd/devmapper/*.db || true
            # Clear containerd's main metadata (image references, snapshots)
            rm -rf /var/lib/containerd/io.containerd.metadata.v1.bolt || true

            # Also wipe the thin-pool metadata file (it references old data)
            truncate -s 0 "$META_FILE"
            truncate -s 200M "$META_FILE"

            # Detach loop, wipe data file, reattach
            losetup -d "$DATA_LOOP"
            truncate -s 0 "$DATA_FILE"
            truncate -s ${baseCfg.containerd.thinPoolSize} "$DATA_FILE"
            DATA_LOOP=$(losetup --find --show "$DATA_FILE")
            format_luks
            cryptsetup open \
              --type luks2 \
              "$DATA_LOOP" \
              "$LUKS_NAME" \
              --key-file "$KEY_FILE"
          fi
          echo "LUKS container opened"
        else
          # No LUKS header - fresh format
          format_luks
          cryptsetup open \
            --type luks2 \
            "$DATA_LOOP" \
            "$LUKS_NAME" \
            --key-file "$KEY_FILE"
          echo "LUKS container opened"
        fi

        # Setup metadata loop device
        META_LOOP=$(losetup --find --show "$META_FILE")

        # Get sizes in 512-byte sectors
        DATA_SIZE=$(blockdev --getsize "/dev/mapper/$LUKS_NAME")

        # Create thin-pool with LUKS-encrypted data device
        dmsetup create containerd-pool \
          --table "0 $DATA_SIZE thin-pool $META_LOOP /dev/mapper/$LUKS_NAME 128 32768 1 skip_block_zeroing"

        echo "containerd-pool created with LUKS encryption"
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
        ExecStop = pkgs.writeShellScript "devmapper-luks-cleanup" ''
          dmsetup remove containerd-pool || true
          cryptsetup close containerd-data-crypt || true
        '';
      };
    };

    # Configure containerd to use discard
    virtualisation.containerd.settings.plugins."io.containerd.snapshotter.v1.devmapper" =
      lib.mkIf storageCfg.secureDelete.enable
        {
          discard_blocks = true;
        };
  };
}
