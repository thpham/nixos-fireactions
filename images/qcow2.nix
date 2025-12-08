# Generic QCOW2 cloud image
# Works with any QEMU/KVM-based platform (libvirt, Proxmox, OpenStack, etc.)
{
  pkgs,
  modulesPath,
  ...
}:

{
  imports = [
    "${modulesPath}/profiles/qemu-guest.nix"
  ];

  # Boot configuration
  boot.kernelPackages = pkgs.linuxPackages_6_12;
  boot.loader.grub = {
    enable = true;
    device = "nodev";
    efiSupport = true;
    efiInstallAsRemovable = true;
  };

  # Ensure KVM modules are available
  boot.kernelModules = [
    "kvm-intel"
    "kvm-amd"
  ];

  # QEMU guest agent
  services.qemuGuest.enable = true;

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
      datasource_list = [
        "ConfigDrive"
        "DigitalOcean"
        "NoCloud"
        "None"
      ];
    };
  };

  # Networking
  networking = {
    hostName = "fireactions-node";
    useDHCP = true;
    useNetworkd = true;
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

  # Fireactions preparation script
  environment.etc."fireactions-setup.sh" = {
    mode = "0755";
    text = ''
      #!/usr/bin/env bash
      # Fireactions setup script for generic cloud
      # Configure via cloud-init user-data

      echo "Fireactions node ready for configuration"
      echo "Add your fireactions flake and configuration to complete setup"
    '';
  };

  # Disk configuration
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
