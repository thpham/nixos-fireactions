# Transparent Registry Proxy Cache for Fireactions
#
# This module provides a fully transparent caching proxy for container registries.
# VMs pull images normally (e.g., `docker pull ghcr.io/...`) without any explicit
# proxy configuration - iptables interception + MITM proxy makes caching invisible.
#
# Architecture:
# 1. VMs resolve registry domains to their real IPs (via upstream DNS)
# 2. iptables PREROUTING intercepts HTTPS traffic from VM bridge and REDIRECTs to Squid
# 3. Squid uses SO_ORIGINAL_DST to get the real destination and performs SSL bump
# 4. Cached responses are served from Squid; cache misses go to upstream registries
#
# Components:
# - dnsmasq: DHCP server for VMs (DNS forwarded to upstream, no interception)
# - iptables: REDIRECT rule to intercept HTTPS traffic from VMs
# - Squid: SSL-bump MITM proxy with LRU caching
# - CA generation: Auto-generated CA certificate for TLS termination
# - Cloud-init integration: CA certificate injected via MMDS at VM boot
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
      # Remove any spaces and convert to uppercase
      normalized = lib.toUpper (lib.replaceStrings [ " " ] [ "" ] sizeStr);
      # Extract number and unit
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
      num; # Assume MB if no unit

  storageSizeMB = parseSizeToMB cfg.storage.maxSize;
  memoryCacheMB = parseSizeToMB cfg.storage.memoryCache;

  # Note: We use iptables REDIRECT for transparent interception, NOT DNS overrides.
  # DNS-based interception (pointing registry domains to Squid IP) doesn't work
  # because Squid's intercept mode verifies Host headers against destination IPs.
  # With iptables, Squid can retrieve the original destination via SO_ORIGINAL_DST.

  # Generate Squid ACL domains
  squidDomains = lib.concatStringsSep " " (
    map (r: if r == "docker.io" then ".docker.io .registry-1.docker.io" else ".${r}") cfg.registries
  );

  # CA certificate paths
  caDir = "/var/lib/registry-cache";
  caCertPath = if cfg.ca.certFile != null then cfg.ca.certFile else "${caDir}/ca.crt";
  caKeyPath = if cfg.ca.keyFile != null then cfg.ca.keyFile else "${caDir}/ca.key";

  # Upstream DNS servers for Squid (bypass local dnsmasq to avoid loop)
  # Squid must resolve registry domains to real IPs, not back to itself
  squidDnsServers = lib.concatStringsSep " " cfg.dns.upstreamServers;

  # Squid configuration
  squidConfig = ''
    # ========================================
    # NETWORK CONFIGURATION
    # ========================================
    # Listen on gateway IP for intercepted traffic
    # iptables REDIRECT sends traffic here from the VM bridge interface
    http_port ${gateway}:3128 intercept
    https_port ${gateway}:3129 intercept ssl-bump \
      generate-host-certificates=on \
      dynamic_cert_mem_cache_size=512MB \
      cert=${caCertPath} \
      key=${caKeyPath}

    # Use upstream DNS servers directly
    # This avoids any potential issues with local resolver configuration
    dns_nameservers ${squidDnsServers}

    # Certificate generator helper
    sslcrtd_program ${pkgs.squid}/libexec/security_file_certgen \
      -s ${caDir}/ssl_db -M 512MB
    sslcrtd_children 5

    # ========================================
    # ACCESS CONTROL
    # ========================================
    # Define registry domains to intercept
    acl registries dstdomain ${squidDomains}
    acl localnet src ${fireactionsCfg.networking.subnet}
    acl SSL_ports port 443
    acl Safe_ports port 80 443

    # Allow only local network
    http_access allow localnet
    http_access deny all

    # SSL bump configuration
    # We use peek-then-bump to properly mimic server certificates with SANs.
    # Without peek, Squid generates certs with only CN (no SANs), which
    # modern clients (Go 1.15+, Docker) reject.
    #
    # Steps:
    # 1. step1: Peek at ClientHello to get SNI, initiate connection to server
    # 2. step2: Stare at server certificate to get its properties (including SANs)
    # 3. step3: Bump (generate fake cert mimicking server cert with SANs)
    acl step1 at_step SslBump1
    acl step2 at_step SslBump2
    acl step3 at_step SslBump3

    ssl_bump peek step1
    ssl_bump stare step2
    ssl_bump bump step3

    # ========================================
    # FRESHNESS POLICY (refresh_pattern)
    # Controls when to revalidate, NOT storage lifetime
    # Format: refresh_pattern regex MIN_AGE PERCENT MAX_AGE [options]
    # ========================================

    # Registry blobs (content-addressable) - never revalidate (immutable)
    # Path: /v2/<name>/blobs/sha256:<digest>
    refresh_pattern -i /v2/.*/blobs/sha256:[a-f0-9]+ 10080 100% 525600 override-expire ignore-no-store ignore-private

    # Registry manifests by digest - never revalidate (immutable)
    refresh_pattern -i /v2/.*/manifests/sha256:[a-f0-9]+ 10080 100% 525600 override-expire ignore-no-store ignore-private

    # Registry manifests by tag - short freshness (tags can change)
    refresh_pattern -i /v2/.*/manifests/[^/]+$ 1 50% 60

    # Registry API endpoints - don't cache
    refresh_pattern -i /v2/?$ 0 0% 0
    refresh_pattern -i /v2/_catalog 0 0% 0
    refresh_pattern -i /v2/.*/tags/list 0 0% 0

    # Token endpoints - don't cache
    refresh_pattern -i /token 0 0% 0
    refresh_pattern -i /oauth2/token 0 0% 0

    # Default for everything else
    refresh_pattern . 60 50% 1440

    # ========================================
    # STORAGE WITH LRU EVICTION
    # When full, least-recently-used objects are evicted
    # On miss, re-fetch from upstream (transparent to client)
    # ========================================

    # Cache directory: type path size_MB L1 L2
    cache_dir aufs ${cfg.storage.cacheDir} ${toString storageSizeMB} 16 256

    # Object size limits
    minimum_object_size 0 KB
    maximum_object_size 5 GB
    maximum_object_size_in_memory 10 MB

    # Memory cache (hot objects)
    cache_mem ${toString memoryCacheMB} MB

    # LRU replacement policy
    cache_replacement_policy lru
    memory_replacement_policy lru

    # ========================================
    # PERFORMANCE TUNING
    # ========================================

    # Aggressive caching - store even if upstream says no-cache
    # (Registry blobs are immutable by digest, safe to ignore headers)
    ignore_expect_100 on

    # Logging
    logformat combined %>a %[ui %[un [%tl] "%rm %ru HTTP/%rv" %>Hs %<st "%{Referer}>h" "%{User-Agent}>h" %Ss:%Sh
    access_log daemon:${cfg.logging.accessLog} combined
    cache_log ${cfg.logging.cacheLog}

    ${lib.optionalString cfg.logging.logCacheStatus ''
      # Cache hit headers for debugging
      reply_header_add X-Cache-Status HIT all
    ''}

    # PID file
    pid_filename /run/squid/squid.pid

    # Coredump directory
    coredump_dir ${cfg.storage.cacheDir}
  '';

  squidConfigFile = pkgs.writeText "squid.conf" squidConfig;

  # Cloud-init user-data template for VMs
  # This gets injected into MMDS metadata and processed by cloud-init in the VM
  # Note: DNS is configured via DHCP (dnsmasq option 6) → systemd-resolved
  #       No need for resolv_conf in cloud-init user-data
  cloudInitUserData = pkgs.writeText "cloud-init-user-data.yaml" ''
    #cloud-config
    # Registry cache CA certificate
    # Injected by fireactions registry-cache module

    ca_certs:
      trusted:
        - |
          @REGISTRY_CACHE_CA_CERT@
  '';

  # Credential type for registry authentication
  credentialType = lib.types.submodule {
    options = {
      username = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Username for registry authentication (use usernameFile for secrets)";
      };
      usernameFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Path to file containing username";
      };
      password = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Password for registry authentication (use passwordFile for secrets)";
      };
      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Path to file containing password";
      };
    };
  };

