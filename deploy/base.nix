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
    useDHCP = lib.mkDefault true;
    firewall = {
      enable = true;
      allowedTCPPorts = [ 22 ];
      logRefusedConnections = false; # Reduce noise from port scans
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
