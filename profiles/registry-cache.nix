# Registry Cache Profile
#
# Enables transparent registry proxy cache for Firecracker VMs.
# VMs pull images normally - DNS interception + MITM proxy makes caching invisible.
#
# Features:
# - DNS interception (dnsmasq) redirects registry domains to local proxy
# - Squid ssl-bump terminates TLS, caches content with LRU eviction
# - Auto-generated CA certificate for TLS termination
# - 50GB cache with LRU eviction (configurable)
#
# Usage:
#   Add "registry-cache" tag to host in registry.json
#
# Customization:
#   Override options in host-specific config (hosts/<name>.nix):
#     services.fireactions.registryCache = {
#       storage.maxSize = "100GB";
#       credentials."registry-1.docker.io" = {
#         usernameFile = config.age.secrets.dockerhub-user.path;
#         passwordFile = config.age.secrets.dockerhub-pass.path;
#       };
#     };
{ ... }:

{
  imports = [
    ../modules/registry-cache.nix
  ];

  services.fireactions.registryCache = {
    enable = true;

    # Default registries to cache
    registries = [
      "ghcr.io"
      "docker.io"
      "quay.io"
      "gcr.io"
    ];

    # Default storage settings
    storage = {
      maxSize = "50GB";
      memoryCache = "2GB";
    };
  };
}
