# Fireglab Large Pool Profile
# Applied to hosts tagged with "fireglab-large"
# For instances with abundant resources (32GB+ RAM, 8+ vCPU)
#
# Use with: ["gitlab-runners", "fireglab-large"]
{ lib, ... }:

let
  sizes = import ./sizes/_lib.nix { inherit lib; };
in
{
  services.fireglab.pools = lib.mkDefault [
    (sizes.mkFireglabPool "large" { })
  ];
}
