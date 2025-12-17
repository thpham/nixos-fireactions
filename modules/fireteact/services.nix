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

    containerd = {
      address = "/run/containerd/containerd.sock";
      namespace = "fireteact";
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
          || cfg.gitea.runnerRepoFile != null;
        needsConfigService = cfg.configFile == null && needsSecrets;
      in
      lib.mkIf needsConfigService {
        description = "Prepare fireteact config with secrets";
        wantedBy = [ "fireteact.service" ];
        before = [ "fireteact.service" ];
        requiredBy = [ "fireteact.service" ];

        restartTriggers = [ configFile ];

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

          # Inject secrets into config using Python for proper YAML handling
          export API_TOKEN_FILE="${lib.optionalString (cfg.gitea.apiTokenFile != null) cfg.gitea.apiTokenFile}"
          export INSTANCE_URL_FILE="${lib.optionalString (cfg.gitea.instanceUrlFile != null) cfg.gitea.instanceUrlFile}"
          export RUNNER_OWNER_FILE="${lib.optionalString (cfg.gitea.runnerOwnerFile != null) cfg.gitea.runnerOwnerFile}"
          export RUNNER_REPO_FILE="${lib.optionalString (cfg.gitea.runnerRepoFile != null) cfg.gitea.runnerRepoFile}"

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
        needsConfigService = cfg.configFile == null && (
          cfg.gitea.apiTokenFile != null
          || cfg.gitea.instanceUrlFile != null
          || cfg.gitea.runnerOwnerFile != null
          || cfg.gitea.runnerRepoFile != null
        );
        # Use runtime config if secrets need injection, otherwise static config
        effectiveConfigPath =
          if needsConfigService then "/run/fireteact/config.yaml"
          else if cfg.configFile != null then cfg.configFile
          else "/etc/fireteact/config.yaml";
      in
      {
        description = "Fireteact - Gitea Actions Runner Manager";
        wantedBy = [ "multi-user.target" ];
        after = [
          "network-online.target"
          "containerd.service"
          "fireteact-kernel-setup.service"
        ] ++ lib.optional needsConfigService "fireteact-config.service";
        requires = [ "containerd.service" ] ++ lib.optional needsConfigService "fireteact-config.service";
        wants = [ "network-online.target" ];

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
        Address = lib.head (lib.splitString "/" cfg.networking.subnet) + "/24";
        ConfigureWithoutCarrier = true;
      };
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
  };
}
