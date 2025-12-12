#!/usr/bin/env python3
"""
Inject secrets and registry-cache metadata into fireactions config.
This script is called by fireactions-config.service at runtime.
"""
import yaml
import os

# Custom representer for multi-line strings (block scalar style)
def str_representer(dumper, data):
    if "\n" in data:
        return dumper.represent_scalar("tag:yaml.org,2002:str", data, style="|")
    return dumper.represent_scalar("tag:yaml.org,2002:str", data)

yaml.add_representer(str, str_representer)

# Read the base config
with open("/etc/fireactions/config.yaml", "r") as f:
    config = yaml.safe_load(f)

# Inject GitHub secrets from files
if "github" in config:
    app_id_file = os.environ.get("APP_ID_FILE", "")
    if app_id_file:
        with open(app_id_file, "r") as f:
            config["github"]["app_id"] = int(f.read().strip())

    private_key_file = os.environ.get("PRIVATE_KEY_FILE", "")
    if private_key_file:
        with open(private_key_file, "r") as f:
            config["github"]["app_private_key"] = f.read()

# Inject metadata into all pools
if "pools" in config:
    # Add EC2-compatible metadata fields for cloud-init datasource validation
    # instance-id is required for cloud-init EC2 datasource to recognize MMDS
    # Note: hostname is set dynamically via runcmd from fireactions.runner_id
    for pool in config["pools"]:
        if "firecracker" not in pool:
            pool["firecracker"] = {}
        if "metadata" not in pool["firecracker"]:
            pool["firecracker"]["metadata"] = {}

        pool_name = pool.get("name", "default")
        if "instance-id" not in pool["firecracker"]["metadata"]:
            pool["firecracker"]["metadata"]["instance-id"] = f"i-fireactions-{pool_name}"

# Inject registry-cache cloud-init user-data into all pools
registry_cache_enabled = os.environ.get("REGISTRY_CACHE_ENABLED", "false") == "true"
if registry_cache_enabled and "pools" in config:
    ca_file = os.environ.get("REGISTRY_CACHE_CA_FILE", "")
    gateway = os.environ.get("REGISTRY_CACHE_GATEWAY", "")

    if ca_file and gateway:
        # Read CA certificate
        with open(ca_file, "r") as f:
            ca_cert_raw = f.read().rstrip('\n')

        # Generate cloud-init user-data using write_files + runcmd
        # This approach is more reliable than ca_certs module:
        # 1. write_files runs in init stage - cert file written early
        # 2. runcmd runs in config stage - update-ca-certificates runs after file exists
        user_data_lines = [
            "#cloud-config",
            "# Registry cache configuration - auto-injected by fireactions",
            "",
            "# Write CA certificate to system trust store location",
            "write_files:",
            "  - path: /usr/local/share/ca-certificates/fireactions-registry-cache.crt",
            "    owner: root:root",
            "    permissions: '0644'",
            "    content: |",
        ]
        # Add certificate lines with 6-space indent (under the content block scalar)
        for line in ca_cert_raw.split('\n'):
            user_data_lines.append(f"      {line}")
        # Add runcmd section for CA update, DNS, and hostname configuration
        user_data_lines.extend([
            "",
            "# Runtime configuration via runcmd",
            "runcmd:",
            "  - update-ca-certificates",
            f"  - echo 'nameserver {gateway}' > /etc/resolv.conf",
            "  - |",
            "    RUNNER_ID=$(curl -sf http://169.254.169.254/latest/meta-data/fireactions/runner_id)",
            '    if [ -n "$RUNNER_ID" ]; then',
            '      hostnamectl set-hostname "$RUNNER_ID"',
            "    fi",
        ])
        user_data = '\n'.join(user_data_lines) + '\n'

        # Inject user-data into all pools (firecracker/metadata already initialized above)
        for pool in config["pools"]:
            # Only set if not already configured (allow override)
            if "user-data" not in pool["firecracker"]["metadata"]:
                pool["firecracker"]["metadata"]["user-data"] = user_data
                print(f"Injected registry-cache metadata into pool: {pool.get('name', 'unknown')}")

# Write the final config
with open("/run/fireactions/config.yaml", "w") as f:
    yaml.dump(config, f, default_flow_style=False, allow_unicode=True, sort_keys=False)

print("Config with secrets written to /run/fireactions/config.yaml")
