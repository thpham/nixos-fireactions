{
  description = "NixOS module for self-hosted GitHub Actions runners using Firecracker microVMs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-utils.url = "github:numtide/flake-utils";

    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # microvm.nix for Firecracker packages and networking patterns
    microvm = {
      url = "github:astro/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # disko for declarative disk partitioning
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # colmena for fleet management
    colmena = {
      url = "github:zhaofengli/colmena";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # sops-nix for secrets management
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      nixos-generators,
      microvm,
      disko,
      colmena,
      sops-nix,
      ...
    }:
    let
      allSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
    in
    flake-utils.lib.eachSystem allSystems (
      system:
      let
        # Native pkgs for the host system
        pkgsNative = import nixpkgs { inherit system; };
        lib = pkgsNative.lib;

        # Host architecture detection
        isLinux = pkgsNative.stdenv.isLinux;
        isAarch64 = pkgsNative.stdenv.hostPlatform.isAarch64;
        hostArch = if isAarch64 then "aarch64" else "x86_64";
        crossArch = if isAarch64 then "x86_64" else "aarch64";

        # Target Linux system matching host arch
        targetSystem = "${hostArch}-linux";
        crossTargetSystem = "${crossArch}-linux";

        # Native pkgs with overlays (for local testing of packages)
        pkgsWithOverlays = import nixpkgs {
          inherit system;
          overlays = [ microvm.overlay ];
        };

        # Helper to build NixOS images using nixos-generators
        # Uses system argument to let nixos-generators handle pkgs correctly
        mkImages = targetSys: {
          qcow2 = nixos-generators.nixosGenerate {
            system = targetSys;
            format = "qcow";
            modules = [ ./images/qcow2.nix ];
          };

          azure = nixos-generators.nixosGenerate {
            system = targetSys;
            format = "azure";
            modules = [ ./images/azure.nix ];
          };
        };

        # Build image sets - available on all platforms
        defaultImages = mkImages targetSystem;
        crossImages = mkImages crossTargetSystem;
      in
      {
        # Packages: All Linux-only (fireactions/fireteact depend on Linux networking primitives)
        packages =
          lib.optionalAttrs isLinux {
            fireactions = pkgsWithOverlays.callPackage ./pkgs/fireactions.nix { };
            fireteact = pkgsWithOverlays.callPackage ./pkgs/fireteact.nix { };
            firecracker-kernel = pkgsWithOverlays.callPackage ./pkgs/firecracker-kernel.nix { };
            firecracker-kernel-custom = pkgsWithOverlays.callPackage ./pkgs/firecracker-kernel-custom.nix { };
            tc-redirect-tap = pkgsWithOverlays.callPackage ./pkgs/tc-redirect-tap.nix { };
            zot = pkgsWithOverlays.callPackage ./pkgs/zot.nix { };
            default = pkgsWithOverlays.callPackage ./pkgs/fireactions.nix { };
          }
          // {
            # Images - available on all platforms, always target Linux
            image-qcow2 = defaultImages.qcow2;
            image-azure = defaultImages.azure;
            image-qcow2-cross = crossImages.qcow2;
            image-azure-cross = crossImages.azure;
          };

        # DevShell uses native pkgs
        devShells.default = pkgsNative.mkShell {
          buildInputs =
            with pkgsNative;
            [
              go
              gopls
              nixpkgs-fmt
              jq # For registry.json manipulation
              sops # For secrets management
              age # For sops encryption
              ssh-to-age
            ]
            ++ lib.optionals isLinux [
              firecracker
              containerd
              runc
              cni-plugins
            ]
            ++ [
              colmena.packages.${system}.colmena or colmena.defaultPackage.${system}
            ];

          shellHook = ''
            echo "fireactions/fireteact development shell (${system})"
            echo ""
          ''
          + lib.optionalString isLinux ''
            echo "Package targets (native ${system}):"
            echo "  nix build .#fireactions               # GitHub Actions runner orchestrator"
            echo "  nix build .#fireteact                 # Gitea Actions runner orchestrator"
            echo "  nix build .#firecracker-kernel        # Upstream minimal (no Docker bridge)"
            echo "  nix build .#firecracker-kernel-custom # Minimal + Docker bridge networking"
            echo "  nix build .#tc-redirect-tap"
            echo ""
          ''
          + ''
            echo "Image targets:"
            echo "  nix build .#image-qcow2         → ${targetSystem} QCOW2"
            echo "  nix build .#image-qcow2-cross   → ${crossTargetSystem} QCOW2"
            echo "  nix build .#image-azure         → ${targetSystem} VHD"
            echo "  nix build .#image-azure-cross   → ${crossTargetSystem} VHD"
            echo ""
            echo "Initial deployment (nixos-anywhere):"
            echo "  ./deploy/deploy.sh --provider do --name do-fireactions-1 --tags dev,small <ip>"
            echo "  ./deploy/deploy.sh --provider hetzner --name hz-fireactions-1 <ip>"
            echo ""
            echo "Fleet management (colmena):"
            echo "  colmena apply --on my-host --build-on-target"
            echo "  colmena apply --on @prod --build-on-target"
            echo "  colmena apply --build-on-target  # all hosts"
            echo ""
            echo "Host registry:"
            echo "  ./deploy/deploy.sh list           # list registered hosts"
            echo "  cat hosts/registry.json           # view registry"
          '';
        };
      }
    )
    // {
      # NixOS modules (not system-specific)
      nixosModules = {
        # Foundation layer (shared infrastructure)
        microvm-base = import ./modules/microvm-base;

        # Standalone caching layer (works with any runner)
        registry-cache = import ./modules/registry-cache;

        # Runner technologies
        fireactions = import ./modules/fireactions;
        fireteact = import ./modules/fireteact;

        # Backwards compatibility aliases
        fireactions-node = self.nixosModules.fireactions;
        default = self.nixosModules.fireactions;
      };

      # Overlay for use in other flakes
      overlays.default = final: prev: {
        fireactions = final.callPackage ./pkgs/fireactions.nix { };
        fireteact = final.callPackage ./pkgs/fireteact.nix { };
        firecracker-kernel = final.callPackage ./pkgs/firecracker-kernel.nix { };
        firecracker-kernel-custom = final.callPackage ./pkgs/firecracker-kernel-custom.nix { };
        tc-redirect-tap = final.callPackage ./pkgs/tc-redirect-tap.nix { };
        zot = final.callPackage ./pkgs/zot.nix { };
      };

      # NixOS configurations for deployment via nixos-anywhere
      # Based on nixos-anywhere-examples patterns
      nixosConfigurations =
        let
          # Generic bare-metal/VM configuration
          mkConfig =
            { system, device }:
            nixpkgs.lib.nixosSystem {
              inherit system;
              modules = [
                disko.nixosModules.disko
                # Foundation layer (required by fireactions)
                self.nixosModules.microvm-base
                self.nixosModules.registry-cache
                # Runner
                self.nixosModules.fireactions
                ./deploy/configuration.nix
                { disko.devices.disk.disk1.device = device; }
              ];
            };

          # DigitalOcean-specific configuration (requires 2GB+ droplet for kexec)
          mkDigitalOceanConfig =
            { system }:
            nixpkgs.lib.nixosSystem {
              inherit system;
              modules = [
                ./deploy/digitalocean.nix
                disko.nixosModules.disko
                # Foundation layer (required by fireactions)
                self.nixosModules.microvm-base
                self.nixosModules.registry-cache
                # Runner
                self.nixosModules.fireactions
                { disko.devices.disk.disk1.device = "/dev/vda"; }
                ./deploy/configuration.nix
                # Let cloud-init set hostname (DO module sets it to "")
                { networking.hostName = nixpkgs.lib.mkForce ""; }
              ];
            };
        in
        {
          # Generic x86_64 (bare metal with /dev/sda)
          fireactions-node = mkConfig {
            system = "x86_64-linux";
            device = "/dev/sda";
          };

          # DigitalOcean x86_64 (with cloud-init and /dev/vda)
          fireactions-node-do = mkDigitalOceanConfig { system = "x86_64-linux"; };

          # Generic with specific disk types
          fireactions-node-vda = mkConfig {
            system = "x86_64-linux";
            device = "/dev/vda";
          };
          fireactions-node-nvme = mkConfig {
            system = "x86_64-linux";
            device = "/dev/nvme0n1";
          };

          # aarch64 variants
          fireactions-node-arm = mkConfig {
            system = "aarch64-linux";
            device = "/dev/sda";
          };
          fireactions-node-arm-vda = mkConfig {
            system = "aarch64-linux";
            device = "/dev/vda";
          };
          fireactions-node-arm-nvme = mkConfig {
            system = "aarch64-linux";
            device = "/dev/nvme0n1";
          };
        };

      # Colmena hive for fleet management
      # Use: colmena apply --on <host> --build-on-target
      colmenaHive = colmena.lib.makeHive (
        import ./hosts {
          inherit
            nixpkgs
            disko
            sops-nix
            self
            ;
        }
      );
    };
}
