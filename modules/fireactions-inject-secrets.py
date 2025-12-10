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

# Inject registry-cache cloud-init metadata into all pools
registry_cache_enabled = os.environ.get("REGISTRY_CACHE_ENABLED", "false") == "true"
if registry_cache_enabled and "pools" in config:
    ca_file = os.environ.get("REGISTRY_CACHE_CA_FILE", "")
    gateway = os.environ.get("REGISTRY_CACHE_GATEWAY", "")

    if ca_file and gateway:
        # Read CA certificate and indent it for YAML block scalar
        with open(ca_file, "r") as f:
            ca_cert_raw = f.read().rstrip('\n')
        # Indent each line by 6 spaces (content under "- |" block scalar)
        ca_cert_indented = '\n'.join('      ' + line for line in ca_cert_raw.split('\n'))

        # Generate cloud-init user-data
        user_data = f"""#cloud-config
# Registry cache configuration - auto-injected by fireactions
# CA certificate for HTTPS MITM proxy
ca_certs:
  trusted:
    - |
{ca_cert_indented}
# DNS resolver pointing to host (for registry interception)
manage_resolv_conf: true
resolv_conf:
  nameservers:
    - {gateway}
  searchdomains: []
  options:
    ndots: 1
"""

        # Inject into all pools
        for pool in config["pools"]:
            if "firecracker" not in pool:
                pool["firecracker"] = {}
            if "metadata" not in pool["firecracker"]:
                pool["firecracker"]["metadata"] = {}

            # Only set if not already configured (allow override)
            if "user-data" not in pool["firecracker"]["metadata"]:
                pool["firecracker"]["metadata"]["user-data"] = user_data
                print(f"Injected registry-cache metadata into pool: {pool.get('name', 'unknown')}")

# Write the final config
with open("/run/fireactions/config.yaml", "w") as f:
    yaml.dump(config, f, default_flow_style=False, allow_unicode=True, sort_keys=False)

print("Config with secrets written to /run/fireactions/config.yaml")
