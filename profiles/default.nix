# Tag-based profile system
# Profiles are applied based on host tags from registry.json
#
# Usage:
#   A host with tags ["prod", "github-runners"] will have both
#   profiles/prod.nix and profiles/github-runners.nix applied
#
# Profile priority (later overrides earlier):
#   1. deploy/base.nix (boot, SSH, network - always applied)
#   2. Tag profiles (alphabetical order)
#   3. Per-host config (hosts/<name>.nix) - escape hatch
#
# Composable Deployment Examples:
#   - GitHub Actions only:      ["github-runners", "fireactions-medium"]
#   - GitHub + cache:           ["github-runners", "fireactions-medium", "registry-cache"]
#   - Gitea Actions only:       ["gitea-runners", "fireteact-medium"]
#   - Gitea + cache:            ["gitea-runners", "fireteact-medium", "registry-cache"]
#   - GitLab CI only:           ["gitlab-runners", "fireglab-medium"]
#   - GitLab + cache:           ["gitlab-runners", "fireglab-medium", "registry-cache"]
#   - All three runners:        ["github-runners", "gitea-runners", "gitlab-runners", "fireactions-small", "fireteact-small", "fireglab-small"]
{ lib }:

let
  # Import all available profiles
  allProfiles = {
    # Environment profiles
    prod = ./prod.nix;
    dev = ./dev.nix;

    # Workload profiles (enable services and set credentials)
    github-runners = ./github-runners.nix;
    gitea-runners = ./gitea-runners.nix;
    gitlab-runners = ./gitlab-runners.nix;

    # Technology-specific size profiles
    fireactions-small = ./fireactions-small.nix;
    fireactions-medium = ./fireactions-medium.nix;
    fireactions-large = ./fireactions-large.nix;
    fireteact-small = ./fireteact-small.nix;
    fireteact-medium = ./fireteact-medium.nix;
    fireteact-large = ./fireteact-large.nix;
    fireglab-small = ./fireglab-small.nix;
    fireglab-medium = ./fireglab-medium.nix;
    fireglab-large = ./fireglab-large.nix;

    # Infrastructure profiles
    registry-cache = ./registry-cache.nix;

    # Security profiles
    security-hardened = ./security-hardened.nix;
  };

  # Get profiles for a list of tags
  # Returns list of profile paths that exist for given tags
  getProfilesForTags =
    tags:
    let
      matchingProfiles = lib.filterAttrs (name: _: lib.elem name tags) allProfiles;
    in
    lib.attrValues matchingProfiles;

in
{
  inherit allProfiles getProfilesForTags;

  # List of all available profile names (for documentation)
  availableProfiles = lib.attrNames allProfiles;

  # Preferred profiles for new deployments
  recommendedProfiles = [
    "fireactions-small"
    "fireactions-medium"
    "fireactions-large"
    "fireteact-small"
    "fireteact-medium"
    "fireteact-large"
    "fireglab-small"
    "fireglab-medium"
    "fireglab-large"
  ];

}
