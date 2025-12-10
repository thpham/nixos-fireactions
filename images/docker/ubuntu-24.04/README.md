# Ubuntu 24.04 Fireactions Base Image

Base image for Fireactions GitHub Actions runners based on Ubuntu 24.04 LTS.

## Image Contents

- **Ubuntu 24.04 LTS** base system
- **GitHub Actions Runner** (v2.330.0)
- **Fireactions** agent (v0.4.0)
- **Docker CE** with BuildKit and Compose plugin
- **GitHub CLI** (gh)
- Development tools: git, build-essential, cmake, etc.

## Registry

```
ghcr.io/thpham/fireactions-images/ubuntu-24.04:latest
ghcr.io/thpham/fireactions-images/ubuntu-24.04:<version>
```

## Versioning

Format: `{fireactions_version}-{image_increment}`

Examples:

- `0.4.0-0.1.0` - First release with Fireactions 0.4.0
- `0.4.0-0.2.0` - Second release (bug fix, runner update)
- `0.5.0-0.1.0` - First release with Fireactions 0.5.0

## Creating a Release

### Option 1: Manual Dispatch (Recommended for testing)

1. Go to **Actions** → **Build Ubuntu 24.04 Base Image**
2. Click **Run workflow**
3. Enter version (e.g., `0.4.0-0.1.0`)
4. Click **Run workflow**

### Option 2: Git Tag (Recommended for releases)

```bash
# Create and push tag
git tag ubuntu-24.04/0.4.0-0.1.0
git push origin ubuntu-24.04/0.4.0-0.1.0
```

### Option 3: Push to Main

Any changes to `images/docker/ubuntu-24.04/**` on the `main` branch will trigger a build with `latest` tag.

## Workflow Triggers

| Trigger                      | Version Tag   | Latest Tag |
| ---------------------------- | ------------- | ---------- |
| `workflow_dispatch`          | ✅ (input)    | ✅         |
| `git tag ubuntu-24.04/x.y.z` | ✅ (from tag) | ✅         |
| Push to `main` (paths)       | ❌            | ✅         |

## Updating Components

### Bump Runner Version

1. Edit `Dockerfile`: Update `ARG RUNNER_VERSION="x.x.x"`
2. Edit `CHANGELOG.md`: Add new version entry
3. Create release tag: `ubuntu-24.04/0.4.0-0.x.0`

### Bump Fireactions Version

1. Edit `Dockerfile`: Update `FROM ghcr.io/hostinger/fireactions:x.x.x`
2. Edit `CHANGELOG.md`: Add new version entry
3. Create release tag: `ubuntu-24.04/0.x.0-0.1.0` (reset increment)

## Architecture Support

Built natively on:

- `linux/amd64` (ubuntu-latest runner)
- `linux/arm64` (ubuntu-24.04-arm runner)

## Files

```
ubuntu-24.04/
├── Dockerfile          # Multi-stage build definition
├── CHANGELOG.md        # Version history
├── README.md           # This file
└── overlay/
    └── etc/
        ├── hosts                       # Hostname config
        ├── cloud/cloud.cfg.d/
        │   └── 99-fireactions.cfg      # cloud-init datasource config
        └── systemd/
            ├── system/
            │   └── fireactions.service # Runner agent service
            └── network/
                └── 10-eth0.network     # systemd-networkd config
```

## DNS Configuration

DNS is configured via cloud-init's `resolv_conf` module:

1. Host injects gateway IP (dnsmasq) via cloud-init user-data
2. cloud-init writes `/etc/resolv.conf` with gateway as nameserver
3. dnsmasq intercepts registry domains and points to local proxy
