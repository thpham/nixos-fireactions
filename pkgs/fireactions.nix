{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:

buildGoModule rec {
  pname = "fireactions";
  version = "0.4.0";

  src = fetchFromGitHub {
    owner = "hostinger";
    repo = "fireactions";
    rev = "v${version}";
    hash = "sha256-R4/rbzVOf29hzFygzJemjdVezvGkfmQaF2Vgjppnu+8=";
  };

  vendorHash = "sha256-DCPj2JJr1UY5DYa472NnT1x7ZqZyuu0jOUpM4dxwL+8=";

  # Patches for cloud-init compatibility:
  # 1. Use MMDS V1 instead of V2 (cloud-init IMDSv2 not compatible with Firecracker)
  # 2. Fix MMDS structure for EC2 datasource (user-data must be sibling of meta-data, not nested)
  # 3. Add EC2 API version paths (cloud-init checks /2009-04-04/ before /latest/)
  postPatch = ''
    substituteInPlace server/pool.go \
      --replace-fail 'firecracker.MMDSv2' 'firecracker.MMDSv1'

    # Fix MMDS structure: cloud-init expects user-data at /version/user-data, not /version/meta-data/user-data
    # Also add 2009-04-04 API version path for compatibility
    substituteInPlace server/pool.go \
      --replace-fail \
        'metadata := map[string]interface{}{"latest": map[string]interface{}{"meta-data": deepcopy.Map(p.config.Firecracker.Metadata)}}' \
        'cfgMeta := deepcopy.Map(p.config.Firecracker.Metadata); userData, hasUserData := cfgMeta["user-data"]; delete(cfgMeta, "user-data"); latestData := map[string]interface{}{"meta-data": cfgMeta}; if hasUserData { latestData["user-data"] = userData }; metadata := map[string]interface{}{"latest": latestData, "2009-04-04": latestData}'
  '';

  subPackages = [ "cmd/fireactions" ];

  ldflags = [
    "-s"
    "-w"
    "-X github.com/hostinger/fireactions.Version=v${version}"
    "-X github.com/hostinger/fireactions.Commit=${src.rev}"
    "-X github.com/hostinger/fireactions.Date=1970-01-01T00:00:00Z"
  ];

  # Skip tests that require network or special setup
  doCheck = false;

  meta = with lib; {
    description = "Self-hosted GitHub Actions runners using Firecracker microVMs";
    homepage = "https://github.com/hostinger/fireactions";
    license = licenses.asl20;
    maintainers = [ ];
    platforms = platforms.linux;
    mainProgram = "fireactions";
  };
}
