# nixos-fireactions

Self-hosted CI runners using Firecracker microVMs. Run GitHub Actions and Gitea Actions workflows in lightweight, isolated VMs with auto-scaling and declarative NixOS configuration.

```
┌─────────────────────────────────────────────────────────────────┐
│  Your Server (NixOS)                                            │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  fireactions orchestrator                                │   │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐               │   │
│  │  │ microVM  │  │ microVM  │  │ microVM  │ ← Ephemeral   │   │
│  │  │ Runner 1 │  │ Runner 2 │  │ Runner N │   (per-job)   │   │
│  │  └──────────┘  └──────────┘  └──────────┘               │   │
│  └──────────────────────────────────────────────────────────┘   │
└───────────────────────────┬─────────────────────────────────────┘
                            │
              ┌─────────────┴─────────────┐
              ▼                           ▼
        ┌───────────┐               ┌───────────┐
        │  GitHub   │               │   Gitea   │
        │  Actions  │               │  Actions  │
        └───────────┘               └───────────┘
```

## Why nixos-fireactions?

| Feature | Traditional Runners | nixos-fireactions |
|---------|---------------------|-------------------|
| Isolation | Container/None | KVM microVM |
| Security | Shared kernel | Hardware-level |
| Boot time | N/A | ~1-2 seconds |
| Density | 1-5 per host | 10+ per host |
| Configuration | Scripts/YAML | Declarative Nix |
| Reproducibility | Low | High |

## Status

**Phase 3: Runtime** - Core infrastructure complete with registry caching and multi-provider runner support.

---

## Get Started

### New to nixos-fireactions?

**[Read the Getting Started Guide](docs/GETTING_STARTED.md)** - Step-by-step walkthrough from zero to working runners in ~30 minutes.

### Check Your Environment

```bash
# Verify prerequisites before deploying
./scripts/check-prerequisites.sh

# Also check your target server
./scripts/check-prerequisites.sh --remote <your-server-ip>
```

### Prerequisites

| Requirement | Details |
|-------------|---------|
| **Server** | KVM-capable, 2GB+ RAM |
| **OS** | NixOS 25.11+ (kernel 6.1+) |
| **Auth** | GitHub App or Gitea token |
| **Local** | Nix with flakes enabled |

---

