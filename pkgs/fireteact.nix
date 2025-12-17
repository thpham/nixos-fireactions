# fireteact - Gitea Actions Runner Orchestrator for Firecracker microVMs
#
# This is the main orchestrator that manages pools of Gitea Actions runners
# running in ephemeral Firecracker microVMs.
{
  lib,
  buildGoModule,
}:

buildGoModule {
  pname = "fireteact";
  version = "0.1.0-dev";

  src = ../fireteact;

  # Vendor hash for Go module dependencies
  # To update: set to lib.fakeHash, build on Linux, use hash from error message
  vendorHash = "sha256-ferq9Kel0xz+ggDzf4QiAP+yi0koJa7sARujt4/Yios=";

  subPackages = [ "cmd/fireteact" ];

  ldflags = [
    "-s"
    "-w"
    "-X main.Version=0.1.0-dev"
    "-X main.Commit=unknown"
    "-X main.Date=1970-01-01T00:00:00Z"
  ];

  # Skip tests for now (they require network/special setup)
  doCheck = false;

  meta = with lib; {
    description = "Gitea Actions runner orchestrator using Firecracker microVMs";
    homepage = "https://github.com/thpham/nixos-fireactions";
    license = licenses.asl20;
    maintainers = [ ];
    platforms = platforms.linux;
    mainProgram = "fireteact";
  };
}
