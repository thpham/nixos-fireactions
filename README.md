# nixos-fireactions

NixOS module for self-hosted CI runners using Firecracker microVMs. Supports both GitHub Actions (via [fireactions](https://fireactions.io)) and Gitea Actions (via fireteact).

## Status

**Phase 3: Runtime** - Core infrastructure complete with registry caching and multi-provider runner support.

## Architecture

The module system uses a composable 4-layer architecture, allowing independent deployment of different runner technologies:

```
┌─────────────────────────────────────────────────────────────┐
│                    Layer 4: Profiles                        │
│  fireactions-small  fireteact-medium  registry-cache        │
└─────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────┐
│              Layer 3: Runner Technologies                   │
│   fireactions/     fireteact/     (future: fireglab/)       │
└─────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────┐
│              Layer 2: registry-cache (standalone)           │
│   Zot OCI cache + Squid HTTP proxy (works with any runner)  │
└─────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────┐
│              Layer 1: microvm-base (foundation)             │
│   Bridge registry, containerd, DNSmasq, CNI plugins         │
└─────────────────────────────────────────────────────────────┘
```

### Composable Deployments

| Scenario                      | Tags                                                                          |
| ----------------------------- | ----------------------------------------------------------------------------- |
| Gitea only + cache            | `["gitea-runners", "fireteact-medium", "registry-cache"]`                     |
| GitHub only                   | `["github-runners", "fireactions-large"]`                                     |
| Both runners, different sizes | `["github-runners", "gitea-runners", "fireactions-small", "fireteact-large"]` |

## Quick Start

### Prerequisites

- NixOS 25.11+ (kernel 6.1+ for Firecracker compatibility)
- KVM-capable hardware
- GitHub App configured for fireactions, or Gitea API token for fireteact

### Using the Module

Add to your `flake.nix`:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-fireactions.url = "github:thpham/nixos-fireactions";
    nixos-fireactions.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, nixos-fireactions, ... }: {
    nixosConfigurations.my-runner = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        # Import all modules (microvm-base, registry-cache, fireactions, fireteact)
        nixos-fireactions.nixosModules.microvm-base
        nixos-fireactions.nixosModules.registry-cache
        nixos-fireactions.nixosModules.fireactions
        nixos-fireactions.nixosModules.fireteact
        {
          # Example: GitHub Actions runners only
          services.fireactions = {
            enable = true;
            github.appIdFile = "/run/secrets/github-app-id";
            github.appPrivateKeyFile = "/run/secrets/github-app-key";
            pools = [{
              name = "default";
              maxRunners = 5;
              minRunners = 1;
              runner = {
                organization = "your-org";
                labels = [ "self-hosted" "fireactions" "linux" ];
              };
            }];
          };

          # Optional: Enable registry cache
          services.registry-cache = {
            enable = true;
            useMicrovmBaseBridges = true;  # Auto-detect bridges
            zot.enable = true;
          };
        }
      ];
    };
  };
}
```

### Development Shell

```bash
nix develop
```

## NixOS Modules

| Module                        | Purpose                                             |
| ----------------------------- | --------------------------------------------------- |
| `nixosModules.microvm-base`   | Foundation layer: bridges, containerd, DNSmasq, CNI |
| `nixosModules.registry-cache` | Standalone caching: Zot OCI + Squid HTTP proxy      |
| `nixosModules.fireactions`    | GitHub Actions runner manager                       |
| `nixosModules.fireteact`      | Gitea Actions runner manager                        |

## Packages

| Package                     | Description                                         |
| --------------------------- | --------------------------------------------------- |
| `fireactions`               | Main fireactions binary (v0.4.0)                    |
| `fireteact`                 | Gitea Actions runner orchestrator                   |
| `firecracker-kernel`        | Upstream Firecracker CI kernel (6.1.141, minimal)   |
| `firecracker-kernel-custom` | Custom kernel with Docker bridge networking support |
| `tc-redirect-tap`           | CNI plugin for Firecracker networking               |
| `zot`                       | OCI-native registry for pull-through caching        |

### Kernel Selection

Two kernel options are available depending on your use case:

| Kernel                      | Use Case                                 | Build Time |
| --------------------------- | ---------------------------------------- | ---------- |
| `firecracker-kernel`        | Default, fast boot, no Docker inside VMs | ~30s fetch |
| `firecracker-kernel-custom` | Docker bridge networking inside VMs      | ~10-15 min |

**When to use custom kernel**: If your GitHub/Gitea Actions workflows need Docker with bridge networking inside Firecracker VMs (e.g., `docker run` without `--network=host`), use the custom kernel.

## Module Options

### microvm-base Options

Key configuration under `services.microvm-base`:

| Option                | Type              | Default                  | Description                                  |
| --------------------- | ----------------- | ------------------------ | -------------------------------------------- |
| `enable`              | bool              | `false`                  | Enable microvm-base infrastructure           |
| `bridges`             | attrsOf submodule | `{}`                     | Bridge definitions for runner networks       |
| `kernel.source`       | enum              | `"upstream"`             | Kernel source: `upstream`/`custom`/`nixpkgs` |
| `kernel.version`      | string            | `"6.1.141"`              | Kernel version (for upstream source)         |
| `kernel.args`         | string            | `"console=ttyS0..."`     | Kernel boot arguments                        |
| `dns.upstreamServers` | list              | `["8.8.8.8", "8.8.4.4"]` | Upstream DNS servers                         |

### registry-cache Options

Key configuration under `services.registry-cache`:

| Option                  | Type | Default | Description                            |
| ----------------------- | ---- | ------- | -------------------------------------- |
| `enable`                | bool | `false` | Enable registry cache                  |
| `useMicrovmBaseBridges` | bool | `true`  | Auto-detect networks from microvm-base |
| `zot.enable`            | bool | `false` | Enable Zot OCI pull-through cache      |
| `squid.enable`          | bool | `false` | Enable Squid HTTP/HTTPS proxy          |

### fireactions Options

Key configuration under `services.fireactions`:

| Option           | Type   | Default            | Description                                                |
| ---------------- | ------ | ------------------ | ---------------------------------------------------------- |
| `enable`         | bool   | `false`            | Enable fireactions service                                 |
| `configFile`     | path   | `null`             | Custom config file (overrides other options)               |
| `bindAddress`    | string | `":8080"`          | Server bind address                                        |
| `logLevel`       | enum   | `"info"`           | Log level (debug/info/warn/error)                          |
| `metricsEnable`  | bool   | `true`             | Enable Prometheus metrics                                  |
| `metricsAddress` | string | `"127.0.0.1:8081"` | Metrics endpoint address                                   |
| `kernelSource`   | enum   | `"upstream"`       | **DEPRECATED** - Use `services.microvm-base.kernel.source` |
| `pools`          | list   | `[]`               | Runner pool configurations                                 |

See [docs/requirements.md](docs/requirements.md) for complete documentation.

## Deployment & Fleet Management

This project uses a **two-stage deployment model**:

1. **Initial Deploy** (nixos-anywhere): Creates a minimal, bootable NixOS host with disk partitioning
2. **Fleet Updates** (Colmena): Applies profiles, services, and ongoing configuration

### Initial Deployment

Deploy to any SSH-accessible target using nixos-anywhere with auto-registration:

```bash
# DigitalOcean (2GB+ droplet required for kexec)
./deploy/deploy.sh --provider do --name do-runner-1 --tags prod,github-runners,fireactions-medium 167.71.100.50

