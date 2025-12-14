# Hybrid Registry and HTTP Cache for Fireactions
#
# This module provides:
# 1. Zot Registry: Pull-through cache for container registries (native OCI protocol)
# 2. Squid: HTTP/HTTPS caching proxy with selective SSL bump
#
# Architecture:
# - Container registry traffic: VM → containerd hosts.toml → Zot → upstream registry
# - HTTP/HTTPS traffic: VM → iptables REDIRECT → Squid → upstream
#
# Benefits:
# - No CA certificates needed in containers for registry pulls (Zot uses native OCI)
# - Multi-stage Docker builds work out of the box
# - Optional HTTPS caching for configured domains via Squid SSL bump
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.fireactions.registryCache;
  fireactionsCfg = config.services.fireactions;

  # Calculate gateway IP from subnet (e.g., 10.200.0.0/24 -> 10.200.0.1)
  subnetParts = lib.splitString "/" fireactionsCfg.networking.subnet;
  networkAddr = lib.head subnetParts;
  subnetMask = lib.elemAt subnetParts 1;
  networkOctets = lib.splitString "." networkAddr;
  networkPrefix = "${lib.elemAt networkOctets 0}.${lib.elemAt networkOctets 1}.${lib.elemAt networkOctets 2}";
  gateway = "${networkPrefix}.1";

  # DHCP range (for /24 subnet: .2 to .254)
  dhcpStart = "${networkPrefix}.2";
  dhcpEnd = "${networkPrefix}.254";
  netmask = if subnetMask == "24" then "255.255.255.0" else "255.255.255.0";

  # Parse storage size to MB for Squid (e.g., "50GB" -> 50000)
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
    http_port ${gateway}:3128 intercept
    ${lib.optionalString (cfg.squid.sslBump.mode != "off") ''
      https_port ${gateway}:3129 intercept ssl-bump \
        generate-host-certificates=on \
        dynamic_cert_mem_cache_size=512MB \
        cert=${caCertPath} \
        key=${caKeyPath}
    ''}

    # DNS servers
    dns_nameservers ${lib.concatStringsSep " " cfg.dns.upstreamServers}

    # Run as squid user (matches systemd service)
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
    acl localnet src ${fireactionsCfg.networking.subnet}
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
          # SELECTIVE MODE: Only bump configured domains, splice everything else
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
          # SELECTIVE MODE with no domains configured: splice all HTTPS (no MITM)
          ssl_bump splice all
        ''
      else if cfg.squid.sslBump.mode == "all" then
        ''
          # ALL MODE: Bump all HTTPS traffic (requires CA everywhere)
          acl step1 at_step SslBump1
          acl step2 at_step SslBump2
          acl step3 at_step SslBump3

          ssl_bump peek step1
          ssl_bump stare step2
          ssl_bump bump step3
        ''
      else
        ''
          # HTTPS interception disabled
        ''
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

    # Default freshness
    refresh_pattern . 60 50% 1440

    # ========================================
    # LOGGING
    # ========================================
    access_log stdio:${cfg.logging.accessLog}
    cache_log stdio:${cfg.logging.cacheLog}

    # Required by systemd service
    pid_filename /run/squid.pid
    coredump_dir ${cfg.storage.cacheDir}/squid
  '';

  squidConfigFile = pkgs.writeText "squid.conf" squidConfig;

  # Zot configuration JSON
  # NOTE: docker.io uses NO destination prefix because:
  # - BuildKit sends requests like /v2/library/alpine/... (no registry prefix)
  # - Other registries (ghcr.io, etc.) use destination prefix since containerd
  #   hosts.toml with override_path=true handles the path rewriting
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
                # Only add destination prefix for non-Docker Hub registries
                # Docker Hub images are stored at root (e.g., /library/alpine)
                # so BuildKit can access them without path rewriting
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

  # Credential type for registry authentication
  credentialType = lib.types.submodule {
    options = {
      username = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Username for registry authentication";
      };
      usernameFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Path to file containing username";
      };
      password = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Password for registry authentication";
      };
      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Path to file containing password";
      };
    };
  };

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
        description = "Pull-through cache mode (fetch on first request)";
      };
      credentials = lib.mkOption {
        type = lib.types.nullOr credentialType;
        default = null;
        description = "Optional credentials for this registry";
      };
    };
  };

