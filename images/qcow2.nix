# Generic QCOW2 cloud image for QEMU/KVM platforms
#
# Works with any QEMU/KVM-based platform (libvirt, Proxmox, OpenStack, etc.)
#
# Build: nix build .#image-qcow2
#
# Example user-data (NoCloud):
#   #cloud-config
#   write_files:
#     - path: /etc/fireactions/github-app-id
#       content: "123456"
#       permissions: "0600"
#     - path: /etc/fireactions/github-private-key.pem
#       encoding: b64
#       content: LS0tLS1CRUdJTiBSU0EgUFJJVkFURSBLRVktLS0tLQo... # base64 -w0 < key.pem
#       permissions: "0600"
#     - path: /etc/fireactions/pools.json
#       encoding: b64
#       content: W3sibmFtZSI6ICJkZWZhdWx0IiwgIm1heFJ1bm5lcnMi... # base64 -w0 < pools.json
#       permissions: "0644"
#   runcmd:
#     - /etc/fireactions/bootstrap.sh
{ modulesPath, ... }:

{
  imports = [
    # QEMU/KVM platform module
    "${modulesPath}/profiles/qemu-guest.nix"
    # Common fireactions configuration
    ./common.nix
  ];

  #
  # QEMU-specific Boot Configuration
  #

  boot.loader.grub = {
    enable = true;
    device = "nodev";
    efiSupport = true;
    efiInstallAsRemovable = true;
  };

  # KVM modules for nested virtualization (if needed)
  boot.kernelModules = [
    "kvm-intel"
    "kvm-amd"
  ];

  #
  # QEMU Guest Agent
  #

  services.qemuGuest.enable = true;

  #
  # QEMU-specific Cloud-init Configuration
  #

  services.cloud-init.settings = {
    # Multiple datasources for flexibility across platforms
    datasource_list = [
      "ConfigDrive"
      "NoCloud"
      "None"
    ];
  };

  #
  # QEMU-specific Networking
  #

  # Use systemd-networkd for consistent network management
  networking.useNetworkd = true;
}
