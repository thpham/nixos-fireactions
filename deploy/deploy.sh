#!/usr/bin/env bash
# Deploy NixOS with fireactions to any SSH-accessible target
# Works from Darwin or Linux, deploys to x86_64 or aarch64 Linux
#
# Usage:
#   Initial deploy:  ./deploy.sh [OPTIONS] <ip>
#   List hosts:      ./deploy.sh list
#   Unregister:      ./deploy.sh unregister <name>
#
# Options:
#   --provider TYPE   Provider type (default: baremetal)
#                     do|digitalocean - DigitalOcean droplet (/dev/vda, cloud-init)
#                     hetzner         - Hetzner Cloud (/dev/sda)
#                     generic         - Generic VM (/dev/vda)
#                     nvme            - NVMe-based systems (/dev/nvme0n1)
#                     baremetal       - Bare metal (/dev/sda)
#                     auto            - Auto-detect hardware
#   --name NAME       Host name (default: auto-generated from provider+IP)
#   --tags TAG1,TAG2  Comma-separated tags for profile selection
#   --arch ARCH       Architecture: x86_64 (default) or aarch64
#   --user USER       SSH user (default: root, use 'nixos' for live ISO)
#   --env-password    Use password from SSHPASS environment variable
#   --no-kexec        Skip kexec phase (use when booted from NixOS live ISO)
#
# Examples:
#   ./deploy.sh --provider do --name do-runner-1 --tags prod,runners 167.71.100.50
#   ./deploy.sh --provider hetzner --name hetzner-dev-1 --tags dev 95.217.xxx.xxx
#   ./deploy.sh --provider generic --name my-vm 192.168.1.100
#   ./deploy.sh --provider nvme --name nvme-server 192.168.1.100
#   ./deploy.sh --provider generic --arch aarch64 --name arm-runner 192.168.1.100
#   ./deploy.sh list
#   ./deploy.sh unregister do-runner-1
#
# Prerequisites:
# 1. Target must be accessible via SSH (rescue mode, live ISO, etc.)
# 2. Ensure SSH access to root@<target-ip> works
# 3. Have nix with flakes enabled on your local machine
# 4. For DigitalOcean: Use 2GB+ droplet (1GB lacks RAM for kexec)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLAKE_DIR="$(dirname "$SCRIPT_DIR")"
REGISTRY_FILE="${FLAKE_DIR}/hosts/registry.json"

# Ensure registry file exists
if [[ ! -f "$REGISTRY_FILE" ]]; then
    echo "{}" > "$REGISTRY_FILE"
fi

# --- Subcommands ---

cmd_list() {
    echo "=== Registered Hosts ==="
    if command -v jq &> /dev/null; then
        echo "NAME                 HOSTNAME             PROVIDER      TAGS"
        echo "-------------------  -------------------  ------------  ----------"
        jq -r 'to_entries[] | "\(.key)\t\(.value.hostname)\t\(.value.provider)\t\(.value.tags | join(","))"' "$REGISTRY_FILE" | \
            column -t -s $'\t'
    else
        cat "$REGISTRY_FILE"
    fi
}

cmd_unregister() {
    local name="${1:?Usage: $0 unregister <name>}"

    if ! jq -e ".\"$name\"" "$REGISTRY_FILE" > /dev/null 2>&1; then
        echo "ERROR: Host '$name' not found in registry"
        exit 1
    fi

    echo "Removing '$name' from registry..."
    jq "del(.\"$name\")" "$REGISTRY_FILE" > "${REGISTRY_FILE}.tmp"
    mv "${REGISTRY_FILE}.tmp" "$REGISTRY_FILE"
    echo "Done. Host '$name' unregistered."
}

register_host() {
    local name="$1"
    local hostname="$2"
    local provider="$3"
    local system="$4"
    local tags="$5"

    echo "Registering host '$name' in registry..."

    jq --arg name "$name" \
       --arg hostname "$hostname" \
       --arg provider "$provider" \
       --arg system "$system" \
       --arg tags "$tags" \
       --arg date "$(date -Iseconds)" \
       '.[$name] = {
           hostname: $hostname,
           provider: $provider,
           system: $system,
           deployed: $date,
           tags: (if $tags == "" then [] else ($tags | split(",")) end)
       }' "$REGISTRY_FILE" > "${REGISTRY_FILE}.tmp"
    mv "${REGISTRY_FILE}.tmp" "$REGISTRY_FILE"

    echo "Host '$name' registered successfully."
}

