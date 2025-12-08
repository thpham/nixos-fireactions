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
