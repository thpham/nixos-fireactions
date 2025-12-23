# Shared NixOS configuration for fleet management
# Used by Colmena for steady-state updates (NO disko - disk config applied only during initial deploy)
{ lib, pkgs, ... }:

{
  # Boot configuration - GRUB with EFI support
  # efiInstallAsRemovable works better with cloud VMs
  boot.loader.grub = {
    enable = true;
    efiSupport = true;
    efiInstallAsRemovable = true;
  };

  # Kernel with KVM support for Firecracker
  boot.kernelPackages = pkgs.linuxPackages_6_12;
  boot.kernelModules = [
    "kvm-intel"
    "kvm-amd"
  ];
  boot.kernelParams = [
    "mem_alloc_profiling=off" # Suppress slab extension warnings on 6.12+
  ];

  # Networking (hostName set by hosts/default.nix safety module)
  networking = {
    # Use systemd-networkd for consistent networking with microvm bridges
    useNetworkd = lib.mkDefault true;
    useDHCP = lib.mkDefault false; # Handled by networkd below

    firewall = {
      enable = true;
      allowedTCPPorts = [ 22 ];
      logRefusedConnections = false; # Reduce noise from port scans
    };
  };

  # Configure systemd-networkd for physical ethernet interfaces
  # This works alongside microvm-base bridge configuration
  systemd.network = {
    enable = lib.mkDefault true;
    wait-online.enable = false; # Don't block boot waiting for network

    # DHCP on physical ethernet interfaces
    # Matches common naming: enp*, eno*, ens*, eth* (but not bridges like fireactions0)
    networks."20-ethernet" = {
      matchConfig.Name = "en* eth*";
      networkConfig = {
        DHCP = "yes";
        IPv6AcceptRA = true;
      };
    };
  };

  # SSH configuration
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };

  # Management SSH keys for fleet access
  # Add your public key(s) here to enable colmena deployments
  users.users.root.openssh.authorizedKeys.keys = [
    # TODO: Add your SSH public key here
    # "ssh-ed25519 AAAAC3Nza... user@host"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOPK49ZsqsVVeKdpFuT4aJn4oNYsyTPvSM7Insw2wR2k"
  ];

  # Fail2ban for SSH brute-force protection
  services.fail2ban = {
    enable = true;
    maxretry = 3;
    bantime = "1h";
    bantime-increment = {
      enable = true;
      maxtime = "48h";
      factor = "4";
    };
    jails.sshd = {
      settings = {
        enabled = true;
        filter = "sshd";
        action = "iptables-multiport[name=sshd, port=\"ssh\"]";
        maxretry = 3;
        findtime = "10m";
        bantime = "1h";
      };
    };
  };

  # System packages
  environment.systemPackages = with pkgs; [
    vim
    git
    curl
    wget
    htop
    tmux
    dig
  ];

  # Timezone (override in per-host config if needed)
  time.timeZone = lib.mkDefault "UTC";

  # Nix settings for fleet management
  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    trusted-users = [
      "root"
      "@wheel"
    ];
  };

  system.stateVersion = "25.11";
}
