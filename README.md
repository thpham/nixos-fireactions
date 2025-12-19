# nixos-fireactions

NixOS module for self-hosted CI runners using Firecracker microVMs. Supports GitHub Actions (via [fireactions](https://fireactions.io)), Gitea Actions (via fireteact), and GitLab CI (via fireglab).

## Status

**Phase 3: Runtime** - Core infrastructure complete with registry caching and multi-provider runner support.

## Architecture

The module system uses a composable 4-layer architecture, allowing independent deployment of different runner technologies:

```
┌─────────────────────────────────────────────────────────────┐
│                    Layer 4: Profiles                        │
│  {runner}-{size}   registry-cache   prod/dev                │
└─────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────┐
│              Layer 3: Runner Orchestrators                  │
│   fireactions/     fireteact/     fireglab/                 │
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

| Scenario       | Tags                                                                           |
| -------------- | ------------------------------------------------------------------------------ |
| GitHub only    | `["github-runners", "fireactions-large"]`                                      |
| Gitea + cache  | `["gitea-runners", "fireteact-medium", "registry-cache"]`                      |
| GitLab only    | `["gitlab-runners", "fireglab-medium"]`                                        |
| Multi-platform | `["github-runners", "gitlab-runners", "fireactions-small", "fireglab-medium"]` |

## Quick Start

### Prerequisites

- NixOS 25.11+ (kernel 6.1+ for Firecracker compatibility)
- KVM-capable hardware
- Platform-specific credentials:
  - **GitHub**: GitHub App (app_id + private_key)
  - **Gitea**: API Token with runner management scope
  - **GitLab**: Personal Access Token with `create_runner` scope

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
        # Import all modules
        nixos-fireactions.nixosModules.microvm-base
        nixos-fireactions.nixosModules.registry-cache
        nixos-fireactions.nixosModules.fireactions  # GitHub Actions
        nixos-fireactions.nixosModules.fireteact    # Gitea Actions
        nixos-fireactions.nixosModules.fireglab     # GitLab CI
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
| `nixosModules.fireactions`    | GitHub Actions runner orchestrator                  |
| `nixosModules.fireteact`      | Gitea Actions runner orchestrator                   |
| `nixosModules.fireglab`       | GitLab CI runner orchestrator                       |

## Packages

| Package                     | Description                                         |
| --------------------------- | --------------------------------------------------- |
| `fireactions`               | GitHub Actions runner orchestrator (v0.4.0)         |
| `fireteact`                 | Gitea Actions runner orchestrator                   |
| `fireglab`                  | GitLab CI runner orchestrator                       |
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

**Size Profiles** (per runner technology):

Each runner orchestrator has small/medium/large size profiles following the pattern `{runner}-{size}`:

| Size   | Resources       | Max Runners | Available Profiles                                          |
| ------ | --------------- | ----------- | ----------------------------------------------------------- |
| small  | 1GB RAM, 1 vCPU | 2           | `fireactions-small`, `fireteact-small`, `fireglab-small`    |
| medium | 2GB RAM, 2 vCPU | 5           | `fireactions-medium`, `fireteact-medium`, `fireglab-medium` |
| large  | 4GB RAM, 4 vCPU | 10          | `fireactions-large`, `fireteact-large`, `fireglab-large`    |

**Workload Profiles**:

| Profile          | Purpose                                |
| ---------------- | -------------------------------------- |
| `github-runners` | Enables fireactions with GitHub App    |
| `gitea-runners`  | Enables fireteact with Gitea API token |
| `gitlab-runners` | Enables fireglab with GitLab PAT       |
| `registry-cache` | Enables Zot/Squid caching layer        |

**Environment Profiles**: `prod` (strict security) | `dev` (debug logging)

**Example deployment combinations**:

```bash
# GitHub runners only
./deploy/deploy.sh -p do -n github-1 -t prod,github-runners,fireactions-large <ip>

# GitLab runners with caching
./deploy/deploy.sh -p do -n gitlab-1 -t prod,gitlab-runners,fireglab-medium,registry-cache <ip>

# Multi-platform runners
./deploy/deploy.sh -p do -n multi-1 -t prod,github-runners,gitlab-runners,fireactions-small,fireglab-medium <ip>
```

## Secrets Management

This project uses [sops-nix](https://github.com/Mic92/sops-nix) for secrets management.

### Defined Secrets

| Secret                | Path on Host                       | Platform |
| --------------------- | ---------------------------------- | -------- |
| `github-app-id`       | `/run/secrets/github-app-id`       | GitHub   |
| `github-app-key`      | `/run/secrets/github-app-key`      | GitHub   |
| `gitea-api-token`     | `/run/secrets/gitea-api-token`     | Gitea    |
| `gitea-instance-url`  | `/run/secrets/gitea-instance-url`  | Gitea    |
| `gitea-runner-owner`  | `/run/secrets/gitea-runner-owner`  | Gitea    |
| `gitlab-access-token` | `/run/secrets/gitlab-access-token` | GitLab   |
| `gitlab-instance-url` | `/run/secrets/gitlab-instance-url` | GitLab   |
| `gitlab-group-id`     | `/run/secrets/gitlab-group-id`     | GitLab   |

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

## Runner Orchestrators

Three Go-based orchestrators manage ephemeral Firecracker microVMs for different CI platforms:

| Orchestrator | Platform       | Auth Method   | Runner Agent   | Network Bridge |
| ------------ | -------------- | ------------- | -------------- | -------------- |
| fireactions  | GitHub Actions | GitHub App    | actions/runner | fireactions0   |
| fireteact    | Gitea Actions  | API Token     | act_runner     | fireteact0     |
| fireglab     | GitLab CI      | PAT (glrt-\*) | gitlab-runner  | fireglab0      |

Each orchestrator:

- Registers its own bridge with `microvm-base`
- Uses per-pool containerd namespaces for isolation
- Supports the same pool configuration structure
- Works with `registry-cache` for image caching

See individual READMEs for detailed configuration:

- [fireteact/README.md](fireteact/README.md) - Gitea Actions
- [fireglab/README.md](fireglab/README.md) - GitLab CI

## Project Structure

```
nixos-fireactions/
├── flake.nix                    # Flake definition
├── modules/
│   ├── microvm-base/            # Layer 1: Foundation (bridges, containerd, DNS, CNI)
│   ├── registry-cache/          # Layer 2: Standalone caching (Zot + Squid)
│   ├── fireactions/             # Layer 3: GitHub Actions orchestrator
│   ├── fireteact/               # Layer 3: Gitea Actions orchestrator
│   └── fireglab/                # Layer 3: GitLab CI orchestrator
├── fireactions/                 # Upstream fireactions (submodule/reference)
├── fireteact/                   # Gitea runner orchestrator (Go)
├── fireglab/                    # GitLab runner orchestrator (Go)
├── pkgs/
│   ├── fireactions.nix          # GitHub orchestrator package
│   ├── fireteact.nix            # Gitea orchestrator package
│   ├── fireglab.nix             # GitLab orchestrator package
│   ├── firecracker-kernel*.nix  # Guest kernels (upstream + custom)
│   ├── tc-redirect-tap.nix      # CNI plugin
│   └── zot.nix                  # OCI registry
├── profiles/
│   ├── sizes/_lib.nix           # Pool factory functions (mkFireactionsPool, etc.)
│   ├── {runner}-{size}.nix      # Size profiles (9 total: 3 runners × 3 sizes)
│   ├── {platform}-runners.nix   # Workload profiles (github, gitea, gitlab)
│   ├── registry-cache.nix       # Caching layer
│   └── prod.nix, dev.nix        # Environment profiles
├── hosts/
│   ├── default.nix              # Colmena hive generator
│   └── registry.json            # Auto-populated host registry
├── deploy/                      # nixos-anywhere deployment
├── images/                      # Cloud image builders (QCOW2, Azure)
├── secrets/                     # sops-nix encrypted secrets
└── docs/                        # Documentation
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
- [GitLab Runner](https://docs.gitlab.com/runner/)
- [GitLab Runners API](https://docs.gitlab.com/ee/api/users.html#create-a-runner)
- [microvm.nix](https://github.com/astro/microvm.nix)

## License

MIT
