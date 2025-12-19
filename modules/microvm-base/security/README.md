# microvm-base Security Module

Shared host-level security hardening for all Firecracker-based runner technologies.

## Overview

This module provides infrastructure-level security that benefits all runner technologies (fireactions, fireteact, and future additions):

- **Kernel hardening**: Restrictive sysctls for the host system
- **CPU mitigations**: Optional SMT/Hyperthreading disable for Spectre protection
- **Storage encryption**: LUKS encryption for containerd devmapper pool
- **Secure secrets**: Tmpfs mount for sensitive runtime data
- **Snapshot cleanup**: Secure deletion of devmapper snapshots on shutdown

## Module Structure

```
modules/microvm-base/security/
├── default.nix      # Entry point, services.microvm-base.security.enable
├── hardening.nix    # Kernel sysctls and SMT disable
└── storage.nix      # LUKS encryption and tmpfs secrets
```

## Quick Start

```nix
{
  services.microvm-base.security = {
    enable = true;

    hardening = {
      sysctls.enable = true;
      # disableHyperthreading = true;  # Maximum security, -50% vCPUs
    };

    storage = {
      enable = true;
      encryption.enable = true;
      tmpfsSecrets.enable = true;
    };
  };
}
```

Or use the `security-hardened` profile which configures everything:

```nix
{
  imports = [ ./profiles/security-hardened.nix ];
}
```

## Features

### 1. Kernel Hardening (`hardening.nix`)

Applies security-focused kernel sysctls:

| Sysctl                               | Value | Purpose                  |
| ------------------------------------ | ----- | ------------------------ |
| `kernel.kptr_restrict`               | 2     | Hide kernel pointers     |
| `kernel.dmesg_restrict`              | 1     | Restrict dmesg to root   |
| `kernel.sysrq`                       | 0     | Disable SysRq key        |
| `kernel.perf_event_paranoid`         | 3     | Restrict perf_event      |
| `kernel.unprivileged_bpf_disabled`   | 1     | Disable unprivileged BPF |
| `net.core.bpf_jit_harden`            | 2     | Harden BPF JIT           |
| `net.ipv4.conf.all.rp_filter`        | 1     | Anti-spoofing            |
| `net.ipv4.tcp_syncookies`            | 1     | SYN flood protection     |
| `net.ipv4.conf.all.accept_redirects` | 0     | Disable ICMP redirects   |

**Options:**

| Option                            | Default | Purpose                          |
| --------------------------------- | ------- | -------------------------------- |
| `hardening.sysctls.enable`        | true    | Enable kernel sysctl hardening   |
| `hardening.disableHyperthreading` | false   | Disable SMT (Spectre mitigation) |

### 2. Storage Security (`storage.nix`)

Provides data-at-rest protection for the containerd devmapper pool:

**LUKS Encryption:**

- AES-XTS-PLAIN64 with 512-bit key
- Argon2id key derivation
- Ephemeral key generated at each boot (stored in tmpfs)

**Tmpfs Secrets:**

- Dedicated mount at `/run/microvm-base/secrets`
- Mode 0700, noswap, nodev, nosuid, noexec
- Encryption keys stored here (never touches disk)

**Options:**

| Option                        | Default                     | Purpose                            |
| ----------------------------- | --------------------------- | ---------------------------------- |
| `storage.enable`              | false                       | Enable storage security            |
| `storage.encryption.enable`   | false                       | Enable LUKS encryption             |
| `storage.secureDelete.enable` | true                        | Enable discard for secure deletion |
| `storage.secureDelete.method` | "discard"                   | "discard" (TRIM) or "zero"         |
| `storage.tmpfsSecrets.enable` | true                        | Mount tmpfs for secrets            |
| `storage.tmpfsSecrets.size`   | "64M"                       | Tmpfs size                         |
| `storage.tmpfsSecrets.path`   | "/run/microvm-base/secrets" | Mount path                         |

**Snapshot Cleanup:**

When `secureDelete` is enabled, the module also provides:

- `microvm-snapshot-cleanup.service`: Runs on shutdown to securely delete all `containerd-pool-snap-*` devices
- `microvm-snapshot-cleanup.timer`: Periodic cleanup every 30 minutes

This cleanup service handles all runner technologies (fireactions, fireteact, etc.) since they share the same containerd devmapper pool.

## Ephemeral Encryption Design

The LUKS encryption uses **ephemeral keys** - a new random key is generated at each boot:

```
Boot → Generate random key → Store in tmpfs → Format/Open LUKS → Create thin-pool
```

This design is intentional for Firecracker microVMs because:

1. **VMs are ephemeral**: Destroyed after job completion
2. **Thin-pool is recreated**: devmapper pool reinitializes on boot
3. **No key management**: Fresh key each boot, no secrets to rotate
4. **Defense in depth**: Even if disk is stolen, data is unrecoverable

**Note:** Data is lost on reboot. This is expected and desired for ephemeral CI/CD workloads.

## Relationship with Runner Modules

```
┌────────────────────────────────────────────────────┐
│              microvm-base.security                 │
│  (this module - shared host-level security)        │
├────────────────────────────────────────────────────┤
│  - Kernel hardening (sysctls, SMT disable)         │
│  - Storage encryption (LUKS, tmpfs secrets)        │
│  - Snapshot cleanup (all runners share pool)       │
└────────────────────────────────────────────────────┘
                        │
          ┌─────────────┴─────────────┐
          ▼                           ▼
┌──────────────────────┐    ┌──────────────────────┐
│ fireactions (built-in│    │ fireteact (built-in  │
│ security in service) │    │ security in service) │
│ - Network isolation  │    │ - Network isolation  │
│ - Systemd hardening  │    │ - Systemd hardening  │
└──────────────────────┘    └──────────────────────┘
```

**Note:** Runner-specific security (network isolation, systemd hardening) is
built directly into each runner module and enabled automatically when the
runner is enabled. No separate security configuration is needed.

## Verification

Check sysctls are applied:

```bash
sysctl kernel.kptr_restrict
sysctl kernel.dmesg_restrict
sysctl net.ipv4.conf.all.rp_filter
```

Verify LUKS encryption (if enabled):

```bash
cryptsetup status containerd-data-crypt
dmsetup status containerd-pool
```

Check tmpfs secrets mount:

```bash
mount | grep /run/microvm-base/secrets
ls -la /run/microvm-base/secrets/
```

Check snapshot cleanup timer:

```bash
systemctl status microvm-snapshot-cleanup.timer
systemctl list-timers microvm-snapshot-cleanup.timer
```

List current snapshots:

```bash
ls -la /dev/mapper/containerd-pool-snap-*
```

## Troubleshooting

### Devmapper pool fails to create

Check the setup service:

```bash
journalctl -u containerd-devmapper-setup -f
```

Common issues:

- Missing cryptsetup package
- Tmpfs not mounted (secrets path unavailable)
- Existing pool with stale LUKS header (key mismatch)

### LUKS key mismatch after reboot

This is expected! Ephemeral keys mean a new key each boot. The setup service automatically detects this and re-creates the LUKS container:

```
LUKS header found → Try current key → Key mismatch → Wipe and recreate
```

This wipes all containerd data, which is fine for ephemeral workloads.
