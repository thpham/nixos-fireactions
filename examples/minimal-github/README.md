# Minimal GitHub Actions Runner

The simplest possible setup for self-hosted GitHub Actions runners using Firecracker microVMs.

## What You Get

- Single NixOS host with fireactions orchestrator
- Up to 5 concurrent runners (configurable)
- Each job runs in an isolated microVM
- Prometheus metrics endpoint

## Prerequisites

- Server with KVM support (2GB+ RAM)
- GitHub App configured ([see guide](../../docs/GETTING_STARTED.md#step-1-create-a-github-app))
- SSH access to target server
- Nix with flakes enabled

## Setup Steps

### 1. Copy this example

```bash
cp -r examples/minimal-github ~/my-runners
cd ~/my-runners
```

### 2. Configure your organization

Edit `flake.nix` and update:

```nix
# Line 50: Your GitHub organization
organization = "YOUR-ORG-NAME";

# Line 92: Your SSH public key
"ssh-ed25519 AAAA... your-key-here"
```

### 3. Set up secrets

```bash
# Create secrets directory
mkdir -p secrets

# Create .sops.yaml
cat > secrets/.sops.yaml << 'EOF'
keys:
  - &admin age1your-public-key-here

creation_rules:
  - path_regex: secrets\.yaml$
    key_groups:
      - age:
          - *admin
EOF

# Create encrypted secrets
cat > secrets/secrets.yaml << 'EOF'
github-app-id: "123456"
github-app-key: |
  -----BEGIN RSA PRIVATE KEY-----
  YOUR_KEY_HERE
  -----END RSA PRIVATE KEY-----
EOF

# Encrypt (you must have sops and your age key configured)
sops -e -i secrets/secrets.yaml
```

### 4. Build and deploy

```bash
# Build the system
nix build .#nixosConfigurations.github-runner.config.system.build.toplevel

# Deploy with nixos-anywhere (replace IP)
nix run github:nix-community/nixos-anywhere -- \
  --flake .#github-runner \
  root@YOUR-SERVER-IP
```

### 5. Verify

```bash
# Check service status
ssh root@YOUR-SERVER-IP systemctl status fireactions

# View logs
ssh root@YOUR-SERVER-IP journalctl -u fireactions -f

# Check metrics
curl http://YOUR-SERVER-IP:8081/metrics
```

## Using the Runner

In your GitHub Actions workflows:

```yaml
name: My Workflow
on: [push]

jobs:
  build:
    runs-on: [self-hosted, fireactions, linux]
    steps:
      - uses: actions/checkout@v4
      - run: echo "Running in Firecracker!"
```

## Customization

### More runners

```nix
pools = [{
  name = "default";
  maxRunners = 10;  # Increase this
  # ...
}];
```

### More resources per VM

```nix
machine = {
  vcpu = 4;          # More CPU cores
  memSizeMib = 4096; # More RAM
};
```

### Multiple pools

```nix
pools = [
  {
    name = "small";
    maxRunners = 5;
    machine = { vcpu = 1; memSizeMib = 1024; };
    runner = {
      organization = "my-org";
      labels = [ "self-hosted" "small" ];
    };
  }
  {
    name = "large";
    maxRunners = 2;
    machine = { vcpu = 4; memSizeMib = 8192; };
    runner = {
      organization = "my-org";
      labels = [ "self-hosted" "large" ];
    };
  }
];
```

Then in workflows:
```yaml
jobs:
  small-job:
    runs-on: [self-hosted, small]
  large-job:
    runs-on: [self-hosted, large]
```
