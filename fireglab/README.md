# Fireglab

GitLab CI runner orchestrator using Firecracker microVMs.

Fireglab manages ephemeral GitLab CI runners in isolated Firecracker microVMs with auto-scaling pool management. It's the GitLab equivalent of [fireactions](https://github.com/hostinger/fireactions) for GitHub Actions and [fireteact](../fireteact/) for Gitea Actions.

## Architecture

Fireglab operates in two modes via a single binary:

| Mode         | Command           | Where it runs | Purpose                            |
| ------------ | ----------------- | ------------- | ---------------------------------- |
| Orchestrator | `fireglab serve`  | Host          | Manages VMs, talks to GitLab API   |
| Runner       | `fireglab runner` | Inside VM     | Bootstraps gitlab-runner from MMDS |

```
┌────────────────────────────────────────────────────────────────┐
│                    Fireglab (Host)                             │
│  ┌─────────────┐  ┌─────────────┐  ┌────────────────────────┐  │
│  │ HTTP API    │  │ Metrics     │  │ Pool Manager           │  │
│  │ :8084       │  │ :8085       │  │ - Auto-scaling         │  │
│  └─────────────┘  └─────────────┘  │ - VM lifecycle         │  │
│                                    │ - Runner tracking      │  │
│                                    └────────────────────────┘  │
└────────────────────────────────────────────────────────────────┘
         │                                      │
         │ GitLab API                           │ Firecracker API + MMDS
         ▼                                      ▼
┌─────────────────┐                 ┌─────────────────────────────┐
│ GitLab Instance │                 │ Firecracker microVMs        │
│                 │                 │ ┌─────────────────────────┐ │
│ - Runners API   │◄────────────────│ │ fireglab runner (VM)    │ │
│ - Job queue     │  Registration   │ │   └─► gitlab-runner     │ │
│                 │                 │ └─────────────────────────┘ │
└─────────────────┘                 └─────────────────────────────┘
```

## Key Features

- **Ephemeral Runners**: Each job runs in a fresh VM, destroyed after completion
- **Pool-based Auto-scaling**: Maintains min/max runners per pool
- **Dynamic Runner Creation**: Per-runner tokens via GitLab API (`glrt-*` tokens)
- **Multiple Scopes**: Instance, group, or project-level runners
- **Automatic Cleanup**: Runners deleted from GitLab when VM exits
- **Prometheus Metrics**: Built-in observability
- **Cloud-init Integration**: VM configuration via MMDS metadata

## Authentication Flow

Unlike static runner registration tokens (deprecated in GitLab 17.0), fireglab uses the modern runner creation workflow via `POST /api/v4/user/runners`:

```
                         HOST                                      VM
┌──────────────────────────────────────────┐    ┌──────────────────────────────────────┐
│ 1. fireglab serve                        │    │ 5. fireglab runner                   │
│    └─► Authenticates with GitLab PAT     │    │    └─► Fetches metadata from MMDS    │
│                                          │    │        (169.254.169.254)             │
│ 2. For each new runner:                  │    │                                      │
│    └─► POST /api/v4/user/runners         │    │ 6. Registers gitlab-runner:          │
│    └─► Receives runner_id + glrt-* token │    │    └─► gitlab-runner register        │
│                                          │    │        --token glrt-xxx              │
│ 3. Spawns Firecracker VM:                │    │        --url <gitlab-url>            │
│    └─► Injects token + config via MMDS   │    │                                      │
│    └─► Metadata at /fireglab path        │    │ 7. Runs gitlab-runner:               │
│                                          │    │    └─► gitlab-runner run --once      │
│ 4. Tracks runner_id for cleanup          │    │    └─► Executes CI job               │
└──────────────────────────────────────────┘    │    └─► Exits when job completes      │
                                                │                                      │
                   ┌────────────────────────────│ 8. VM shutdown triggered             │
                   │                            └──────────────────────────────────────┘
                   ▼
┌──────────────────────────────────────────┐
│ 9. Host cleanup:                         │
│    └─► DELETE /api/v4/runners/:id        │
│    └─► Runner removed from GitLab        │
└──────────────────────────────────────────┘
```

