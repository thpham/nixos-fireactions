# Fireactions Large Pool Profile
# Applied to hosts tagged with "fireactions-large"
# For instances with abundant resources (32GB+ RAM, 8+ vCPU)
#
# Use with: ["github-runners", "fireactions-large"]
{ lib, ... }:

let
  sizes = import ./sizes/_lib.nix { inherit lib; };
in
{
  services.fireactions.pools = lib.mkDefault [
    (sizes.mkFireactionsPool "large" {
      organization = "ithings-ch";
      groupId = 1;
    })
  ];
}