# --- Main ---

# Handle subcommands
case "${1:-}" in
    list)
        cmd_list
        exit 0
        ;;
    unregister)
        shift
        cmd_unregister "$@"
        exit 0
        ;;
esac

# Parse arguments for deploy
TARGET_HOST=""
PROVIDER="baremetal"
ARCH="x86_64"
HOST_NAME=""
TAGS=""
GENERATE_HW_CONFIG=""
NO_KEXEC=""
SSH_USER="root"
ENV_PASSWORD=""
POSITIONAL_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --provider|-p)
            PROVIDER="$2"
            shift 2
            ;;
        --name|-n)
            HOST_NAME="$2"
            shift 2
            ;;
        --tags|-t)
            TAGS="$2"
            shift 2
            ;;
        --arch|-a)
            ARCH="$2"
            shift 2
            ;;
        --user|-u)
            SSH_USER="$2"
            shift 2
            ;;
        --env-password)
            ENV_PASSWORD="--env-password"
            shift
            ;;
        --no-kexec)
            # Skip kexec phase - use disko,install,reboot instead
            NO_KEXEC="--phases disko,install,reboot"
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS] <ip>"
            echo "       $0 list"
            echo "       $0 unregister <name>"
            echo ""
            echo "Options:"
            echo "  --provider, -p TYPE   Provider: do, hetzner, generic, nvme, baremetal (default), auto"
            echo "  --name, -n NAME       Host name (default: auto-generated)"
            echo "  --tags, -t TAG1,TAG2  Comma-separated tags for profile selection"
            echo "  --arch, -a ARCH       Architecture: x86_64 (default) or aarch64"
            echo "  --user, -u USER       SSH user (default: root, use 'nixos' for live ISO)"
            echo "  --env-password        Use password from SSHPASS environment variable"
            echo "  --no-kexec            Skip kexec phase (manually, usually auto-detected)"
            exit 0
            ;;
        -*)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
        *)
            POSITIONAL_ARGS+=("$1")
            shift
            ;;
    esac
done

# IP should be the last (and only) positional argument
if [[ ${#POSITIONAL_ARGS[@]} -eq 0 ]]; then
    echo "Usage: $0 [OPTIONS] <ip>"
    echo "       $0 list"
    echo "       $0 unregister <name>"
    echo ""
    echo "Use --help for more information"
    exit 1
fi

TARGET_HOST="${POSITIONAL_ARGS[-1]}"

# Auto-generate name if not provided
if [[ -z "$HOST_NAME" ]]; then
    # Generate name from provider and IP last octet
    IP_SUFFIX="${TARGET_HOST##*.}"
    HOST_NAME="${PROVIDER}-${IP_SUFFIX}"
    echo "Auto-generated host name: $HOST_NAME"
fi

# Determine flake target based on architecture and provider
if [[ "$ARCH" == "aarch64" ]]; then
    case "$PROVIDER" in
        do|digitalocean)
            echo "ERROR: DigitalOcean does not support aarch64"
            exit 1
            ;;
        auto)
            FLAKE_TARGET="fireactions-node-arm"
            GENERATE_HW_CONFIG="--generate-hardware-config nixos-generate-config ./hardware-configuration.nix"
            ;;
        generic|vda)
            FLAKE_TARGET="fireactions-node-arm-vda"
            ;;
        nvme)
            FLAKE_TARGET="fireactions-node-arm-nvme"
            ;;
        *)
            FLAKE_TARGET="fireactions-node-arm"
            ;;
    esac
    SYSTEM="aarch64-linux"
