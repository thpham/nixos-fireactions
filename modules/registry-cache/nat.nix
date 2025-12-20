# registry-cache/nat.nix - NAT rules for transparent proxy
#
# Provides iptables/nftables rules for redirecting HTTP/HTTPS to Squid
#
# IMPORTANT: MMDS traffic (169.254.169.254) must NOT be redirected!
# Firecracker MMDS provides VM metadata on this link-local address.

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.registry-cache;
  parsedNetworks = cfg._internal.networks;
  primaryGateway = cfg._internal.primaryGateway;
in
{
  config = lib.mkIf (cfg.enable && cfg.squid.enable) {
    # ========================================
    # NAT RULES FOR SQUID TRANSPARENT PROXY
    # ========================================

    # Use nftables when enabled
    networking.nftables.tables.registry_cache_nat = lib.mkIf config.networking.nftables.enable {
      family = "ip";
      content = ''
        chain prerouting {
          type nat hook prerouting priority dstnat; policy accept;

          ${lib.concatMapStringsSep "\n" (net: ''
            # Redirect HTTP (80) to Squid for ${net.bridgeName}
            # Exclude: gateway (local services) and MMDS (Firecracker metadata)
            iifname "${net.bridgeName}" ip daddr != ${net.gateway} ip daddr != 169.254.169.254 tcp dport 80 \
              redirect to :3128

            ${lib.optionalString (cfg.squid.sslBump.mode != "off") ''
              # Redirect HTTPS (443) to Squid for ${net.bridgeName}
              iifname "${net.bridgeName}" ip daddr != ${net.gateway} ip daddr != 169.254.169.254 tcp dport 443 \
                redirect to :3129
            ''}
          '') parsedNetworks}
        }
      '';
    };

    # Fallback to iptables when nftables is not enabled
    networking.nat = lib.mkIf (!config.networking.nftables.enable) {
      enable = true;
      internalInterfaces = map (n: n.bridgeName) parsedNetworks;
      extraCommands = lib.concatMapStringsSep "\n" (net: ''
        # Redirect HTTP (80) to Squid for ${net.bridgeName}
        # Exclude: gateway (local services) and MMDS (Firecracker metadata at 169.254.169.254)
        iptables -t nat -A PREROUTING -i ${net.bridgeName} \
          -p tcp --dport 80 \
          ! -d ${net.gateway} \
          ! -d 169.254.169.254 \
          -j REDIRECT --to-port 3128
        ${lib.optionalString (cfg.squid.sslBump.mode != "off") ''
          # Redirect HTTPS (443) to Squid for ${net.bridgeName}
          iptables -t nat -A PREROUTING -i ${net.bridgeName} \
            -p tcp --dport 443 \
            ! -d ${net.gateway} \
            ! -d 169.254.169.254 \
            -j REDIRECT --to-port 3129
        ''}
      '') parsedNetworks;

      extraStopCommands = lib.concatMapStringsSep "\n" (net: ''
        iptables -t nat -D PREROUTING -i ${net.bridgeName} \
          -p tcp --dport 80 \
          ! -d ${net.gateway} \
          ! -d 169.254.169.254 \
          -j REDIRECT --to-port 3128 2>/dev/null || true
        ${lib.optionalString (cfg.squid.sslBump.mode != "off") ''
          iptables -t nat -D PREROUTING -i ${net.bridgeName} \
            -p tcp --dport 443 \
            ! -d ${net.gateway} \
            ! -d 169.254.169.254 \
            -j REDIRECT --to-port 3129 2>/dev/null || true
        ''}
      '') parsedNetworks;
    };
  };
}
