# Fireteact Small Pool Profile
# Applied to hosts tagged with "fireteact-small"
# For instances with limited resources (2-4GB RAM, 2 vCPU)
#
# Use with: ["gitea-runners", "fireteact-small"]
{ lib, ... }:

let
  sizes = import ./sizes/_lib.nix { inherit lib; };
in
{
  services.fireteact.pools = lib.mkDefault [
    (sizes.mkFireteactPool "small" { })
  ];
}
