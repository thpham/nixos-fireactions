#!/usr/bin/env python3
"""
Inject secrets and registry-cache metadata into fireglab config.
This script is called by fireglab-config.service at runtime.

Handles:
- GitLab access token injection (for dynamic runner creation via API)
- GitLab instance URL injection (from sops secret)
- Group ID / Project ID injection (from sops secrets)
- Registry cache configuration (containerd hosts.toml, Docker mirrors)
- Squid SSL bump CA certificate (only when needed)
- Debug SSH key injection
"""
import yaml
import os
import json


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
with open("/etc/fireglab/config.yaml", "r") as f:
    config = yaml.safe_load(f)

# Inject GitLab secrets from files
if "gitlab" in config:
    # Access token
    access_token = read_secret_file("ACCESS_TOKEN_FILE")
    if access_token:
        config["gitlab"]["accessToken"] = access_token

    # Instance URL (file takes precedence)
    instance_url = read_secret_file("INSTANCE_URL_FILE")
    if instance_url:
        config["gitlab"]["instanceURL"] = instance_url

    # Group ID (file takes precedence)
    group_id = read_secret_file("GROUP_ID_FILE")
    if group_id:
        try:
            config["gitlab"]["groupId"] = int(group_id)
        except ValueError:
            print(f"Warning: Invalid group ID (not an integer): {group_id}")

    # Project ID (file takes precedence)
    project_id = read_secret_file("PROJECT_ID_FILE")
    if project_id:
        try:
            config["gitlab"]["projectId"] = int(project_id)
        except ValueError:
            print(f"Warning: Invalid project ID (not an integer): {project_id}")

