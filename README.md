# nixos-fireactions

NixOS images for self-hosted GitHub Actions runners using [fireactions](https://fireactions.io) and Firecracker microVMs.

## Status

**Phase 1: Foundation** - Core flake structure with working NixOS module.

## Quick Start

### Prerequisites

- NixOS 25.11+ (kernel 6.1+ for Firecracker compatibility)
- KVM-capable hardware
- GitHub App configured for fireactions

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
        nixos-fireactions.nixosModules.fireactions-node
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

## Project Structure

```
nixos-fireactions/
├── flake.nix                    # Flake definition
├── flake.lock                   # Lock file
├── modules/
│   └── fireactions-node.nix     # NixOS module
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
│   └── .sops.yaml               # sops-nix configuration
├── deploy/
│   ├── deploy.sh                # Deployment + registration script
│   ├── base.nix                 # Shared config (boot, network, SSH) - used by Colmena
│   ├── configuration.nix        # Initial deploy config (imports base.nix + disko.nix)
│   ├── disko.nix                # Disk partitioning (initial deploy only)
│   └── digitalocean.nix         # DigitalOcean cloud-init config
├── images/
│   ├── qcow2.nix                # Generic QCOW2 cloud image
│   └── azure.nix                # Azure VHD image
└── docs/
    └── requirements.md          # Full requirements
```

## Roadmap

- [x] **Phase 1**: Foundation (flake, module, packages)
- [x] **Phase 2**: Image builders & Deployment (nixos-anywhere, Azure, DO)
- [ ] **Phase 3**: Runtime components (registry, networking)
- [ ] **Phase 4**: CI & Testing

## References

- [fireactions documentation](https://fireactions.io)
- [Firecracker](https://github.com/firecracker-microvm/firecracker)
- [microvm.nix](https://github.com/astro/microvm.nix)

## License

MIT
