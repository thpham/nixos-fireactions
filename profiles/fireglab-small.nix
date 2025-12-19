# Fireglab Small Pool Profile
# Applied to hosts tagged with "fireglab-small"
# For instances with limited resources (2-4GB RAM, 2 vCPU)
#
# Use with: ["gitlab-runners", "fireglab-small"]
{ lib, ... }:

let
  sizes = import ./sizes/_lib.nix { inherit lib; };
in
{
  services.fireglab.pools = lib.mkDefault [
    (sizes.mkFireglabPool "small" { })
  ];
}
