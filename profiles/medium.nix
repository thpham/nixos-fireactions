# Medium instance profile
# Applied to hosts tagged with "medium"
# For instances with moderate resources (8-16GB RAM, 4 vCPU)
{ lib, ... }:

{
  # GitHub Actions runners (fireactions)
  services.fireactions = {
    #kernelSource = "custom";
    pools = lib.mkDefault [
      {
        name = "default";
        maxRunners = 5;
        minRunners = 2;
        runner = {
          imagePullPolicy = "Always";
          organization = "ithings-ch";
          groupId = 1; # Default runner group
          labels = [
            "self-hosted"
            "fireactions"
            "linux"
            "medium"
          ];
        };
        firecracker = {
          memSizeMib = 2048;
          vcpuCount = 2;
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
        maxRunners = 5;
        minRunners = 2;
        runner = {
          imagePullPolicy = "Always";
          labels = [
            "self-hosted"
            "fireteact"
            "linux"
            "medium"
          ];
        };
        firecracker = {
          memSizeMib = 2048;
          vcpuCount = 2;
        };
      }
    ];
  };
}