## Quick Start

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
        nixos-fireactions.nixosModules.fireactions
        {
          services.fireactions = {
            enable = true;
            # Use file-based secrets (recommended with sops-nix)
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

## Packages

| Package                     | Description                                         |
| --------------------------- | --------------------------------------------------- |
| `fireactions`               | Main fireactions binary (v0.4.0)                    |
| `firecracker-kernel`        | Upstream Firecracker CI kernel (6.1.141, minimal)   |
| `firecracker-kernel-custom` | Custom kernel with Docker bridge networking support |
| `tc-redirect-tap`           | CNI plugin for Firecracker networking               |

### Kernel Selection

Two kernel options are available depending on your use case:

| Kernel                      | Use Case                                 | Build Time |
| --------------------------- | ---------------------------------------- | ---------- |
| `firecracker-kernel`        | Default, fast boot, no Docker inside VMs | ~30s fetch |
| `firecracker-kernel-custom` | Docker bridge networking inside VMs      | ~10-15 min |

**When to use custom kernel**: If your GitHub Actions workflows need Docker with bridge networking inside Firecracker VMs (e.g., `docker run` without `--network=host`), use the custom kernel.

The custom kernel adds:

- Netfilter modules (`CONFIG_IP_NF_RAW`, `CONFIG_IP6_NF_RAW`, `CONFIG_NETFILTER_XT_*`)
- Bridge netfilter support (`CONFIG_BRIDGE_NETFILTER`, `CONFIG_NF_CONNTRACK_BRIDGE`)
- Virtio MMIO cmdline devices (`CONFIG_VIRTIO_MMIO_CMDLINE_DEVICES`)
- PCI/PCIe support for advanced configurations
- Virtio memory/pmem for dynamic memory management

## Module Options

Key configuration options under `services.fireactions`:

| Option           | Type   | Default            | Description                                  |
| ---------------- | ------ | ------------------ | -------------------------------------------- |
| `enable`         | bool   | `false`            | Enable fireactions service                   |
| `configFile`     | path   | `null`             | Custom config file (overrides other options) |
| `bindAddress`    | string | `":8080"`          | Server bind address                          |
| `logLevel`       | enum   | `"info"`           | Log level (debug/info/warn/error)            |
| `metricsEnable`  | bool   | `true`             | Enable Prometheus metrics                    |
| `metricsAddress` | string | `"127.0.0.1:8081"` | Metrics endpoint address                     |
| `kernelSource`   | enum   | `"upstream"`       | Kernel source (upstream/nixpkgs)             |
| `kernelVersion`  | string | `"6.1.141"`        | Upstream kernel version                      |
| `pools`          | list   | `[]`               | Runner pool configurations                   |

See [docs/requirements.md](docs/requirements.md) for complete documentation.

## Deployment & Fleet Management

This project uses a **two-stage deployment model**:

1. **Initial Deploy** (nixos-anywhere): Creates a minimal, bootable NixOS host with disk partitioning
2. **Fleet Updates** (Colmena): Applies profiles, services, and ongoing configuration

This separation ensures disk partitioning is only applied once during initial install, protecting running systems from accidental reformatting during updates.

### Initial Deployment

Deploy to any SSH-accessible target using nixos-anywhere with auto-registration:

```bash
# DigitalOcean (2GB+ droplet required for kexec)
./deploy/deploy.sh --provider do --name do-runner-1 --tags prod,runners 167.71.100.50

# Hetzner Cloud or bare metal
./deploy/deploy.sh --provider hetzner --name hetzner-prod-1 --tags prod 95.217.xxx.xxx

# Generic VM with /dev/vda
./deploy/deploy.sh --provider generic --name my-vm <ip>

# NVMe-based systems
./deploy/deploy.sh --provider nvme --name nvme-server <ip>

# ARM servers (aarch64)
./deploy/deploy.sh --provider generic --arch aarch64 --name arm-runner <ip>

# Short flags also work
./deploy/deploy.sh -p do -n runner-1 -t prod,runners,large 167.71.100.50
```

Hosts are automatically registered in `hosts/registry.json` after successful deployment.

**Note**: Initial deployment creates a minimal system. Tags are recorded in the registry but profiles are applied during the first Colmena update.

### Fleet Updates with Colmena

After initial deployment, use Colmena to apply profiles and configuration (builds on target, works from Darwin):

```bash
# Update single host
colmena apply --on do-runner-1 --build-on-target

# Update hosts by tag
colmena apply --on @prod --build-on-target

# Update entire fleet
colmena apply --build-on-target

# Dry run (build only)
colmena build --on do-runner-1
```

### Host Registry

```bash
# List registered hosts
./deploy/deploy.sh list

# Unregister a host
./deploy/deploy.sh unregister do-runner-1

# View registry directly
cat hosts/registry.json
```

### Tag-Based Profiles

Configuration is applied via **tags** using a profile system. Tags specified during deployment (e.g., `--tags prod,runners,large`) automatically apply matching profiles:

```bash
# Deploy with tags - profiles are composed automatically
./deploy/deploy.sh --provider do --name do-runner-1 --tags prod,runners,large 167.71.100.50
```

**Available profiles** (`profiles/`):

| Profile   | Purpose                                             |
| --------- | --------------------------------------------------- |
| `prod`    | Production settings (strict security, warn logging) |
| `dev`     | Development settings (debug logging, extra tools)   |
| `runners` | Enables fireactions service                         |
| `small`   | 2 runners max, 1GB/1vCPU per VM                     |
| `medium`  | 5 runners max, 2GB/2vCPU per VM                     |
| `large`   | 10 runners max, 4GB/4vCPU per VM                    |

**Profile application order** (later overrides earlier):

1. Base profile (always applied)
2. Tag profiles (alphabetical order)
3. Per-host config (`hosts/<name>.nix`) - escape hatch for unique needs

**Example: Create a custom profile** (`profiles/gpu.nix`):

```nix
{ lib, ... }: {
  services.fireactions.pools = lib.mkDefault [{
    name = "gpu";
    maxRunners = 2;
    runner.labels = [ "self-hosted" "gpu" ];
  }];
}
```

Then add `"gpu"` to `profiles/default.nix` and use `--tags runners,gpu`.

**Note**: DigitalOcean 1GB droplets don't have enough RAM for kexec. Use 2GB+ droplets.

## Secrets Management

This project uses [sops-nix](https://github.com/Mic92/sops-nix) for secrets management. Secrets are encrypted at rest and decrypted on hosts at activation time.

### Initial Setup

1. **Install sops and age** on your workstation:

   ```bash
   nix profile install nixpkgs#sops nixpkgs#age nixpkgs#ssh-to-age
   ```

2. **Generate your admin key** (if you haven't already):

   ```bash
   mkdir -p ~/.config/sops/age
   age-keygen -o ~/.config/sops/age/keys.txt
   age-keygen -y ~/.config/sops/age/keys.txt  # Shows your public key
   ```

3. **Add your admin key** to `secrets/.sops.yaml` (already configured with a default key)

### Adding Host Keys

After deploying a host, add its age key to allow decryption:

```bash
# Get the host's age public key (derived from SSH host key)
ssh root@<host> "cat /etc/ssh/ssh_host_ed25519_key.pub" | ssh-to-age

# Or via ssh-keyscan
ssh-keyscan <host> 2>/dev/null | grep ed25519 | ssh-to-age
```

Add the resulting key to `secrets/.sops.yaml`:

```yaml
keys:
  - &admin age1jhxhe7w978fc4t6glav5pprtzdgy0juf8rqq4m7f6aelfmuz55fs7y5jdj
  - &do-runner-1 age1xxxxxxxxx... # Add this

creation_rules:
  - path_regex: secrets\.yaml$
    key_groups:
      - age:
          - *admin
          - *do-runner-1 # Add this
```

### Creating Secrets

1. **Create the encrypted secrets file**:

   ```bash
   cd secrets
   cp secrets.yaml.example secrets.yaml
   sops secrets.yaml  # Opens in $EDITOR, encrypts on save
   ```

2. **Add your GitHub App private key** (get from GitHub App settings):

   ```yaml
   github_app_private_key: |
     -----BEGIN RSA PRIVATE KEY-----
     YOUR_ACTUAL_KEY_HERE
     -----END RSA PRIVATE KEY-----
   ```

3. **Re-encrypt when adding new hosts**:
   ```bash
   sops updatekeys secrets/secrets.yaml
   ```

### Defined Secrets

| Secret           | Path on Host                  | Description            |
| ---------------- | ----------------------------- | ---------------------- |
| `github-app-id`  | `/run/secrets/github-app-id`  | GitHub App ID          |
| `github-app-key` | `/run/secrets/github-app-key` | GitHub App private key |

Secrets are defined in `deploy/secrets.nix` and automatically decrypted during system activation.

## Cloud Images

Build cloud-ready images:

```bash
# Generic QCOW2 (libvirt, Proxmox, OpenStack, etc.)
nix build .#image-qcow2

# Azure VHD
nix build .#image-azure

# Cross-compile for different architecture
nix build .#image-qcow2-cross
nix build .#image-azure-cross
```

## Registry Cache

Optional pull-through cache for container registries using Zot and Squid. Reduces bandwidth, speeds up image pulls, and provides resilience against registry outages.

### Architecture

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│  Firecracker VM │────▶│   Zot (OCI)     │────▶│  Docker Hub     │
│  (containerd)   │     │   + Squid       │     │  ghcr.io, etc.  │
└─────────────────┘     └─────────────────┘     └─────────────────┘
```

### Enable Registry Cache

```nix
services.fireactions.registryCache = {
  enable = true;
  mirrors = {
    "docker.io" = {};
    "ghcr.io" = {};
  };
};
```

### Features

- **Zot**: OCI-native pull-through cache for container images
- **Squid**: HTTP/HTTPS caching proxy for non-OCI traffic
- **Automatic VM configuration**: containerd, Docker, and BuildKit are auto-configured via cloud-init
- **SSL bump** (optional): Intercept HTTPS for deeper caching

## Gitea Actions Support (Fireteact)

The `fireteact` module provides Gitea Actions runner support using the same Firecracker microVM infrastructure.

### Enable Fireteact

```nix
services.fireteact = {
  enable = true;
  gitea = {
    instanceUrl = "https://gitea.example.com";
    runnerTokenFile = "/run/secrets/gitea-runner-token";
  };
  pools = [{
    name = "default";
    maxRunners = 5;
    runner = {
      labels = [ "ubuntu-24.04" ];
    };
  }];
};
```

### Differences from Fireactions

| Feature        | Fireactions (GitHub) | Fireteact (Gitea)         |
| -------------- | -------------------- | ------------------------- |
| Auth           | GitHub App           | Runner registration token |
| Runner binary  | actions/runner       | act_runner                |
| Image format   | Same OCI images      | Same OCI images           |
| Registry cache | Supported            | Supported                 |

## Project Structure

```
nixos-fireactions/
├── flake.nix                    # Flake definition
├── flake.lock                   # Lock file
├── modules/
│   ├── fireactions/             # GitHub Actions runner module
│   │   ├── default.nix          # Entry point + options
│   │   ├── services.nix         # systemd services
│   │   ├── registry-cache.nix   # Zot/Squid caching
│   │   └── security/            # Security hardening
│   └── fireteact/               # Gitea Actions runner module
│       ├── default.nix          # Entry point + options
│       └── services.nix         # systemd services
├── pkgs/
│   ├── fireactions.nix                  # Main binary
│   ├── firecracker-kernel.nix           # Upstream guest kernel (minimal)
│   ├── firecracker-kernel-custom.nix    # Custom kernel with Docker support
│   ├── firecracker-kernel-custom.config # Custom kernel config additions
│   └── tc-redirect-tap.nix              # CNI plugin
├── profiles/                    # Tag-based configuration profiles
│   ├── default.nix              # Profile index
│   ├── prod.nix                 # Production environment
│   ├── dev.nix                  # Development environment
│   ├── runners.nix              # Enables fireactions + guest kernelSource
│   ├── small.nix                # Small instance sizing
│   ├── medium.nix               # Medium instance sizing
│   └── large.nix                # Large instance sizing
├── hosts/
│   ├── default.nix              # Colmena hive generator
│   ├── registry.json            # Auto-populated host registry
│   └── <name>.nix               # Per-host config (escape hatch)
├── secrets/
│   ├── .sops.yaml               # sops-nix configuration
│   └── secrets.yaml.example     # Secrets template
├── deploy/
│   ├── deploy.sh                # Deployment + registration script
│   ├── base.nix                 # Shared config (boot, network, SSH) - used by Colmena
│   ├── configuration.nix        # Initial deploy config (imports base.nix + disko.nix)
│   ├── disko.nix                # Disk partitioning (initial deploy only)
│   └── digitalocean.nix         # DigitalOcean cloud-init config
├── images/
│   ├── qcow2.nix                # Generic QCOW2 cloud image
│   └── azure.nix                # Azure VHD image
├── scripts/
│   └── check-prerequisites.sh   # Environment validation tool
├── examples/
│   ├── minimal-github/          # Minimal GitHub Actions setup
│   └── README.md                # Examples index
└── docs/
    ├── GETTING_STARTED.md       # Step-by-step setup guide
    └── requirements.md          # Full requirements
```

## Documentation

| Document | Description |
|----------|-------------|
| [Getting Started Guide](docs/GETTING_STARTED.md) | Step-by-step walkthrough for new users |
| [Security Hardening](modules/fireactions/security/README.md) | VM isolation and security options |
| [Fireteact (Gitea)](fireteact/README.md) | Gitea Actions runner documentation |
| [Runner Images](images/docker/ubuntu-24.04/README.md) | Container image customization |
| [Examples](examples/) | Complete configuration examples |

## Roadmap

- [x] **Phase 1**: Foundation (flake, module, packages)
- [x] **Phase 2**: Image builders & Deployment (nixos-anywhere, Azure, DO)
- [x] **Phase 3**: Runtime components (registry cache, networking, Gitea support)
- [ ] **Phase 4**: CI & Testing

## Quick Reference

```bash
# Check prerequisites
./scripts/check-prerequisites.sh
./scripts/check-prerequisites.sh --remote <ip>

# Deploy new host
./deploy/deploy.sh -p do -n runner-1 -t prod,github-runners,medium <ip>

# List registered hosts
./deploy/deploy.sh list

# Update hosts with Colmena
colmena apply --on runner-1 --build-on-target  # Single host
colmena apply --on @prod --build-on-target      # By tag
colmena apply --build-on-target                 # All hosts

# Check service status
ssh root@<ip> systemctl status fireactions

# View logs
ssh root@<ip> journalctl -u fireactions -f

# Check metrics
curl http://<ip>:8081/metrics
```

## Getting Help

- **Documentation**: [Getting Started Guide](docs/GETTING_STARTED.md)
- **Issues**: [GitHub Issues](https://github.com/thpham/nixos-fireactions/issues)
- **Logs**: `journalctl -u fireactions -f` on the runner host

## References

- [fireactions documentation](https://fireactions.io)
- [Firecracker](https://github.com/firecracker-microvm/firecracker)
- [Gitea act_runner](https://gitea.com/gitea/act_runner)
- [microvm.nix](https://github.com/astro/microvm.nix)

## License

MIT