in
{
  options.services.fireactions.registryCache = {
    enable = lib.mkEnableOption "registry and HTTP cache for Firecracker VMs";

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
        description = ''
          Container registries to mirror via Zot.
          Each entry creates a namespace under the local registry.
        '';
        example = lib.literalExpression ''
          {
            "docker.io" = { url = "https://registry-1.docker.io"; };
            "ghcr.io" = { url = "https://ghcr.io"; };
            "harbor.corp" = {
              url = "https://harbor.internal.corp";
              credentials = {
                usernameFile = config.sops.secrets.harbor-user.path;
                passwordFile = config.sops.secrets.harbor-pass.path;
              };
            };
          }
        '';
      };
    };

    # ========================================
    # SQUID HTTP/HTTPS CACHE OPTIONS
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
          description = ''
            SSL bump mode:
            - "selective": Only MITM domains in 'domains' list (default, recommended)
            - "all": MITM all HTTPS traffic (requires CA in all containers)
            - "off": No HTTPS interception (HTTP caching only)
          '';
        };

        domains = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = ''
            Domains to SSL bump when mode="selective".
            Leave empty to splice (passthrough) all HTTPS traffic.
          '';
          example = [
            "internal.corp"
            "cache.example.com"
          ];
        };
      };

      memoryCache = lib.mkOption {
        type = lib.types.str;
        default = "256MB";
        description = "Memory cache for hot objects";
      };

      ca = {
        certFile = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = "Path to CA certificate. Auto-generated if null.";
        };

        keyFile = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = "Path to CA private key. Auto-generated if null.";
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
        description = "Path to Squid access log";
      };

      cacheLog = lib.mkOption {
        type = lib.types.path;
        default = "/var/log/registry-cache/squid-cache.log";
        description = "Path to Squid cache log";
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

    # Debug options
    debug = {
      sshKeyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "SSH public key file for VM debugging access";
      };
    };

    # Internal options (used by services.nix)
    _internal = {
      gateway = lib.mkOption {
        type = lib.types.str;
        internal = true;
        default = gateway;
      };

      zotPort = lib.mkOption {
        type = lib.types.port;
        internal = true;
        default = cfg.zot.port;
      };

      zotMirrors = lib.mkOption {
        type = lib.types.attrsOf mirrorType;
        internal = true;
        default = cfg.zot.mirrors;
      };

      caCertPath = lib.mkOption {
        type = lib.types.str;
        internal = true;
        default = caCertPath;
      };

      debugSshKeyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        internal = true;
        default = cfg.debug.sshKeyFile;
      };

      squidSslBumpMode = lib.mkOption {
        type = lib.types.str;
        internal = true;
        default = cfg.squid.sslBump.mode;
      };

      squidSslBumpDomains = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        internal = true;
        default = cfg.squid.sslBump.domains;
      };
    };
  };

  config = lib.mkIf (fireactionsCfg.enable && cfg.enable) {
    # ========================================
    # DNSMASQ (DHCP + DNS for VMs)
    # ========================================
    services.dnsmasq = {
      enable = true;
      settings = {
        interface = fireactionsCfg.networking.bridgeName;
        bind-interfaces = true;
        no-resolv = true;
        server = cfg.dns.upstreamServers;
        cache-size = 1000;
        log-queries = false;
        dhcp-range = "${dhcpStart},${dhcpEnd},${netmask},12h";
        dhcp-option = [
          "3,${gateway}"
          "6,${gateway}"
        ];
        dhcp-rapid-commit = true;
      };
    };

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

        # Security hardening
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

    # CA certificate generation (only if SSL bump is enabled)
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
              echo "CA certificate expired or expiring soon, regenerating..."
            fi

            ${pkgs.openssl}/bin/openssl genrsa -out "$CA_KEY" 4096
            ${pkgs.openssl}/bin/openssl req -new -x509 \
              -days ${toString cfg.squid.ca.validDays} \
              -key "$CA_KEY" \
              -out "$CA_CERT" \
              -subj "/CN=Fireactions Registry Cache CA" \
              -addext "basicConstraints=critical,CA:TRUE" \
              -addext "keyUsage=critical,keyCertSign,cRLSign"

            chown squid:squid "$CA_CERT" "$CA_KEY"
            chmod 0644 "$CA_CERT"
            chmod 0600 "$CA_KEY"

            echo "CA certificate generated: $CA_CERT"
          '';
        };

    # SSL database initialization (only if SSL bump is enabled)
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

    # Main Squid service (follows NixOS native squid module pattern)
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

      # preStart runs as root (no User in serviceConfig)
      # This allows proper directory creation and cache initialization
      preStart = ''
        # Create log directory
        mkdir -p /var/log/registry-cache
        chown squid:squid /var/log/registry-cache

        # Initialize cache directories if needed
        ${pkgs.squid}/bin/squid --foreground -z -f ${squidConfigFile}
      '';

      serviceConfig = {
        # Note: No User/Group here - Squid starts as root and drops
        # privileges via cache_effective_user in config
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
    networking.firewall.interfaces.${fireactionsCfg.networking.bridgeName} = {
      allowedTCPPorts =
        (lib.optional cfg.zot.enable cfg.zot.port)
        ++ (lib.optionals cfg.squid.enable [
          3128
          3129
        ]);
      allowedUDPPorts = [
        53
        67
      ]; # DNS + DHCP
    };

    # ========================================
    # NAT RULES FOR SQUID TRANSPARENT PROXY
    # ========================================
    # Use nftables when security module enables it, otherwise fallback to iptables
    networking.nftables.tables.registry_cache_nat =
      lib.mkIf (cfg.squid.enable && config.networking.nftables.enable)
        {
          family = "ip";
          content = ''
            chain prerouting {
              type nat hook prerouting priority dstnat; policy accept;

              # Redirect HTTP (80) to Squid intercept port (skip gateway traffic)
              iifname "${fireactionsCfg.networking.bridgeName}" ip daddr != ${gateway} tcp dport 80 \
                redirect to :3128

              ${lib.optionalString (cfg.squid.sslBump.mode != "off") ''
                # Redirect HTTPS (443) to Squid intercept port (for SSL bump)
                iifname "${fireactionsCfg.networking.bridgeName}" ip daddr != ${gateway} tcp dport 443 \
                  redirect to :3129
              ''}
            }
          '';
        };

    # Fallback to iptables when nftables is not enabled
    networking.nat = lib.mkIf (cfg.squid.enable && !config.networking.nftables.enable) {
      enable = true;
      internalInterfaces = [ fireactionsCfg.networking.bridgeName ];
      extraCommands = ''
        # Redirect HTTP (80) to Squid intercept port
        iptables -t nat -A PREROUTING -i ${fireactionsCfg.networking.bridgeName} \
          -p tcp --dport 80 \
          ! -d ${gateway} \
          -j REDIRECT --to-port 3128
        ${lib.optionalString (cfg.squid.sslBump.mode != "off") ''
          # Redirect HTTPS (443) to Squid intercept port (for SSL bump)
          iptables -t nat -A PREROUTING -i ${fireactionsCfg.networking.bridgeName} \
            -p tcp --dport 443 \
            ! -d ${gateway} \
            -j REDIRECT --to-port 3129
        ''}
      '';
      extraStopCommands = ''
        iptables -t nat -D PREROUTING -i ${fireactionsCfg.networking.bridgeName} \
          -p tcp --dport 80 \
          ! -d ${gateway} \
          -j REDIRECT --to-port 3128 2>/dev/null || true
        ${lib.optionalString (cfg.squid.sslBump.mode != "off") ''
          iptables -t nat -D PREROUTING -i ${fireactionsCfg.networking.bridgeName} \
            -p tcp --dport 443 \
            ! -d ${gateway} \
            -j REDIRECT --to-port 3129 2>/dev/null || true
        ''}
      '';
    };

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
