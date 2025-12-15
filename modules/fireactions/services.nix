# Fireactions systemd services and system configuration
#
# This file contains:
# - Boot configuration (kernel modules, sysctl)
# - containerd and devmapper setup
# - CNI configuration
# - systemd services (fireactions, kernel setup, config injection)
# - Network configuration (firewall, NAT)

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.fireactions;
  registryCacheCfg = config.services.fireactions.registryCache;

  # Import our custom packages
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

  # Generate fireactions config from NixOS options (upstream YAML format)
  fireactionsConfig = {
    bind_address = cfg.bindAddress;
    log_level = cfg.logLevel;
    debug = cfg.debug;
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
    # Boot Configuration
    #

    # Ensure KVM is available
    boot.kernelModules = [
      "kvm-intel"
      "kvm-amd"
    ];

    # Enable IP forwarding for microVM networking
    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = 1;
      "net.ipv4.conf.all.forwarding" = 1;
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

    # Ensure /dev/kvm is accessible
    services.udev.extraRules = ''
      KERNEL=="kvm", GROUP="kvm", MODE="0660"
    '';

    #
    # containerd Configuration
    #

    # Enable containerd for OCI image handling
    # Firecracker requires devmapper snapshotter for block device support
    virtualisation.containerd = {
      enable = true;
      settings = {
        version = 2;
        plugins."io.containerd.grpc.v1.cri" = {
          sandbox_image = "pause:3.9";
        };
        # Configure devmapper snapshotter for Firecracker
        plugins."io.containerd.snapshotter.v1.devmapper" = {
          root_path = "/var/lib/containerd/devmapper";
          pool_name = "containerd-pool";
          base_image_size = "10GB";
          async_remove = true;
        };
      };
    };

    # Add registry mirrors to containerd when Zot is enabled
    # This allows the host's containerd to use the Zot cache for pulling runner images
    virtualisation.containerd.settings.plugins."io.containerd.grpc.v1.cri".registry.mirrors =
      lib.mkIf (registryCacheCfg.enable && registryCacheCfg.zot.enable)
        (
          lib.mapAttrs' (
            name: _mirror:
            let
              # Zot serves mirrors under namespace paths: http://gateway:5000/v2/<registry>/
              endpoint = "http://${registryCacheCfg._internal.gateway}:${toString registryCacheCfg._internal.zotPort}";
            in
            lib.nameValuePair name { endpoint = [ endpoint ]; }
          ) registryCacheCfg._internal.zotMirrors
        );

    # Add required tools to containerd's PATH for devmapper snapshotter
    # - util-linux: blkdiscard for TRIM/discard (required by containerd plugins)
    # - lvm2: dmsetup for device mapper operations
    # - thin-provisioning-tools: thin_check, thin_repair for thin pools
    # - e2fsprogs: mkfs.ext4 for formatting snapshot volumes
    systemd.services.containerd.path = [
      pkgs.util-linux
      pkgs.lvm2
      pkgs.thin-provisioning-tools
      pkgs.e2fsprogs
    ];

    #
    # Devmapper Setup Services
    #

    # Setup devmapper thin-pool for containerd (required for Firecracker)
    systemd.services.containerd-devmapper-setup = {
      description = "Setup devmapper thin-pool for containerd";
      wantedBy = [ "containerd.service" ];
      before = [ "containerd.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [
        pkgs.util-linux
        pkgs.lvm2
        pkgs.thin-provisioning-tools
      ];
      script = ''
        set -euo pipefail

        POOL_DIR="/var/lib/containerd/devmapper"
        DATA_FILE="$POOL_DIR/data"
        META_FILE="$POOL_DIR/metadata"

        # Skip if pool already exists
        if dmsetup status containerd-pool &>/dev/null; then
          echo "containerd-pool already exists"
          exit 0
        fi

        mkdir -p "$POOL_DIR"

        # Create sparse files for thin-pool (20GB data, 200MB metadata)
        if [ ! -f "$DATA_FILE" ]; then
          truncate -s 20G "$DATA_FILE"
        fi
        if [ ! -f "$META_FILE" ]; then
          truncate -s 200M "$META_FILE"
        fi

        # Setup loop devices
        DATA_DEV=$(losetup --find --show "$DATA_FILE")
        META_DEV=$(losetup --find --show "$META_FILE")

        # Get sizes in 512-byte sectors
        DATA_SIZE=$(blockdev --getsize "$DATA_DEV")
        META_SIZE=$(blockdev --getsize "$META_DEV")

        # Create thin-pool
        # Format: start length thin-pool metadata_dev data_dev data_block_size low_water_mark
        dmsetup create containerd-pool --table "0 $DATA_SIZE thin-pool $META_DEV $DATA_DEV 128 32768 1 skip_block_zeroing"

        echo "containerd-pool created successfully"
      '';
    };

    # Cleanup devmapper on shutdown
    systemd.services.containerd-devmapper-cleanup = {
      description = "Cleanup devmapper thin-pool for containerd";
      wantedBy = [ "multi-user.target" ];
      after = [ "containerd.service" ];
      path = [ pkgs.lvm2 ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Use PATH-relative command to avoid store path mismatches when building on target
        ExecStop = pkgs.writeShellScript "devmapper-cleanup" ''
          dmsetup remove containerd-pool || true
        '';
      };
      script = "true"; # No-op on start
    };

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

    # Create required directories
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 ${cfg.user} ${cfg.group} -"
      "d ${cfg.dataDir}/kernels 0750 ${cfg.user} ${cfg.group} -"
      "d ${cfg.dataDir}/rootfs 0750 ${cfg.user} ${cfg.group} -"
      "d ${cfg.dataDir}/templates 0750 ${cfg.user} ${cfg.group} -"
      "d /etc/fireactions 0750 ${cfg.user} ${cfg.group} -"
      "d /run/fireactions 0750 ${cfg.user} ${cfg.group} -"
      "d /var/log/fireactions 0750 ${cfg.user} ${cfg.group} -"
      # Network namespace directory for Firecracker VMs
      "d /run/netns 0755 root root -"
      # CNI plugins directory (standard path used by CNI libraries)
      "d /opt/cni/bin 0755 root root -"
      # CNI cache directory
      "d /var/lib/cni 0755 root root -"
    ];

    #
    # Setup Services
    #

    # Symlink CNI plugins to standard /opt/cni/bin path
    # CNI libraries often use this as a fallback regardless of config
    systemd.services.cni-plugins-setup = {
      description = "Setup CNI plugins in /opt/cni/bin";
      wantedBy = [ "fireactions.service" ];
      before = [ "fireactions.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        mkdir -p /opt/cni/bin
        # Link all CNI plugins
        for plugin in ${pkgs.cni-plugins}/bin/*; do
          ln -sf "$plugin" /opt/cni/bin/
        done
        # Link tc-redirect-tap
        ln -sf ${tcRedirectTapPkg}/bin/tc-redirect-tap /opt/cni/bin/
      '';
    };

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
        after = lib.optional (needsRegistryCache && registryCacheCfg._internal.squidSslBumpMode != "off") "registry-cache-ca-setup.service";

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
          export REGISTRY_CACHE_GATEWAY="${lib.optionalString needsRegistryCache registryCacheCfg._internal.gateway}"
          export DEBUG_SSH_KEY_FILE="${lib.optionalString (needsRegistryCache && registryCacheCfg._internal.debugSshKeyFile != null) registryCacheCfg._internal.debugSshKeyFile}"

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
        wants = [ "network-online.target" ]
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

          # Working directory
          WorkingDirectory = cfg.dataDir;

          # Security hardening
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
    # Network Configuration
    #

    # Create the bridge interface via systemd-networkd
    # This ensures the bridge exists before dnsmasq starts (CNI would only create it when containers run)
    systemd.network = {
      enable = true;
      netdevs."10-${cfg.networking.bridgeName}" = {
        netdevConfig = {
          Name = cfg.networking.bridgeName;
          Kind = "bridge";
        };
      };
      networks."10-${cfg.networking.bridgeName}" = {
        matchConfig.Name = cfg.networking.bridgeName;
        networkConfig = {
          ConfigureWithoutCarrier = true;
        };
        # Assign gateway IP to the bridge (first IP in subnet)
        # CNI expects the bridge to have the gateway IP for routing
        address = [
          (let
            # Parse subnet like "10.200.0.0/24" to get gateway "10.200.0.1/24"
            parts = lib.splitString "/" cfg.networking.subnet;
            network = lib.head parts;
            prefix = lib.last parts;
            octets = lib.splitString "." network;
            gateway = "${lib.elemAt octets 0}.${lib.elemAt octets 1}.${lib.elemAt octets 2}.1/${prefix}";
          in gateway)
        ];
        linkConfig.RequiredForOnline = "no";
      };
    };

    # Firewall rules for microVM networking (optional, can be disabled)
    networking.firewall = {
      allowedTCPPorts = lib.mkIf cfg.metricsEnable [
        (lib.toInt (lib.last (lib.splitString ":" cfg.metricsAddress)))
      ];
      trustedInterfaces = [ cfg.networking.bridgeName ];
    };

    # NAT configuration for microVM networking
    # CNI's ipMasq only creates NAT rules for CNI-assigned IPs, but our DHCP server
    # assigns different IPs. This adds subnet-wide masquerading for all VM traffic.
    networking.nat = {
      enable = true;
      internalInterfaces = [ cfg.networking.bridgeName ];
      internalIPs = [ cfg.networking.subnet ];
      externalInterface = cfg.networking.externalInterface;
    };
  };
}
