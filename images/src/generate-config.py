#!/usr/bin/env python3
"""
Fireactions Configuration Generator for Cloud Images (Azure, etc.)

Generates complete fireactions config from cloud-init user-data.
Includes registry-cache metadata injection (ported from inject-secrets.py).

Environment variables:
  GITHUB_APP_ID - GitHub App ID
  GITHUB_PRIVATE_KEY - GitHub App private key (PEM)
  POOLS - JSON array of pool configurations
  BIND_ADDRESS - Server bind address (default: 0.0.0.0:8080)
  LOG_LEVEL - Log level (default: info)

Registry cache (optional, from Nix):
  REGISTRY_CACHE_ENABLED - "true" to enable registry cache metadata
  REGISTRY_CACHE_GATEWAY - Gateway IP (e.g., 10.200.0.1)
  ZOT_PORT - Zot registry port (default: 5000)
  ZOT_MIRRORS - JSON of registry mirrors
"""

import json
import os
import sys

import yaml


# Custom representer for multi-line strings (block scalar style)
def str_representer(dumper, data):
    if "\n" in data:
        return dumper.represent_scalar("tag:yaml.org,2002:str", data, style="|")
    return dumper.represent_scalar("tag:yaml.org,2002:str", data)


yaml.add_representer(str, str_representer)


def transform_pool(pool: dict) -> dict:
    """Transform user-friendly pool config to fireactions format."""
    runner = pool.get("runner", {})
    firecracker = pool.get("firecracker", {})

    pool_config = {
        "name": pool.get("name", "default"),
        "max_runners": pool.get("maxRunners", 10),
        "min_runners": pool.get("minRunners", 1),
        "runner": {
            "name": runner.get("name", "runner"),
            "image": runner.get(
                "image", "ghcr.io/thpham/fireactions-images/ubuntu-24.04:latest"
            ),
            "image_pull_policy": runner.get("imagePullPolicy", "IfNotPresent"),
            "organization": runner.get("organization"),
            "labels": runner.get("labels", ["self-hosted", "fireactions"]),
        },
        "firecracker": {
            "binary_path": "firecracker",
            "kernel_image_path": "/var/lib/fireactions/kernels/vmlinux",
            "kernel_args": firecracker.get(
                "kernelArgs", "console=ttyS0 reboot=k panic=1 pci=off"
            ),
            "cni_conf_dir": "/etc/cni/conf.d",
            "cni_bin_dirs": ["/opt/cni/bin"],
            "machine_config": {
                "mem_size_mib": firecracker.get("memSizeMib", 2048),
                "vcpu_count": firecracker.get("vcpuCount", 2),
            },
        },
    }

    # Optional: runner group ID
    if runner.get("groupId"):
        pool_config["runner"]["group_id"] = runner["groupId"]

    return pool_config


def generate_registry_cache_userdata(gateway: str, zot_port: str, zot_mirrors: dict) -> str:
    """Generate cloud-init user-data for registry cache (containerd hosts.toml, etc.)."""
    user_data_lines = [
        "#cloud-config",
        "# Registry cache configuration - auto-injected by fireactions",
        "",
        "# Containerd registry mirror configuration for Zot pull-through cache",
        "write_files:",
    ]

    # Default upstream URLs for well-known registries
    default_upstreams = {
        "docker.io": "https://registry-1.docker.io",
        "ghcr.io": "https://ghcr.io",
        "quay.io": "https://quay.io",
        "gcr.io": "https://gcr.io",
    }

    for registry_name, mirror_config in zot_mirrors.items():
        # Get the upstream URL from mirror config or use default
        if isinstance(mirror_config, dict):
            upstream_url = mirror_config.get(
                "url", default_upstreams.get(registry_name, f"https://{registry_name}")
            )
        else:
            upstream_url = default_upstreams.get(registry_name, f"https://{registry_name}")

        # Generate hosts.toml content
        if registry_name == "docker.io":
            # Docker Hub: images at root, no path override needed
            hosts_toml = f'''server = "{upstream_url}"

[host."http://{gateway}:{zot_port}"]
  capabilities = ["pull", "resolve"]
  skip_verify = true'''
        else:
            # Other registries: images under /{registry_name}/, use override_path
            hosts_toml = f'''server = "{upstream_url}"

[host."http://{gateway}:{zot_port}"]
  capabilities = ["pull", "resolve"]
  skip_verify = true

[host."http://{gateway}:{zot_port}/v2/{registry_name}"]
  capabilities = ["pull", "resolve"]
  override_path = true'''

        user_data_lines.extend([
            f"  - path: /etc/containerd/certs.d/{registry_name}/hosts.toml",
            "    content: |",
        ])
        for line in hosts_toml.split("\n"):
            user_data_lines.append(f"      {line}")

    # BuildKit config for Buildx
    buildkit_config_lines = []
    for registry_name in zot_mirrors.keys():
        buildkit_config_lines.extend([
            f'[registry."{registry_name}"]',
            f'  mirrors = ["{gateway}:{zot_port}"]',
            f"  http = true",
            f"  insecure = true",
            "",
        ])

    buildkit_config = "\n".join(buildkit_config_lines)

    user_data_lines.extend([
        f"  - path: /etc/buildkit/buildkitd.toml",
        "    content: |",
        "      # BuildKit registry mirrors for docker/setup-buildx-action",
    ])
    for line in buildkit_config.split("\n"):
        user_data_lines.append(f"      {line}")

    # Docker daemon.json
    docker_daemon_config = {
        "registry-mirrors": [f"http://{gateway}:{zot_port}"],
        "insecure-registries": [f"{gateway}:{zot_port}"],
    }
    docker_daemon_json = json.dumps(docker_daemon_config, indent=2)

    user_data_lines.extend([
        f"  - path: /etc/docker/daemon.json",
        "    content: |",
    ])
    for line in docker_daemon_json.split("\n"):
        user_data_lines.append(f"      {line}")

    # Runcmd section
    user_data_lines.extend([
        "",
        "runcmd:",
        "  # Ensure containerd picks up the new registry mirrors",
        "  - mkdir -p /etc/containerd/certs.d",
        "  - mkdir -p /etc/buildkit",
        "  - systemctl restart containerd || true",
        "  - systemctl restart docker || true",
        "  # Create pre-configured Buildx builder",
        "  - |",
        "    if command -v docker &> /dev/null && [ -f /etc/buildkit/buildkitd.toml ]; then",
        "      docker buildx create --name zot-cache --driver docker-container \\",
        "        --config /etc/buildkit/buildkitd.toml --use 2>/dev/null || true",
        "    fi",
        f"  # Set DNS to use host gateway",
        f"  - echo 'nameserver {gateway}' > /etc/resolv.conf",
        "  # Set hostname from MMDS metadata",
        "  - |",
        "    RUNNER_ID=$(curl -sf http://169.254.169.254/latest/meta-data/fireactions/runner_id)",
        '    if [ -n "$RUNNER_ID" ]; then',
        '      hostnamectl set-hostname "$RUNNER_ID"',
        "    fi",
    ])

    return "\n".join(user_data_lines) + "\n"