else
    case "$PROVIDER" in
        do|digitalocean)
            FLAKE_TARGET="fireactions-node-do"
            ;;
        auto)
            FLAKE_TARGET="fireactions-node"
            GENERATE_HW_CONFIG="--generate-hardware-config nixos-generate-config ./hardware-configuration.nix"
            ;;
        generic|vda)
            FLAKE_TARGET="fireactions-node-vda"
            ;;
        nvme)
            FLAKE_TARGET="fireactions-node-nvme"
            ;;
        hetzner|baremetal|*)
            FLAKE_TARGET="fireactions-node"
            ;;
    esac
    SYSTEM="x86_64-linux"
fi

echo "=== Fireactions NixOS Deployment ==="
echo "Target host:  $TARGET_HOST"
echo "SSH user:     $SSH_USER"
echo "Host name:    $HOST_NAME"
echo "Provider:     $PROVIDER"
echo "Architecture: $ARCH"
echo "Flake target: $FLAKE_TARGET"
echo "Tags:         ${TAGS:-<none>}"
if [[ -n "$GENERATE_HW_CONFIG" ]]; then
    echo "Hardware:     Auto-detect (generates hardware-configuration.nix)"
fi
echo ""

# Check if host already registered
if jq -e ".\"$HOST_NAME\"" "$REGISTRY_FILE" > /dev/null 2>&1; then
    echo "WARNING: Host '$HOST_NAME' already exists in registry"
    read -p "Overwrite? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 1
    fi
fi

# Verify SSH connectivity
echo "Verifying SSH connectivity..."
if [[ -n "$ENV_PASSWORD" ]]; then
    if [[ -z "$SSHPASS" ]]; then
        echo "ERROR: --env-password requires SSHPASS environment variable"
        echo "Usage: SSHPASS='your-password' $0 --env-password ..."
        exit 1
    fi
    if ! command -v sshpass &> /dev/null; then
        echo "ERROR: sshpass command not found (required for --env-password)"
        echo "Install with: nix-shell -p sshpass"
        exit 1
    fi
    if ! sshpass -e ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "${SSH_USER}@$TARGET_HOST" exit 2>/dev/null; then
        echo "ERROR: Cannot connect to ${SSH_USER}@$TARGET_HOST with password"
        exit 1
    fi
else
    if ! ssh -o ConnectTimeout=10 -o BatchMode=yes "${SSH_USER}@$TARGET_HOST" exit 2>/dev/null; then
        echo "ERROR: Cannot connect to ${SSH_USER}@$TARGET_HOST"
        echo "Make sure the target is accessible via SSH."
        echo "For NixOS live ISO with password, use: SSHPASS='password' $0 --user nixos --env-password ..."
        exit 1
    fi
fi

echo "SSH connection verified."
echo ""
echo "WARNING: This will ERASE all data on the target disk"
read -p "Continue? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
fi

echo ""
echo "=== Starting nixos-anywhere deployment ==="
echo ""

# Run nixos-anywhere
# shellcheck disable=SC2086
if nix run github:nix-community/nixos-anywhere -- \
    --flake "${FLAKE_DIR}#${FLAKE_TARGET}" \
    --target-host "${SSH_USER}@$TARGET_HOST" \
    --build-on remote \
    --option accept-flake-config true \
    $ENV_PASSWORD \
    $NO_KEXEC \
    $GENERATE_HW_CONFIG \
    --debug; then

    echo ""
    echo "=== Deployment successful ==="
    echo ""

    # Register the host
    register_host "$HOST_NAME" "$TARGET_HOST" "$PROVIDER" "$SYSTEM" "$TAGS"

    echo ""
    echo "=== Next steps ==="
    echo ""
    echo "1. Wait for reboot (~2-3 minutes)"
    echo "2. SSH to root@$TARGET_HOST"
    echo "3. For future updates, use colmena:"
    echo "   colmena apply --on $HOST_NAME --build-on-target"
    echo ""
    echo "4. To customize this host, create: hosts/${HOST_NAME}.nix"
    echo "5. To update all hosts: colmena apply --build-on-target"
else
    echo ""
    echo "=== Deployment FAILED ==="
    echo "Host was NOT registered in the registry."
    exit 1
fi
