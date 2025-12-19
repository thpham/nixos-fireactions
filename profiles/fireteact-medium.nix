# Fireteact Medium Pool Profile
# Applied to hosts tagged with "fireteact-medium"
# For instances with moderate resources (8-16GB RAM, 4 vCPU)
#
# Use with: ["gitea-runners", "fireteact-medium"]
{ lib, ... }:

let
  sizes = import ./sizes/_lib.nix { inherit lib; };
in
{
  services.fireteact.pools = lib.mkDefault [
    (sizes.mkFireteactPool "medium" { })
  ];
}
