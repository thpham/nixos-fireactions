# Fireteact Large Pool Profile
# Applied to hosts tagged with "fireteact-large"
# For instances with abundant resources (32GB+ RAM, 8+ vCPU)
#
# Use with: ["gitea-runners", "fireteact-large"]
{ lib, ... }:

let
  sizes = import ./sizes/_lib.nix { inherit lib; };
in
{
  services.fireteact.pools = lib.mkDefault [
    (sizes.mkFireteactPool "large" { })
  ];
}
