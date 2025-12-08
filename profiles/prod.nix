# Production environment profile
# Applied to hosts tagged with "prod"
{ lib, ... }:

{
  # Production-grade fireactions settings
  services.fireactions = {
    logLevel = lib.mkDefault "warn";
    metricsEnable = lib.mkDefault true;
  };

  # Stricter security for production
  services.openssh.settings = {
    PermitRootLogin = lib.mkForce "prohibit-password";
    PasswordAuthentication = lib.mkForce false;
  };

  # Production logging
  services.journald.extraConfig = ''
    SystemMaxUse=2G
    MaxRetentionSec=30day
  '';

  # Enable automatic security updates
  system.autoUpgrade = {
    enable = lib.mkDefault false;  # Disabled - use colmena for controlled updates
    allowReboot = false;
  };
}