# Hetzner Cloud or bare metal
./deploy/deploy.sh --provider hetzner --name hetzner-prod-1 --tags prod 95.217.xxx.xxx

# Generic VM with /dev/vda
./deploy/deploy.sh --provider generic --name my-vm <ip>
```

### Fleet Updates with Colmena

```bash
# Update single host
colmena apply --on do-runner-1 --build-on-target

# Update hosts by tag
colmena apply --on @prod --build-on-target

# Update entire fleet
colmena apply --build-on-target
```

### Tag-Based Profiles

Configuration is applied via **tags** using a profile system. Tags specified during deployment automatically apply matching profiles.

**Technology-Specific Profiles** (recommended):

| Profile              | Purpose                                  |
| -------------------- | ---------------------------------------- |
| `fireactions-small`  | GitHub runners: 2 max, 1GB/1vCPU per VM  |
| `fireactions-medium` | GitHub runners: 5 max, 2GB/2vCPU per VM  |
| `fireactions-large`  | GitHub runners: 10 max, 4GB/4vCPU per VM |
| `fireteact-small`    | Gitea runners: 2 max, 1GB/1vCPU per VM   |
| `fireteact-medium`   | Gitea runners: 5 max, 2GB/2vCPU per VM   |
| `fireteact-large`    | Gitea runners: 10 max, 4GB/4vCPU per VM  |

**Workload Profiles**:

| Profile          | Purpose                                                 |
| ---------------- | ------------------------------------------------------- |
| `github-runners` | Enables fireactions service with GitHub App credentials |
| `gitea-runners`  | Enables fireteact service with Gitea API credentials    |
| `registry-cache` | Enables Zot/Squid caching layer                         |

**Environment Profiles**:

| Profile | Purpose                                             |
| ------- | --------------------------------------------------- |
| `prod`  | Production settings (strict security, warn logging) |
| `dev`   | Development settings (debug logging, extra tools)   |

**Example deployment combinations**:

```bash
# Gitea runners only with caching
./deploy/deploy.sh -p do -n gitea-1 -t prod,gitea-runners,fireteact-medium,registry-cache <ip>

