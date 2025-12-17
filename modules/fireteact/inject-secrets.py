#!/usr/bin/env python3
"""
Inject secrets into fireteact config.
This script is called by fireteact-config.service at runtime.

Handles:
- Gitea API token injection (for dynamic runner registration)
- Gitea instance URL injection (from sops secret)
- Runner owner/repo injection (from sops secrets)
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

# Write the modified config
os.makedirs("/run/fireteact", exist_ok=True)
with open("/run/fireteact/config.yaml", "w") as f:
    yaml.dump(config, f, default_flow_style=False, sort_keys=False)

print("fireteact config generated at /run/fireteact/config.yaml")
