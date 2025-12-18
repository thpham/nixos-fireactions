# Changelog

All notable changes to the Ubuntu 24.04 runner images will be documented in this file.

Versioning format: `{runner_version}-{increment}` (e.g., `2.322.0-1` for GitHub, `0.2.13-1` for Gitea)

## GitHub Runner

### [2.322.0-1] - Unreleased

Initial release with new versioning scheme.

#### Components

| Component             | Version   |
| --------------------- | --------- |
| Ubuntu                | 24.04 LTS |
| GitHub Actions Runner | 2.322.0   |
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

#### Components

| Component  | Version   |
| ---------- | --------- |
| Ubuntu     | 24.04 LTS |
| act_runner | 0.2.13    |
| fireteact  | latest    |
| Docker CE  | latest    |
