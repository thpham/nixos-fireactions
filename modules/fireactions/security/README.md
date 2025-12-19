# Fireactions Security Module

Fireactions-specific security hardening for GitHub Actions runners using Firecracker microVMs.

## Architecture

Security is split between two layers:

```
┌─────────────────────────────────────────────────────────────┐
│              microvm-base.security (shared)                 │
│  Host-level hardening that benefits ALL runner technologies │
├─────────────────────────────────────────────────────────────┤
│  - Kernel sysctls (kptr_restrict, dmesg_restrict, etc.)     │
│  - SMT/Hyperthreading disable (Spectre mitigation)          │
│  - LUKS encryption for containerd devmapper                 │
│  - Tmpfs secrets mount                                      │
│  - Secure deletion config for containerd                    │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│           fireactions.security (runner-specific)            │
│  Fireactions-specific security features                     │
├─────────────────────────────────────────────────────────────┤
│  - Network isolation (VM-to-VM blocking, nftables)          │
│  - Cloud metadata protection (169.254.169.254)              │
│  - Systemd service hardening                                │
│  - Secure snapshot cleanup timer                            │
└─────────────────────────────────────────────────────────────┘
```

## Quick Start

Enable the security-hardened profile (recommended):

```nix
{ ... }:
{
  imports = [ ./profiles/security-hardened.nix ];
}
```

Or configure manually:

```nix
{ ... }:
{
  # Shared host-level security (benefits all runners)
  services.microvm-base.security = {
    enable = true;
    hardening.sysctls.enable = true;
    storage = {
      enable = true;
      encryption.enable = true;
      tmpfsSecrets.enable = true;
    };
  };

  # Fireactions-specific security
  services.fireactions.security = {
    enable = true;
    network = {
      enable = true;
      blockVmToVm = true;
      blockCloudMetadata = true;
    };
    storage.enable = true;
  };
}
```

## Security Model

Firecracker's KVM-based VM isolation is the **primary security boundary**. Each GitHub Actions job runs in its own isolated virtual machine with:

- Separate kernel instance
- Isolated memory space
- No shared filesystem with host
- Network namespace isolation (via CNI)

This module adds defense-in-depth layers on top of Firecracker's VM isolation.

> **Note:** The Firecracker jailer was evaluated but not implemented due to NixOS incompatibility. NixOS binaries are dynamically linked and require `/nix/store` access, which conflicts with the jailer's chroot model.

## Module Structure

```
modules/fireactions/security/
├── default.nix      # Entry point, services.fireactions.security.enable
├── hardening.nix    # Systemd service isolation
├── network.nix      # nftables rules for VM network isolation
└── storage.nix      # Secure snapshot cleanup timer
```

## Features

### 1. Systemd Service Hardening (`hardening.nix`)

Applies enhanced isolation to the fireactions systemd service:

| Setting                   | Purpose                          |
| ------------------------- | -------------------------------- |
| `SystemCallFilter`        | Allow only necessary syscalls    |
| `MemoryDenyWriteExecute`  | Prevent code injection           |
| `RestrictAddressFamilies` | Limit network protocols          |
| `RestrictNamespaces`      | Limit namespace creation         |
| `ProtectKernelTunables`   | Prevent kernel parameter changes |

**Options:**

- `hardening.systemdHardening.enable` (default: true)

### 2. Network Isolation (`network.nix`)

Implements nftables rules for VM segmentation:

- **VM-to-VM blocking**: Prevents lateral movement between GitHub Actions jobs
- **Cloud metadata blocking**: Blocks 169.254.169.254 (Azure/AWS/GCP IMDS)
- **Rate limiting**: Limits new connections per VM (default: 100/sec)
- **Gateway access control**: Only allows specific ports (DNS, DHCP, proxy)

**Options:**

| Option                         | Default                    | Purpose                  |
| ------------------------------ | -------------------------- | ------------------------ |
| `network.enable`               | false                      | Enable network isolation |
| `network.blockVmToVm`          | true                       | Block VM-to-VM traffic   |
| `network.blockCloudMetadata`   | true                       | Block cloud IMDS access  |
| `network.rateLimitConnections` | 100                        | Max new conn/sec per VM  |
| `network.allowedHostPorts`     | [53, 67, 3128, 3129, 5000] | TCP ports to gateway     |
| `network.allowedHostUdpPorts`  | [53, 67]                   | UDP ports to gateway     |
| `network.additionalRules`      | ""                         | Custom nftables rules    |

### 3. Storage Cleanup (`storage.nix`)

Provides secure cleanup of fireactions VM snapshots:

- **Periodic cleanup timer**: Runs every 30 minutes
- **Shutdown cleanup**: Secure deletion on system shutdown
- **TRIM/discard or zero-fill**: Choice of deletion method

**Options:**

| Option                        | Default   | Purpose                    |
| ----------------------------- | --------- | -------------------------- |
| `storage.enable`              | false     | Enable storage cleanup     |
| `storage.secureDelete.enable` | true      | Enable secure deletion     |
| `storage.secureDelete.method` | "discard" | "discard" (TRIM) or "zero" |

## Host-Level Security (microvm-base)

The following security features are now in `microvm-base.security` and benefit all runner technologies (fireactions, fireteact, etc.):

| Feature                | Option Path                                                      |
| ---------------------- | ---------------------------------------------------------------- |
| Kernel sysctls         | `services.microvm-base.security.hardening.sysctls.enable`        |
| SMT/HT disable         | `services.microvm-base.security.hardening.disableHyperthreading` |
| LUKS encryption        | `services.microvm-base.security.storage.encryption.enable`       |
| Tmpfs secrets          | `services.microvm-base.security.storage.tmpfsSecrets.enable`     |
| Secure deletion config | `services.microvm-base.security.storage.secureDelete.enable`     |

See `modules/microvm-base/security/README.md` for details.

## Verification

Check nftables rules:

```bash
nft list table inet fireactions_isolation
```

Verify systemd hardening:

```bash
systemctl show fireactions --property=SystemCallFilter
systemctl show fireactions --property=MemoryDenyWriteExecute
```

Check cleanup timer:

```bash
systemctl status fireactions-snapshot-cleanup.timer
```

## Security Recommendations

### Minimum (security-hardened profile defaults)

- Kernel sysctls hardening
- VM-to-VM network isolation
- Cloud metadata blocking
- Secure deletion
- LUKS encryption with ephemeral key

### Maximum Security

```nix
{
  services.microvm-base.security.hardening.disableHyperthreading = true;  # -50% vCPUs
}
```

## Troubleshooting

### VM cannot access internet

Check nftables rules:

```bash
nft list table inet fireactions_isolation
```

Ensure established connections are allowed and the bridge interface is correct.

### Cleanup timer not running

```bash
systemctl status fireactions-snapshot-cleanup.timer
journalctl -u fireactions-snapshot-cleanup
```
