# Disko disk partitioning configuration
# Based on nixos-anywhere-examples pattern
#
# Creates a BIOS/UEFI hybrid boot with LVM for flexibility:
# - 1M BIOS boot partition (for legacy boot compatibility)
# - 500M ESP partition (for UEFI boot)
# - LVM volume group with root logical volume
#
# Device is overridden in flake.nix per target:
#   /dev/sda     - SATA/SAS disks (bare metal)
#   /dev/vda     - Virtio (KVM/QEMU/DigitalOcean/cloud VMs)
#   /dev/nvme0n1 - NVMe SSDs
{ lib, ... }:

{
  disko.devices = {
    disk.disk1 = {
      device = lib.mkDefault "/dev/sda";
      type = "disk";
      content = {
        type = "gpt";
        partitions = {
          boot = {
            name = "boot";
            size = "1M";
            type = "EF02";  # BIOS boot partition
          };
          esp = {
            name = "ESP";
            size = "500M";
            type = "EF00";  # EFI System Partition
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
            };
          };
          root = {
            name = "root";
            size = "100%";
            content = {
              type = "lvm_pv";
              vg = "pool";
            };
          };
        };
      };
    };

    lvm_vg = {
      pool = {
        type = "lvm_vg";
        lvs = {
          root = {
            size = "100%FREE";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
              mountOptions = [ "defaults" ];
            };
          };
        };
      };
    };
  };
}