# GitHub runners only, large size
./deploy/deploy.sh -p do -n github-1 -t prod,github-runners,fireactions-large <ip>

# Both runners with different sizes
./deploy/deploy.sh -p do -n mixed-1 -t prod,github-runners,gitea-runners,fireactions-small,fireteact-large <ip>
```

## Secrets Management

This project uses [sops-nix](https://github.com/Mic92/sops-nix) for secrets management.

### Defined Secrets

| Secret               | Path on Host                      | Description            |
| -------------------- | --------------------------------- | ---------------------- |
| `github-app-id`      | `/run/secrets/github-app-id`      | GitHub App ID          |
| `github-app-key`     | `/run/secrets/github-app-key`     | GitHub App private key |
| `gitea-api-token`    | `/run/secrets/gitea-api-token`    | Gitea API token        |
| `gitea-instance-url` | `/run/secrets/gitea-instance-url` | Gitea instance URL     |
| `gitea-runner-owner` | `/run/secrets/gitea-runner-owner` | Gitea runner owner/org |

## Registry Cache

Optional pull-through cache for container registries using Zot and Squid. Now a **standalone module** that works with any runner technology.

### Architecture

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│  Firecracker VM │────▶│   Zot (OCI)     │────▶│  Docker Hub     │
│  (containerd)   │     │   + Squid       │     │  ghcr.io, etc.  │
└─────────────────┘     └─────────────────┘     └─────────────────┘
```

### Enable Registry Cache

```nix
services.registry-cache = {
  enable = true;
  useMicrovmBaseBridges = true;  # Auto-detect networks

  zot = {
    enable = true;
    mirrors = {
      "docker.io" = {};
      "ghcr.io" = {};
    };
  };

  squid = {
    enable = true;
    sslBump.mode = "selective";  # "off", "selective", or "all"
  };
};
```

### Features

- **Zot**: OCI-native pull-through cache for container images
- **Squid**: HTTP/HTTPS caching proxy for non-OCI traffic
- **Automatic VM configuration**: containerd, Docker, and BuildKit are auto-configured via cloud-init
- **SSL bump** (optional): Intercept HTTPS for deeper caching
- **Multi-network support**: Serves all registered bridges from microvm-base

## Gitea Actions Support (Fireteact)

The `fireteact` module provides Gitea Actions runner support using the same Firecracker microVM infrastructure.

### Enable Fireteact

```nix
# Kernel configuration is now at microvm-base layer
services.microvm-base.kernel.source = "custom";  # Includes Docker bridge networking

services.fireteact = {
  enable = true;

  gitea = {
    instanceUrlFile = config.sops.secrets."gitea-instance-url".path;
    apiTokenFile = config.sops.secrets."gitea-api-token".path;
    runnerScope = "org";  # "org", "repo", or "instance"
    runnerOwnerFile = config.sops.secrets."gitea-runner-owner".path;
  };

  pools = [{
    name = "default";
    maxRunners = 5;
    runner = {
      labels = [ "ubuntu-24.04" ];
      image = "ghcr.io/thpham/fireactions-images/ubuntu-24.04-gitea:latest";
    };
  }];
};
```

