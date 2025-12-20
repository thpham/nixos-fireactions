# Development environment profile
# Applied to hosts tagged with "dev"
{
  config,
  lib,
  pkgs,
  ...
}:

{
  # Shared kernel configuration (required for container workloads with Docker bridge)
  services.microvm-base.kernel.source = lib.mkDefault "custom";

  # Fireactions dev settings (only if enabled)
  services.fireactions = lib.mkIf config.services.fireactions.enable {
    logLevel = lib.mkDefault "debug";
    metricsEnable = lib.mkDefault true;
    debug.sshKeyFile = config.sops.secrets."debug-ssh-key".path;
  };

  # Fireteact dev settings (only if enabled)
  services.fireteact = lib.mkIf config.services.fireteact.enable {
    logLevel = lib.mkDefault "debug";
    debug.sshKeyFile = config.sops.secrets."debug-ssh-key".path;
  };

  # Fireglab dev settings (only if enabled)
  services.fireglab = lib.mkIf config.services.fireglab.enable {
    logLevel = lib.mkDefault "debug";
    debug.sshKeyFile = config.sops.secrets."debug-ssh-key".path;
  };

  # More permissive SSH for development
  services.openssh.settings = {
    PermitRootLogin = lib.mkDefault "prohibit-password";
  };

  # Useful development tools
  environment.systemPackages = with pkgs; [
    htop
    vim
    curl
    jq
  ];

  # More verbose logging for debugging
  services.journald.extraConfig = ''
    SystemMaxUse=4G
    MaxRetentionSec=7day
  '';
}
