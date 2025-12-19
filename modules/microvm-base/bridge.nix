# microvm-base/bridge.nix - Bridge network generation
#
# Creates systemd-networkd netdevs and networks for each registered bridge

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.microvm-base;
in
{
  config = lib.mkIf (cfg.enable && cfg.bridges != { }) {
    #
    # Bridge Network Configuration
    #

    systemd.network = {
      enable = true;

      # Create bridge netdevs
      netdevs = lib.mapAttrs' (
        name: bridge:
        lib.nameValuePair "10-${bridge.bridgeName}" {
          netdevConfig = {
            Name = bridge.bridgeName;
            Kind = "bridge";
          };
        }
      ) cfg.bridges;

      # Configure bridge networks with gateway IPs
      networks = lib.mapAttrs' (
        name: bridge:
        let
          info = cfg._internal.bridges.${name};
        in
        lib.nameValuePair "10-${bridge.bridgeName}" {
          matchConfig.Name = bridge.bridgeName;
          networkConfig = {
            ConfigureWithoutCarrier = true;
          };
          # Assign gateway IP to the bridge (first IP in subnet)
          # CNI expects the bridge to have the gateway IP for routing
          address = [ "${info.gateway}/${info.mask}" ];
          linkConfig.RequiredForOnline = "no";
        }
      ) cfg.bridges;
    };

    # Trust all bridge interfaces in firewall
    networking.firewall.trustedInterfaces = lib.mapAttrsToList (_: b: b.bridgeName) cfg.bridges;
  };
}
