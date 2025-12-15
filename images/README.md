# Cloud Images

Pre-built NixOS images for deploying Firecracker runner infrastructure across cloud platforms.

## Platform Requirements

> **Important:** Firecracker requires KVM (Kernel-based Virtual Machine) for hardware-accelerated virtualization. The target cloud platform must provide either:
>
> - **Bare-metal instances** - Direct hardware access with KVM support (e.g., Azure Ddsv5/Edsv5, AWS metal instances, Hetzner dedicated)
> - **Nested virtualization** - VMs with KVM passthrough enabled (e.g., Azure Dv3/Ev3 with nested virt, GCP N1/N2 with nested virt, Proxmox with CPU passthrough)
>
> Standard cloud VMs without nested virtualization support **will not work** with Firecracker.

## File Structure

```
images/
├── common.nix          # Shared configuration (fireactions, profiles, bootstrap)
├── azure.nix           # Azure-specific settings (IMDS, data disk)
├── qcow2.nix           # QEMU/KVM-specific settings (GRUB, guest agent)
├── src/
│   ├── bootstrap.sh        # Main bootstrap script
│   └── generate-config.py  # Config generator with registry-cache injection
└── README.md
```

## Architecture

All cloud images follow a standardized pattern:

```
┌─────────────────────────────────────────────────────────────────┐
│                        Cloud Platform                           │
│  (Azure VMSS, Proxmox, OpenStack, DigitalOcean, etc.)           │
├─────────────────────────────────────────────────────────────────┤
│                      Cloud-init User-data                       │
│  - GitHub App credentials (base64 encoded)                      │
│  - Pool configuration (JSON)                                    │
│  - SSH keys for access                                          │
├─────────────────────────────────────────────────────────────────┤
│                      Bootstrap Scripts                          │
│  src/bootstrap.sh → src/generate-config.py                      │
│  - Reads cloud-init written files                               │
│  - Generates /run/fireactions/config.yaml                       │
│  - Injects registry-cache metadata into pools                   │
├─────────────────────────────────────────────────────────────────┤
│                     Fireactions Module                          │
│  - Firecracker VM orchestration                                 │
│  - GitHub Actions runner management                             │
│  - CNI networking (tc-redirect-tap)                             │
├─────────────────────────────────────────────────────────────────┤
│                    Production Profiles                          │
│  - security-hardened.nix: Kernel/network/storage hardening      │
│  - registry-cache.nix: Zot + Squid caching infrastructure       │
│  - prod.nix: Production logging and metrics                     │
└─────────────────────────────────────────────────────────────────┘
```

## Building Images

```bash
# Azure VHD (from any platform)
nix build .#image-azure

# QCOW2 for QEMU/KVM platforms
nix build .#image-qcow2

# Cross-architecture builds
nix build .#image-azure-cross   # Build opposite arch
nix build .#image-qcow2-cross
```

## Available Images

### Azure (`azure.nix`)

Production-ready image for Azure Virtual Machine Scale Sets (VMSS).

**Features:**

- Full fireactions module with registry-cache
- Security-hardened kernel and network configuration
- Cloud-init with Azure IMDS datasource
- Bootstrap scripts for runtime configuration
- Data disk support for containerd storage

**Configuration Flow:**

```
cloud-init user-data
    ↓
/etc/fireactions/bootstrap.sh (wrapper - sets Nix paths + registry-cache env)
    ↓
/etc/fireactions/bootstrap-impl.sh (shared script)
    ↓
/etc/fireactions/generate-config.py (config generator)
    ↓
/run/fireactions/config.yaml (runtime config)
```

**Environment Variables (set by Nix wrapper):**
| Variable | Description |
|----------|-------------|
| `KERNEL_PATH` | Path to Firecracker kernel |
| `PYTHON_WITH_YAML` | Python interpreter with PyYAML |
| `REGISTRY_CACHE_ENABLED` | Enable registry cache metadata injection |
| `REGISTRY_CACHE_GATEWAY` | Gateway IP for containerd mirrors |
| `ZOT_PORT` | Zot registry port |
| `ZOT_MIRRORS` | JSON of configured registry mirrors |

**Example User-data:**

```yaml
#cloud-config
write_files:
  - path: /etc/fireactions/github-app-id
    content: "123456"
    permissions: "0600"
  - path: /etc/fireactions/github-private-key.pem
    encoding: b64
    content: LS0tLS1CRUdJTi... # base64 -w0 < key.pem
    permissions: "0600"
  - path: /etc/fireactions/pools.json
    encoding: b64
    content: W3sibmFtZSI6IC... # base64 -w0 < pools.json
    permissions: "0644"
runcmd:
  - /etc/fireactions/bootstrap.sh
```

**Pool Configuration Format (`pools.json`):**

```json
[
  {
    "name": "default",
    "maxRunners": 10,
    "minRunners": 1,
    "runner": {
      "name": "runner",
      "image": "ghcr.io/thpham/fireactions-images/ubuntu-24.04:latest",
      "imagePullPolicy": "IfNotPresent",
      "organization": "your-org",
      "labels": ["self-hosted", "fireactions", "linux"]
    },
    "firecracker": {
      "vcpuCount": 2,
      "memSizeMib": 4096,
      "kernelArgs": "console=ttyS0 reboot=k panic=1 pci=off"
    }
  }
]
```

**Deployment:**

```bash
# Build the image
nix build .#image-azure

# Upload to Azure (example)
az image create \
  --name fireactions-node \
  --resource-group mygroup \
  --source result/nixos.vhd \
  --os-type Linux

# Create VMSS with user-data
az vmss create \
  --name fireactions-runners \
  --resource-group mygroup \
  --image fireactions-node \
  --custom-data @cloud-init.yaml \
  --instance-count 3
```