def main():
    # Read from environment
    github_app_id = os.environ.get("GITHUB_APP_ID")
    github_private_key = os.environ.get("GITHUB_PRIVATE_KEY")
    pools_json = os.environ.get("POOLS")
    bind_address = os.environ.get("BIND_ADDRESS", "0.0.0.0:8080")
    log_level = os.environ.get("LOG_LEVEL", "info")

    if not github_app_id:
        print("ERROR: GITHUB_APP_ID not set", file=sys.stderr)
        sys.exit(1)

    if not github_private_key:
        print("ERROR: GITHUB_PRIVATE_KEY not set", file=sys.stderr)
        sys.exit(1)

    if not pools_json:
        print("ERROR: POOLS not set", file=sys.stderr)
        sys.exit(1)

    # Parse pools JSON
    try:
        pools = json.loads(pools_json)
    except json.JSONDecodeError as e:
        print(f"ERROR: Invalid POOLS JSON: {e}", file=sys.stderr)
        sys.exit(1)

    # Transform pools
    transformed_pools = [transform_pool(pool) for pool in pools]

    # Check for registry cache configuration
    registry_cache_enabled = os.environ.get("REGISTRY_CACHE_ENABLED", "false") == "true"
    gateway = os.environ.get("REGISTRY_CACHE_GATEWAY", "")
    zot_port = os.environ.get("ZOT_PORT", "5000")
    zot_mirrors_json = os.environ.get("ZOT_MIRRORS", "{}")

    # Inject registry cache metadata into pools
    if registry_cache_enabled and gateway:
        try:
            zot_mirrors = json.loads(zot_mirrors_json) if zot_mirrors_json else {}
        except json.JSONDecodeError:
            zot_mirrors = {
                "docker.io": {"url": "https://registry-1.docker.io"},
                "ghcr.io": {"url": "https://ghcr.io"},
                "quay.io": {"url": "https://quay.io"},
                "gcr.io": {"url": "https://gcr.io"},
            }

        if zot_mirrors:
            user_data = generate_registry_cache_userdata(gateway, zot_port, zot_mirrors)

            for pool in transformed_pools:
                pool_name = pool.get("name", "default")

                # Ensure firecracker.metadata exists
                if "metadata" not in pool["firecracker"]:
                    pool["firecracker"]["metadata"] = {}

                # Add instance-id for cloud-init
                if "instance-id" not in pool["firecracker"]["metadata"]:
                    pool["firecracker"]["metadata"]["instance-id"] = f"i-fireactions-{pool_name}"

                # Inject user-data with registry cache config
                if "user-data" not in pool["firecracker"]["metadata"]:
                    pool["firecracker"]["metadata"]["user-data"] = user_data

            print(f"Injected registry-cache metadata for {len(zot_mirrors)} registries")

    # Build config
    config = {
        "bind_address": bind_address,
        "log_level": log_level,
        "debug": False,
        "metrics": {"enabled": True, "address": "0.0.0.0:8081"},
        "github": {"app_id": int(github_app_id), "app_private_key": github_private_key},
        "pools": transformed_pools,
    }

    # Write config
    output_path = "/run/fireactions/config.yaml"
    with open(output_path, "w") as f:
        yaml.dump(config, f, default_flow_style=False, allow_unicode=True, sort_keys=False)

    print(f"Configuration written to {output_path}")


if __name__ == "__main__":
    main()
