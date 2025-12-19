# Fireactions Medium Pool Profile
# Applied to hosts tagged with "fireactions-medium"
# For instances with moderate resources (8-16GB RAM, 4 vCPU)
#
# Use with: ["github-runners", "fireactions-medium"]
{ lib, ... }:

let
  sizes = import ./sizes/_lib.nix { inherit lib; };
in
{
  services.fireactions.pools = lib.mkDefault [
    (sizes.mkFireactionsPool "medium" {
      organization = "ithings-ch";
      groupId = 1;
    })
  ];
}
