# Fireactions systemd services and system configuration
#
# This file contains:
# - User/group configuration
# - CNI configuration for fireactions
# - systemd services (fireactions, kernel setup, config injection)
# - Built-in security hardening (systemd isolation, network isolation)
#
# Delegated to microvm-base:
# - Boot configuration (kernel modules, sysctl)
# - containerd and devmapper setup
# - Bridge creation via systemd-networkd
# - DNSmasq configuration
# - NAT configuration
# - CNI plugins setup
# - Storage security (LUKS, tmpfs secrets, snapshot cleanup)
#
# Delegated to registry-cache (standalone module):
# - Zot/Squid caching services
#
# Security model:
# - Firecracker's KVM-based VM isolation is the primary security boundary
# - Network isolation (VM-to-VM blocking, metadata protection) is always enabled
# - Systemd service hardening is always enabled
# - Host-level security (sysctls, LUKS) is in microvm-base.security

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.fireactions;
  # Access standalone registry-cache module (no longer nested under fireactions)
  registryCacheCfg = config.services.registry-cache;
  # Access shared infrastructure from microvm-base
  microvmBaseCfg = config.services.microvm-base;

  # Kernel path from microvm-base (shared by all runner technologies)
  kernelPath = microvmBaseCfg._internal.kernelPath;

  # tc-redirect-tap from microvm-base
  tcRedirectTapPkg = microvmBaseCfg._internal.tcRedirectTapPkg;

  # CNI configuration
  cniConfig = {
    cniVersion = "1.0.0";
    name = "fireactions";
    plugins = [
      {
        type = "bridge";
        bridge = cfg.networking.bridgeName;
        isGateway = true;
        ipMasq = true;
        ipam = {
          type = "host-local";
          subnet = cfg.networking.subnet;
          routes = [ { dst = "0.0.0.0/0"; } ];
        };
      }
      { type = "firewall"; }
      { type = "tc-redirect-tap"; }
    ];
  };

  cniConfigFile = pkgs.writeText "fireactions.conflist" (builtins.toJSON cniConfig);

  #
  # Network isolation configuration (always enabled)
  #

  # Calculate gateway IP from subnet (e.g., 10.200.0.0/24 -> 10.200.0.1)
  subnetParts = lib.splitString "/" cfg.networking.subnet;
  networkAddr = builtins.head subnetParts;
  networkOctets = lib.splitString "." networkAddr;
  gatewayIp = lib.concatStringsSep "." (lib.take 3 networkOctets ++ [ "1" ]);

  # Network isolation settings (hardcoded for security - not configurable)
  networkIsolation = {
    blockVmToVm = true;
    blockCloudMetadata = true;
    rateLimitConnections = 100;
    allowedHostPorts = [
      53 # DNS (dnsmasq)
      67 # DHCP
      3128 # Squid HTTP proxy
      3129 # Squid HTTPS proxy (SSL bump)
      5000 # Zot registry cache
    ];
    allowedHostUdpPorts = [
      53 # DNS
      67 # DHCP
    ];
  };

  # Format port list for nftables
  formatPorts = ports: lib.concatMapStringsSep ", " toString ports;

  # Generate fireactions config from NixOS options (upstream YAML format)
  fireactionsConfig = {
    bind_address = cfg.bindAddress;
    log_level = cfg.logLevel;
    basic_auth_enabled = cfg.basicAuth.enable;
  }
  // lib.optionalAttrs (cfg.basicAuth.enable && cfg.basicAuth.users != { }) {
    basic_auth_users = cfg.basicAuth.users;
  }
  // {
    metrics = {
      enabled = cfg.metricsEnable;
      address = cfg.metricsAddress;
    };

    github = {
      # app_id: use placeholder if appIdFile is set, otherwise use direct value
      app_id = if cfg.github.appIdFile != null then "@GITHUB_APP_ID@" else cfg.github.appId;
      # app_private_key is injected at runtime from appPrivateKeyFile
      # Placeholder that gets replaced by fireactions-config service
      app_private_key = "@GITHUB_APP_PRIVATE_KEY@";
    };

    pools = map (pool: {
      name = pool.name;
      max_runners = pool.maxRunners;
      min_runners = pool.minRunners;
      runner = {
        name = pool.runner.name;
        image = pool.runner.image;
        image_pull_policy = pool.runner.imagePullPolicy;
        organization = pool.runner.organization;
        labels = pool.runner.labels;
      }
      // lib.optionalAttrs (pool.runner.groupId != null) {
        group_id = pool.runner.groupId;
      };
      firecracker = {
        binary_path = "firecracker";
        kernel_image_path = kernelPath;
        kernel_args = pool.firecracker.kernelArgs;
        cni_conf_dir = "/etc/cni/conf.d";
        cni_bin_dirs = [
          "${pkgs.cni-plugins}/bin"
          "${tcRedirectTapPkg}/bin"
        ];
        machine_config = {
          mem_size_mib = pool.firecracker.memSizeMib;
          vcpu_count = pool.firecracker.vcpuCount;
        };
      }
      # Add metadata if configured (either user-defined or auto-injected)
      // lib.optionalAttrs (pool.firecracker.metadata != { }) {
        metadata = pool.firecracker.metadata;
      };
    }) cfg.pools;
  };

  # Use YAML format via pkgs.formats.yaml
  configFormat = pkgs.formats.yaml { };
  configFile = configFormat.generate "fireactions-config.yaml" fireactionsConfig;