### Differences from Fireactions

| Feature        | Fireactions (GitHub) | Fireteact (Gitea) |
| -------------- | -------------------- | ----------------- |
| Auth           | GitHub App           | API Token         |
| Runner binary  | actions/runner       | act_runner        |
| Image format   | Same OCI images      | Same OCI images   |
| Registry cache | Supported            | Supported         |

## Project Structure

```
nixos-fireactions/
├── flake.nix                    # Flake definition
├── flake.lock                   # Lock file
├── modules/
│   ├── microvm-base/            # Foundation layer
│   │   ├── default.nix          # Bridge registry, shared infrastructure
│   │   ├── containerd.nix       # containerd + devmapper setup
│   │   ├── dnsmasq.nix          # Multi-bridge DHCP/DNS
│   │   ├── bridge.nix           # systemd-networkd bridges
│   │   └── cni.nix              # CNI plugins setup
│   ├── registry-cache/          # Standalone caching
│   │   ├── default.nix          # Entry point + options
│   │   └── nat.nix              # NAT rules for transparent proxy
│   ├── fireactions/             # GitHub Actions runner module
│   │   ├── default.nix          # Entry point + options
│   │   ├── services.nix         # systemd services
│   │   └── security/            # Security hardening
│   └── fireteact/               # Gitea Actions runner module
│       ├── default.nix          # Entry point + options
│       └── services.nix         # systemd services
├── pkgs/
│   ├── fireactions.nix                  # Main binary
│   ├── fireteact.nix                    # Gitea runner orchestrator
│   ├── firecracker-kernel.nix           # Upstream guest kernel (minimal)
│   ├── firecracker-kernel-custom.nix    # Custom kernel with Docker support
│   ├── firecracker-kernel-custom.config # Custom kernel config additions
│   ├── tc-redirect-tap.nix              # CNI plugin
│   └── zot.nix                          # OCI registry
├── profiles/                    # Tag-based configuration profiles
│   ├── default.nix              # Profile index
│   ├── sizes/                   # Size definitions
│   │   └── _lib.nix             # Pool factory functions
│   ├── fireactions-small.nix    # GitHub runners - small
│   ├── fireactions-medium.nix   # GitHub runners - medium
│   ├── fireactions-large.nix    # GitHub runners - large
│   ├── fireteact-small.nix      # Gitea runners - small
│   ├── fireteact-medium.nix     # Gitea runners - medium
│   ├── fireteact-large.nix      # Gitea runners - large
│   ├── github-runners.nix       # Enables fireactions + credentials
│   ├── gitea-runners.nix        # Enables fireteact + credentials
│   ├── registry-cache.nix       # Enables caching layer
│   ├── prod.nix                 # Production environment
│   └── dev.nix                  # Development environment
├── hosts/
│   ├── default.nix              # Colmena hive generator
│   ├── registry.json            # Auto-populated host registry
│   └── <name>.nix               # Per-host config (escape hatch)
├── secrets/
│   └── .sops.yaml               # sops-nix configuration
├── deploy/
│   ├── deploy.sh                # Deployment + registration script
│   ├── base.nix                 # Shared config (boot, network, SSH)
│   ├── configuration.nix        # Initial deploy config
│   ├── disko.nix                # Disk partitioning
│   └── digitalocean.nix         # DigitalOcean cloud-init config
├── images/
│   ├── qcow2.nix                # Generic QCOW2 cloud image
│   └── azure.nix                # Azure VHD image
└── docs/
    ├── CLAUDE.md                # Development guidance
    └── requirements.md          # Full requirements
```

## Roadmap

- [x] **Phase 1**: Foundation (flake, module, packages)
- [x] **Phase 2**: Image builders & Deployment (nixos-anywhere, Azure, DO)
- [x] **Phase 3**: Runtime components (registry cache, networking, Gitea support)
- [x] **Phase 3.5**: Composable architecture (microvm-base, standalone registry-cache)
- [ ] **Phase 4**: CI & Testing

## References

- [fireactions documentation](https://fireactions.io)
- [Firecracker](https://github.com/firecracker-microvm/firecracker)
- [Gitea act_runner](https://gitea.com/gitea/act_runner)
- [microvm.nix](https://github.com/astro/microvm.nix)

## License

MIT
