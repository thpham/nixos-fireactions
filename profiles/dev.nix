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
  };

  # Fireteact dev settings (only if enabled)
  services.fireteact = lib.mkIf config.services.fireteact.enable {
    logLevel = lib.mkDefault "debug";
    # VM debug access - SSH key for debugging inside VMs
    debug.sshKeyFile = config.sops.secrets."debug-ssh-key".path;
  };

  # Registry cache debug access (standalone module)
  # Add your public SSH key to secrets/secrets.yaml under debug_ssh_key
  services.registry-cache.debug.sshKeyFile =
    lib.mkIf config.services.registry-cache.enable
      config.sops.secrets."debug-ssh-key".path;

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
