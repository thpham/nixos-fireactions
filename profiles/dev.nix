# Development environment profile
# Applied to hosts tagged with "dev"
{ lib, pkgs, ... }:

{
  # Development-friendly fireactions settings
  services.fireactions = {
    logLevel = lib.mkDefault "debug";
    metricsEnable = lib.mkDefault true;
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
