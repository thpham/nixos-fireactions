# Fireactions Small Pool Profile
# Applied to hosts tagged with "fireactions-small"
# For instances with limited resources (2-4GB RAM, 2 vCPU)
#
# Use with: ["github-runners", "fireactions-small"]
{ lib, ... }:

let
  sizes = import ./sizes/_lib.nix { inherit lib; };
in
{
  services.fireactions.pools = lib.mkDefault [
    (sizes.mkFireactionsPool "small" {
      organization = "ithings-ch";
      groupId = 1;
    })
  ];
}
