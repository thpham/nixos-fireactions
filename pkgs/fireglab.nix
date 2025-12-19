# fireglab - GitLab CI Runner Orchestrator for Firecracker microVMs
#
# This is the main orchestrator that manages pools of GitLab CI runners
# running in ephemeral Firecracker microVMs.
#
# Key features:
# - Dynamic runner creation via POST /api/v4/user/runners API
# - Runner authentication tokens (glrt-*) for secure registration
# - Support for instance, group, and project-level runners
# - Automatic cleanup via DELETE /api/v4/runners/:id on VM exit
{
  lib,
  buildGoModule,
}:

buildGoModule {
  pname = "fireglab";
  version = "0.1.0-dev";

  src = ../fireglab;

  # Vendor hash for Go module dependencies
  # To update: set to lib.fakeHash, build on Linux, use hash from error message
  # Note: Same dependencies as fireteact, so same hash
  vendorHash = "sha256-ferq9Kel0xz+ggDzf4QiAP+yi0koJa7sARujt4/Yios=";

  subPackages = [ "cmd/fireglab" ];

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
    description = "GitLab CI runner orchestrator using Firecracker microVMs";
    homepage = "https://github.com/thpham/nixos-fireactions";
    license = licenses.asl20;
    maintainers = [ ];
    platforms = platforms.linux;
    mainProgram = "fireglab";
  };
}
