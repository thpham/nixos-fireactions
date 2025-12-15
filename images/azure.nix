# Azure VHD image for VMSS deployment with Firecracker support
#
# This image is designed for Azure Virtual Machine Scale Sets (VMSS):
# - Imports common fireactions configuration
# - Cloud-init configured for Azure IMDS datasource
# - Supports separate data disk for containerd storage
#
# Build: nix build .#image-azure
# Upload to Azure: az image create --source result/nixos.vhd ...
#
# Example user-data for VMSS (use base64 for binary/multiline content):
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
{
  lib,
  modulesPath,
  ...
}:

{
  imports = [
    # Azure platform modules
    "${modulesPath}/virtualisation/azure-common.nix"
    "${modulesPath}/virtualisation/azure-image.nix"
    # Common fireactions configuration
    ./common.nix
  ];

  #
  # Azure-specific Boot Configuration
  #

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  #
  # Azure-specific Cloud-init Configuration
  #

  services.cloud-init.settings = {
    # Azure IMDS as primary datasource
    datasource_list = [
      "Azure"
      "None"
    ];

    datasource.Azure = {
      apply_network_config = true;
      data_dir = "/var/lib/waagent";
      disk_aliases = {
        ephemeral0 = "/dev/disk/cloud/azure_resource";
      };
    };

    # Disk setup for data disk (Azure attaches as /dev/disk/azure/scsi1/lun0)
    # This provides extra storage for containerd images
    disk_setup = {
      "/dev/disk/azure/scsi1/lun0" = {
        table_type = "gpt";
        layout = true;
        overwrite = false;
      };
    };

    fs_setup = [
      {
        label = "containerd-data";
        filesystem = "ext4";
        device = "/dev/disk/azure/scsi1/lun0-part1";
        partition = "auto";
        overwrite = false;
      }
    ];

    mounts = [
      [
        "/dev/disk/azure/scsi1/lun0-part1"
        "/var/lib/containerd"
        "ext4"
        "defaults,nofail,discard"
        "0"
        "2"
      ]
    ];
  };

  #
  # Azure-specific Fireactions Overrides
  #

  services.fireactions = {
    # Larger cache for Azure VMs (typically have more memory)
    registryCache.squid.memoryCache = lib.mkForce "512MB";
  };
}
