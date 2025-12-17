# Small instance profile
# Applied to hosts tagged with "small"
# For instances with limited resources (2-4GB RAM, 2 vCPU)
{ lib, ... }:

{
  # GitHub Actions runners (fireactions)
  services.fireactions = {
    #kernelSource = "custom";
    pools = lib.mkDefault [
      {
        name = "default";
        maxRunners = 2;
        minRunners = 1;
        runner = {
          imagePullPolicy = "Always";
          organization = "ithings-ch";
          groupId = 1; # Default runner group
          labels = [
            "self-hosted"
            "fireactions"
            "linux"
            "small"
          ];
        };
        firecracker = {
          memSizeMib = 1024;
          vcpuCount = 1;
        };
      }
    ];
  };

  # Gitea Actions runners (fireteact)
  services.fireteact = {
    #kernelSource = "custom";
    pools = lib.mkDefault [
      {
        name = "default";
        maxRunners = 2;
        minRunners = 1;
        runner = {
          imagePullPolicy = "Always";
          labels = [
            "self-hosted"
            "fireteact"
            "linux"
            "small"
          ];
        };
        firecracker = {
          memSizeMib = 1024;
          vcpuCount = 1;
        };
      }
    ];
  };
}
