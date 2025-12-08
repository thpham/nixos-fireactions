{
  lib,
  stdenvNoCC,
  fetchurl,
  firecrackerVersion ? "v1.13",
  kernelVersion ? "6.1.141",
}:

let
  arch =
    if stdenvNoCC.hostPlatform.isx86_64 then
      "x86_64"
    else if stdenvNoCC.hostPlatform.isAarch64 then
      "aarch64"
    else
      throw "Unsupported architecture: ${stdenvNoCC.hostPlatform.system}";

  # Hashes for different architectures (kernel 6.1.141)
  hashes = {
    x86_64 = "sha256-s2pKGxDzO5z9zePRp4fZwJBVaj7bIRzQbR8/mmx+hyQ=";
    aarch64 = "sha256-aaozCCGewaBwvJqOf4DDs0BW/tiuBe+0TlX3OzGt3kQ=";
  };
in
stdenvNoCC.mkDerivation {
  pname = "firecracker-kernel";
  version = kernelVersion;

  src = fetchurl {
    url = "https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/${firecrackerVersion}/${arch}/vmlinux-${kernelVersion}";
    hash = hashes.${arch};
  };

  dontUnpack = true;
  dontBuild = true;
  dontFixup = true;

  installPhase = ''
    runHook preInstall
    install -D -m 0644 $src $out/vmlinux
    runHook postInstall
  '';

  passthru = {
    inherit firecrackerVersion kernelVersion arch;
  };

  meta = with lib; {
    description = "Firecracker-optimized Linux kernel for microVMs";
    homepage = "https://github.com/firecracker-microvm/firecracker";
    license = licenses.gpl2Only;
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    sourceProvenance = [ sourceTypes.binaryNativeCode ];
  };
}
