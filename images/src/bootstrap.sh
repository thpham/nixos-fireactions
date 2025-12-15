#!/usr/bin/env bash
# Fireactions Bootstrap Script
#
# Reads configuration from cloud-init written files and generates
# the runtime fireactions config. Called by cloud-init runcmd.
#
# Required files (from cloud-init user-data):
#   /etc/fireactions/github-app-id
#   /etc/fireactions/github-private-key.pem
#   /etc/fireactions/pools.json
#
# Optional files:
#   /etc/fireactions/bind-address (default: 0.0.0.0:8080)
#   /etc/fireactions/log-level (default: info)
#
# Environment variables (set by Nix):
#   KERNEL_PATH - path to firecracker kernel
#   PYTHON_WITH_YAML - path to python with pyyaml

set -euo pipefail

echo "=== Fireactions Bootstrap ==="

CONFIG_DIR="/etc/fireactions"
RUNTIME_CONFIG="/run/fireactions/config.yaml"

# Check required files (written by cloud-init from user-data)
if [ ! -f "$CONFIG_DIR/github-app-id" ]; then
	echo "ERROR: Missing $CONFIG_DIR/github-app-id"
	echo "Ensure cloud-init user-data includes this file"
	exit 1
fi

if [ ! -f "$CONFIG_DIR/github-private-key.pem" ]; then
	echo "ERROR: Missing $CONFIG_DIR/github-private-key.pem"
	exit 1
fi

if [ ! -f "$CONFIG_DIR/pools.json" ]; then
	echo "ERROR: Missing $CONFIG_DIR/pools.json"
	exit 1
fi

# Read configuration
GITHUB_APP_ID=$(cat "$CONFIG_DIR/github-app-id")
GITHUB_PRIVATE_KEY=$(cat "$CONFIG_DIR/github-private-key.pem")
POOLS=$(cat "$CONFIG_DIR/pools.json")

# Optional settings with defaults
BIND_ADDRESS=$(cat "$CONFIG_DIR/bind-address" 2>/dev/null || echo "0.0.0.0:8080")
LOG_LEVEL=$(cat "$CONFIG_DIR/log-level" 2>/dev/null || echo "info")

# Kernel path (set by Nix wrapper or default)
KERNEL_PATH="${KERNEL_PATH:-/var/lib/fireactions/kernels/vmlinux}"

# Create runtime directory
mkdir -p /run/fireactions

# Link kernel (the module expects it here)
mkdir -p /var/lib/fireactions/kernels
if [ -n "${KERNEL_PATH:-}" ] && [ -f "$KERNEL_PATH" ]; then
	ln -sf "$KERNEL_PATH" /var/lib/fireactions/kernels/vmlinux
fi

# Export for Python script
export GITHUB_APP_ID GITHUB_PRIVATE_KEY POOLS BIND_ADDRESS LOG_LEVEL

# Generate config using Python
"${PYTHON_WITH_YAML:-python3}" /etc/fireactions/generate-config.py

# Set permissions
chmod 0640 /run/fireactions/config.yaml

# Restart fireactions to pick up new config
echo "Restarting fireactions service..."
systemctl restart fireactions

echo "=== Fireactions Bootstrap Complete ==="
systemctl status fireactions --no-pager || true
