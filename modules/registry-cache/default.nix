# Standalone Registry and HTTP Cache for Firecracker microVMs
#
# This module provides:
# 1. Zot Registry: Pull-through cache for container registries (native OCI protocol)
# 2. Squid: HTTP/HTTPS caching proxy with selective SSL bump
#
# Architecture:
# - Container registry traffic: VM -> containerd hosts.toml -> Zot -> upstream registry
# - HTTP/HTTPS traffic: VM -> iptables REDIRECT -> Squid -> upstream
#
# This module is DECOUPLED from any specific runner technology (fireactions, fireteact, etc.)
# It works with any bridges registered in microvm-base.
#
# Usage:
#   services.registry-cache.enable = true;
#   # Auto-detects bridges from microvm-base, or specify manually:
#   services.registry-cache.networks = [
#     { bridgeName = "fireteact0"; subnet = "10.201.0.0/24"; }
#   ];

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.registry-cache;
  microvmBaseCfg = config.services.microvm-base;

  # Determine which networks to serve
  # If networks is empty and useMicrovmBaseBridges is true, use all bridges from microvm-base
  effectiveNetworks =
    if cfg.networks != [ ] then
      cfg.networks
    else if cfg.useMicrovmBaseBridges && microvmBaseCfg.enable then
      lib.mapAttrsToList (name: bridge: {
        inherit (bridge) bridgeName subnet;
        inherit name;
      }) microvmBaseCfg.bridges
    else
      [ ];

  # Parse subnet to get network info
  parseSubnet =
    subnet:
    let
      parts = lib.splitString "/" subnet;
      networkAddr = lib.head parts;
      mask = lib.elemAt parts 1;
      octets = lib.splitString "." networkAddr;
      prefix = "${lib.elemAt octets 0}.${lib.elemAt octets 1}.${lib.elemAt octets 2}";
    in
    {
      network = networkAddr;
      mask = mask;
      prefix = prefix;
      gateway = "${prefix}.1";
    };

  # Parse all networks with computed values
  parsedNetworks = map (
    net:
    let
      info = parseSubnet net.subnet;
    in
    net // info
  ) effectiveNetworks;

  # Use first network's gateway as primary (for Zot/Squid binding)
  primaryNetwork = if parsedNetworks != [ ] then lib.head parsedNetworks else null;
  primaryGateway = if primaryNetwork != null then primaryNetwork.gateway else "127.0.0.1";

  # All subnets for ACLs
  allSubnets = map (n: n.subnet) parsedNetworks;
  allBridgeNames = map (n: n.bridgeName) parsedNetworks;

  # Parse storage size to MB for Squid
  parseSizeToMB =
    sizeStr:
    let
      normalized = lib.toUpper (lib.replaceStrings [ " " ] [ "" ] sizeStr);
      numStr = lib.head (builtins.match "([0-9]+).*" normalized);
      num = lib.toInt numStr;
    in
    if lib.hasSuffix "TB" normalized then
      num * 1000000
    else if lib.hasSuffix "GB" normalized then
      num * 1000
    else if lib.hasSuffix "MB" normalized then
      num
    else
      num;

  storageSizeMB = parseSizeToMB cfg.storage.maxSize;
  memoryCacheMB = parseSizeToMB cfg.squid.memoryCache;

  # Squid paths
  caDir = "/var/lib/registry-cache";
  caCertPath = if cfg.squid.ca.certFile != null then cfg.squid.ca.certFile else "${caDir}/ca.crt";
  caKeyPath = if cfg.squid.ca.keyFile != null then cfg.squid.ca.keyFile else "${caDir}/ca.key";

  # Generate SSL bump domains ACL
  sslBumpDomainsAcl = lib.concatMapStringsSep " " (d: ".${d}") cfg.squid.sslBump.domains;

  # Squid configuration
  squidConfig = ''
    # ========================================
    # NETWORK CONFIGURATION
    # ========================================
    # Listen on all bridge gateways (one http_port per bridge)
    ${lib.concatMapStringsSep "\n    " (net: "http_port ${net.gateway}:3128 intercept") parsedNetworks}
    ${lib.optionalString (cfg.squid.sslBump.mode != "off") ''
      # HTTPS ports for all bridges
      ${lib.concatMapStringsSep "\n      " (net: ''
        https_port ${net.gateway}:3129 intercept ssl-bump \
                generate-host-certificates=on \
                dynamic_cert_mem_cache_size=512MB \
                cert=${caCertPath} \
                key=${caKeyPath}'') parsedNetworks}
    ''}

    # DNS servers
    dns_nameservers ${lib.concatStringsSep " " cfg.dns.upstreamServers}

    # Run as squid user
    cache_effective_user squid
    cache_effective_group squid

    ${lib.optionalString (cfg.squid.sslBump.mode != "off") ''
      # Certificate generator helper
      sslcrtd_program ${pkgs.squid}/libexec/security_file_certgen \
        -s ${caDir}/ssl_db -M 512MB
      sslcrtd_children 5
    ''}

    # ========================================
    # ACCESS CONTROL
    # ========================================
    ${lib.concatMapStringsSep "\n" (subnet: "acl localnet src ${subnet}") allSubnets}
    acl SSL_ports port 443
    acl Safe_ports port 80 443

    http_access allow localnet
    http_access deny all

    # ========================================
    # SSL BUMP CONFIGURATION
    # ========================================
    ${
      if cfg.squid.sslBump.mode == "selective" && cfg.squid.sslBump.domains != [ ] then
        ''
          # SELECTIVE MODE: Only bump configured domains
          acl bump_domains ssl::server_name ${sslBumpDomainsAcl}

          acl step1 at_step SslBump1
          acl step2 at_step SslBump2
          acl step3 at_step SslBump3

          ssl_bump peek step1
          ssl_bump stare bump_domains step2
          ssl_bump splice step2
          ssl_bump bump bump_domains step3
          ssl_bump splice step3
        ''
      else if cfg.squid.sslBump.mode == "selective" then
        ''
          # SELECTIVE MODE with no domains: splice all HTTPS
          ssl_bump splice all
        ''
      else if cfg.squid.sslBump.mode == "all" then
        ''
          # ALL MODE: Bump all HTTPS traffic
          acl step1 at_step SslBump1
          acl step2 at_step SslBump2
          acl step3 at_step SslBump3

          ssl_bump peek step1
          ssl_bump stare step2
          ssl_bump bump step3
        ''
      else
        "# HTTPS interception disabled"
    }

    # ========================================
    # CACHE CONFIGURATION
    # ========================================
    cache_dir aufs ${cfg.storage.cacheDir}/squid ${toString storageSizeMB} 16 256

    minimum_object_size 0 KB
    maximum_object_size 5 GB
    maximum_object_size_in_memory 10 MB

    cache_mem ${toString memoryCacheMB} MB

    cache_replacement_policy lru
    memory_replacement_policy lru

    refresh_pattern . 60 50% 1440

    # ========================================
    # LOGGING
    # ========================================
    access_log stdio:${cfg.logging.accessLog}
    cache_log stdio:${cfg.logging.cacheLog}

    pid_filename /run/squid.pid
    coredump_dir ${cfg.storage.cacheDir}/squid
  '';

  squidConfigFile = pkgs.writeText "squid.conf" squidConfig;

  # Zot configuration
  zotConfig = {
    distSpecVersion = "1.1.0";
    storage = {
      rootDirectory = "${cfg.storage.cacheDir}/zot";
      gc = true;
      gcDelay = "1h";
      gcInterval = "24h";
    };
    http = {
      address = "0.0.0.0";
      port = toString cfg.zot.port;
    };
    log = {
      level = "info";
    };
    extensions = {
      sync = {
        enable = true;
        registries = lib.mapAttrsToList (name: mirror: {
          urls = [ mirror.url ];
          content = [
            (
              {
                prefix = mirror.prefix;
              }
              // lib.optionalAttrs (name != "docker.io") {
                destination = "/${name}";
              }
            )
          ];
          onDemand = mirror.onDemand;
          tlsVerify = true;
        }) cfg.zot.mirrors;
      };
    };
  };

  zotConfigFile = pkgs.writeText "zot-config.json" (builtins.toJSON zotConfig);

  # Mirror type for Zot
  mirrorType = lib.types.submodule {
    options = {
      url = lib.mkOption {
        type = lib.types.str;
        description = "Upstream registry URL";
      };
      prefix = lib.mkOption {
        type = lib.types.str;
        default = "**";
        description = "Repository prefix to sync";
      };
      onDemand = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Pull-through cache mode";
      };
    };
  };

  # Network type for manual configuration
  networkType = lib.types.submodule {
    options = {
      name = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Optional name for this network";
      };
      bridgeName = lib.mkOption {
        type = lib.types.str;
        description = "Bridge interface name";
      };
      subnet = lib.mkOption {
        type = lib.types.str;
        description = "Subnet in CIDR notation";
      };
    };
  };