in
{
  config = lib.mkIf cfg.enable {
    #
    # Register bridge with microvm-base (shared infrastructure)
    #

    services.microvm-base = {
      enable = true;
      bridges.fireactions = {
        bridgeName = cfg.networking.bridgeName;
        subnet = cfg.networking.subnet;
        externalInterface = cfg.networking.externalInterface;
      };
    };

    #
    # User and Group Configuration
    #

    # Create fireactions user and group (only if not running as root)
    users.users.${cfg.user} = lib.mkIf (cfg.user != "root") {
      isSystemUser = true;
      group = cfg.group;
      extraGroups = [ "kvm" ];
      home = cfg.dataDir;
      description = "Fireactions service user";
    };

    users.groups.${cfg.group} = lib.mkIf (cfg.group != "root") { };

    #
    # containerd Registry Mirrors (when registry-cache is enabled)
    #

    # Add registry mirrors to containerd when Zot is enabled
    # This allows the host's containerd to use the Zot cache for pulling runner images
    virtualisation.containerd.settings.plugins."io.containerd.grpc.v1.cri".registry.mirrors =
      lib.mkIf (registryCacheCfg.enable && registryCacheCfg.zot.enable)
        (
          lib.mapAttrs' (
            name: _mirror:
            let
              # Zot serves mirrors under namespace paths: http://gateway:5000/v2/<registry>/
              endpoint = "http://${registryCacheCfg._internal.primaryGateway}:${toString registryCacheCfg._internal.zotPort}";
            in
            lib.nameValuePair name { endpoint = [ endpoint ]; }
          ) registryCacheCfg._internal.zotMirrors
        );

    #
    # System Packages
    #

    # Install required packages
    environment.systemPackages = [
      cfg.package
      pkgs.firecracker
      pkgs.containerd
      pkgs.runc
      pkgs.cni-plugins
      tcRedirectTapPkg
      # Required for devmapper snapshotter
      pkgs.lvm2
      pkgs.thin-provisioning-tools
    ];

    #
    # CNI Configuration
    #

    # CNI configuration - place in both directories:
    # - conf.d: used by fireactions (cni_conf_dir setting)
    # - net.d: used by containerd CRI plugin (default path)
    environment.etc."cni/conf.d/fireactions.conflist".source = cniConfigFile;
    environment.etc."cni/net.d/fireactions.conflist".source = cniConfigFile;

    # Generate fireactions config file (only if not using custom configFile)
    environment.etc."fireactions/config.yaml" = lib.mkIf (cfg.configFile == null) {
      source = configFile;
      mode = "0640";
      user = cfg.user;
      group = cfg.group;
    };

    #
    # Directory Setup
    #

    # Create required directories and cleanup rules
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 ${cfg.user} ${cfg.group} -"
      "d ${cfg.dataDir}/kernels 0750 ${cfg.user} ${cfg.group} -"
      "d ${cfg.dataDir}/rootfs 0750 ${cfg.user} ${cfg.group} -"
      "d ${cfg.dataDir}/templates 0750 ${cfg.user} ${cfg.group} -"
      "d /etc/fireactions 0750 ${cfg.user} ${cfg.group} -"
      "d /run/fireactions 0750 ${cfg.user} ${cfg.group} -"
      "d /var/log/fireactions 0750 ${cfg.user} ${cfg.group} -"

      # Cleanup stale socket files on boot (VMs that didn't shut down cleanly)
      "r ${cfg.dataDir}/pools/*/*.sock - - - - -"

      # Remove VM log files older than 1 day
      "e ${cfg.dataDir}/pools/*/runner-*.log - - - 1d -"
    ];

    #
    # Setup Services
    #

    # Link kernel to expected location
    systemd.services.fireactions-kernel-setup = {
      description = "Setup fireactions kernel";
      wantedBy = [ "fireactions.service" ];
      before = [ "fireactions.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "root";
      };
      script = ''
        mkdir -p ${cfg.dataDir}/kernels
        ln -sf ${kernelPath} ${cfg.dataDir}/kernels/vmlinux
        chown -R ${cfg.user}:${cfg.group} ${cfg.dataDir}/kernels
      '';
    };

    #
    # Config Preparation Service
    #

    # Config preparation service - injects secrets and registry-cache metadata at runtime
    systemd.services.fireactions-config =
      let
        needsGithubSecrets = cfg.github.appPrivateKeyFile != null || cfg.github.appIdFile != null;
        needsRegistryCache = registryCacheCfg.enable;
        needsConfigService = cfg.configFile == null && (needsGithubSecrets || needsRegistryCache);
      in
      lib.mkIf needsConfigService {
        description = "Prepare fireactions config with secrets and registry-cache metadata";
        wantedBy = [ "fireactions.service" ];
        before = [ "fireactions.service" ];
        requiredBy = [ "fireactions.service" ];

        # Restart when base config changes (e.g., pool settings, organization)
        restartTriggers = [ configFile ];

        # Wait for registry-cache CA to be generated (only if SSL bump is enabled)
        after = lib.optional (
          needsRegistryCache && registryCacheCfg._internal.squidSslBumpMode != "off"
        ) "registry-cache-ca-setup.service";

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = "root"; # Need root to read secrets
        };

        script = ''
          set -euo pipefail

          ${lib.optionalString (cfg.github.appPrivateKeyFile != null) ''
            # Verify the private key file exists
            if [ ! -f "${cfg.github.appPrivateKeyFile}" ]; then
              echo "ERROR: GitHub App private key file not found: ${cfg.github.appPrivateKeyFile}"
              exit 1
            fi
          ''}

          ${lib.optionalString (cfg.github.appIdFile != null) ''
            # Verify the app ID file exists
            if [ ! -f "${cfg.github.appIdFile}" ]; then
              echo "ERROR: GitHub App ID file not found: ${cfg.github.appIdFile}"
              exit 1
            fi
          ''}

          ${lib.optionalString (needsRegistryCache && registryCacheCfg._internal.squidSslBumpMode != "off") ''
            # Verify the registry-cache CA cert exists (only needed for SSL bump)
            if [ ! -f "${registryCacheCfg._internal.caCertPath}" ]; then
              echo "ERROR: Registry cache CA certificate not found: ${registryCacheCfg._internal.caCertPath}"
              exit 1
            fi
          ''}

          # Inject secrets into config using Python for proper YAML handling
          export APP_ID_FILE="${lib.optionalString (cfg.github.appIdFile != null) cfg.github.appIdFile}"
          export PRIVATE_KEY_FILE="${
            lib.optionalString (cfg.github.appPrivateKeyFile != null) cfg.github.appPrivateKeyFile
          }"

          # Registry cache configuration
          export REGISTRY_CACHE_GATEWAY="${lib.optionalString needsRegistryCache registryCacheCfg._internal.primaryGateway}"
          export DEBUG_SSH_KEY_FILE="${
            lib.optionalString (cfg.debug.sshKeyFile != null) cfg.debug.sshKeyFile
          }"

          # Zot registry mirror configuration
          export ZOT_ENABLED="${lib.boolToString (needsRegistryCache && registryCacheCfg.zot.enable)}"
          export ZOT_PORT="${lib.optionalString needsRegistryCache (toString registryCacheCfg._internal.zotPort)}"
          export ZOT_MIRRORS='${
            lib.optionalString needsRegistryCache (
              builtins.toJSON (
                lib.mapAttrs (name: mirror: { url = mirror.url; }) registryCacheCfg._internal.zotMirrors
              )
            )
          }'

          # Squid SSL bump configuration
          export SQUID_SSL_BUMP_MODE="${lib.optionalString needsRegistryCache registryCacheCfg._internal.squidSslBumpMode}"
          export SQUID_SSL_BUMP_DOMAINS="${lib.optionalString needsRegistryCache (lib.concatStringsSep "," registryCacheCfg._internal.squidSslBumpDomains)}"
          export SQUID_CA_FILE="${
            lib.optionalString (
              needsRegistryCache && registryCacheCfg._internal.squidSslBumpMode != "off"
            ) registryCacheCfg._internal.caCertPath
          }"

          ${pkgs.python3.withPackages (ps: [ ps.ruamel-yaml ])}/bin/python3 ${./inject-secrets.py}

          # Set proper permissions
          chown ${cfg.user}:${cfg.group} /run/fireactions/config.yaml
          chmod 0640 /run/fireactions/config.yaml
        '';
      };

    #
    # Main Fireactions Service
    #

    systemd.services.fireactions =
      let
        # Whether we need the config service (file-based secrets or registry-cache metadata)
        needsConfigService =
          cfg.configFile == null
          && (
            cfg.github.appPrivateKeyFile != null || cfg.github.appIdFile != null || registryCacheCfg.enable
          );
      in
      {
        description = "Fireactions - GitHub Actions Runner Manager";
        wantedBy = [ "multi-user.target" ];
        after = [
          "network-online.target"
          "containerd.service"
          "fireactions-kernel-setup.service"
        ]
        ++ lib.optional needsConfigService "fireactions-config.service"
        ++ lib.optional (registryCacheCfg.enable && registryCacheCfg.zot.enable) "zot.service";
        requires = [ "containerd.service" ] ++ lib.optional needsConfigService "fireactions-config.service";
        wants = [
          "network-online.target"
        ]
        ++ lib.optional (registryCacheCfg.enable && registryCacheCfg.zot.enable) "zot.service";

        # Restart when config changes
        restartTriggers = [ configFile ];

        path = [
          pkgs.firecracker
          pkgs.containerd
          pkgs.runc
          pkgs.cni-plugins
          tcRedirectTapPkg
          pkgs.iptables
          pkgs.iproute2
        ];

        environment = {
          CNI_PATH = lib.makeBinPath [
            pkgs.cni-plugins
            tcRedirectTapPkg
          ];
          NETCONFPATH = "/etc/cni/conf.d";
        };

        serviceConfig = {
          Type = "simple";
          User = cfg.user;
          Group = cfg.group;
          ExecStart =
            if cfg.configFile != null then
              "${cfg.package}/bin/fireactions server --config ${cfg.configFile}"
            else if needsConfigService then
              "${cfg.package}/bin/fireactions server --config /run/fireactions/config.yaml"
            else
              "${cfg.package}/bin/fireactions server --config /etc/fireactions/config.yaml";
          Restart = "on-failure";
          RestartSec = 5;

          # Allow enough time for graceful shutdown (runner unregistration from GitHub API)
          TimeoutStopSec = "60s";

          # Cleanup stale socket files when service stops
          ExecStopPost = "${pkgs.findutils}/bin/find ${cfg.dataDir}/pools -name '*.sock' -delete";

          # Working directory
          WorkingDirectory = cfg.dataDir;

          # OOM protection - critical infrastructure service
          OOMScoreAdjust = -900;
          OOMPolicy = "continue";

          #
          # Security hardening (built-in, always enabled)
          #

          # Basic isolation
          NoNewPrivileges = false; # Needs privileges for network setup
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          ReadWritePaths = [
            cfg.dataDir
            "/run/containerd"
            "/var/log/fireactions"
            "/etc/fireactions"
            "/var/run/netns" # For Firecracker network namespaces
            "/run/netns" # Symlink target
            "/var/lib/cni" # CNI plugin cache directory
          ];

          # System call filtering - allow only necessary syscall groups
          SystemCallFilter = [
            "@system-service"
            "@mount"
            "@network-io"
            "@privileged"
            "~@obsolete"
          ];
          SystemCallArchitectures = "native";

          # Memory protection
          MemoryDenyWriteExecute = true;

          # Personality restrictions
          LockPersonality = true;

          # Restrict address families to required ones
          RestrictAddressFamilies = [
            "AF_UNIX"
            "AF_INET"
            "AF_INET6"
            "AF_NETLINK"
          ];

          # Restrict namespace creation (except network for VMs)
          RestrictNamespaces = "~user pid ipc";

          # Protect clock and kernel resources
          ProtectClock = true;
          ProtectKernelLogs = true;
          ProtectKernelModules = true;
          ProtectKernelTunables = true;
          ProtectControlGroups = true;
          ProtectProc = "invisible";

          # Restrict realtime scheduling
          RestrictRealtime = true;

          # Restrict SUID/SGID execution
          RestrictSUIDSGID = true;

          # Private /dev with only needed devices
          PrivateDevices = false; # Need /dev/kvm access

          # Remove all capabilities not explicitly needed
          SecureBits = "noroot-locked";

          # Capabilities for Firecracker networking
          AmbientCapabilities = [
            "CAP_NET_ADMIN"
            "CAP_SYS_ADMIN"
          ];
          CapabilityBoundingSet = [
            "CAP_NET_ADMIN"
            "CAP_SYS_ADMIN"
            "CAP_NET_RAW"
          ];

          # Resource limits
          LimitNOFILE = 65536;
          LimitNPROC = 4096;
        };
      };

    #
    # Firewall Configuration
    #

    # Firewall rules for metrics endpoint
    networking.firewall = {
      allowedTCPPorts = lib.mkIf cfg.metricsEnable [
        (lib.toInt (lib.last (lib.splitString ":" cfg.metricsAddress)))
      ];
    };

    #
    # Network Isolation (Built-in, always enabled)
    #
    # Implements strict network segmentation for multi-tenant security:
    # - Block VM-to-VM communication (prevent lateral movement)
    # - Block access to cloud metadata service (169.254.169.254)
    # - Rate limit outbound connections (prevent abuse)
    # - Allow only specific gateway services (DNS, DHCP, proxy)
    #

    # Enable nftables for network isolation
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

          # CRITICAL: Block VM-to-VM communication on bridge
          # This prevents lateral movement between GitHub Actions jobs
          iifname "${cfg.networking.bridgeName}" oifname "${cfg.networking.bridgeName}" \
            counter drop comment "Block VM-to-VM traffic"

          # Block access to cloud metadata services
          # Azure IMDS, AWS IMDS, GCP metadata all use this IP
          iifname "${cfg.networking.bridgeName}" ip daddr 169.254.169.254 \
            counter drop comment "Block cloud metadata access"

          # Also block the link-local range used by some cloud metadata
          iifname "${cfg.networking.bridgeName}" ip daddr 169.254.0.0/16 \
            counter drop comment "Block link-local metadata"

          # Rate limit new outbound connections from VMs
          iifname "${cfg.networking.bridgeName}" ct state new \
            limit rate over ${toString networkIsolation.rateLimitConnections}/second burst 50 packets \
            counter drop comment "Rate limit new connections"

          # Allow VMs to reach external networks (via NAT)
          iifname "${cfg.networking.bridgeName}" oifname != "${cfg.networking.bridgeName}" accept
        }

        # Chain for traffic to the host (gateway services)
        chain input {
          type filter hook input priority filter; policy accept;

          # Always allow established/related
          ct state established,related accept

          # Allow loopback
          iif lo accept

          # Allow VMs to access specific TCP services on gateway
          iifname "${cfg.networking.bridgeName}" ip daddr ${gatewayIp} \
            tcp dport { ${formatPorts networkIsolation.allowedHostPorts} } accept

          # Allow VMs to access specific UDP services on gateway
          iifname "${cfg.networking.bridgeName}" ip daddr ${gatewayIp} \
            udp dport { ${formatPorts networkIsolation.allowedHostUdpPorts} } accept

          # Allow DHCP broadcast (client sends to 255.255.255.255:67)
          iifname "${cfg.networking.bridgeName}" ip daddr 255.255.255.255 udp dport 67 accept

          # Block VMs from accessing other host services
          iifname "${cfg.networking.bridgeName}" ip daddr ${gatewayIp} \
            counter drop comment "Block unauthorized gateway access"

          # Block VMs from accessing host's external IP
          # (they should only communicate via gateway IP on bridge)
          # Exceptions:
          # - 169.254.0.0/16: Firecracker MMDS (metadata service)
          # - 255.255.255.255: DHCP broadcast
          iifname "${cfg.networking.bridgeName}" \
            ip daddr != ${gatewayIp} \
            ip daddr != { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 255.255.255.255 } \
            counter drop comment "Block VM to host external IP"
        }
      '';
    };

    # Kernel modules and sysctls for bridge traffic filtering
    boot.kernelModules = [ "br_netfilter" ];
    boot.kernel.sysctl = {
      # Let nftables handle bridge traffic at L3
      "net.bridge.bridge-nf-call-iptables" = lib.mkDefault 1;
      "net.bridge.bridge-nf-call-ip6tables" = lib.mkDefault 1;
    };
  };
}
