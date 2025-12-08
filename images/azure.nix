# Azure VHD image with cloud-init
# Produces a VHD image compatible with Azure
{
  pkgs,
  modulesPath,
  ...
}:

{
  imports = [
    "${modulesPath}/virtualisation/azure-common.nix"
  ];

  # Boot configuration
  boot.kernelPackages = pkgs.linuxPackages_6_12;
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Ensure KVM modules are available
  boot.kernelModules = [
    "kvm-intel"
    "kvm-amd"
  ];

  # Azure-specific settings are provided by azure-common.nix

  # Cloud-init for configuration injection
  services.cloud-init = {
    enable = true;
    network.enable = true;
    settings = {
      cloud_init_modules = [
        "migrator"
        "seed_random"
        "bootcmd"
        "write-files"
        "growpart"
        "resizefs"
        "disk_setup"
        "mounts"
        "set_hostname"
        "update_hostname"
        "update_etc_hosts"
        "ca-certs"
        "users-groups"
        "ssh"
      ];
      cloud_config_modules = [
        "emit_upstart"
        "ssh-import-id"
        "locale"
        "set-passwords"
        "ntp"
        "timezone"
        "runcmd"
      ];
      cloud_final_modules = [
        "package-update-upgrade-install"
        "scripts-vendor"
        "scripts-per-once"
        "scripts-per-boot"
        "scripts-per-instance"
        "scripts-user"
        "ssh-authkey-fingerprints"
        "keys-to-console"
        "final-message"
      ];
    };
  };

  # Networking
  networking = {
    hostName = "fireactions-node";
    useDHCP = true;
    firewall = {
      enable = true;
      allowedTCPPorts = [ 22 ];
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

  # System packages
  environment.systemPackages = with pkgs; [
    vim
    git
    curl
    wget
    htop
    tmux
  ];

  # Fireactions preparation script (run via cloud-init runcmd)
  environment.etc."fireactions-setup.sh" = {
    mode = "0755";
    text = ''
      #!/usr/bin/env bash
      # Fireactions setup script
      # This is called by cloud-init to configure fireactions

      # Read configuration from cloud-init metadata
      # Expected user-data format:
      # #cloud-config
      # write_files:
      #   - path: /etc/fireactions/config.yaml
      #     content: |
      #       <your fireactions config>
      # runcmd:
      #   - /etc/fireactions-setup.sh

      echo "Fireactions node ready for configuration"
      echo "Add your fireactions flake and configuration to complete setup"
    '';
  };

  # Disk configuration for Azure
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
    autoResize = true;
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-label/ESP";
    fsType = "vfat";
  };

  # Grow partition on first boot
  boot.growPartition = true;

  system.stateVersion = "25.11";
}