in
{
  options.services.fireactions.registryCache = {
    enable = lib.mkEnableOption "transparent registry proxy cache for Firecracker VMs";

    registries = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "ghcr.io"
        "docker.io"
        "quay.io"
        "gcr.io"
      ];
      description = "Container registries to intercept and cache";
      example = [
        "ghcr.io"
        "docker.io"
      ];
    };

    storage = {
      cacheDir = lib.mkOption {
        type = lib.types.path;
        default = "/var/cache/registry-cache";
        description = "Directory for cached registry data";
      };

      maxSize = lib.mkOption {
        type = lib.types.str;
        default = "50GB";
        description = "Maximum cache size (LRU eviction when full)";
        example = "100GB";
      };

      memoryCache = lib.mkOption {
        type = lib.types.str;
        default = "2GB";
        description = "Memory cache for hot objects";
        example = "4GB";
      };
    };

    credentials = lib.mkOption {
      type = lib.types.attrsOf credentialType;
      default = { };
      description = ''
        Registry credentials for authenticated pulls (e.g., docker.io rate limit bypass).
        Use *File options for secrets management (agenix, sops-nix).
      '';
      example = lib.literalExpression ''
        {
          "registry-1.docker.io" = {
            usernameFile = config.age.secrets.dockerhub-user.path;
            passwordFile = config.age.secrets.dockerhub-pass.path;
          };
        }
      '';
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
        description = "CA certificate validity in days (for auto-generated cert)";
      };

      commonName = lib.mkOption {
        type = lib.types.str;
        default = "Fireactions Registry Cache CA";
        description = "Common name for auto-generated CA certificate";
      };
    };

    logging = {
      accessLog = lib.mkOption {
        type = lib.types.path;
        default = "/var/log/registry-cache/access.log";
        description = "Path to access log";
      };

      cacheLog = lib.mkOption {
        type = lib.types.path;
        default = "/var/log/registry-cache/cache.log";
        description = "Path to cache log";
      };

      logCacheStatus = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Add X-Cache-Status header to responses";
      };
    };

    dns = {
      upstreamServers = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "8.8.8.8"
          "1.1.1.1"
        ];
        description = "Upstream DNS servers for non-intercepted queries";
      };
    };

    # Debug options for VM access
    debug = {
      sshKeyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Path to file containing SSH public key for VM debugging access.
          When set, this key is injected into VMs via cloud-init.

          For Colmena deployments, use deployment.keys to transfer the key:

          deployment.keys.debug-ssh-key = {
            text = "ssh-ed25519 AAAA... your-key";
            destDir = "/run/keys";
          };
          services.fireactions.registryCache.debug.sshKeyFile = "/run/keys/debug-ssh-key";
        '';
        example = "/run/keys/debug-ssh-key";
      };
    };

    # Internal options (set by this module, used by fireactions-node.nix)
    _internal = {
      caCertPath = lib.mkOption {
        type = lib.types.str;
        internal = true;
        default = caCertPath;
        description = "Path to CA certificate (set automatically)";
      };

      gateway = lib.mkOption {
        type = lib.types.str;
        internal = true;
        default = gateway;
        description = "Gateway IP address (set automatically)";
      };

      cloudInitUserData = lib.mkOption {
        type = lib.types.path;
        internal = true;
        default = cloudInitUserData;
        description = "Cloud-init user-data template (set automatically)";
      };

      debugSshKeyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        internal = true;
        default = cfg.debug.sshKeyFile;
        description = "Path to debug SSH key file (set automatically from debug.sshKeyFile)";
      };
    };
  };

  config = lib.mkIf (fireactionsCfg.enable && cfg.enable) {
    # DNS and DHCP via dnsmasq
    # Note: We do NOT override registry domain IPs here - we use iptables REDIRECT instead.
    # DNS-based interception doesn't work because Squid's intercept mode verifies
    # Host headers against destination IPs (client_dst_passthru limitation).
    services.dnsmasq = {
      enable = true;
      settings = {
        # Listen only on the VM bridge interface
        interface = fireactionsCfg.networking.bridgeName;
        bind-interfaces = true;

        # Don't use /etc/resolv.conf
        no-resolv = true;

        # Forward all queries to upstream DNS (no registry overrides)
        # VMs will resolve registry domains to their real IPs
        # iptables will intercept and redirect the traffic to Squid
        server = cfg.dns.upstreamServers;

        # Cache DNS responses
        cache-size = 1000;

        # Log queries for debugging (optional)
        log-queries = false;

        # DHCP server for VMs
        # Range: .2 to .254 (reserve .1 for gateway)
        dhcp-range = "${dhcpStart},${dhcpEnd},${netmask},12h";

        # DHCP options
        # Option 3: Router (gateway)
        dhcp-option = [
          "3,${gateway}"
          "6,${gateway}"
        ];

        # Rapid commit for faster DHCP
        dhcp-rapid-commit = true;
      };
    };

    # Create required directories
    systemd.tmpfiles.rules = [
      "d ${caDir} 0750 squid squid -"
      "d ${caDir}/ssl_db 0750 squid squid -"
      "d ${cfg.storage.cacheDir} 0750 squid squid -"
      "d /var/log/registry-cache 0750 squid squid -"
      "d /run/squid 0750 squid squid -"
    ];

    # CA certificate generation service
    systemd.services.registry-cache-ca-setup = lib.mkIf (cfg.ca.certFile == null) {
      description = "Generate CA certificate for registry cache";
      wantedBy = [ "registry-cache.service" ];
      before = [ "registry-cache.service" ];
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

        # Always ensure directories exist with correct permissions
        # Note: Don't create ssl_db - security_file_certgen needs to create it
        mkdir -p "$CA_DIR"
        chown squid:squid "$CA_DIR"

        # Skip CA generation if CA already exists and is valid
        if [ -f "$CA_CERT" ] && [ -f "$CA_KEY" ]; then
          # Check if cert is still valid (has at least 30 days left)
          if ${pkgs.openssl}/bin/openssl x509 -checkend 2592000 -noout -in "$CA_CERT" 2>/dev/null; then
            echo "CA certificate exists and is valid"
            exit 0
          fi
          echo "CA certificate expired or expiring soon, regenerating..."
        fi

        # Generate CA private key
        ${pkgs.openssl}/bin/openssl genrsa -out "$CA_KEY" 4096

        # Generate CA certificate
        ${pkgs.openssl}/bin/openssl req -new -x509 \
          -days ${toString cfg.ca.validDays} \
          -key "$CA_KEY" \
          -out "$CA_CERT" \
          -subj "/CN=${cfg.ca.commonName}" \
          -addext "basicConstraints=critical,CA:TRUE" \
          -addext "keyUsage=critical,keyCertSign,cRLSign"

        # Set permissions
        chown squid:squid "$CA_CERT" "$CA_KEY"
        chmod 0644 "$CA_CERT"
        chmod 0600 "$CA_KEY"

        echo "CA certificate generated: $CA_CERT"
      '';
    };

    # Initialize Squid SSL certificate database
    systemd.services.registry-cache-ssl-db-setup = {
      description = "Initialize Squid SSL certificate database";
      wantedBy = [ "registry-cache.service" ];
      before = [ "registry-cache.service" ];
      after = [ "registry-cache-ca-setup.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "squid";
      };
      script = ''
        set -euo pipefail

        SSL_DB="${caDir}/ssl_db"

        echo "Initialization SSL db..."

        # Skip if already initialized
        if [ -f "$SSL_DB/index.txt" ]; then
          echo "SSL database already initialized"
          exit 0
        fi

        # Remove empty/corrupt ssl_db directory if it exists
        # security_file_certgen needs to create the directory itself
        if [ -d "$SSL_DB" ]; then
          echo "Removing incomplete ssl_db directory..."
          rm -rf "$SSL_DB"
        fi

        # Initialize the SSL certificate database
        ${pkgs.squid}/libexec/security_file_certgen -c -s "$SSL_DB" -M 512MB

        echo "SSL database initialized"
      '';
    };

    # Initialize Squid cache directory
    systemd.services.registry-cache-cache-setup = {
      description = "Initialize Squid cache directory";
      wantedBy = [ "registry-cache.service" ];
      before = [ "registry-cache.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "squid";
      };
      script = ''
        set -euo pipefail

        CACHE_DIR="${cfg.storage.cacheDir}"

        # Skip if already initialized
        if [ -d "$CACHE_DIR/00" ]; then
          echo "Cache directory already initialized"
          exit 0
        fi

        # Initialize cache directory structure
        ${pkgs.squid}/bin/squid -z -f ${squidConfigFile} -N

        echo "Cache directory initialized"
      '';
    };

    # Main Squid proxy service
    systemd.services.registry-cache = {
      description = "Registry Cache Proxy (Squid)";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "registry-cache-ca-setup.service"
        "registry-cache-ssl-db-setup.service"
        "registry-cache-cache-setup.service"
      ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "simple";
        User = "squid";
        Group = "squid";
        ExecStart = "${pkgs.squid}/bin/squid -f ${squidConfigFile} -N";
        ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
        Restart = "on-failure";
        RestartSec = 5;

        # Capabilities for binding to port 443
        AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
        CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];

        # Security hardening
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ReadWritePaths = [
          caDir
          cfg.storage.cacheDir
          "/var/log/registry-cache"
          "/run/squid"
        ];
      };
    };

    # Ensure squid user exists
    users.users.squid = {
      isSystemUser = true;
      group = "squid";
      description = "Squid proxy daemon user";
    };
    users.groups.squid = { };

    # Firewall: allow DNS and Squid ports from VM subnet
    networking.firewall = {
      interfaces.${fireactionsCfg.networking.bridgeName} = {
        allowedTCPPorts = [ 3128 3129 ];
        allowedUDPPorts = [ 53 67 ];  # DNS + DHCP
      };
    };

    # iptables NAT rules to intercept HTTP/HTTPS traffic from VMs
    # This redirects web traffic from VMs to Squid's intercept ports
    # Squid then uses SO_ORIGINAL_DST to get the real destination
    networking.nat = {
      enable = true;
      internalInterfaces = [ fireactionsCfg.networking.bridgeName ];
      # PREROUTING: Redirect HTTP/HTTPS traffic from VMs to Squid intercept ports
      # Only redirect traffic NOT destined for the gateway itself
      extraCommands = ''
        # Redirect HTTP (80) from VM subnet to Squid intercept port (3128)
        iptables -t nat -A PREROUTING -i ${fireactionsCfg.networking.bridgeName} \
          -p tcp --dport 80 \
          ! -d ${gateway} \
          -j REDIRECT --to-port 3128
        # Redirect HTTPS (443) from VM subnet to Squid intercept port (3129)
        iptables -t nat -A PREROUTING -i ${fireactionsCfg.networking.bridgeName} \
          -p tcp --dport 443 \
          ! -d ${gateway} \
          -j REDIRECT --to-port 3129
      '';
      extraStopCommands = ''
        iptables -t nat -D PREROUTING -i ${fireactionsCfg.networking.bridgeName} \
          -p tcp --dport 80 \
          ! -d ${gateway} \
          -j REDIRECT --to-port 3128 2>/dev/null || true
        iptables -t nat -D PREROUTING -i ${fireactionsCfg.networking.bridgeName} \
          -p tcp --dport 443 \
          ! -d ${gateway} \
          -j REDIRECT --to-port 3129 2>/dev/null || true
      '';
    };

    # Logrotate for registry-cache logs
    services.logrotate.settings.registry-cache = {
      files = "/var/log/registry-cache/*.log";
      frequency = "daily";
      rotate = 7;
      compress = true;
      delaycompress = true;
      missingok = true;
      notifempty = true;
      create = "0640 squid squid";
      postrotate = ''
        ${pkgs.systemd}/bin/systemctl kill --signal=HUP registry-cache.service 2>/dev/null || true
      '';
    };
  };
}