**MMDS Metadata Structure** (passed to each VM):

```json
{
  "fireglab": {
    "gitlab_instance_url": "https://gitlab.example.com",
    "runner_token": "glrt-xxxxxxxxxxxx",
    "runner_id": 12345,
    "runner_name": "fireglab-pool-abc123",
    "runner_tags": "self-hosted,fireglab,linux",
    "pool_name": "default",
    "vm_id": "abc123",
    "system_id": "abc123xyz"
  }
}
```

## Configuration

```yaml
server:
  address: ":8084"
  metricsAddress: ":8085"

gitlab:
  instanceURL: "https://gitlab.example.com"
  accessToken: "glpat-xxx" # Or use accessTokenFile
  runnerType: "group_type" # Recommended (see Security section)
  groupId: 123 # Required for group_type
  # projectId: 456                # Required for project_type

logLevel: "info"

pools:
  - name: "default"
    maxRunners: 10
    minRunners: 2
    runner:
      name: "fireglab-runner"
      image: "ghcr.io/thpham/fireactions-images/ubuntu-24.04-gitlab:latest"
      tags:
        - "self-hosted"
        - "fireglab"
        - "linux"
    firecracker:
      memSizeMib: 2048
      vcpuCount: 2
      kernelPath: "/var/lib/fireglab/kernels/vmlinux"
      kernelArgs: "console=ttyS0 reboot=k panic=1 pci=off"

# Optional: containerd and cni settings (defaults shown below)
containerd:
  address: "/run/containerd/containerd.sock"
  snapshotter: "devmapper"

cni:
  confDir: "/etc/cni/conf.d"
  binDir: "/opt/cni/bin"
```

## API Endpoints

| Endpoint                       | Method | Description          |
| ------------------------------ | ------ | -------------------- |
| `/health`                      | GET    | Health check         |
| `/api/v1/pools`                | GET    | List all pools       |
| `/api/v1/pools/{name}`         | GET    | Get pool details     |
| `/api/v1/pools/{name}/runners` | GET    | List runners in pool |
| `/api/v1/runners`              | GET    | List all runners     |
| `/api/v1/runners/{id}`         | GET    | Get runner details   |
| `/api/v1/runners/{id}`         | DELETE | Force stop runner    |
| `/metrics`                     | GET    | Prometheus metrics   |

## Prometheus Metrics

| Metric                                  | Type      | Description                     |
| --------------------------------------- | --------- | ------------------------------- |
| `fireglab_pools_total`                  | Gauge     | Total number of pools           |
| `fireglab_runners_total`                | Gauge     | Total runners by pool and state |
| `fireglab_runner_spawn_total`           | Counter   | Total runners spawned           |
| `fireglab_runner_spawn_errors_total`    | Counter   | Runner spawn errors             |
| `fireglab_vm_creation_duration_seconds` | Histogram | VM creation latency             |

## Runner Types & Security

Fireglab supports three runner types with different security implications:

| Type            | API Scope             | Required Token Permission  | Risk Level |
| --------------- | --------------------- | -------------------------- | ---------- |
| `instance_type` | Instance-wide runners | Administrator              | High       |
| `group_type`    | Group runners         | Owner role on group        | Medium     |
| `project_type`  | Project runners       | Maintainer role on project | Low        |

### Security Recommendations

**Avoid `instance_type` in production** - An admin token on each orchestrator host means a compromise exposes your entire GitLab instance.

**Recommended: Use `group_type`** (default)

- Create a dedicated group for CI/CD workloads
- Generate a PAT with `create_runner` scope from a group Owner
- Runners only have access to that group's projects

**Most secure: Use `project_type`**

- Each orchestrator manages runners for a single project
- Minimal blast radius if compromised
- Best for high-security workloads

### Token Requirements

```
instance_type → Requires: Administrator access (dangerous!)
group_type    → Requires: Owner role on the group + groupId
project_type  → Requires: Maintainer role on the project + projectId
```

