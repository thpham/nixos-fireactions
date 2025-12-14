# Network isolation for Firecracker microVMs
#
# Implements strict network segmentation:
# - Block VM-to-VM communication (critical for multi-tenant isolation)
# - Block access to cloud metadata service (169.254.169.254)
# - Rate limit outbound connections (prevent abuse)
# - Allow only specific gateway services (DNS, DHCP, proxy)

{
  config,
  lib,
  ...
}:

let
  cfg = config.services.fireactions.security;
  networkCfg = cfg.network;
  fireactionsCfg = config.services.fireactions;

  # Calculate gateway IP from subnet (e.g., 10.200.0.0/24 -> 10.200.0.1)
  subnetParts = lib.splitString "/" fireactionsCfg.networking.subnet;
  networkAddr = builtins.head subnetParts;
  networkOctets = lib.splitString "." networkAddr;
  gatewayIp = lib.concatStringsSep "." (lib.take 3 networkOctets ++ [ "1" ]);

  # Format port list for nftables
  formatPorts = ports: lib.concatMapStringsSep ", " toString ports;
in
{
  options.services.fireactions.security.network = {
    enable = lib.mkEnableOption ''
      Network isolation for Firecracker microVMs.

      Implements strict network policies:
      - Blocks all VM-to-VM traffic on the bridge
      - Blocks access to cloud metadata (169.254.169.254)
      - Rate limits outbound connections
      - Restricts VM access to specific host services
    '';

    blockVmToVm = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Block direct communication between microVMs on the same bridge.

        This is critical for multi-tenant isolation - prevents one
        GitHub Actions job from communicating with or attacking another.
      '';
    };

    blockCloudMetadata = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Block access to HOST cloud metadata service (169.254.169.254).

        Prevents VMs from accessing the host's instance metadata, credentials,
        or other sensitive cloud provider information (Azure IMDS, AWS IMDS, GCP).

        NOTE: This does NOT affect Firecracker MMDS (used by cloud-init inside VMs).
        Firecracker MMDS is intercepted internally by Firecracker before traffic
        reaches the network, so cloud-init metadata injection continues to work.
      '';
    };

    rateLimitConnections = lib.mkOption {
      type = lib.types.int;
      default = 100;
      description = ''
        Maximum new connections per second allowed from each VM.

        Prevents abuse and DoS attacks from compromised jobs.
        Set to 0 to disable rate limiting.

        Note: This limit applies to new connections only; established
        connections are not affected.
      '';
    };

    allowedHostPorts = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [
        53 # DNS (dnsmasq)
        67 # DHCP
        3128 # Squid HTTP proxy
        3129 # Squid HTTPS proxy (SSL bump)
        5000 # Zot registry cache
      ];
      description = ''
        TCP ports on the gateway that VMs are allowed to access.

        Default includes DNS, DHCP, and optional proxy/registry services.
        All other ports on the gateway are blocked.
      '';
    };

    allowedHostUdpPorts = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [
        53 # DNS
        67 # DHCP
      ];
      description = ''
        UDP ports on the gateway that VMs are allowed to access.
      '';
    };

    additionalRules = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = ''
        Additional nftables rules to add to the fireactions_isolation table.

        Use this for custom policies like:
        - Allowing specific internal services
        - Blocking specific external destinations
        - Custom logging rules
      '';
      example = ''
        # Allow access to internal artifact storage
        iifname "fireactions0" ip daddr 10.0.0.50 tcp dport 443 accept

        # Log dropped packets (verbose)
        iifname "fireactions0" log prefix "fc-drop: " drop
      '';
    };
  };

  config = lib.mkIf (cfg.enable && networkCfg.enable) {
    # Enable nftables
    networking.nftables.enable = true;

    # nftables ruleset for VM isolation
    networking.nftables.tables.fireactions_isolation = {
      family = "inet";
      content = ''
        # Chain for forwarded traffic (VM to external, VM to VM)
        chain forward {
          type filter hook forward priority filter; policy accept;

          # Always allow established/related connections
          ct state established,related accept

          ${lib.optionalString networkCfg.blockVmToVm ''
            # CRITICAL: Block VM-to-VM communication on bridge
            # This prevents lateral movement between GitHub Actions jobs
            iifname "${fireactionsCfg.networking.bridgeName}" oifname "${fireactionsCfg.networking.bridgeName}" \
              counter drop comment "Block VM-to-VM traffic"
          ''}

          ${lib.optionalString networkCfg.blockCloudMetadata ''
            # Block access to cloud metadata services
            # Azure IMDS, AWS IMDS, GCP metadata all use this IP
            iifname "${fireactionsCfg.networking.bridgeName}" ip daddr 169.254.169.254 \
              counter drop comment "Block cloud metadata access"

            # Also block the link-local range used by some cloud metadata
            iifname "${fireactionsCfg.networking.bridgeName}" ip daddr 169.254.0.0/16 \
              counter drop comment "Block link-local metadata"
          ''}

          ${lib.optionalString (networkCfg.rateLimitConnections > 0) ''
            # Rate limit new outbound connections from VMs
            iifname "${fireactionsCfg.networking.bridgeName}" ct state new \
              limit rate over ${toString networkCfg.rateLimitConnections}/second burst 50 packets \
              counter drop comment "Rate limit new connections"
          ''}

          # Allow VMs to reach external networks (via NAT)
          iifname "${fireactionsCfg.networking.bridgeName}" oifname != "${fireactionsCfg.networking.bridgeName}" accept
        }

        # Chain for traffic to the host (gateway services)
        chain input {
          type filter hook input priority filter; policy accept;

          # Always allow established/related
          ct state established,related accept

          # Allow loopback
          iif lo accept

          ${lib.optionalString (networkCfg.allowedHostPorts != [ ]) ''
            # Allow VMs to access specific TCP services on gateway
            iifname "${fireactionsCfg.networking.bridgeName}" ip daddr ${gatewayIp} \
              tcp dport { ${formatPorts networkCfg.allowedHostPorts} } accept
          ''}

          ${lib.optionalString (networkCfg.allowedHostUdpPorts != [ ]) ''
            # Allow VMs to access specific UDP services on gateway
            iifname "${fireactionsCfg.networking.bridgeName}" ip daddr ${gatewayIp} \
              udp dport { ${formatPorts networkCfg.allowedHostUdpPorts} } accept
          ''}

          # Block VMs from accessing other host services
          iifname "${fireactionsCfg.networking.bridgeName}" ip daddr ${gatewayIp} \
            counter drop comment "Block unauthorized gateway access"

          # Block VMs from accessing host's external IP
          # (they should only communicate via gateway IP on bridge)
          iifname "${fireactionsCfg.networking.bridgeName}" \
            ip daddr != ${gatewayIp} \
            ip daddr != { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } \
            counter drop comment "Block VM to host external IP"

          ${networkCfg.additionalRules}
        }

        # Chain for logging (optional, for debugging)
        chain log_drops {
          # Uncomment for verbose logging during debugging
          # log prefix "nft-drop: " flags all
        }
      '';
    };

    # Ensure bridge traffic goes through nftables
    # (disable bridge-nf-call if using pure nftables at L3)
    boot.kernel.sysctl = {
      # Let nftables handle bridge traffic at L3
      "net.bridge.bridge-nf-call-iptables" = lib.mkDefault 1;
      "net.bridge.bridge-nf-call-ip6tables" = lib.mkDefault 1;
    };

    # Load bridge netfilter module for bridge traffic filtering
    boot.kernelModules = [ "br_netfilter" ];
  };
}