# Build cloud-init user-data for pools
# This injects registry cache config, debug SSH key, and other cloud-init config
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
            pool["firecracker"]["metadata"]["instance-id"] = f"i-fireglab-{pool_name}"

    # Get gateway addresses
    # FIREGLAB_GATEWAY is the fireglab subnet gateway (10.202.0.1) for DNS
    # REGISTRY_CACHE_GATEWAY is the fireactions gateway (10.200.0.1) where Zot runs
    fireglab_gateway = os.environ.get("FIREGLAB_GATEWAY", "")
    registry_cache_gateway = os.environ.get("REGISTRY_CACHE_GATEWAY", "")
    zot_enabled = os.environ.get("ZOT_ENABLED", "false") == "true"

    # Build cloud-init user-data
    user_data_lines = [
        "#cloud-config",
        "# Fireglab VM configuration - auto-injected by inject-secrets.py",
        "",
    ]

    # === CONTAINERD HOSTS.TOML FILES ===
    # Generate containerd registry mirror configuration for Zot
    if zot_enabled and registry_cache_gateway:
        zot_port = os.environ.get("ZOT_PORT", "5000")
        zot_mirrors_json = os.environ.get("ZOT_MIRRORS", "{}")

        try:
            zot_mirrors = json.loads(zot_mirrors_json)
        except json.JSONDecodeError:
            zot_mirrors = {}
            print(f"Warning: Failed to parse ZOT_MIRRORS JSON: {zot_mirrors_json}")

        if zot_mirrors:
            user_data_lines.extend([
                "# Containerd registry mirror configuration for Zot pull-through cache",
                "# Each registry gets a hosts.toml that points to the local Zot mirror",
                "write_files:",
            ])

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
                    upstream_url = mirror_config.get("url", default_upstreams.get(registry_name, f"https://{registry_name}"))
                else:
                    upstream_url = default_upstreams.get(registry_name, f"https://{registry_name}")

                # Generate hosts.toml content
                # docker.io images are stored at root paths in Zot (e.g., /library/alpine)
                # Other registries use namespaced paths (e.g., /ghcr.io/owner/repo)
                if registry_name == "docker.io":
                    # Docker Hub: images at root, no path override needed
                    hosts_toml = f'''server = "{upstream_url}"

[host."http://{registry_cache_gateway}:{zot_port}"]
  capabilities = ["pull", "resolve"]
  skip_verify = true'''
                else:
                    # Other registries: images under /{registry_name}/, use override_path
                    hosts_toml = f'''server = "{upstream_url}"

[host."http://{registry_cache_gateway}:{zot_port}"]
  capabilities = ["pull", "resolve"]
  skip_verify = true

[host."http://{registry_cache_gateway}:{zot_port}/v2/{registry_name}"]
  capabilities = ["pull", "resolve"]
  override_path = true'''

                user_data_lines.extend([
                    f"  - path: /etc/containerd/certs.d/{registry_name}/hosts.toml",
                    "    content: |",
                ])
                # Add hosts.toml content with proper indentation
                for line in hosts_toml.split('\n'):
                    user_data_lines.append(f"      {line}")

            # === BUILDKIT CONFIG FOR BUILDX ===
            # docker/setup-buildx-action creates a BuildKit container that doesn't inherit
            # the host's containerd config. We need to provide a buildkitd.toml that Buildx
            # can use via --config flag or BUILDKIT_CONFIG env var.
            buildkit_config_lines = []
            for registry_name in zot_mirrors.keys():
                # BuildKit uses a different format than containerd
                # The mirror URL should point to Zot's namespaced path
                buildkit_config_lines.extend([
                    f'[registry."{registry_name}"]',
                    f'  mirrors = ["{registry_cache_gateway}:{zot_port}"]',
                    f'  http = true',
                    f'  insecure = true',
                    '',
                ])

            buildkit_config = '\n'.join(buildkit_config_lines)

            user_data_lines.extend([
                f"  - path: /etc/buildkit/buildkitd.toml",
                "    content: |",
                "      # BuildKit registry mirrors for docker/setup-buildx-action",
                "      # Use with: docker buildx create --config /etc/buildkit/buildkitd.toml",
                "      # Or set BUILDKIT_CONFIG=/etc/buildkit/buildkitd.toml",
            ])
            for line in buildkit_config.split('\n'):
                user_data_lines.append(f"      {line}")

            # === DOCKER DAEMON.JSON ===
            # Configure Docker daemon to use Zot as registry mirror
            # This works for regular 'docker pull' commands
            # Note: Docker only supports mirrors for docker.io (Docker Hub)
            docker_daemon_config = {
                "registry-mirrors": [f"http://{registry_cache_gateway}:{zot_port}"],
                "insecure-registries": [f"{registry_cache_gateway}:{zot_port}"]
            }
            docker_daemon_json = json.dumps(docker_daemon_config, indent=2)

            user_data_lines.extend([
                f"  - path: /etc/docker/daemon.json",
                "    content: |",
            ])
            for line in docker_daemon_json.split('\n'):
                user_data_lines.append(f"      {line}")

            print(f"Generated containerd hosts.toml for {len(zot_mirrors)} registries: {', '.join(zot_mirrors.keys())}")
            print(f"Generated BuildKit config for Buildx at /etc/buildkit/buildkitd.toml")
            print(f"Generated Docker daemon.json with registry mirror")

    # === CA CERTIFICATE (only if Squid SSL bump is enabled for some domains) ===
    squid_ssl_bump_mode = os.environ.get("SQUID_SSL_BUMP_MODE", "off")
    squid_ssl_bump_domains = os.environ.get("SQUID_SSL_BUMP_DOMAINS", "")
    squid_ca_file = os.environ.get("SQUID_CA_FILE", "")

    # Only inject CA cert if:
    # 1. SSL bump mode is "all" (needs CA everywhere), OR
    # 2. SSL bump mode is "selective" AND domains are configured (needs CA for those domains)
    needs_ca = (
        squid_ssl_bump_mode == "all" or
        (squid_ssl_bump_mode == "selective" and squid_ssl_bump_domains)
    )

    if needs_ca and squid_ca_file:
        with open(squid_ca_file, "r") as f:
            ca_cert_raw = f.read().rstrip('\n')

        user_data_lines.extend([
            "",
            "# CA certificate for Squid SSL bump",
            "# Required for HTTPS interception of configured domains",
            "ca_certs:",
            "  trusted:",
            "    - |",
        ])
        for line in ca_cert_raw.split('\n'):
            user_data_lines.append(f"      {line}")

        print(f"Injected CA certificate for SSL bump mode: {squid_ssl_bump_mode}")

    # === DEBUG SSH KEY ===
    debug_ssh_key = read_secret_file("DEBUG_SSH_KEY_FILE")
    if debug_ssh_key:
        user_data_lines.extend([
            "",
            "# SSH access for debugging",
            "users:",
            "  - name: root",
            "    ssh_authorized_keys:",
            f"      - {debug_ssh_key}",
        ])
        print(f"Debug SSH key configured for VMs")

    # === RUNCMD SECTION ===
    user_data_lines.extend([
        "",
        "# Runtime configuration via runcmd",
        "runcmd:",
    ])

    # CA bundle fix (only if we injected a CA cert)
    if needs_ca and squid_ca_file:
        user_data_lines.extend([
            "  # Fix Ubuntu 24.04 bug: ca_certs module creates hash symlinks but doesn't",
            "  # add cert to /etc/ssl/certs/ca-certificates.crt bundle file.",
            "  # curl/docker use the bundle file, not symlinks, so we must append manually.",
            "  - |",
            "    CA_CERT=$(ls /usr/local/share/ca-certificates/cloud-init-ca-cert-*.crt 2>/dev/null | head -1)",
            '    if [ -n "$CA_CERT" ]; then',
            "      update-ca-certificates",
            '      cat "$CA_CERT" >> /etc/ssl/certs/ca-certificates.crt',
            '      echo "CA cert added to bundle: $CA_CERT"',
            "    fi",
        ])

    # Container runtime restarts (if Zot mirrors were configured)
    if zot_enabled and registry_cache_gateway:
        zot_mirrors_json = os.environ.get("ZOT_MIRRORS", "{}")
        try:
            zot_mirrors = json.loads(zot_mirrors_json)
        except json.JSONDecodeError:
            zot_mirrors = {}

        if zot_mirrors:
            user_data_lines.extend([
                "  # Ensure containerd picks up the new registry mirrors",
                "  - mkdir -p /etc/containerd/certs.d",
                "  - mkdir -p /etc/buildkit",
                "  - systemctl restart containerd || true",
                "  # Restart Docker daemon to pick up registry mirror config",
                "  - systemctl restart docker || true",
                "  # Create a pre-configured Buildx builder that uses our registry mirrors",
                "  - |",
                "    if command -v docker &> /dev/null && [ -f /etc/buildkit/buildkitd.toml ]; then",
                "      docker buildx create --name zot-cache --driver docker-container \\",
                "        --config /etc/buildkit/buildkitd.toml --use 2>/dev/null || true",
                "    fi",
            ])

    # DNS configuration
    # Use fireglab gateway for DNS (10.202.0.1) which forwards to main dnsmasq
    if fireglab_gateway:
        user_data_lines.extend([
            "  # Set DNS to use fireglab gateway (centralized DNS via dnsmasq)",
            f"  - echo 'nameserver {fireglab_gateway}' > /etc/resolv.conf",
        ])

    # Hostname from MMDS
    user_data_lines.extend([
        "  # Set hostname from MMDS metadata",
        "  - |",
        "    RUNNER_NAME=$(curl -sf http://169.254.169.254/latest/meta-data/fireglab/runner_name)",
        '    if [ -n "$RUNNER_NAME" ]; then',
        '      hostnamectl set-hostname "$RUNNER_NAME"',
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
os.makedirs("/run/fireglab", exist_ok=True)
with open("/run/fireglab/config.yaml", "w") as f:
    yaml.dump(config, f, default_flow_style=False, sort_keys=False)

print("fireglab config generated at /run/fireglab/config.yaml")
