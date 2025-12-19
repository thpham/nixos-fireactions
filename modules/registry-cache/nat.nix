# registry-cache/nat.nix - NAT rules for transparent proxy
#
# Provides iptables/nftables rules for redirecting HTTP/HTTPS to Squid

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
            iifname "${net.bridgeName}" ip daddr != ${net.gateway} tcp dport 80 \
              redirect to :3128

            ${lib.optionalString (cfg.squid.sslBump.mode != "off") ''
              # Redirect HTTPS (443) to Squid for ${net.bridgeName}
              iifname "${net.bridgeName}" ip daddr != ${net.gateway} tcp dport 443 \
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
        iptables -t nat -A PREROUTING -i ${net.bridgeName} \
          -p tcp --dport 80 \
          ! -d ${net.gateway} \
          -j REDIRECT --to-port 3128
        ${lib.optionalString (cfg.squid.sslBump.mode != "off") ''
          # Redirect HTTPS (443) to Squid for ${net.bridgeName}
          iptables -t nat -A PREROUTING -i ${net.bridgeName} \
            -p tcp --dport 443 \
            ! -d ${net.gateway} \
            -j REDIRECT --to-port 3129
        ''}
      '') parsedNetworks;

      extraStopCommands = lib.concatMapStringsSep "\n" (net: ''
        iptables -t nat -D PREROUTING -i ${net.bridgeName} \
          -p tcp --dport 80 \
          ! -d ${net.gateway} \
          -j REDIRECT --to-port 3128 2>/dev/null || true
        ${lib.optionalString (cfg.squid.sslBump.mode != "off") ''
          iptables -t nat -D PREROUTING -i ${net.bridgeName} \
            -p tcp --dport 443 \
            ! -d ${net.gateway} \
            -j REDIRECT --to-port 3129 2>/dev/null || true
        ''}
      '') parsedNetworks;
    };
  };
}
