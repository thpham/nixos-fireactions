#!/usr/bin/env python3
"""
Inject secrets into fireteact config.
This script is called by fireteact-config.service at runtime.

Handles:
- Gitea API token injection (for dynamic runner registration)
- Gitea instance URL injection (from sops secret)
- Runner owner/repo injection (from sops secrets)
- Debug SSH key injection into pool metadata (cloud-init user-data)
"""
import yaml
import os


def read_secret_file(env_var):
    """Read a secret from a file path specified in an environment variable."""
    file_path = os.environ.get(env_var, "")
    if file_path and os.path.exists(file_path):
        with open(file_path, "r") as f:
            return f.read().strip()
    return None


# Custom representer for multi-line strings (block scalar style)
def str_representer(dumper, data):
    if "\n" in data:
        return dumper.represent_scalar("tag:yaml.org,2002:str", data, style="|")
    return dumper.represent_scalar("tag:yaml.org,2002:str", data)


yaml.add_representer(str, str_representer)

# Read the base config
with open("/etc/fireteact/config.yaml", "r") as f:
    config = yaml.safe_load(f)

# Inject Gitea secrets from files
if "gitea" in config:
    # API token
    api_token = read_secret_file("API_TOKEN_FILE")
    if api_token:
        config["gitea"]["apiToken"] = api_token

    # Instance URL (file takes precedence)
    instance_url = read_secret_file("INSTANCE_URL_FILE")
    if instance_url:
        config["gitea"]["instanceURL"] = instance_url

    # Runner owner (file takes precedence)
    runner_owner = read_secret_file("RUNNER_OWNER_FILE")
    if runner_owner:
        config["gitea"]["runnerOwner"] = runner_owner

    # Runner repo (file takes precedence)
    runner_repo = read_secret_file("RUNNER_REPO_FILE")
    if runner_repo:
        config["gitea"]["runnerRepo"] = runner_repo

# Build cloud-init user-data for pools (like fireactions does)
# This injects the debug SSH key and other cloud-init config into pool metadata
if "pools" in config:
    # Initialize metadata for all pools
    for pool in config["pools"]:
        if "firecracker" not in pool:
            pool["firecracker"] = {}
        if "metadata" not in pool["firecracker"]:
            pool["firecracker"]["metadata"] = {}

        pool_name = pool.get("name", "default")

        # Add EC2-compatible instance-id if not already set
        # cloud-init EC2 datasource requires this
        if "instance-id" not in pool["firecracker"]["metadata"]:
            pool["firecracker"]["metadata"]["instance-id"] = f"i-fireteact-{pool_name}"

    # Build cloud-init user-data
    user_data_lines = [
        "#cloud-config",
        "# Fireteact VM configuration - auto-injected by inject-secrets.py",
        "",
    ]

    # === DEBUG SSH KEY ===
    debug_ssh_key = read_secret_file("DEBUG_SSH_KEY_FILE")
    if debug_ssh_key:
        user_data_lines.extend([
            "# SSH access for debugging",
            "users:",
            "  - name: root",
            "    ssh_authorized_keys:",
            f"      - {debug_ssh_key}",
            "",
        ])
        print(f"Debug SSH key configured for VMs")

    # === RUNCMD SECTION ===
    user_data_lines.extend([
        "# Runtime configuration via runcmd",
        "runcmd:",
        "  # Fix DNS resolution - systemd-resolved is running but resolv.conf may be empty",
        "  # Link to stub-resolv.conf which points to the local resolver at 127.0.0.53",
        "  - ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf",
        "  # Set hostname from MMDS metadata",
        "  - |",
        "    RUNNER_ID=$(curl -sf http://169.254.169.254/latest/meta-data/fireteact/runner_id)",
        '    if [ -n "$RUNNER_ID" ]; then',
        '      hostnamectl set-hostname "$RUNNER_ID"',
        "    fi",
    ])

    user_data = '\n'.join(user_data_lines) + '\n'

    # Inject user-data into all pools
    for pool in config["pools"]:
        # Only set if not already configured (allow override)
        if "user-data" not in pool["firecracker"]["metadata"]:
            pool["firecracker"]["metadata"]["user-data"] = user_data
            print(f"Injected cloud-init user-data into pool: {pool.get('name', 'unknown')}")

# Write the modified config
os.makedirs("/run/fireteact", exist_ok=True)
with open("/run/fireteact/config.yaml", "w") as f:
    yaml.dump(config, f, default_flow_style=False, sort_keys=False)

print("fireteact config generated at /run/fireteact/config.yaml")
