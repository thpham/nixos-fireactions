# Fireteact

Gitea Actions runner orchestrator using Firecracker microVMs.

Fireteact manages ephemeral Gitea Actions runners in isolated Firecracker microVMs with auto-scaling pool management. It's the Gitea equivalent of [fireactions](https://github.com/hostinger/fireactions) for GitHub Actions.

## Architecture

Fireteact operates in two modes via a single binary:

| Mode         | Command            | Where it runs | Purpose                         |
| ------------ | ------------------ | ------------- | ------------------------------- |
| Orchestrator | `fireteact serve`  | Host          | Manages VMs, talks to Gitea API |
| Runner       | `fireteact runner` | Inside VM     | Bootstraps act_runner from MMDS |

```
┌────────────────────────────────────────────────────────────────┐
│                    Fireteact (Host)                            │
│  ┌─────────────┐  ┌─────────────┐  ┌────────────────────────┐  │
│  │ HTTP API    │  │ Metrics     │  │ Pool Manager           │  │
│  │ :8082       │  │ :8083       │  │ - Auto-scaling         │  │
│  └─────────────┘  └─────────────┘  │ - VM lifecycle         │  │
│                                    │ - Runner tracking      │  │
│                                    └────────────────────────┘  │
└────────────────────────────────────────────────────────────────┘
         │                                      │
         │ Gitea API                            │ Firecracker API + MMDS
         ▼                                      ▼
┌─────────────────┐                 ┌─────────────────────────────┐
│ Gitea Instance  │                 │ Firecracker microVMs        │
│                 │                 │ ┌─────────────────────────┐ │
│ - Runner API    │◄────────────────│ │ fireteact runner (VM)   │ │
│ - Job queue     │  Registration   │ │   └─► act_runner daemon │ │
│                 │                 │ └─────────────────────────┘ │
└─────────────────┘                 └─────────────────────────────┘
```

## Key Features

- **Ephemeral Runners**: Each job runs in a fresh VM, destroyed after completion
- **Pool-based Auto-scaling**: Maintains min/max runners per pool
- **Dynamic Registration**: Per-runner tokens via Gitea API (not static tokens)
- **Multiple Scopes**: Instance, organization, or repository-level runners
- **Prometheus Metrics**: Built-in observability
- **Cloud-init Integration**: VM configuration via MMDS metadata

## Authentication Flow

Unlike a static registration token, fireteact uses a Gitea API token to dynamically request per-runner registration tokens:

```
                         HOST                                      VM
┌──────────────────────────────────────────┐    ┌──────────────────────────────────────┐
│ 1. fireteact serve                       │    │ 4. fireteact runner                  │
│    └─► Authenticates with Gitea API      │    │    └─► Fetches metadata from MMDS    │
│                                          │    │        (169.254.169.254)             │
│ 2. For each new runner:                  │    │                                      │
│    └─► GET /api/v1/.../registration-token│    │ 5. Registers act_runner:             │
│    └─► Receives one-time token           │    │    └─► act_runner register           │
│                                          │    │        --token <from MMDS>           │
│ 3. Spawns Firecracker VM:                │    │        --instance <gitea-url>        │
│    └─► Injects token + config via MMDS   │    │                                      │
│    └─► Metadata at /fireteact path       │    │ 6. Runs act_runner daemon:           │
│                                          │    │    └─► Polls for jobs                │
└──────────────────────────────────────────┘    │    └─► Executes workflow             │
                                                │    └─► Exits when job completes      │
                                                │                                      │
                                                │ 7. VM shutdown triggered             │
                                                └──────────────────────────────────────┘
```

**MMDS Metadata Structure** (passed to each VM):

```json
{
  "gitea_instance_url": "https://gitea.example.com",
  "registration_token": "one-time-token-here",
  "runner_name": "fireteact-pool-abc123",
  "runner_labels": "self-hosted,linux,x64",
  "pool_name": "default",
  "runner_id": "abc123"
}
```

