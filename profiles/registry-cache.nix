# Registry Cache Profile
#
# Enables hybrid caching for Firecracker VMs:
# - Zot Registry: Pull-through cache for container registries (native OCI, no CA needed)
# - Squid Proxy: HTTP/HTTPS caching with selective SSL bump
#
# Architecture:
# - Container registry traffic: containerd → hosts.toml → Zot → upstream
# - HTTP/HTTPS traffic: iptables REDIRECT → Squid → upstream
#
# Features:
# - No CA certificate needed for registry pulls (native OCI protocol)
# - Multi-stage Docker builds work out of the box
# - Optional HTTPS caching for configured domains via Squid SSL bump
# - 50GB cache with LRU eviction (configurable)
#
# Usage:
#   Add "registry-cache" tag to host in registry.json
#
# Customization:
#   Override options in host-specific config (hosts/<name>.nix):
#     services.fireactions.registryCache = {
#       storage.maxSize = "100GB";
#       # Add private registry
#       zot.mirrors."harbor.corp" = {
#         url = "https://harbor.internal.corp";
#       };
#       # Enable SSL bump for specific domains
#       squid.sslBump.domains = [ "internal.corp" ];
#     };
{ ... }:

{
  # Note: registry-cache module is now part of the fireactions module
  # No separate import needed - just set the options

  services.fireactions.registryCache = {
    enable = true;

    # Zot registry pull-through cache (default registries are already configured)
    # zot.mirrors defaults to: docker.io, ghcr.io, quay.io, gcr.io

    # Squid HTTP/HTTPS cache with selective SSL bump
    # squid.sslBump.mode = "selective" (default - splice all HTTPS unless domains configured)
    # squid.sslBump.domains = []; (default - no HTTPS interception)

    # Default storage settings
    storage.maxSize = "50GB";
    squid.memoryCache = "256MB";
  };
}
