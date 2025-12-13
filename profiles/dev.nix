# Development environment profile
# Applied to hosts tagged with "dev"
{ config, lib, pkgs, ... }:

{
  # Development-friendly fireactions settings
  services.fireactions = {
    logLevel = lib.mkDefault "debug";
    metricsEnable = lib.mkDefault true;

    # Enable debug SSH access to VMs (key from sops secrets)
    # Add your public SSH key to secrets/secrets.yaml under debug_ssh_key
    registryCache.debug.sshKeyFile = config.sops.secrets."debug-ssh-key".path;
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
