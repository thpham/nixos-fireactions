# Fireglab systemd services and system configuration
#
# This file contains:
# - User/group configuration
# - CNI configuration for fireglab network
# - systemd services (fireglab, kernel setup, config injection)
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
  cfg = config.services.fireglab;
  # Access standalone registry-cache module (no longer via fireactions)
  registryCacheCfg = config.services.registry-cache;
  # Access shared infrastructure from microvm-base
  microvmBaseCfg = config.services.microvm-base;

  # Kernel path from microvm-base (shared by all runner technologies)
  kernelPath = microvmBaseCfg._internal.kernelPath;

  # tc-redirect-tap from microvm-base
  tcRedirectTapPkg = microvmBaseCfg._internal.tcRedirectTapPkg;

  # CNI configuration for fireglab (separate network from fireactions/fireteact)
  cniConfig = {
    cniVersion = "1.0.0";
    name = "fireglab";
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

  cniConfigFile = pkgs.writeText "fireglab.conflist" (builtins.toJSON cniConfig);

  # Calculate gateway for config injection
  subnetParts = lib.splitString "/" cfg.networking.subnet;
  networkAddr = lib.head subnetParts;
  networkOctets = lib.splitString "." networkAddr;
  networkPrefix = "${lib.elemAt networkOctets 0}.${lib.elemAt networkOctets 1}.${lib.elemAt networkOctets 2}";
  gateway = "${networkPrefix}.1";

  # Generate fireglab config from NixOS options
  fireglabConfig = {
    server = {
      address = cfg.bindAddress;
      metricsAddress = cfg.metricsAddress;
    };

    gitlab = {
      instanceURL = cfg.gitlab.instanceUrl;
      # Access token is injected at runtime from file
      accessToken = "@GITLAB_ACCESS_TOKEN@";
      runnerType = cfg.gitlab.runnerType;
    }
    // lib.optionalAttrs (cfg.gitlab.groupId != null) {
      groupId = cfg.gitlab.groupId;
    }
    // lib.optionalAttrs (cfg.gitlab.projectId != null) {
      projectId = cfg.gitlab.projectId;
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
        tags = pool.runner.tags;
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

    # containerd settings use sensible defaults
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
  configFile = configFormat.generate "fireglab-config.yaml" fireglabConfig;

in
{
  config = lib.mkIf cfg.enable {
    #
    # Register bridge with microvm-base (shared infrastructure)
    #

    services.microvm-base = {
      enable = true;
      bridges.fireglab = {
        bridgeName = cfg.networking.bridgeName;
        subnet = cfg.networking.subnet;
        externalInterface = cfg.networking.externalInterface;
      };
    };

    #
    # User and Group Configuration
    #

    users.users.${cfg.user} = lib.mkIf (cfg.user != "root") {
      isSystemUser = true;
      group = cfg.group;
      extraGroups = [ "kvm" ];
      home = cfg.dataDir;
      description = "Fireglab service user";
    };

    users.groups.${cfg.group} = lib.mkIf (cfg.group != "root") { };

    #
    # containerd Registry Mirrors (when registry-cache is enabled)
    #

    virtualisation.containerd.settings.plugins."io.containerd.grpc.v1.cri".registry.mirrors =
      lib.mkIf (registryCacheCfg.enable && registryCacheCfg.zot.enable)
        (
          lib.mapAttrs' (
            name: _mirror:
            let
              endpoint = "http://${registryCacheCfg._internal.primaryGateway}:${toString registryCacheCfg._internal.zotPort}";
            in
            lib.nameValuePair name { endpoint = [ endpoint ]; }
          ) registryCacheCfg._internal.zotMirrors
        );

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

    environment.etc."cni/conf.d/fireglab.conflist".source = cniConfigFile;
    environment.etc."cni/net.d/fireglab.conflist".source = cniConfigFile;

    environment.etc."fireglab/config.yaml" = lib.mkIf (cfg.configFile == null) {
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
      "d /etc/fireglab 0750 ${cfg.user} ${cfg.group} -"
      "d /run/fireglab 0750 ${cfg.user} ${cfg.group} -"
      "d /var/log/fireglab 0750 ${cfg.user} ${cfg.group} -"

      # Cleanup stale socket files on boot (VMs that didn't shut down cleanly)
      "r ${cfg.dataDir}/pools/*/*.sock - - - - -"

      # Remove VM log files older than 1 day
      "e ${cfg.dataDir}/pools/*/*.log - - - 1d -"
    ];

    #
    # Setup Services
    #

    # Kernel setup
    systemd.services.fireglab-kernel-setup = {
      description = "Setup fireglab kernel";
      wantedBy = [ "fireglab.service" ];
      before = [ "fireglab.service" ];
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

    systemd.services.fireglab-config =
      let
        needsSecrets =
          cfg.gitlab.accessTokenFile != null
          || cfg.gitlab.instanceUrlFile != null
          || cfg.gitlab.groupIdFile != null
          || cfg.gitlab.projectIdFile != null
          || cfg.debug.sshKeyFile != null;
        needsRegistryCache = registryCacheCfg.enable;
        needsConfigService = cfg.configFile == null && (needsSecrets || needsRegistryCache);
      in
      lib.mkIf needsConfigService {
        description = "Prepare fireglab config with secrets and registry-cache metadata";
        wantedBy = [ "fireglab.service" ];
        before = [ "fireglab.service" ];
        requiredBy = [ "fireglab.service" ];

        restartTriggers = [ configFile ];

        # Wait for registry-cache CA to be generated (only if SSL bump is enabled)
        after = lib.optional (
          needsRegistryCache && registryCacheCfg._internal.squidSslBumpMode != "off"
        ) "registry-cache-ca-setup.service";

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = "root";
        };

        script = ''
          set -euo pipefail

          ${lib.optionalString (cfg.gitlab.accessTokenFile != null) ''
            if [ ! -f "${cfg.gitlab.accessTokenFile}" ]; then
              echo "ERROR: GitLab access token file not found: ${cfg.gitlab.accessTokenFile}"
              exit 1
            fi
          ''}

          ${lib.optionalString (cfg.gitlab.instanceUrlFile != null) ''
            if [ ! -f "${cfg.gitlab.instanceUrlFile}" ]; then
              echo "ERROR: GitLab instance URL file not found: ${cfg.gitlab.instanceUrlFile}"
              exit 1
            fi
          ''}

          ${lib.optionalString (cfg.gitlab.groupIdFile != null) ''
            if [ ! -f "${cfg.gitlab.groupIdFile}" ]; then
              echo "ERROR: GitLab group ID file not found: ${cfg.gitlab.groupIdFile}"
              exit 1
            fi
          ''}

          ${lib.optionalString (cfg.gitlab.projectIdFile != null) ''
            if [ ! -f "${cfg.gitlab.projectIdFile}" ]; then
              echo "ERROR: GitLab project ID file not found: ${cfg.gitlab.projectIdFile}"
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
            if [ ! -f "${registryCacheCfg._internal.caCertPath}" ]; then
              echo "ERROR: Registry cache CA certificate not found: ${registryCacheCfg._internal.caCertPath}"
              exit 1
            fi
          ''}

          # Inject secrets into config using Python for proper YAML handling
          export ACCESS_TOKEN_FILE="${
            lib.optionalString (cfg.gitlab.accessTokenFile != null) cfg.gitlab.accessTokenFile
          }"
          export INSTANCE_URL_FILE="${
            lib.optionalString (cfg.gitlab.instanceUrlFile != null) cfg.gitlab.instanceUrlFile
          }"
          export GROUP_ID_FILE="${
            lib.optionalString (cfg.gitlab.groupIdFile != null) cfg.gitlab.groupIdFile
          }"
          export PROJECT_ID_FILE="${
            lib.optionalString (cfg.gitlab.projectIdFile != null) cfg.gitlab.projectIdFile
          }"
          export DEBUG_SSH_KEY_FILE="${
            lib.optionalString (cfg.debug.sshKeyFile != null) cfg.debug.sshKeyFile
          }"

          # Fireglab gateway for cloud-init
          export FIREGLAB_GATEWAY="${gateway}"
          export REGISTRY_CACHE_GATEWAY="${lib.optionalString needsRegistryCache registryCacheCfg._internal.primaryGateway}"

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

          chown ${cfg.user}:${cfg.group} /run/fireglab/config.yaml
          chmod 0640 /run/fireglab/config.yaml
        '';
      };

    #
    # Main Fireglab Service
    #

    systemd.services.fireglab =
      let
        needsConfigService =
          cfg.configFile == null
          && (
            cfg.gitlab.accessTokenFile != null
            || cfg.gitlab.instanceUrlFile != null
            || cfg.gitlab.groupIdFile != null
            || cfg.gitlab.projectIdFile != null
            || cfg.debug.sshKeyFile != null
            || registryCacheCfg.enable
          );
        effectiveConfigPath =
          if needsConfigService then
            "/run/fireglab/config.yaml"
          else if cfg.configFile != null then
            cfg.configFile
          else
            "/etc/fireglab/config.yaml";
      in
      {
        description = "Fireglab - GitLab CI Runner Manager";
        wantedBy = [ "multi-user.target" ];
        after = [
          "network-online.target"
          "containerd.service"
          "fireglab-kernel-setup.service"
        ]
        ++ lib.optional needsConfigService "fireglab-config.service"
        ++ lib.optional (registryCacheCfg.enable && registryCacheCfg.zot.enable) "zot.service";
        requires = [ "containerd.service" ] ++ lib.optional needsConfigService "fireglab-config.service";
        wants = [
          "network-online.target"
        ]
        ++ lib.optional (registryCacheCfg.enable && registryCacheCfg.zot.enable) "zot.service";

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
          HOME = cfg.dataDir;
        };

        serviceConfig = {
          Type = "simple";
          User = cfg.user;
          Group = cfg.group;
          ExecStart = "${cfg.package}/bin/fireglab serve --config ${effectiveConfigPath}";
          Restart = "always";
          RestartSec = "10s";

          # Allow enough time for graceful shutdown:
          # - BusyRunnerGracePeriod (2min) for busy runners to complete jobs
          # - Plus 30s for cleanup (GitLab deregistration, VM destruction)
          TimeoutStopSec = "150s";

          # Cleanup stale socket files when service stops
          ExecStopPost = "${pkgs.findutils}/bin/find ${cfg.dataDir}/pools -name '*.sock' -delete";

          # OOM protection - critical infrastructure service
          OOMScoreAdjust = -900;
          OOMPolicy = "continue";

          # Security hardening
          NoNewPrivileges = false;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          ReadWritePaths = [
            cfg.dataDir
            "/run/fireglab"
            "/var/log/fireglab"
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
      };
  };
}
