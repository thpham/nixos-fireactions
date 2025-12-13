{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:

buildGoModule rec {
  pname = "zot";
  version = "2.1.11";

  src = fetchFromGitHub {
    owner = "project-zot";
    repo = "zot";
    rev = "v${version}";
    hash = "sha256-j9iS9qN+L9+vUrW7n5oQ6BZ/ssUasWVHTd/7zYTJNEQ=";
  };

  vendorHash = "sha256-jDNSAEDkn/Zt8zzDJ7hCy0U86bebv7tpk68aEHJTNYc=";

  subPackages = [ "cmd/zot" ];

  # CGO disabled - sync extension works without CGO
  env.CGO_ENABLED = "0";

  # Enable sync extension for pull-through cache functionality
  tags = [ "sync" ];

  ldflags = [
    "-s"
    "-w"
    "-X zotregistry.dev/zot/pkg/api/config.ReleaseTag=v${version}"
    "-X zotregistry.dev/zot/pkg/api/config.Commit=${src.rev}"
    "-X zotregistry.dev/zot/pkg/api/config.BinaryType=zot"
  ];

  # Skip tests - they require network and special setup
  doCheck = false;

  meta = with lib; {
    description = "OCI-native container image registry with pull-through cache support";
    homepage = "https://zotregistry.dev";
    license = licenses.asl20;
    maintainers = [ ];
    platforms = platforms.linux;
    mainProgram = "zot";
  };
}
