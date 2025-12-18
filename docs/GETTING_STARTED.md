# Getting Started with nixos-fireactions

This guide walks you through setting up self-hosted GitHub Actions runners using Firecracker microVMs. By the end, you'll have a working runner infrastructure that auto-scales based on demand.

## Table of Contents

1. [Overview](#overview)
2. [Prerequisites Checklist](#prerequisites-checklist)
3. [Step 1: Create a GitHub App](#step-1-create-a-github-app)
4. [Step 2: Set Up Your Local Environment](#step-2-set-up-your-local-environment)
5. [Step 3: Configure Secrets](#step-3-configure-secrets)
6. [Step 4: Deploy Your First Runner](#step-4-deploy-your-first-runner)
7. [Step 5: Verify the Deployment](#step-5-verify-the-deployment)
8. [Step 6: Run a Test Workflow](#step-6-run-a-test-workflow)
9. [Next Steps](#next-steps)
10. [Troubleshooting](#troubleshooting)

---

## Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        Your Server                               │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │                   fireactions                            │    │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐      │    │
│  │  │ Firecracker │  │ Firecracker │  │ Firecracker │ ...  │    │
│  │  │   microVM   │  │   microVM   │  │   microVM   │      │    │
│  │  │  (Runner 1) │  │  (Runner 2) │  │  (Runner N) │      │    │
│  │  └─────────────┘  └─────────────┘  └─────────────┘      │    │
│  └─────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
                       ┌─────────────┐
                       │   GitHub    │
                       │   Actions   │
                       └─────────────┘
```

**What you'll deploy:**
- A NixOS host running the `fireactions` orchestrator
- Auto-scaling pool of Firecracker microVMs as GitHub Actions runners
- Each job runs in an isolated, ephemeral VM (destroyed after completion)

**Time required:** ~30 minutes for first deployment

---

## Prerequisites Checklist

Before starting, ensure you have:

### Required

- [ ] **Server with KVM support** (2GB+ RAM, modern CPU with virtualization)
  - DigitalOcean: 2GB+ Droplet (s-1vcpu-2gb or larger)
  - Hetzner: Any cloud server
  - Bare metal: Any KVM-capable hardware

- [ ] **SSH access** to the target server (root access required for initial deployment)

- [ ] **Nix installed** on your workstation ([install guide](https://nixos.org/download))

- [ ] **GitHub organization** (or personal account for testing)

### Recommended

- [ ] **Flakes enabled** in your Nix configuration

Run this to verify your local setup:

```bash
# Check Nix is installed and flakes work
nix --version
nix flake show github:thpham/nixos-fireactions

# Check SSH access to your server
ssh root@<your-server-ip> "cat /proc/cpuinfo | grep -c vmx || cat /proc/cpuinfo | grep -c svm"
# Should output a number > 0 (indicates KVM support)
```

---

## Step 1: Create a GitHub App

GitHub Apps provide secure authentication for self-hosted runners.

### 1.1 Create the App

1. Go to **GitHub → Settings → Developer settings → GitHub Apps → New GitHub App**
2. Fill in:
   - **Name**: `My Fireactions Runner` (must be unique)
   - **Homepage URL**: `https://github.com/your-org`
   - **Webhook**: Uncheck "Active" (not needed)

3. Set **Permissions**:

   | Category | Permission | Access |
   |----------|-----------|--------|
   | Repository | Actions | Read & Write |
   | Repository | Administration | Read & Write |
   | Repository | Checks | Read & Write |
   | Repository | Metadata | Read-only |
   | Organization | Self-hosted runners | Read & Write |

4. Click **Create GitHub App**

### 1.2 Note Your App ID

After creation, you'll see your **App ID** at the top of the page. Save this.

```
App ID: 123456  ← Note this number
```

### 1.3 Generate Private Key

1. Scroll down to **Private keys**
2. Click **Generate a private key**
3. A `.pem` file will download - keep this safe!

### 1.4 Install the App

1. Go to **Install App** in the sidebar
2. Click **Install** next to your organization
3. Choose repositories (or select "All repositories")
4. Click **Install**

---

## Step 2: Set Up Your Local Environment

### 2.1 Clone the Repository

```bash
git clone https://github.com/thpham/nixos-fireactions
cd nixos-fireactions
```

### 2.2 Enter Development Shell

```bash
nix develop
```

This provides all required tools: `colmena`, `sops`, `age`, `ssh-to-age`.

### 2.3 Generate Your Admin Key

```bash
# Create age key directory
mkdir -p ~/.config/sops/age

# Generate your personal encryption key
age-keygen -o ~/.config/sops/age/keys.txt

# Show your public key (needed for .sops.yaml)
age-keygen -y ~/.config/sops/age/keys.txt
```

Output will look like:

```
Public key: age1abc123xyz...
```

---

## Step 3: Configure Secrets

### 3.1 Update .sops.yaml

Edit `secrets/.sops.yaml` and replace the admin key with yours:

```yaml
keys:
  - &admin age1abc123xyz...  # Your public key from Step 2.3

creation_rules:
  - path_regex: secrets\.yaml$
    key_groups:
      - age:
          - *admin
```

### 3.2 Create Secrets File

```bash
cd secrets

# Create from example
cp secrets.yaml.example secrets.yaml

# Edit with sops (opens in $EDITOR, encrypts on save)
sops secrets.yaml
```

Add your GitHub App credentials:

```yaml
github_app_id: "123456"  # Your App ID from Step 1.2
github_app_private_key: |
  -----BEGIN RSA PRIVATE KEY-----
  (paste entire contents of your .pem file here)
  -----END RSA PRIVATE KEY-----
```

Save and exit. The file is now encrypted.

---

## Step 4: Deploy Your First Runner

### 4.1 Initial Deployment

Deploy to your server using the deploy script:

```bash
# Replace with your actual values
./deploy/deploy.sh \
  --provider do \
  --name my-first-runner \
  --tags prod,github-runners,medium \
  <your-server-ip>
```

**Provider options:**
| Provider | Description | Disk Device |
|----------|-------------|-------------|
| `do` | DigitalOcean | /dev/vda |
| `hetzner` | Hetzner Cloud | /dev/sda |
| `generic` | Generic VM | /dev/vda |
| `nvme` | NVMe systems | /dev/nvme0n1 |
| `baremetal` | Bare metal | /dev/sda |

**Size tags:**
| Tag | Runners | RAM/vCPU per VM |
|-----|---------|-----------------|
| `small` | 2 max | 1GB / 1vCPU |
| `medium` | 5 max | 2GB / 2vCPU |
| `large` | 10 max | 4GB / 4vCPU |

The deployment will:
1. Install NixOS via nixos-anywhere
2. Configure disk partitioning
3. Set up base system
4. Register host in `hosts/registry.json`

Wait for completion (~5-10 minutes).

### 4.2 Add Host's Age Key

After deployment, add the host's key for secrets decryption:

```bash
# Get the host's age public key
ssh root@<your-server-ip> "cat /etc/ssh/ssh_host_ed25519_key.pub" | ssh-to-age
```

Add this key to `secrets/.sops.yaml`:

```yaml
keys:
  - &admin age1abc123xyz...
  - &my-first-runner age1hostkey...  # Add this

creation_rules:
  - path_regex: secrets\.yaml$
    key_groups:
      - age:
          - *admin
          - *my-first-runner  # Add this
```

Re-encrypt secrets:

```bash
sops updatekeys secrets/secrets.yaml
```

### 4.3 Apply Full Configuration

Now apply profiles and start the runner service:

```bash
colmena apply --on my-first-runner --build-on-target
```

This will:
- Apply tag-based profiles (prod, github-runners, medium)
- Start the fireactions service
- Begin polling GitHub for jobs

---

## Step 5: Verify the Deployment

### 5.1 Check Service Status

```bash
ssh root@<your-server-ip>

# Check fireactions service
systemctl status fireactions

# View logs
journalctl -u fireactions -f
```

You should see:

```
Starting fireactions server...
Connected to GitHub App
Pool 'default': 0/5 runners active
```

### 5.2 Check Metrics

```bash
# From your workstation
curl http://<your-server-ip>:8081/metrics
```

### 5.3 Verify in GitHub

1. Go to your GitHub organization
2. Navigate to **Settings → Actions → Runners**
3. You should see your runner pool (runners spin up on demand)

---

## Step 6: Run a Test Workflow

Create a test workflow in any repository in your organization:

```yaml
# .github/workflows/test-fireactions.yml
name: Test Fireactions Runner

on:
  workflow_dispatch:  # Manual trigger

jobs:
  test:
    runs-on: [self-hosted, fireactions]
    steps:
      - name: Hello from Firecracker
        run: |
          echo "Running in Firecracker microVM!"
          uname -a
          cat /etc/os-release
```

Trigger it manually from the Actions tab. Watch your runner logs:

```bash
journalctl -u fireactions -f
```

You should see:
1. Job received
2. Firecracker VM started
3. Job executed
4. VM destroyed

---

## Next Steps

### Scale Your Fleet

Deploy additional runners:

```bash
./deploy/deploy.sh -p do -n runner-2 -t prod,github-runners,large <ip-2>
./deploy/deploy.sh -p hetzner -n runner-3 -t prod,github-runners,medium <ip-3>
```

Update all at once:

```bash
colmena apply --on @prod --build-on-target
```

### Enable Registry Cache

Speed up image pulls with a local cache:

```bash
# Add registry-cache tag to your host
# Edit hosts/registry.json or redeploy with:
./deploy/deploy.sh -p do -n my-runner -t prod,github-runners,registry-cache,medium <ip>
```

### Security Hardening

Enable additional security features:

```nix
# profiles/security-hardened.nix is available
# Add 'security-hardened' to your tags
```

### Custom Profiles

Create profiles for your specific needs:

```nix
# profiles/my-custom.nix
{ lib, ... }: {
  services.fireactions.pools = lib.mkDefault [{
    name = "custom";
    maxRunners = 3;
    runner = {
      labels = [ "self-hosted" "custom" "linux" ];
      organization = "my-org";
    };
  }];
}
```

Add to `profiles/default.nix` and use `--tags ...,my-custom`.

---

## Troubleshooting

### Common Issues

#### "Permission denied" during deployment

```bash
# Ensure you have root SSH access
ssh root@<ip> "whoami"

# If using key-based auth, ensure your key is loaded
ssh-add ~/.ssh/your_key
```

#### Fireactions service fails to start

```bash
# Check logs for specific error
journalctl -u fireactions -e

# Common issue: GitHub App credentials not decrypted
ls -la /run/secrets/
# Should show github-app-id and github-app-key
```

#### Runners don't appear in GitHub

1. Verify App ID is correct
2. Check private key format (must include headers)
3. Ensure App is installed on your organization
4. Check fireactions logs for authentication errors

#### VM fails to start

```bash
# Check KVM is available
ls -la /dev/kvm

# Check containerd is running
systemctl status containerd

# Check available memory
free -h
```

#### Jobs stuck in "Queued"

1. Verify runner labels match workflow `runs-on`
2. Check fireactions logs for errors
3. Ensure `minRunners >= 1` for faster startup

### Getting Help

- Check logs: `journalctl -u fireactions -f`
- Verify registry: `cat hosts/registry.json`
- List hosts: `./deploy/deploy.sh list`
- GitHub issues: https://github.com/thpham/nixos-fireactions/issues

---

## Quick Reference

```bash
# Deploy new host
./deploy/deploy.sh -p <provider> -n <name> -t <tags> <ip>

# List registered hosts
./deploy/deploy.sh list

# Update single host
colmena apply --on <name> --build-on-target

# Update by tag
colmena apply --on @<tag> --build-on-target

# Update all hosts
colmena apply --build-on-target

# View logs
ssh root@<ip> journalctl -u fireactions -f

# Check metrics
curl http://<ip>:8081/metrics
```