## Configuration

```yaml
server:
  address: ":8082"
  metricsAddress: ":8083"

gitea:
  instanceURL: "https://gitea.example.com"
  apiToken: "your-api-token" # Or use apiTokenFile
  runnerScope: "org" # Recommended: "org" (see Security section)
  runnerOwner: "my-org" # Required for org/repo scope
  # runnerRepo: "my-repo"    # Required for repo scope only

logLevel: "info"

pools:
  - name: "default"
    maxRunners: 10
    minRunners: 2
    runner:
      name: "fireteact-runner"
      image: "ghcr.io/thpham/fireactions-images/ubuntu-24.04-gitea:latest"
      labels:
        - "self-hosted"
        - "linux"
        - "x64"
    firecracker:
      memSizeMib: 2048
      vcpuCount: 2
      kernelPath: "/var/lib/fireteact/kernels/vmlinux"
      kernelArgs: "console=ttyS0 reboot=k panic=1 pci=off"

# Optional: containerd and cni settings (defaults shown below)
# Images are stored in per-pool namespaces for isolation
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

| Metric                                   | Type      | Description                     |
| ---------------------------------------- | --------- | ------------------------------- |
| `fireteact_pools_total`                  | Gauge     | Total number of pools           |
| `fireteact_runners_total`                | Gauge     | Total runners by pool and state |
| `fireteact_runner_spawn_total`           | Counter   | Total runners spawned           |
| `fireteact_runner_spawn_errors_total`    | Counter   | Runner spawn errors             |
| `fireteact_vm_creation_duration_seconds` | Histogram | VM creation latency             |

## Runner Scopes & Security

Fireteact supports three runner registration scopes with different security implications:

| Scope      | API Endpoint                                       | Required Token Scope   | Risk Level |
| ---------- | -------------------------------------------------- | ---------------------- | ---------- |
| `instance` | `/api/v1/admin/runners/...`                        | Admin access           | 🔴 High    |
| `org`      | `/api/v1/orgs/{owner}/actions/runners/...`         | Org runner management  | 🟡 Medium  |
| `repo`     | `/api/v1/repos/{owner}/{repo}/actions/runners/...` | Repo runner management | 🟢 Low     |

### Security Recommendations

⚠️ **Avoid `instance` scope in production** - An admin token on each orchestrator host means a compromise exposes your entire Gitea instance.

**Recommended: Use `org` scope** (default)

- Create a dedicated organization for CI/CD workloads
- Generate a token with only `write:organization` scope
- Runners only have access to that organization's repositories

**Most secure: Use `repo` scope**

- Each orchestrator manages runners for a single repository
- Minimal blast radius if compromised
- Best for high-security workloads

### Token Permissions by Scope

```
instance → Requires: Site Admin access (dangerous!)
org      → Requires: Organization Owner or write:organization scope
repo     → Requires: Repository Admin or write:repository scope
```

## NixOS Integration

Fireteact is designed for NixOS deployment via the `nixos-fireactions` flake. It's part of a composable 4-layer architecture:

1. **microvm-base** - Foundation (bridges, containerd, DNSmasq, CNI, **kernel configuration**)
2. **registry-cache** - Optional OCI/HTTP caching
3. **fireteact** - Gitea Actions runner management
4. **profiles** - Tag-based configuration

### Using Profiles (Recommended)

Configure hosts via tags in `hosts/registry.json`:

```nix
# Example deployment tags:
tags = ["gitea-runners", "fireteact-medium"]              # Gitea only
tags = ["gitea-runners", "fireteact-large", "registry-cache"]  # With cache
tags = ["github-runners", "gitea-runners", "fireactions-small", "fireteact-medium"]  # Both runners
```

Available size profiles:

- `fireteact-small` - 1GB RAM, 1 vCPU, 2 max runners
- `fireteact-medium` - 2GB RAM, 2 vCPU, 5 max runners
- `fireteact-large` - 4GB RAM, 4 vCPU, 10 max runners

### Direct Module Configuration

For custom configurations, use the module directly:

```nix
{
  # Kernel configuration is at microvm-base layer (shared by all runners)
  services.microvm-base.kernel.source = "custom";  # Includes Docker bridge networking

  services.fireteact = {
    enable = true;

    gitea = {
      instanceUrl = "https://gitea.example.com";
      apiTokenFile = config.sops.secrets."gitea-api-token".path;
      runnerScope = "org";       # Recommended (see Security section)
      runnerOwner = "my-org";    # Your organization name
    };

    pools = [{
      name = "default";
      maxRunners = 5;
      minRunners = 1;
      runner = {
        labels = [ "self-hosted" "linux" "x64" ];
        image = "ghcr.io/thpham/fireactions-images/ubuntu-24.04-gitea:latest";
      };
      firecracker = {
        memSizeMib = 2048;
        vcpuCount = 2;
      };
    }];
  };
}
```

### Architecture Isolation

When fireteact is enabled, it automatically:

- Registers a dedicated bridge (`fireteact0`) with `microvm-base`
- Uses per-pool containerd namespaces for isolation
- Configures DNSmasq for the fireteact subnet
- Can optionally use `registry-cache` for image caching

## Development

```bash
# Build
go build -v ./cmd/fireteact