**Personal Access Token (PAT) Setup:**

1. Navigate to: GitLab > User Settings > Access Tokens
2. Create token with scope: `create_runner`
3. Select appropriate expiration (recommend: 90 days max)
4. Store securely (use sops-nix for NixOS deployments)

## NixOS Integration

Fireglab is designed for NixOS deployment via the `nixos-fireactions` flake. It's part of a composable 4-layer architecture:

1. **microvm-base** - Foundation (bridges, containerd, DNSmasq, CNI, **kernel configuration**)
2. **registry-cache** - Optional OCI/HTTP caching
3. **fireglab** - GitLab CI runner management
4. **profiles** - Tag-based configuration

### Using Profiles (Recommended)

Configure hosts via tags in `hosts/registry.json`:

```nix
# Example deployment tags:
tags = ["gitlab-runners", "fireglab-medium"]              # GitLab only
tags = ["gitlab-runners", "fireglab-large", "registry-cache"]  # With cache
tags = ["github-runners", "gitlab-runners", "fireactions-small", "fireglab-medium"]  # Both runners
```

Available size profiles:

- `fireglab-small` - 1GB RAM, 1 vCPU, 2 max runners
- `fireglab-medium` - 2GB RAM, 2 vCPU, 5 max runners
- `fireglab-large` - 4GB RAM, 4 vCPU, 10 max runners

### Direct Module Configuration

For custom configurations, use the module directly:

```nix
{
  # Kernel configuration is at microvm-base layer (shared by all runners)
  services.microvm-base.kernel.source = "custom";  # Includes Docker bridge networking

  services.fireglab = {
    enable = true;

    gitlab = {
      instanceUrlFile = config.sops.secrets."gitlab-instance-url".path;
      accessTokenFile = config.sops.secrets."gitlab-access-token".path;
      runnerType = "group_type";     # Recommended (see Security section)
      groupIdFile = config.sops.secrets."gitlab-group-id".path;
    };

    pools = [{
      name = "default";
      maxRunners = 5;
      minRunners = 1;
      runner = {
        tags = [ "self-hosted" "fireglab" "linux" ];
        image = "ghcr.io/thpham/fireactions-images/ubuntu-24.04-gitlab:latest";
      };
      firecracker = {
        memSizeMib = 2048;
        vcpuCount = 2;
      };
    }];
  };
}
```

### Secrets Configuration

Add these secrets to your `secrets/secrets.yaml`:

```yaml
# GitLab Personal Access Token with create_runner scope
gitlab_access_token: "glpat-xxxxxxxxxxxxxxxxxxxx"

# GitLab instance URL
gitlab_instance_url: "https://gitlab.example.com"

# Group ID (required for group_type)
gitlab_group_id: "123"

# Project ID (required for project_type)
gitlab_project_id: "456"
```

### Architecture Isolation

When fireglab is enabled, it automatically:

- Registers a dedicated bridge (`fireglab0`) with `microvm-base`
- Uses the subnet `10.202.0.0/24` (separate from fireactions and fireteact)
- Uses per-pool containerd namespaces for isolation
- Configures DNSmasq for the fireglab subnet
- Can optionally use `registry-cache` for image caching

## Development

```bash
# Build
go build -v ./cmd/fireglab

# Show help
./fireglab --help

# Run orchestrator (host mode)
./fireglab serve --config config.yaml
./fireglab --config config.yaml  # 'serve' is the default

# Run runner agent (VM mode) - only inside a Firecracker VM
./fireglab runner --log-level debug

# Show version
./fireglab --version
```

### Runner Agent Options

```bash
./fireglab runner \
  --log-level info \              # Log level (debug, info, warn, error)
  --gitlab-runner /usr/bin/gitlab-runner \  # Path to gitlab-runner
  --work-dir /opt/gitlab-runner \ # Working directory
  --config /etc/gitlab-runner/config.toml \ # Config file path
  --owner runner \                # User to run as
  --group docker \                # Group to run as
  --generate-config               # Auto-generate config if missing
```

## Project Structure