### QCOW2 (`qcow2.nix`)

Production-ready image for QEMU/KVM-based platforms (libvirt, Proxmox, OpenStack).

**Features:**

- Full fireactions module with registry-cache
- Security-hardened kernel and network configuration
- Cloud-init with ConfigDrive/NoCloud datasources
- Bootstrap scripts for runtime configuration
- QEMU guest agent for VM management
- GRUB bootloader with EFI support
- Auto-resize root partition

**Configuration Flow:**

Same as Azure - uses shared bootstrap scripts from `src/`.

**Example User-data (NoCloud):**

```yaml
#cloud-config
write_files:
  - path: /etc/fireactions/github-app-id
    content: "123456"
    permissions: "0600"
  - path: /etc/fireactions/github-private-key.pem
    encoding: b64
    content: LS0tLS1CRUdJTi... # base64 -w0 < key.pem
    permissions: "0600"
  - path: /etc/fireactions/pools.json
    encoding: b64
    content: W3sibmFtZSI6IC... # base64 -w0 < pools.json
    permissions: "0644"
runcmd:
  - /etc/fireactions/bootstrap.sh
```

**Deployment (libvirt):**

```bash
# Build the image
nix build .#image-qcow2

# Import into libvirt
virsh vol-create-as default fireactions.qcow2 20G --format qcow2
virsh vol-upload default fireactions.qcow2 result/nixos.qcow2

# Boot with cloud-init
virt-install \
  --name fireactions-node \
  --memory 4096 \
  --vcpus 2 \
  --disk vol=default/fireactions.qcow2 \
  --cloud-init user-data=cloud-init.yaml \
  --import
```

**Deployment (Proxmox):**

```bash
# Build the image
nix build .#image-qcow2

# Upload to Proxmox storage
scp result/nixos.qcow2 proxmox:/var/lib/vz/images/

# Import disk to VM (VM ID 100)
qm importdisk 100 /var/lib/vz/images/nixos.qcow2 local-lvm

# Attach and configure via Proxmox UI or CLI
```

## Shared Scripts (`src/`)

Reusable scripts shared across cloud images for maintainability.

### `bootstrap.sh`

Main bootstrap script called by cloud-init `runcmd`. Reads configuration files written by cloud-init and generates the fireactions runtime config.

**Expected Files:**

- `/etc/fireactions/github-app-id` - GitHub App ID
- `/etc/fireactions/github-private-key.pem` - GitHub App private key
- `/etc/fireactions/pools.json` - Pool configuration

**Required Environment:**

- `KERNEL_PATH` - Path to Firecracker vmlinux kernel
- `PYTHON_WITH_YAML` - Python interpreter with PyYAML package

### `generate-config.py`

Python script that generates the complete fireactions configuration.

**Features:**

- Transforms user-friendly pool config to fireactions format
- Injects registry-cache metadata (containerd hosts.toml, BuildKit config, Docker daemon.json)
- Generates cloud-init user-data for Firecracker VMs

**Registry Cache Environment:**

- `REGISTRY_CACHE_ENABLED` - Set to "true" to enable
- `REGISTRY_CACHE_GATEWAY` - Gateway IP (e.g., 10.200.0.1)
- `ZOT_PORT` - Zot registry port (default: 5000)
- `ZOT_MIRRORS` - JSON of registry mirrors

## Adding New Cloud Images

To add support for a new cloud platform:

1. Create `images/<platform>.nix` importing the shared `common.nix`:

```nix
{ lib, modulesPath, ... }:

{
  imports = [
    # Platform-specific NixOS modules
    "${modulesPath}/virtualisation/<platform>-image.nix"
    # OR "${modulesPath}/profiles/<platform>-guest.nix"
    # Shared fireactions configuration (includes module, profiles, bootstrap)
    ./common.nix
  ];

  #
  # Platform-specific Boot Configuration
  #

  boot.loader.<bootloader> = {
    # Platform-specific bootloader settings
  };

  #
  # Platform-specific Cloud-init Configuration
  #

  services.cloud-init.settings = {
    # Configure appropriate datasource for the platform
    datasource_list = [ "<Platform>" "None" ];
    # Platform-specific datasource configuration
  };

  #
  # Platform-specific Overrides (optional)
  #

  # Override shared settings if needed (use lib.mkForce for conflicts)
  # services.fireactions.registryCache.squid.memoryCache = lib.mkForce "512MB";
}
```

2. Add to `flake.nix`:

```nix
mkImages = targetSys: {
  # ... existing images ...

  <platform> = nixos-generators.nixosGenerate {
    system = targetSys;
    format = "<format>";
    modules = [
      overlayModule  # Required for custom packages (zot, etc.)
      ./images/<platform>.nix
    ];
  };
};
```

3. The `common.nix` provides:

   - Fireactions module and production profiles (security-hardened, registry-cache, prod)
   - Kernel 6.12 with growPartition enabled
   - Cloud-init module configuration (common modules across all platforms)
   - Networking with firewall (SSH, API, metrics ports)
   - Fireactions service configuration with runtime config path
   - Bootstrap scripts (wrapper with registry-cache env, implementation, config generator)
   - Disk layout (root ext4, ESP boot)

4. Ensure the overlay module is included for custom packages (zot, fireactions, etc.).

## Security Considerations

All production images include:

- **Kernel Hardening:** Disabled kernel modules, restricted dmesg, ASLR
- **Network Isolation:** nftables firewall, restricted bridge access
- **Storage Security:** LUKS encryption support, noexec mounts
- **SSH Hardening:** Key-only auth, no root password login
- **Audit Logging:** Comprehensive logging for compliance

See `profiles/security-hardened.nix` for full security configuration.
