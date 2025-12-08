# Large instance profile
# Applied to hosts tagged with "large"
# For instances with abundant resources (32GB+ RAM, 8+ vCPU)
{ lib, ... }:

{
  services.fireactions = {
    #kernelSource = "custom";
    pools = lib.mkDefault [
      {
        name = "default";
        maxRunners = 10;
        minRunners = 5;
        runner = {
          organization = "ithings-ch";
          groupId = 1; # Default runner group
          labels = [
            "self-hosted"
            "fireactions"
            "linux"
            "large"
          ];
        };
        firecracker = {
          memSizeMib = 4096;
          vcpuCount = 4;
        };
      }
    ];
  };
}