```
fireglab/
├── cmd/fireglab/
│   └── main.go           # Entry point
├── commands/
│   ├── root.go           # Root command (cobra)
│   ├── serve.go          # Orchestrator command (host)
│   └── runner.go         # Runner agent command (VM)
├── runner/
│   ├── runner.go         # gitlab-runner lifecycle management
│   └── mmds/
│       └── mmds.go       # MMDS client for metadata
├── internal/
│   ├── config/
│   │   └── config.go     # Configuration loading
│   ├── gitlab/
│   │   ├── client.go     # GitLab API client
│   │   └── types.go      # API request/response types
│   ├── firecracker/
│   │   └── manager.go    # VM lifecycle management
│   ├── pool/
│   │   ├── pool.go       # Pool and runner management
│   │   └── metrics.go    # Prometheus metrics
│   ├── server/
│   │   └── server.go     # HTTP API and metrics
│   └── stringid/
│       └── stringid.go   # ID generation utilities
├── go.mod
├── go.sum
└── README.md
```

## Comparison with Fireactions and Fireteact

| Feature        | Fireactions (GitHub)     | Fireteact (Gitea)          | Fireglab (GitLab)                 |
| -------------- | ------------------------ | -------------------------- | --------------------------------- |
| Platform       | GitHub Actions           | Gitea Actions              | GitLab CI                         |
| Auth           | GitHub App               | API Token                  | Personal Access Token (PAT)       |
| Runner Agent   | actions/runner           | act_runner                 | gitlab-runner                     |
| Token Model    | JIT config via API       | Registration token via API | Runner creation via API (glrt-\*) |
| Cleanup        | Automatic                | Automatic                  | DELETE /api/v4/runners/:id        |
| VM Runtime     | Firecracker              | Firecracker                | Firecracker                       |
| Network Bridge | fireactions0             | fireteact0                 | fireglab0                         |
| Subnet         | 10.200.0.0/24            | 10.201.0.0/24              | 10.202.0.0/24                     |
| Ports          | 8080/8081                | 8082/8083                  | 8084/8085                         |
| Binary Modes   | `fireactions` / `runner` | `serve` / `runner`         | `serve` / `runner`                |
| Metadata Path  | MMDS `/fireactions`      | MMDS `/fireteact`          | MMDS `/fireglab`                  |

## GitLab API Reference

Fireglab uses the following GitLab APIs:

**Create Runner** ([docs](https://docs.gitlab.com/ee/api/users.html#create-a-runner)):

```
POST /api/v4/user/runners
```

Request body:

```json
{
  "runner_type": "group_type",
  "group_id": 123,
  "description": "fireglab-pool-abc123",
  "tag_list": ["self-hosted", "fireglab", "linux"],
  "run_untagged": false
}
```

Response:

```json
{
  "id": 12345,
  "token": "glrt-xxxxxxxxxxxxxxxxxxxx",
  "token_expires_at": null
}
```

**Delete Runner** ([docs](https://docs.gitlab.com/ee/api/runners.html#delete-a-runner)):

```
DELETE /api/v4/runners/:id
```

## Troubleshooting

### Runner not appearing in GitLab

1. Check fireglab logs: `journalctl -u fireglab -f`
2. Verify PAT has `create_runner` scope
3. For group_type: verify you have Owner role on the group
4. Check network connectivity to GitLab instance

### VM fails to start

1. Check kernel is available: `ls /var/lib/fireglab/kernels/`
2. Verify containerd is running: `systemctl status containerd`
3. Check image exists: `ctr -n fireglab.default images ls`
4. Review firecracker logs in journal

### Runner stuck in "pending" state

1. Check gitlab-runner logs inside VM (if SSH enabled)
2. Verify MMDS metadata is accessible at `169.254.169.254`
3. Check DNS resolution from VM

### Debug SSH Access

Enable SSH access to VMs for debugging:

```nix
services.fireglab.debug.sshKeyFile = config.sops.secrets."debug-ssh-key".path;
```

Then SSH into a running VM:

```bash
ssh -i /path/to/debug-key root@<vm-ip>
```
