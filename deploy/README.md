# Deployment Guide

This guide covers deploying NixOS with fireactions to various machine types using `nixos-anywhere` for initial installation and `colmena` for ongoing fleet management.

## Prerequisites

1. **Management machine** with Nix and flakes enabled
2. **Target machine** accessible via SSH (rescue mode, live ISO, or existing Linux)
3. **SSH public key** added to `deploy/base.nix` (see [SSH Key Setup](#ssh-key-setup))
4. **sops-nix** configured with your admin age key (see `secrets/.sops.yaml`)

## SSH Key Setup

Before deploying, add your SSH public key to `deploy/base.nix`:

```bash
# Get your public key
cat ~/.ssh/id_ed25519.pub
```

Edit `deploy/base.nix` line ~45:

```nix
users.users.root.openssh.authorizedKeys.keys = [
  "ssh-ed25519 AAAAC3Nza... your-key-here"
];
```

## Deployment Scenarios

### Cloud VMs (DigitalOcean, Hetzner)

Cloud VMs typically have SSH access pre-configured in rescue mode.

```bash
# DigitalOcean
./deploy/deploy.sh --provider do --name do-runner-1 \
  --tags dev,github-runners,fireactions-small \
  167.71.100.50

# Hetzner
./deploy/deploy.sh --provider hetzner --name hetzner-runner-1 \
  --tags prod,github-runners,fireactions-medium \
  95.217.xxx.xxx
```

### Bare Metal / Desktop from NixOS Live ISO

For bare-metal machines or desktops where kexec may fail (common on AMD hardware), boot from a NixOS live ISO first.

#### Step 1: Prepare Bootable USB

Download NixOS minimal ISO from https://nixos.org/download and write to USB:

```bash
# macOS
sudo dd if=nixos-minimal-*.iso of=/dev/diskX bs=4M

# Linux
sudo dd if=nixos-minimal-*.iso of=/dev/sdX bs=4M status=progress
```

#### Step 2: Boot Target and Enable SSH

On the target machine (physical access required):

```bash
# Set password for nixos user
passwd

# Get IP address
ip addr
```

#### Step 3: Deploy from Management Machine

```bash
# Enter dev shell (includes sshpass)
nix develop

# Deploy with password authentication
SSHPASS='your-password' ./deploy/deploy.sh \
  --provider nvme \
  --name nixtower \
  --user nixos \
  --env-password \
  --tags dev,github-runners,fireactions-small \
  192.168.55.56
```

The `--user nixos` flag is required because the NixOS live ISO uses `nixos` as the default user, not `root`.

nixos-anywhere automatically detects the NixOS installer environment and skips kexec (which can fail on AMD hardware).

#### Step 4: Wait for Reboot

After successful deployment:

- Machine reboots automatically
- IP may change (check your DHCP server)
- Update `hosts/registry.json` if IP changed

#### Step 5: Register Host for Secrets (sops-nix)

For the new host to decrypt secrets (runner tokens, API keys, etc.), you must add its age key to `secrets/.sops.yaml`:

```bash
# Get the host's age key from its SSH host key
ssh-keyscan <host-ip> 2>/dev/null | ssh-to-age
# Or if you can SSH directly:
ssh root@<host-ip> "cat /etc/ssh/ssh_host_ed25519_key.pub" | ssh-to-age
```

Edit `secrets/.sops.yaml`:

```yaml
keys:
  # ... existing keys ...
  - &my-new-host age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

creation_rules:
  - path_regex: secrets\.yaml$
    key_groups:
      - age:
          - *admin
          - *my-new-host  # Add the new host anchor here
```

Re-encrypt secrets so the new host can decrypt them:

```bash
# Enter dev shell (includes sops)
nix develop

# Re-encrypt with the new key
sops updatekeys secrets/secrets.yaml
```

Deploy to push the updated configuration:

```bash
colmena apply --on my-new-host --build-on-target
```

### Existing NixOS System (with working kexec)

If kexec works on your hardware:

```bash
./deploy/deploy.sh --provider nvme --name my-server 192.168.1.100
```

If kexec fails (machine freezes), use the [Live ISO method](#bare-metal--desktop-from-nixos-live-iso) instead.

## Provider Types

| Provider    | Disk Device    | Use Case                                     |
| ----------- | -------------- | -------------------------------------------- |
| `do`        | `/dev/vda`     | DigitalOcean droplets                        |
| `hetzner`   | `/dev/sda`     | Hetzner Cloud/Dedicated                      |
| `generic`   | `/dev/vda`     | Generic KVM/QEMU VMs                         |
| `nvme`      | `/dev/nvme0n1` | NVMe-based systems (modern desktops/servers) |
| `baremetal` | `/dev/sda`     | Bare metal with SATA/SAS                     |
| `auto`      | auto-detect    | Generates hardware-configuration.nix         |

## Command Reference

### deploy.sh Options

```
Usage: ./deploy.sh [OPTIONS] <ip>
       ./deploy.sh list
       ./deploy.sh unregister <name>

Options:
  --provider, -p TYPE   Provider: do, hetzner, generic, nvme, baremetal (default), auto
  --name, -n NAME       Host name (default: auto-generated)
  --tags, -t TAG1,TAG2  Comma-separated tags for profile selection
  --arch, -a ARCH       Architecture: x86_64 (default) or aarch64
  --user, -u USER       SSH user (default: root, use 'nixos' for live ISO)
  --env-password        Use password from SSHPASS environment variable
  --no-kexec            Skip kexec phase (manually, usually auto-detected)
```

### List Registered Hosts

```bash
./deploy/deploy.sh list
```

### Remove Host from Registry

```bash
./deploy/deploy.sh unregister my-host
```

## Fleet Management with Colmena

After initial deployment, use colmena for configuration updates:

```bash
# Update single host
colmena apply --on nixtower --build-on-target

# Update all hosts with a specific tag
colmena apply --on @dev --build-on-target

# Update all hosts
colmena apply --build-on-target
```

## Tag-Based Profiles

Profiles are applied based on tags specified during deployment:

### Environment Profiles

- `dev` - Debug mode, verbose logging
- `prod` - Production hardening

### Workload Profiles

- `github-runners` - GitHub Actions runners
- `gitea-runners` - Gitea Actions runners
- `gitlab-runners` - GitLab CI runners

### Size Profiles

- `fireactions-small` - 1GB RAM, 1 vCPU, 1-2 runners
- `fireactions-medium` - 2GB RAM, 2 vCPU, 2-5 runners
- `fireactions-large` - 4GB RAM, 4 vCPU, 5-10 runners
- (similarly for `fireteact-*` and `fireglab-*`)

### Example Combinations

```bash
# GitHub Actions only (small)
--tags dev,github-runners,fireactions-small

# Multi-platform runners
--tags prod,github-runners,gitlab-runners,fireactions-medium,fireglab-medium

# With registry cache
--tags prod,github-runners,fireactions-large,registry-cache
```

## Troubleshooting

### SSH Connection Failed

```
ERROR: Cannot connect to nixos@192.168.55.64 with password
```

**Solutions:**

1. Verify password is set on target: `passwd`
2. Check IP address: `ip addr`
3. Ensure SSH is running: `systemctl status sshd`

### Kexec Fails / Machine Freezes

Some hardware (especially AMD) doesn't support kexec well. Use the NixOS live ISO method instead - nixos-anywhere automatically skips kexec when it detects an installer environment.

### Permission Denied After Deployment

```
root@192.168.55.56: Permission denied (publickey)
```

Your SSH key is not in the deployed system. Add it to `deploy/base.nix` and redeploy, or manually add it on the target:

```bash
# On target machine (physical access)
mkdir -p /root/.ssh
echo "ssh-ed25519 AAAAC3Nza... your-key" >> /root/.ssh/authorized_keys
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys
```

### IP Changed After Reboot

DHCP may assign a different IP. Update `hosts/registry.json`:

```json
{
  "nixtower": {
    "hostname": "192.168.55.56",  // <- Update this
    ...
  }
}
```

## File Overview

| File                      | Purpose                                       |
| ------------------------- | --------------------------------------------- |
| `deploy.sh`               | Main deployment script                        |
| `base.nix`                | Shared config (boot, SSH, firewall, packages) |
| `disko.nix`               | Disk partitioning (LVM on GPT)                |
| `secrets.nix`             | sops-nix configuration                        |
| `digitalocean.nix`        | DigitalOcean-specific settings                |
| `configuration.nix`       | Legacy entry point                            |
| `../secrets/.sops.yaml`   | Age keys for secret encryption                |
| `../secrets/secrets.yaml` | Encrypted secrets (runner tokens, API keys)   |
| `../hosts/registry.json`  | Deployed hosts registry                       |
