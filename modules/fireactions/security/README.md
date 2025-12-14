# Firecracker Security Hardening Module

This module provides comprehensive security hardening for the NixOS-based Firecracker runner infrastructure.

## Quick Start

Enable the security-hardened profile in your host configuration:

```nix
{ ... }:
{
  imports = [ ./profiles/security-hardened.nix ];
}
```

Or enable individual features:

```nix
{ ... }:
{
  services.fireactions.security = {
    enable = true;

    network.enable = true;      # VM-to-VM blocking
    storage.enable = true;      # Secure deletion
    hardening.sysctls.enable = true;  # Kernel hardening

    # Optional: Maximum security
    jailer.enable = true;       # Process isolation
    storage.encryption.enable = true;
    hardening.disableHyperthreading = true;
  };
}
```

## Features

### 1. Kernel Hardening (`hardening.nix`)

Applies security-focused kernel sysctls:

| Sysctl                        | Value | Purpose                |
| ----------------------------- | ----- | ---------------------- |
| `kernel.dmesg_restrict`       | 1     | Restrict dmesg to root |
| `kernel.kptr_restrict`        | 2     | Hide kernel pointers   |
| `kernel.sysrq`                | 0     | Disable SysRq key      |
| `net.ipv4.conf.all.rp_filter` | 1     | Anti-spoofing          |
| `net.ipv4.tcp_syncookies`     | 1     | SYN flood protection   |

**Options:**

- `hardening.sysctls.enable` (default: true)
- `hardening.disableHyperthreading` (default: false) - Set true for Spectre mitigation
- `hardening.systemdHardening.enable` (default: true)

### 2. Network Isolation (`network.nix`)

Implements nftables rules for VM segmentation:

- **VM-to-VM blocking**: Prevents lateral movement between GitHub Actions jobs
- **Cloud metadata blocking**: Blocks 169.254.169.254 (Azure/AWS/GCP IMDS)
- **Rate limiting**: Limits new connections per VM (default: 100/sec)
- **Gateway access control**: Only allows specific ports (DNS, DHCP, proxy)

**Options:**

- `network.enable` (default when security enabled)
- `network.blockVmToVm` (default: true)
- `network.blockCloudMetadata` (default: true)
- `network.rateLimitConnections` (default: 100)
- `network.allowedHostPorts` (default: [53, 67, 3128, 3129, 5000])

### 3. Storage Security (`storage.nix`)

Provides data-at-rest protection:

- **LUKS encryption**: Full-disk encryption for the devmapper storage pool
- **Ephemeral keys**: New encryption key generated at each boot (stored in tmpfs)
- **Secure deletion**: TRIM/discard support for secure data removal
- **Tmpfs secrets**: Dedicated tmpfs mount for sensitive runtime data

**Options:**

- `storage.enable`
- `storage.encryption.enable` (default: true in security-hardened profile)
- `storage.secureDelete.enable` (default: true)
- `storage.secureDelete.method` ("discard" | "zero")
- `storage.tmpfsSecrets.enable` (default: true)

**Note:** Encryption always uses ephemeral keys - a new random key is generated at
each boot and stored in tmpfs. This is ideal for Firecracker because:

- VMs are ephemeral by design (destroyed after job completion)
- The devmapper thin-pool is recreated on each boot anyway
- No key management complexity
- Fresh encryption key on each boot = defense in depth

### 4. Jailer Integration (`jailer.nix`)

Wraps Firecracker with the jailer for enhanced isolation:

- **Unique UID/GID per VM**: Each microVM runs as a different user
- **Chroot isolation**: VMs run in isolated filesystem
- **Automatic cleanup**: Orphaned UIDs and chroot directories cleaned periodically

**Options:**

- `jailer.enable` (default: false - requires testing)
- `jailer.uidRangeStart` (default: 100000)
- `jailer.uidRangeEnd` (default: 165535)
- `jailer.chrootBaseDir` (default: "/srv/jailer")
- `jailer.cleanupInterval` (default: "5m")

## Verification

Run the verification script after deployment:

```bash
./tests/verify-security.sh --verbose
```

To test VM isolation (requires a running VM):

```bash
./tests/verify-security.sh --vm-ip 10.200.0.2
```

## Security Recommendations

### Minimum (Default Profile)

- Kernel sysctls hardening
- VM-to-VM network isolation
- Cloud metadata blocking
- Secure deletion
- LUKS encryption with ephemeral key

### Maximum Security

```nix
services.fireactions.security = {
  enable = true;

  hardening.disableHyperthreading = true;  # -50% vCPUs

  jailer.enable = true;

  storage.encryption.enable = true;  # Already enabled in security-hardened profile
};
```

## Troubleshooting

### VM cannot access internet

Check nftables rules:

```bash
nft list table inet fireactions_isolation
```

Ensure established connections are allowed and the bridge interface is correct.

### Jailer fails to start

1. Check UID pool status:

   ```bash
   /var/lib/fireactions/jailer/uid-pool/allocations.json
   ```

2. Verify chroot directory permissions:

   ```bash
   ls -la /srv/jailer/firecracker/
   ```

3. Check logs:
   ```bash
   journalctl -u fireactions -f
   ```

### Storage encryption

Encryption uses ephemeral keys by design - the key is generated at boot and stored
in tmpfs (`/run/fireactions/secrets/storage.key`). This means:

- **Data is lost on reboot** - this is intentional for ephemeral Firecracker VMs
- **Key is destroyed on power loss** - tmpfs is RAM-backed
- **No key management needed** - fresh key each boot

If the devmapper pool fails to initialize:

1. Check tmpfs secrets mount: `mount | grep /run/fireactions/secrets`
2. Verify cryptsetup is available: `which cryptsetup`
3. Check logs: `journalctl -u containerd-devmapper-setup -f`

## Architecture

```
fireactions daemon
    │
    ├── [jailer wrapper] (if jailer.enable)
    │       │
    │       └── firecracker (chroot + unique UID)
    │
    └── firecracker (direct, if jailer disabled)
            │
            └── microVM
                    │
                    ├── [nftables] VM-to-VM block
                    ├── [nftables] Metadata block
                    └── [nftables] Rate limit
```

## Files

| File            | Purpose                                    |
| --------------- | ------------------------------------------ |
| `default.nix`   | Module entry point, imports all submodules |
| `hardening.nix` | Kernel sysctls and systemd hardening       |
| `network.nix`   | nftables rules for VM isolation            |
| `storage.nix`   | LUKS encryption and secure deletion        |
| `jailer.nix`    | Jailer wrapper and UID pool management     |
