# Ubuntu 24.04 Runner Images

Multi-target base image for Firecracker VM runners, supporting both GitHub Actions and Gitea Actions.

## Build Targets

| Target          | Platform       | Agent       | Runner Binary  |
| --------------- | -------------- | ----------- | -------------- |
| `github-runner` | GitHub Actions | fireactions | actions/runner |
| `gitea-runner`  | Gitea Actions  | fireteact   | act_runner     |

## Image Contents (Shared Base)

- **Ubuntu 24.04 LTS** base system
- **Docker CE** with BuildKit and Compose plugin
- **cloud-init** for MMDS metadata integration
- **systemd** with networking
- Development tools: git, build-essential, cmake, etc.

### GitHub Runner Target

- **GitHub Actions Runner** (v2.322.0)
- **fireactions** agent (v0.4.0)
- **GitHub CLI** (gh)

### Gitea Runner Target

- **act_runner** (v0.2.11)
- **fireteact** agent

## Registry

```
# GitHub Actions runner
ghcr.io/thpham/fireactions-images/ubuntu-24.04-github:latest
ghcr.io/thpham/fireactions-images/ubuntu-24.04-github:<version>

# Gitea Actions runner
ghcr.io/thpham/fireactions-images/ubuntu-24.04-gitea:latest
ghcr.io/thpham/fireactions-images/ubuntu-24.04-gitea:<version>
```

## Building Locally

```bash
# Build GitHub runner image
docker build --target github-runner -t ubuntu-24.04-github:latest .

# Build Gitea runner image
docker build --target gitea-runner -t ubuntu-24.04-gitea:latest .

# Build with specific versions
docker build --target github-runner \
  --build-arg RUNNER_VERSION=2.322.0 \
  -t ubuntu-24.04-github:latest .

docker build --target gitea-runner \
  --build-arg ACT_RUNNER_VERSION=0.2.11 \
  -t ubuntu-24.04-gitea:latest .
```

## Versioning

Format: `{runner_version}-{increment}`

Each target uses its runner binary version as the primary version component:

**GitHub Runner** (actions/runner):
- `2.322.0-1` - First release with runner 2.322.0
- `2.322.0-2` - Second release (agent update, bug fix)
- `2.323.0-1` - First release with runner 2.323.0

**Gitea Runner** (act_runner):
- `0.2.11-1` - First release with act_runner 0.2.11
- `0.2.11-2` - Second release (agent update, bug fix)
- `0.2.12-1` - First release with act_runner 0.2.12

## Creating a Release

### Option 1: Manual Dispatch (Development builds only)

1. Go to **Actions** → **Build Runner Images**
2. Click **Run workflow**
3. Select target: `github-runner` or `gitea-runner` (or `both`)
4. Enter version starting with `dev-` (e.g., `dev-test`, `dev-feature-x`)
5. Click **Run workflow**

> **Note**: Manual dispatch is restricted to `dev-*` versions only. Release versions must use git tags (Option 2).

### Option 2: Git Tag (Recommended for releases)

```bash
# GitHub runner release
git tag ubuntu-24.04-github/2.322.0-1
git push origin ubuntu-24.04-github/2.322.0-1

# Gitea runner release
git tag ubuntu-24.04-gitea/0.2.11-1
git push origin ubuntu-24.04-gitea/0.2.11-1
```

### Option 3: Push to Main

Any changes to `images/docker/ubuntu-24.04/**` on the `main` branch will trigger builds for both targets with `latest` tag.

## Workflow Triggers

| Trigger                            | Version Tag   | Latest Tag |
| ---------------------------------- | ------------- | ---------- |
| `workflow_dispatch`                | ✅ (input)    | ✅         |
| `git tag ubuntu-24.04-{platform}/*`| ✅ (from tag) | ✅         |
| Push to `main` (paths)             | ❌            | ✅         |

## Updating Components

### Bump Runner Version

1. Edit `Dockerfile`: Update `ARG RUNNER_VERSION` or `ARG ACT_RUNNER_VERSION`
2. Edit `CHANGELOG.md`: Add new version entry
3. Create release tag with new runner version (resets increment):
   - GitHub: `ubuntu-24.04-github/2.323.0-1`
   - Gitea: `ubuntu-24.04-gitea/0.2.12-1`

### Bump Agent Version (fireactions/fireteact)

1. Edit `Dockerfile`: Update `ARG FIREACTIONS_VERSION` or `ARG FIRETEACT_VERSION`
2. Edit `CHANGELOG.md`: Add new version entry
3. Create release tag with incremented suffix:
   - GitHub: `ubuntu-24.04-github/2.322.0-2`
   - Gitea: `ubuntu-24.04-gitea/0.2.11-2`

## Architecture Support

Built natively on:

- `linux/amd64` (ubuntu-latest runner)
- `linux/arm64` (ubuntu-24.04-arm runner)

## Files

```
ubuntu-24.04/
├── Dockerfile              # Multi-target build definition
├── CHANGELOG.md            # Version history
├── README.md               # This file
└── overlay/
    ├── common/             # Shared configuration
    │   └── etc/
    │       └── systemd/
    │           ├── network/
    │           │   └── 10-eth0.network         # Network config (DHCP)
    │           └── system/
    │               └── docker.service.d/
    │                   └── cloud-init.conf     # Docker waits for cloud-init
    ├── github/             # GitHub Actions specific
    │   └── etc/
    │       ├── hosts                           # Hostname (metadata.fireactions.internal)
    │       ├── cloud/cloud.cfg.d/
    │       │   └── 99-fireactions.cfg          # cloud-init MMDS config
    │       └── systemd/system/
    │           └── fireactions.service         # fireactions runner agent
    └── gitea/              # Gitea Actions specific
        └── etc/
            ├── hosts                           # Hostname (metadata.fireteact.internal)
            ├── cloud/cloud.cfg.d/
            │   └── 99-fireteact.cfg            # cloud-init MMDS config
            └── systemd/system/
                └── fireteact.service           # fireteact runner agent
```

## DNS Configuration

DNS is configured via cloud-init runcmd (resolv_conf module doesn't work with systemd-resolved):

1. Host injects gateway IP (dnsmasq) via cloud-init user-data
2. runcmd writes `/etc/resolv.conf` with gateway as nameserver
3. dnsmasq intercepts registry domains and points to local proxy

## Comparison

| Feature           | GitHub Runner                 | Gitea Runner                |
| ----------------- | ----------------------------- | --------------------------- |
| Platform          | GitHub Actions                | Gitea Actions               |
| Runner binary     | actions/runner                | act_runner                  |
| Agent binary      | fireactions                   | fireteact                   |
| Auth method       | GitHub App (JIT config)       | API Token (registration)    |
| Root password     | `fireactions`                 | `fireteact`                 |
| Service           | fireactions.service           | fireteact.service           |
| Metadata hostname | metadata.fireactions.internal | metadata.fireteact.internal |
