{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:

buildGoModule {
  pname = "tc-redirect-tap";
  version = "0-unstable-2025-05-14";

  src = fetchFromGitHub {
    owner = "awslabs";
    repo = "tc-redirect-tap";
    rev = "34bf829e9a5c99df47318c7feeb637576df239fc";
    hash = "sha256-yeokm0aTwlMXmnMcNVRER9cZVuuNqk/RW0HY9vjiPPA=";
  };

  vendorHash = "sha256-gKkWzy+PVlLSOSljFG/T5RmROmfaK/nfXDId4kTeZKM=";

  # Build just the CNI plugin
  subPackages = [ "cmd/tc-redirect-tap" ];

  # Skip tests
  doCheck = false;

  postInstall = ''
    # CNI plugins are typically installed without version suffix
    mv $out/bin/tc-redirect-tap $out/bin/tc-redirect-tap || true
  '';

  meta = with lib; {
    description = "CNI plugin to redirect traffic to a TAP device for Firecracker microVMs";
    homepage = "https://github.com/awslabs/tc-redirect-tap";
    license = licenses.asl20;
    maintainers = [ ];
    platforms = platforms.linux;
    mainProgram = "tc-redirect-tap";
  };
}