in
{
  imports = [
    ./nat.nix
  ];

  options.services.registry-cache = {
    enable = lib.mkEnableOption "registry and HTTP cache for microVMs";

    # ========================================
    # NETWORK CONFIGURATION
    # ========================================
    networks = lib.mkOption {
      type = lib.types.listOf networkType;
      default = [ ];
      description = ''
        Networks to serve with caching.
        Leave empty to auto-detect from microvm-base.bridges.
      '';
      example = lib.literalExpression ''
        [
          { bridgeName = "fireteact0"; subnet = "10.201.0.0/24"; }
        ]
      '';
    };

    useMicrovmBaseBridges = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        When networks is empty, automatically use all bridges
        registered in microvm-base.
      '';
    };

    # ========================================
    # ZOT REGISTRY OPTIONS
    # ========================================
    zot = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable Zot registry for container image caching";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 5000;
        description = "Port for Zot registry";
      };

      mirrors = lib.mkOption {
        type = lib.types.attrsOf mirrorType;
        default = {
          "docker.io" = {
            url = "https://registry-1.docker.io";
          };
          "ghcr.io" = {
            url = "https://ghcr.io";
          };
          "quay.io" = {
            url = "https://quay.io";
          };
          "gcr.io" = {
            url = "https://gcr.io";
          };
        };
        description = "Container registries to mirror via Zot";
      };
    };

    # ========================================
    # SQUID OPTIONS
    # ========================================
    squid = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable Squid for HTTP/HTTPS caching";
      };

      sslBump = {
        mode = lib.mkOption {
          type = lib.types.enum [
            "selective"
            "all"
            "off"
          ];
          default = "selective";
          description = "SSL bump mode";
        };

        domains = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Domains to SSL bump when mode=selective";
        };
      };

      memoryCache = lib.mkOption {
        type = lib.types.str;
        default = "256MB";
        description = "Memory cache size";
      };

      ca = {
        certFile = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = "CA certificate path (auto-generated if null)";
        };

        keyFile = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = "CA key path (auto-generated if null)";
        };

        validDays = lib.mkOption {
          type = lib.types.int;
          default = 3650;
          description = "CA certificate validity in days";
        };
      };
    };

    # ========================================
    # SHARED OPTIONS
    # ========================================
    storage = {
      cacheDir = lib.mkOption {
        type = lib.types.path;
        default = "/var/cache/registry-cache";
        description = "Base directory for cached data";
      };

      maxSize = lib.mkOption {
        type = lib.types.str;
        default = "50GB";
        description = "Maximum cache size for Squid";
      };
    };

    logging = {
      accessLog = lib.mkOption {
        type = lib.types.path;
        default = "/var/log/registry-cache/squid-access.log";
        description = "Squid access log path";
      };

      cacheLog = lib.mkOption {
        type = lib.types.path;
        default = "/var/log/registry-cache/squid-cache.log";
        description = "Squid cache log path";
      };
    };

    dns = {
      upstreamServers = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "8.8.8.8"
          "1.1.1.1"
        ];
        description = "Upstream DNS servers";
      };
    };

    # ========================================
    # INTERNAL OPTIONS (for downstream consumers)
    # ========================================
    _internal = {
      networks = lib.mkOption {
        type = lib.types.listOf lib.types.attrs;
        internal = true;
        readOnly = true;
        default = parsedNetworks;
        description = "Parsed network configurations";
      };

      primaryGateway = lib.mkOption {
        type = lib.types.str;
        internal = true;
        readOnly = true;
        default = primaryGateway;
        description = "Primary gateway IP for Zot/Squid";
      };

      zotPort = lib.mkOption {
        type = lib.types.port;
        internal = true;
        readOnly = true;
        default = cfg.zot.port;
      };

      zotMirrors = lib.mkOption {
        type = lib.types.attrsOf mirrorType;
        internal = true;
        readOnly = true;
        default = cfg.zot.mirrors;
      };

      caCertPath = lib.mkOption {
        type = lib.types.str;
        internal = true;
        readOnly = true;
        default = caCertPath;
      };

      squidSslBumpMode = lib.mkOption {
        type = lib.types.str;
        internal = true;
        readOnly = true;
        default = cfg.squid.sslBump.mode;
      };

      squidSslBumpDomains = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        internal = true;
        readOnly = true;
        default = cfg.squid.sslBump.domains;
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Assertions
    assertions = [
      {
        assertion = effectiveNetworks != [ ];
        message = "registry-cache requires at least one network. Either set networks manually or enable microvm-base with bridges.";
      }
    ];

    # ========================================
    # DIRECTORY SETUP
    # ========================================
    systemd.tmpfiles.rules = [
      "d ${cfg.storage.cacheDir} 0755 root root -"
      "d ${cfg.storage.cacheDir}/zot 0755 zot zot -"
      "d ${cfg.storage.cacheDir}/squid 0750 squid squid -"
      "d ${caDir} 0750 squid squid -"
      "d ${caDir}/ssl_db 0750 squid squid -"
      "d /var/log/registry-cache 0750 squid squid -"
    ];

    # ========================================
    # ZOT REGISTRY SERVICE
    # ========================================
    systemd.services.zot = lib.mkIf cfg.zot.enable {
      description = "Zot OCI Registry (Pull-through Cache)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "simple";
        User = "zot";
        Group = "zot";
        ExecStart = "${pkgs.zot}/bin/zot serve ${zotConfigFile}";
        Restart = "on-failure";
        RestartSec = 5;

        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ReadWritePaths = [ "${cfg.storage.cacheDir}/zot" ];
      };
    };

    users.users.zot = lib.mkIf cfg.zot.enable {
      isSystemUser = true;
      group = "zot";
      description = "Zot registry daemon user";
    };
    users.groups.zot = lib.mkIf cfg.zot.enable { };

    # ========================================
    # SQUID PROXY SERVICES
    # ========================================

    # CA certificate generation
    systemd.services.registry-cache-ca-setup =
      lib.mkIf (cfg.squid.enable && cfg.squid.sslBump.mode != "off" && cfg.squid.ca.certFile == null)
        {
          description = "Generate CA certificate for Squid SSL bump";
          wantedBy = [ "registry-cache-squid.service" ];
          before = [ "registry-cache-squid.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            User = "root";
          };
          script = ''
            set -euo pipefail

            CA_DIR="${caDir}"
            CA_CERT="$CA_DIR/ca.crt"
            CA_KEY="$CA_DIR/ca.key"

            mkdir -p "$CA_DIR"
            chown squid:squid "$CA_DIR"

            if [ -f "$CA_CERT" ] && [ -f "$CA_KEY" ]; then
              if ${pkgs.openssl}/bin/openssl x509 -checkend 2592000 -noout -in "$CA_CERT" 2>/dev/null; then
                echo "CA certificate exists and is valid"
                exit 0
              fi
              echo "CA certificate expired, regenerating..."
            fi

            ${pkgs.openssl}/bin/openssl genrsa -out "$CA_KEY" 4096
            ${pkgs.openssl}/bin/openssl req -new -x509 \
              -days ${toString cfg.squid.ca.validDays} \
              -key "$CA_KEY" \
              -out "$CA_CERT" \
              -subj "/CN=Registry Cache CA" \
              -addext "basicConstraints=critical,CA:TRUE" \
              -addext "keyUsage=critical,keyCertSign,cRLSign"

            chown squid:squid "$CA_CERT" "$CA_KEY"
            chmod 0644 "$CA_CERT"
            chmod 0600 "$CA_KEY"

            echo "CA certificate generated: $CA_CERT"
          '';
        };

    # SSL database initialization
    systemd.services.registry-cache-ssl-db-setup =
      lib.mkIf (cfg.squid.enable && cfg.squid.sslBump.mode != "off")
        {
          description = "Initialize Squid SSL certificate database";
          wantedBy = [ "registry-cache-squid.service" ];
          before = [ "registry-cache-squid.service" ];
          after = [ "registry-cache-ca-setup.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            User = "squid";
          };
          script = ''
            set -euo pipefail

            SSL_DB="${caDir}/ssl_db"

            if [ -f "$SSL_DB/index.txt" ]; then
              echo "SSL database already initialized"
              exit 0
            fi

            if [ -d "$SSL_DB" ]; then
              rm -rf "$SSL_DB"
            fi

            ${pkgs.squid}/libexec/security_file_certgen -c -s "$SSL_DB" -M 512MB
            echo "SSL database initialized"
          '';
        };

    # Main Squid service
    systemd.services.registry-cache-squid = lib.mkIf cfg.squid.enable {
      description = "Squid HTTP/HTTPS Cache Proxy";
      documentation = [ "man:squid(8)" ];
      wantedBy = [ "multi-user.target" ];
      after = [
        "network.target"
        "nss-lookup.target"
        "registry-cache-ca-setup.service"
        "registry-cache-ssl-db-setup.service"
      ];

      preStart = ''
        mkdir -p /var/log/registry-cache
        chown squid:squid /var/log/registry-cache
        ${pkgs.squid}/bin/squid --foreground -z -f ${squidConfigFile}
      '';

      serviceConfig = {
        PIDFile = "/run/squid.pid";
        ExecStart = "${pkgs.squid}/bin/squid --foreground -YCs -f ${squidConfigFile}";
        ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
        KillMode = "mixed";
        NotifyAccess = "all";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };

    users.users.squid = lib.mkIf cfg.squid.enable {
      isSystemUser = true;
      group = "squid";
      home = "${cfg.storage.cacheDir}/squid";
      createHome = true;
      description = "Squid proxy daemon user";
    };
    users.groups.squid = lib.mkIf cfg.squid.enable { };

    # ========================================
    # FIREWALL
    # ========================================
    networking.firewall.interfaces = lib.listToAttrs (
      map (
        net:
        lib.nameValuePair net.bridgeName {
          allowedTCPPorts =
            (lib.optional cfg.zot.enable cfg.zot.port)
            ++ (lib.optionals cfg.squid.enable [
              3128
              3129
            ]);
        }
      ) parsedNetworks
    );

    # ========================================
    # LOGROTATE
    # ========================================
    services.logrotate.settings.registry-cache = lib.mkIf cfg.squid.enable {
      files = "/var/log/registry-cache/*.log";
      frequency = "daily";
      rotate = 7;
      compress = true;
      delaycompress = true;
      missingok = true;
      notifempty = true;
      create = "0640 squid squid";
      postrotate = ''
        ${pkgs.systemd}/bin/systemctl kill --signal=HUP registry-cache-squid.service 2>/dev/null || true
      '';
    };
  };
}
