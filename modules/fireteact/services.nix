# Fireteact systemd services and system configuration
#
# This file contains:
# - Boot configuration (kernel modules, sysctl)
# - containerd integration (shared with fireactions)
# - CNI configuration for fireteact network
# - systemd services (fireteact, kernel setup, config injection)
# - Network configuration (firewall, NAT)

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.fireteact;
  # Access fireactions registry cache config (shared infrastructure)
  registryCacheCfg = config.services.fireactions.registryCache;

  # Calculate network values for DHCP configuration
  subnetParts = lib.splitString "/" cfg.networking.subnet;
  networkAddr = lib.head subnetParts;
  subnetMask = lib.elemAt subnetParts 1;
  networkOctets = lib.splitString "." networkAddr;
  networkPrefix = "${lib.elemAt networkOctets 0}.${lib.elemAt networkOctets 1}.${lib.elemAt networkOctets 2}";
  gateway = "${networkPrefix}.1";

  # DHCP range (for /24 subnet: .2 to .254)
  dhcpStart = "${networkPrefix}.2";
  dhcpEnd = "${networkPrefix}.254";
  netmask = if subnetMask == "24" then "255.255.255.0" else "255.255.255.0";

  # Import kernel packages (shared with fireactions)
  firecrackerKernelPkg = pkgs.callPackage ../../pkgs/firecracker-kernel.nix {
    kernelVersion = cfg.kernelVersion;
  };
  firecrackerKernelCustomPkg = pkgs.callPackage ../../pkgs/firecracker-kernel-custom.nix { };
  tcRedirectTapPkg = pkgs.callPackage ../../pkgs/tc-redirect-tap.nix { };

  # Determine kernel path based on source
  kernelPath =
    if cfg.kernelSource == "upstream" then
      "${firecrackerKernelPkg}/vmlinux"
    else if cfg.kernelSource == "custom" then
      "${firecrackerKernelCustomPkg}/vmlinux"
    else if cfg.kernelSource == "nixpkgs" then
      if pkgs.stdenv.hostPlatform.system == "x86_64-linux" then
        "${cfg.kernelPackage.dev}/vmlinux"
      else
        "${cfg.kernelPackage.out}/${pkgs.stdenv.hostPlatform.linux-kernel.target}"
    else
      throw "Invalid kernelSource: ${cfg.kernelSource}";

  # CNI configuration for fireteact (separate network from fireactions)
  cniConfig = {
    cniVersion = "1.0.0";
    name = "fireteact";
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

  cniConfigFile = pkgs.writeText "fireteact.conflist" (builtins.toJSON cniConfig);

  # Generate fireteact config from NixOS options
  fireteactConfig = {
    server = {
      address = cfg.bindAddress;
      metricsAddress = cfg.metricsAddress;
    };

    gitea = {
      instanceURL = cfg.gitea.instanceUrl;
      # API token is injected at runtime from file
      apiToken = "@GITEA_API_TOKEN@";
      runnerScope = cfg.gitea.runnerScope;
    }
    // lib.optionalAttrs (cfg.gitea.runnerOwner != null) {
      runnerOwner = cfg.gitea.runnerOwner;
    }
    // lib.optionalAttrs (cfg.gitea.runnerRepo != null) {
      runnerRepo = cfg.gitea.runnerRepo;
    };

    logLevel = cfg.logLevel;

    pools = map (pool: {
      name = pool.name;
      maxRunners = pool.maxRunners;
      minRunners = pool.minRunners;
      runner = {
        name = pool.runner.name;
        image = pool.runner.image;
        imagePullPolicy = pool.runner.imagePullPolicy;
        labels = pool.runner.labels;
      };
      firecracker = {
        memSizeMib = pool.firecracker.memSizeMib;
        vcpuCount = pool.firecracker.vcpuCount;
        kernelPath = kernelPath;
        kernelArgs = pool.firecracker.kernelArgs;
      }
      // lib.optionalAttrs (pool.firecracker.metadata != { }) {
        metadata = pool.firecracker.metadata;
      };
    }) cfg.pools;

    # containerd settings use sensible defaults, only override if needed
    # Images are stored in per-pool namespaces (pool.name) for isolation
    containerd = {
      address = "/run/containerd/containerd.sock";
      snapshotter = "devmapper";
    };

    cni = {
      confDir = "/etc/cni/conf.d";
      binDir = "/opt/cni/bin";
    };
  };

  # Use YAML format
  configFormat = pkgs.formats.yaml { };
  configFile = configFormat.generate "fireteact-config.yaml" fireteactConfig;

