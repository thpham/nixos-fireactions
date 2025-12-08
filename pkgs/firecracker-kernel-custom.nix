{
  lib,
  stdenv,
  fetchurl,
  fetchFromGitHub,
  flex,
  bison,
  perl,
  bc,
  openssl,
  elfutils,
  ncurses,
  hostname,
  ...
}:

let
  kernelVersion = "6.1.141";
  kernelMajor = "6";

  kernelSrc = fetchurl {
    url = "https://cdn.kernel.org/pub/linux/kernel/v${kernelMajor}.x/linux-${kernelVersion}.tar.xz";
    hash = "sha256-vDxF+vb18EUGZsdfqdrZvHwM98fLoNvZTlz9xYIpwRY=";
  };

  # Fetch the official Firecracker CI kernel configs
  firecrackerConfigs = fetchFromGitHub {
    owner = "firecracker-microvm";
    repo = "firecracker";
    rev = "v1.13.0";
    hash = "sha256-FI4w5YxfM8v6dL66rHorcrZ0I6BhhBFBqGh8Q8PgtyA=";
  };

  # Additional kernel config - external file to avoid IDE whitespace formatting issues
  # The .config file has no leading whitespace (kernel config parser requires CONFIG_xxx=y at column 0)
  customConfigFile = ./firecracker-kernel-custom.config;

  arch = if stdenv.hostPlatform.isx86_64 then "x86_64" else "arm64";
  configFile =
    if stdenv.hostPlatform.isx86_64 then
      "microvm-kernel-ci-x86_64-6.1.config"
    else
      "microvm-kernel-ci-aarch64-6.1.config";

in
stdenv.mkDerivation {
  pname = "firecracker-kernel-custom";
  version = kernelVersion;

  src = kernelSrc;

  nativeBuildInputs = [
    flex
    bison
    perl
    bc
    openssl
    elfutils
    ncurses
    hostname
  ];

  # Kernel build environment setup
  hardeningDisable = [ "all" ];

  makeFlags = [
    "ARCH=${arch}"
    "HOSTCC=${stdenv.cc}/bin/cc"
    "HOSTCXX=${stdenv.cc}/bin/c++"
  ];

  configurePhase = ''
    runHook preConfigure

    # Start with Firecracker's minimal CI config
    cp ${firecrackerConfigs}/resources/guest_configs/${configFile} .config
    chmod u+w .config

    # Append our custom config (file has no leading whitespace, CONFIG_xxx=y at column 0)
    cat ${customConfigFile} >> .config

    # Resolve any config conflicts (new options take precedence)
    make ARCH=${arch} olddefconfig

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild

    # Build only vmlinux (uncompressed kernel image for Firecracker)
    make ARCH=${arch} -j$NIX_BUILD_CORES vmlinux

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    install -D -m 0644 vmlinux $out/vmlinux

    # Also save the config for reference/debugging
    install -D -m 0644 .config $out/config

    runHook postInstall
  '';

  # Skip standard fixup phases that don't apply to kernel images
  dontStrip = true;
  dontPatchELF = true;
  dontFixup = true;

  passthru = {
    inherit kernelVersion arch;
    baseConfig = "${firecrackerConfigs}/resources/guest_configs/${configFile}";
  };

  meta = with lib; {
    description = "Custom Firecracker kernel with Docker bridge networking support";
    longDescription = ''
      Based on the official Firecracker CI kernel configuration with additional
      netfilter modules (CONFIG_IP_NF_RAW, CONFIG_IP6_NF_RAW, etc.) required
      for Docker bridge networking inside Firecracker microVMs.
    '';
    homepage = "https://github.com/firecracker-microvm/firecracker";
    license = licenses.gpl2Only;
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    maintainers = [ ];
  };
}
