# Size profile library
# Helper functions for creating pool configurations
#
# Usage:
#   let sizes = import ./sizes/_lib.nix { inherit lib; };
#   in sizes.fireactionsPool "small" { organization = "my-org"; }
{ lib }:

let
  # Size definitions with resource allocations
  sizeSpecs = {
    small = {
      memSizeMib = 1024;
      vcpuCount = 1;
      maxRunners = 2;
      minRunners = 1;
      description = "For instances with limited resources (2-4GB RAM, 2 vCPU)";
    };
    medium = {
      memSizeMib = 2048;
      vcpuCount = 2;
      maxRunners = 5;
      minRunners = 2;
      description = "For instances with moderate resources (8-16GB RAM, 4 vCPU)";
    };
    large = {
      memSizeMib = 4096;
      vcpuCount = 4;
      maxRunners = 10;
      minRunners = 5;
      description = "For instances with abundant resources (32GB+ RAM, 8+ vCPU)";
    };
  };

  # Create a fireactions pool configuration
  # Args:
  #   size: "small" | "medium" | "large"
  #   overrides: attrset to override defaults (organization, groupId, labels, etc.)
  mkFireactionsPool =
    size: overrides:
    let
      spec = sizeSpecs.${size};
    in
    {
      name = overrides.name or "default";
      maxRunners = overrides.maxRunners or spec.maxRunners;
      minRunners = overrides.minRunners or spec.minRunners;
      runner = {
        imagePullPolicy = overrides.imagePullPolicy or "Always";
        organization = overrides.organization or (throw "fireactions pool requires 'organization'");
        groupId = overrides.groupId or 1;
        labels =
          overrides.labels or [
            "self-hosted"
            "fireactions"
            "linux"
            size
          ];
      };
      firecracker = {
        memSizeMib = overrides.memSizeMib or spec.memSizeMib;
        vcpuCount = overrides.vcpuCount or spec.vcpuCount;
      };
    };

  # Create a fireteact pool configuration
  # Args:
  #   size: "small" | "medium" | "large"
  #   overrides: attrset to override defaults (labels, image, etc.)
  mkFireteactPool =
    size: overrides:
    let
      spec = sizeSpecs.${size};
    in
    {
      name = overrides.name or "default";
      maxRunners = overrides.maxRunners or spec.maxRunners;
      minRunners = overrides.minRunners or spec.minRunners;
      runner = {
        imagePullPolicy = overrides.imagePullPolicy or "Always";
        labels =
          overrides.labels or [
            "self-hosted"
            "fireteact"
            "linux"
            size
          ];
      }
      // lib.optionalAttrs (overrides ? image) {
        image = overrides.image;
      };
      firecracker = {
        memSizeMib = overrides.memSizeMib or spec.memSizeMib;
        vcpuCount = overrides.vcpuCount or spec.vcpuCount;
      };
    };

in
{
  inherit sizeSpecs mkFireactionsPool mkFireteactPool;

  # Convenience accessors for size specs
  small = sizeSpecs.small;
  medium = sizeSpecs.medium;
  large = sizeSpecs.large;
}
