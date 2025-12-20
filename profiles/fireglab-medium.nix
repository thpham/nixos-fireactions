# Fireglab Medium Pool Profile
# Applied to hosts tagged with "fireglab-medium"
# For instances with moderate resources (8-16GB RAM, 4 vCPU)
#
# Use with: ["gitlab-runners", "fireglab-medium"]
{ lib, ... }:

let
  sizes = import ./sizes/_lib.nix { inherit lib; };
in
{
  services.fireglab.pools = lib.mkDefault [
    (sizes.mkFireglabPool "medium" { })
  ];
}