in
{
  config = lib.mkIf cfg.enable {
    #
    # Boot Configuration (may already be set by fireactions, use mkDefault)
    #

    boot.kernelModules = lib.mkDefault [
      "kvm-intel"
      "kvm-amd"
    ];

    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = lib.mkDefault 1;
      "net.ipv4.conf.all.forwarding" = lib.mkDefault 1;
    };

    #
    # User and Group Configuration
    #

    users.users.${cfg.user} = lib.mkIf (cfg.user != "root") {
      isSystemUser = true;
      group = cfg.group;
      extraGroups = [ "kvm" ];
      home = cfg.dataDir;
      description = "Fireteact service user";
    };

    users.groups.${cfg.group} = lib.mkIf (cfg.group != "root") { };

    services.udev.extraRules = lib.mkDefault ''
      KERNEL=="kvm", GROUP="kvm", MODE="0660"
    '';

    #
    # containerd Configuration (shared with fireactions)
    #

    virtualisation.containerd = {
      enable = true;
      settings = {
        version = 2;
        plugins."io.containerd.grpc.v1.cri" = {
          sandbox_image = "pause:3.9";
        };
        plugins."io.containerd.snapshotter.v1.devmapper" = {
          root_path = "/var/lib/containerd/devmapper";
          pool_name = "containerd-pool";
          base_image_size = "10GB";
          async_remove = true;
        };
      };
    };

    #
    # Required System Packages
    #

    environment.systemPackages = [
      pkgs.firecracker
      pkgs.containerd
      pkgs.runc
      pkgs.cni-plugins
      tcRedirectTapPkg
      pkgs.lvm2
      pkgs.thin-provisioning-tools
    ];

    #
    # CNI Configuration
    #

    environment.etc."cni/conf.d/fireteact.conflist".source = cniConfigFile;
    environment.etc."cni/net.d/fireteact.conflist".source = cniConfigFile;

    environment.etc."fireteact/config.yaml" = lib.mkIf (cfg.configFile == null) {
      source = configFile;
      mode = "0640";
      user = cfg.user;
      group = cfg.group;
    };

    #
    # Directory Setup
    #

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 ${cfg.user} ${cfg.group} -"
      "d ${cfg.dataDir}/kernels 0750 ${cfg.user} ${cfg.group} -"
      "d ${cfg.dataDir}/rootfs 0750 ${cfg.user} ${cfg.group} -"
      "d /etc/fireteact 0750 ${cfg.user} ${cfg.group} -"
      "d /run/fireteact 0750 ${cfg.user} ${cfg.group} -"
      "d /var/log/fireteact 0750 ${cfg.user} ${cfg.group} -"
      "d /run/netns 0755 root root -"
      "d /opt/cni/bin 0755 root root -"
      "d /var/lib/cni 0755 root root -"
    ];

    #
    # Setup Services
    #

    # CNI plugins setup (may already exist from fireactions)
    systemd.services.cni-plugins-setup-fireteact = {
      description = "Setup CNI plugins for fireteact";
      wantedBy = [ "fireteact.service" ];
      before = [ "fireteact.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        mkdir -p /opt/cni/bin
        for plugin in ${pkgs.cni-plugins}/bin/*; do
          ln -sf "$plugin" /opt/cni/bin/
        done
        ln -sf ${tcRedirectTapPkg}/bin/tc-redirect-tap /opt/cni/bin/
      '';
    };

    # Kernel setup
    systemd.services.fireteact-kernel-setup = {
      description = "Setup fireteact kernel";
      wantedBy = [ "fireteact.service" ];
      before = [ "fireteact.service" ];
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

    systemd.services.fireteact-config =
      let
        needsSecrets =
          cfg.gitea.apiTokenFile != null
          || cfg.gitea.instanceUrlFile != null
          || cfg.gitea.runnerOwnerFile != null
          || cfg.gitea.runnerRepoFile != null
          || cfg.debug.sshKeyFile != null;
        # Also need config service if registry cache is enabled (for cloud-init user-data)
        needsRegistryCache = registryCacheCfg.enable;
        needsConfigService = cfg.configFile == null && (needsSecrets || needsRegistryCache);
      in
      lib.mkIf needsConfigService {
        description = "Prepare fireteact config with secrets and registry-cache metadata";
        wantedBy = [ "fireteact.service" ];
        before = [ "fireteact.service" ];
        requiredBy = [ "fireteact.service" ];

        restartTriggers = [ configFile ];

        # Wait for registry-cache CA to be generated (only if SSL bump is enabled)
        after = lib.optional (needsRegistryCache && registryCacheCfg._internal.squidSslBumpMode != "off") "registry-cache-ca-setup.service";

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = "root";
        };

        script = ''
          set -euo pipefail

          ${lib.optionalString (cfg.gitea.apiTokenFile != null) ''
            if [ ! -f "${cfg.gitea.apiTokenFile}" ]; then
              echo "ERROR: Gitea API token file not found: ${cfg.gitea.apiTokenFile}"
              exit 1
            fi
          ''}

          ${lib.optionalString (cfg.gitea.instanceUrlFile != null) ''
            if [ ! -f "${cfg.gitea.instanceUrlFile}" ]; then
              echo "ERROR: Gitea instance URL file not found: ${cfg.gitea.instanceUrlFile}"
              exit 1
            fi
          ''}

          ${lib.optionalString (cfg.gitea.runnerOwnerFile != null) ''
            if [ ! -f "${cfg.gitea.runnerOwnerFile}" ]; then
              echo "ERROR: Gitea runner owner file not found: ${cfg.gitea.runnerOwnerFile}"
              exit 1
            fi
          ''}

          ${lib.optionalString (cfg.gitea.runnerRepoFile != null) ''
            if [ ! -f "${cfg.gitea.runnerRepoFile}" ]; then
              echo "ERROR: Gitea runner repo file not found: ${cfg.gitea.runnerRepoFile}"
              exit 1
            fi
          ''}

          ${lib.optionalString (cfg.debug.sshKeyFile != null) ''
            if [ ! -f "${cfg.debug.sshKeyFile}" ]; then
              echo "ERROR: Debug SSH key file not found: ${cfg.debug.sshKeyFile}"
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
          export API_TOKEN_FILE="${
            lib.optionalString (cfg.gitea.apiTokenFile != null) cfg.gitea.apiTokenFile
          }"
          export INSTANCE_URL_FILE="${
            lib.optionalString (cfg.gitea.instanceUrlFile != null) cfg.gitea.instanceUrlFile
          }"
          export RUNNER_OWNER_FILE="${
            lib.optionalString (cfg.gitea.runnerOwnerFile != null) cfg.gitea.runnerOwnerFile
          }"
          export RUNNER_REPO_FILE="${
            lib.optionalString (cfg.gitea.runnerRepoFile != null) cfg.gitea.runnerRepoFile
          }"
          export DEBUG_SSH_KEY_FILE="${
            lib.optionalString (cfg.debug.sshKeyFile != null) cfg.debug.sshKeyFile
          }"

          # Registry cache configuration (shared with fireactions)
          # Fireteact VMs use their own gateway for DNS but share the registry cache
          export FIRETEACT_GATEWAY="${gateway}"
          export REGISTRY_CACHE_GATEWAY="${lib.optionalString needsRegistryCache registryCacheCfg._internal.gateway}"

          # Zot registry mirror configuration
          export ZOT_ENABLED="${lib.boolToString (needsRegistryCache && registryCacheCfg.zot.enable)}"
          export ZOT_PORT="${lib.optionalString needsRegistryCache (toString registryCacheCfg._internal.zotPort)}"
          export ZOT_MIRRORS='${lib.optionalString needsRegistryCache (builtins.toJSON (
            lib.mapAttrs (name: mirror: { url = mirror.url; }) registryCacheCfg._internal.zotMirrors
          ))}'

          # Squid SSL bump configuration
          export SQUID_SSL_BUMP_MODE="${lib.optionalString needsRegistryCache registryCacheCfg._internal.squidSslBumpMode}"
          export SQUID_SSL_BUMP_DOMAINS="${lib.optionalString needsRegistryCache (lib.concatStringsSep "," registryCacheCfg._internal.squidSslBumpDomains)}"
          export SQUID_CA_FILE="${lib.optionalString (needsRegistryCache && registryCacheCfg._internal.squidSslBumpMode != "off") registryCacheCfg._internal.caCertPath}"

          ${pkgs.python3.withPackages (ps: [ ps.pyyaml ])}/bin/python3 ${./inject-secrets.py}

          chown ${cfg.user}:${cfg.group} /run/fireteact/config.yaml
          chmod 0640 /run/fireteact/config.yaml
        '';
      };

    #
    # Main Fireteact Service
    #

    systemd.services.fireteact =
      let
        needsConfigService =
          cfg.configFile == null
          && (
            cfg.gitea.apiTokenFile != null
            || cfg.gitea.instanceUrlFile != null
            || cfg.gitea.runnerOwnerFile != null
            || cfg.gitea.runnerRepoFile != null
            || cfg.debug.sshKeyFile != null
          );
        # Use runtime config if secrets need injection, otherwise static config
        effectiveConfigPath =
          if needsConfigService then
            "/run/fireteact/config.yaml"
          else if cfg.configFile != null then
            cfg.configFile
          else
            "/etc/fireteact/config.yaml";
      in
      {
        description = "Fireteact - Gitea Actions Runner Manager";
        wantedBy = [ "multi-user.target" ];
        after = [
          "network-online.target"
          "containerd.service"
          "fireteact-kernel-setup.service"
        ]
        ++ lib.optional needsConfigService "fireteact-config.service";
        requires = [ "containerd.service" ] ++ lib.optional needsConfigService "fireteact-config.service";
        wants = [ "network-online.target" ];

        # Add required tools to PATH for CNI plugins
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
          ExecStart = "${cfg.package}/bin/fireteact serve --config ${effectiveConfigPath}";
          Restart = "always";
          RestartSec = "10s";

          # Security hardening
          NoNewPrivileges = false; # Needs to spawn VMs
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          ReadWritePaths = [
            cfg.dataDir
            "/run/fireteact"
            "/var/log/fireteact"
            "/run/containerd"
            "/var/lib/containerd"
            "/run/netns"
            "/var/lib/cni"
          ];

          # Capabilities for VM management
          AmbientCapabilities = [
            "CAP_NET_ADMIN"
            "CAP_SYS_ADMIN"
          ];
          CapabilityBoundingSet = [
            "CAP_NET_ADMIN"
            "CAP_SYS_ADMIN"
            "CAP_CHOWN"
            "CAP_FOWNER"
            "CAP_SETUID"
            "CAP_SETGID"
          ];
        };

        environment = {
          HOME = cfg.dataDir;
        };
      };

    #
    # Network Configuration
    #

    # Create bridge interface for fireteact (separate from fireactions)
    systemd.network.networks."50-fireteact-bridge" = {
      matchConfig.Name = cfg.networking.bridgeName;
      networkConfig = {
        ConfigureWithoutCarrier = true;
      };
      # Assign gateway IP to the bridge (first IP in subnet)
      # CNI expects the bridge to have the gateway IP for routing
      address = [
        (
          let
            # Parse subnet like "10.201.0.0/24" to get gateway "10.201.0.1/24"
            parts = lib.splitString "/" cfg.networking.subnet;
            network = lib.head parts;
            prefix = lib.last parts;
            octets = lib.splitString "." network;
            gateway = "${lib.elemAt octets 0}.${lib.elemAt octets 1}.${lib.elemAt octets 2}.1/${prefix}";
          in
          gateway
        )
      ];
      linkConfig.RequiredForOnline = "no";
    };

    systemd.network.netdevs."50-fireteact-bridge" = {
      netdevConfig = {
        Name = cfg.networking.bridgeName;
        Kind = "bridge";
      };
    };

    # NAT for fireteact subnet
    # Use mkDefault to allow provider-specific overrides and merge with fireactions
    networking.nat = {
      enable = lib.mkDefault true;
      internalInterfaces = [ cfg.networking.bridgeName ];
      internalIPs = [ cfg.networking.subnet ];
      externalInterface = lib.mkDefault cfg.networking.externalInterface;
    };

    # Firewall rules for fireteact
    networking.firewall = {
      # Allow traffic from fireteact VMs to internet
      trustedInterfaces = [ cfg.networking.bridgeName ];
    };

    #
    # DNSMASQ (DHCP + DNS for VMs)
    #
    # VMs use DHCP to get their IP address from dnsmasq running on the bridge
    # Use lib.mkAfter for list settings to merge with fireactions' registry-cache dnsmasq config
    services.dnsmasq = {
      enable = true;
      settings = {
        # Add fireteact bridge interface (merges with fireactions' interface if both enabled)
        interface = lib.mkAfter [ cfg.networking.bridgeName ];
        bind-interfaces = true;

        # DNS settings (only set if not already configured by fireactions)
        no-resolv = lib.mkDefault true;
        server = lib.mkDefault [
          "8.8.8.8"
          "1.1.1.1"
        ];
        cache-size = lib.mkDefault 1000;
        log-queries = lib.mkDefault false;

        # DHCP settings for fireteact subnet (merges with fireactions' dhcp-range)
        # Use set: tag to scope this range, allowing per-subnet dhcp-options
        dhcp-range = lib.mkAfter [ "set:fireteact,${dhcpStart},${dhcpEnd},${netmask},12h" ];
        # Use tag: to scope options to fireteact subnet only
        dhcp-option = lib.mkAfter [
          "tag:fireteact,3,${gateway}" # Gateway for fireteact subnet
          "tag:fireteact,6,${gateway}" # DNS server for fireteact subnet
        ];
        dhcp-rapid-commit = lib.mkDefault true;
      };
    };

    # Ensure dnsmasq waits for the bridge interface to be created
    systemd.services.dnsmasq = {
      after = [ "sys-subsystem-net-devices-${cfg.networking.bridgeName}.device" ];
      wants = [ "sys-subsystem-net-devices-${cfg.networking.bridgeName}.device" ];
    };
  };
}
