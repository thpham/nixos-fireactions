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
{ lib }:

let
  # Import all available profiles
  allProfiles = {
    # Environment profiles
    prod = ./prod.nix;
    dev = ./dev.nix;

    # Workload profiles
    github-runners = ./github-runners.nix;
    gitea-runners = ./gitea-runners.nix;

    # Size profiles
    small = ./small.nix;
    medium = ./medium.nix;
    large = ./large.nix;

    # Infrastructure profiles
    registry-cache = ./registry-cache.nix;

    # Security profiles
    security-hardened = ./security-hardened.nix;
  };

  # Get profiles for a list of tags
  # Returns list of profile paths that exist for given tags
  getProfilesForTags = tags:
    let
      matchingProfiles = lib.filterAttrs (name: _: lib.elem name tags) allProfiles;
    in
    lib.attrValues matchingProfiles;

in {
  inherit allProfiles getProfilesForTags;

  # List of all available profile names (for documentation)
  availableProfiles = lib.attrNames allProfiles;
}
