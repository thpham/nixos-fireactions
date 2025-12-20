# Changelog

All notable changes to the Ubuntu 24.04 runner images will be documented in this file.

Versioning format: `{runner_version}-{increment}` (e.g., `2.330.0-1` for GitHub, `0.2.13-1` for Gitea, `18.7.0-1` for GitLab)

## GitHub Runner

### [2.330.0-1] - Unreleased

Initial release with new versioning scheme.

#### Fixed

- **MMDS route reliability**: Added `bootcmd` to create route to 169.254.169.254 before cloud-init
  fetches metadata. Previously worked by timing luck; now deterministic per Firecracker docs:
  "guest applications must insert a new rule into the routing table"

#### Components

| Component             | Version   |
| --------------------- | --------- |
| Ubuntu                | 24.04 LTS |
| GitHub Actions Runner | 2.330.0   |
| fireactions           | 0.4.0     |
| Docker CE             | latest    |
| GitHub CLI            | latest    |

## Gitea Runner

### [0.2.13-1] - Unreleased

Ephemeral runner mode for proper VM recycling.

#### Changes

- **Ephemeral runners**: Runners now auto-deregister from Gitea after completing one job
- **Immediate VM recycling**: New VMs spawn immediately after job completion (no 10s delay)
- **Improved logging**: Structured logging for runner lifecycle events

#### Fixed

- **MMDS route reliability**: Added `bootcmd` to create route to 169.254.169.254 before cloud-init
  fetches metadata. Previously worked by timing luck; now deterministic per Firecracker docs:
  "guest applications must insert a new rule into the routing table"

#### Components

| Component  | Version   |
| ---------- | --------- |
| Ubuntu     | 24.04 LTS |
| act_runner | 0.2.13    |
| fireteact  | latest    |
| Docker CE  | latest    |

## GitLab Runner

### [18.7.0-1] - Unreleased

Initial release with GitLab CI runner support.

#### Features

- **Dynamic runner creation**: Uses POST /api/v4/user/runners for glrt-\* tokens
- **Automatic cleanup**: DELETE /api/v4/runners/:id on VM exit
- **Runner types**: Support for instance_type, group_type, and project_type
- **Ephemeral runners**: One job per VM with immediate recycling

#### Fixed

- **MMDS route reliability**: Added `bootcmd` to create route to 169.254.169.254 before cloud-init
  fetches metadata. This was the root cause of MMDS failures - fireglab boots faster than
  fireteact/fireactions, causing cloud-init to run before the route existed. Now deterministic
  per Firecracker docs: "guest applications must insert a new rule into the routing table"

#### Components

| Component     | Version   |
| ------------- | --------- |
| Ubuntu        | 24.04 LTS |
| gitlab-runner | 18.7.0    |
| fireglab      | 0.1.0-dev |
| Docker CE     | latest    |