# Show help
./fireteact --help

# Run orchestrator (host mode)
./fireteact serve --config config.yaml
./fireteact --config config.yaml  # 'serve' is the default

# Run runner agent (VM mode) - only inside a Firecracker VM
./fireteact runner --log-level debug

# Show version
./fireteact --version
```

### Runner Agent Options

```bash
./fireteact runner \
  --log-level info \           # Log level (debug, info, warn, error)
  --act-runner /usr/local/bin/act_runner \  # Path to act_runner
  --work-dir /opt/act_runner \ # Working directory
  --config /etc/act_runner/config.yaml \    # Config file path
  --owner runner \             # User to run as
  --group docker \             # Group to run as
  --generate-config            # Auto-generate config if missing
```

## Project Structure

```
fireteact/
├── cmd/fireteact/
│   └── main.go           # Entry point
├── commands/
│   ├── root.go           # Root command (cobra)
│   ├── serve.go          # Orchestrator command (host)
│   └── runner.go         # Runner agent command (VM)
├── runner/
│   ├── runner.go         # act_runner lifecycle management
│   └── mmds/
│       └── mmds.go       # MMDS client for metadata
├── internal/
│   ├── config/
│   │   └── config.go     # Configuration loading
│   ├── gitea/
│   │   └── client.go     # Gitea API client
│   ├── firecracker/
│   │   └── manager.go    # VM lifecycle management
│   ├── pool/
│   │   └── pool.go       # Pool and runner management
│   └── server/
│       └── server.go     # HTTP API and metrics
├── go.mod
├── go.sum
└── README.md
```

## Comparison with Fireactions

| Feature      | Fireactions (GitHub)                 | Fireteact (Gitea)                      |
| ------------ | ------------------------------------ | -------------------------------------- |
| Platform     | GitHub Actions                       | Gitea Actions                          |
| Auth         | GitHub App (app_id + private_key)    | API Token                              |
| Runner Agent | actions/runner                       | act_runner                             |
| Token Model  | JIT config via GitHub API            | Registration token via Gitea           |
| VM Runtime   | Firecracker                          | Firecracker                            |
| Networking   | CNI (bridge + tc-redirect-tap)       | CNI (bridge + tc-redirect-tap)         |
| Binary Modes | `fireactions` / `fireactions runner` | `fireteact serve` / `fireteact runner` |
| Metadata     | MMDS (runner_jit_config)             | MMDS (registration_token + config)     |
