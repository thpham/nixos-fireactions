# microvm-base/dnsmasq.nix - Multi-bridge DHCP/DNS configuration
#
# Provides DNSmasq with per-bridge DHCP ranges and tagged options

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.microvm-base;

  # Generate DHCP configuration for each bridge
  bridgeConfigs = lib.mapAttrsToList (
    name: bridge:
    let
      info = cfg._internal.bridges.${name};
    in
    {
      inherit name;
      inherit (info)
        bridgeName
        gateway
        dhcpStart
        dhcpEnd
        netmask
        ;
    }
  ) cfg.bridges;

in
{
  config = lib.mkIf (cfg.enable && cfg.bridges != { }) {
    #
    # DNSmasq Configuration
    #

    services.dnsmasq = {
      enable = true;
      settings = {
        # Listen on all registered bridge interfaces
        interface = map (b: b.bridgeName) bridgeConfigs;
        bind-interfaces = true;
        no-resolv = true;
        server = cfg.dns.upstreamServers;
        cache-size = 1000;
        log-queries = false;

        # DHCP ranges with tags for each bridge
        dhcp-range = map (b: "set:${b.name},${b.dhcpStart},${b.dhcpEnd},${b.netmask},12h") bridgeConfigs;

        # Per-bridge gateway and DNS options
        dhcp-option = lib.flatten (
          map (b: [
            "tag:${b.name},3,${b.gateway}" # Gateway
            "tag:${b.name},6,${b.gateway}" # DNS server
          ]) bridgeConfigs
        );

        dhcp-rapid-commit = true;
      };
    };

    # Ensure dnsmasq waits for all bridge interfaces
    systemd.services.dnsmasq = {
      after = map (b: "sys-subsystem-net-devices-${b.bridgeName}.device") bridgeConfigs;
      wants = map (b: "sys-subsystem-net-devices-${b.bridgeName}.device") bridgeConfigs;
    };

    # Open firewall for DNS and DHCP on all bridges
    networking.firewall.interfaces = lib.listToAttrs (
      map (
        b:
        lib.nameValuePair b.bridgeName {
          allowedTCPPorts = [ 53 ]; # DNS (TCP for large responses)
          allowedUDPPorts = [
            53
            67
          ]; # DNS + DHCP
        }
      ) bridgeConfigs
    );
  };
}
