#!/usr/bin/env python3
"""
Inject secrets into fireteact config.
This script is called by fireteact-config.service at runtime.

Handles:
- Gitea API token injection (for dynamic runner registration)
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
with open("/etc/fireteact/config.yaml", "r") as f:
    config = yaml.safe_load(f)

# Inject Gitea API token from file
if "gitea" in config:
    token_file = os.environ.get("API_TOKEN_FILE", "")
    if token_file:
        with open(token_file, "r") as f:
            config["gitea"]["apiToken"] = f.read().strip()

# Write the modified config
os.makedirs("/run/fireteact", exist_ok=True)
with open("/run/fireteact/config.yaml", "w") as f:
    yaml.dump(config, f, default_flow_style=False, sort_keys=False)

print("fireteact config generated at /run/fireteact/config.yaml")
