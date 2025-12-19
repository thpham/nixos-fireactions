# Fireactions systemd services and system configuration
#
# This file contains:
# - User/group configuration
# - CNI configuration for fireactions
# - systemd services (fireactions, kernel setup, config injection)
#
# Delegated to microvm-base:
# - Boot configuration (kernel modules, sysctl)
# - containerd and devmapper setup
# - Bridge creation via systemd-networkd
# - DNSmasq configuration
# - NAT configuration
# - CNI plugins setup
#
# Delegated to registry-cache (standalone module):
# - Zot/Squid caching services

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

    # Create required directories
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 ${cfg.user} ${cfg.group} -"
      "d ${cfg.dataDir}/kernels 0750 ${cfg.user} ${cfg.group} -"
      "d ${cfg.dataDir}/rootfs 0750 ${cfg.user} ${cfg.group} -"
      "d ${cfg.dataDir}/templates 0750 ${cfg.user} ${cfg.group} -"
      "d /etc/fireactions 0750 ${cfg.user} ${cfg.group} -"
      "d /run/fireactions 0750 ${cfg.user} ${cfg.group} -"
      "d /var/log/fireactions 0750 ${cfg.user} ${cfg.group} -"
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
            lib.optionalString (
              needsRegistryCache && registryCacheCfg._internal.debugSshKeyFile != null
            ) registryCacheCfg._internal.debugSshKeyFile
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
    # Firewall Configuration
    #

    # Firewall rules for metrics endpoint
    networking.firewall = {
      allowedTCPPorts = lib.mkIf cfg.metricsEnable [
        (lib.toInt (lib.last (lib.splitString ":" cfg.metricsAddress)))
      ];
    };
  };
}
