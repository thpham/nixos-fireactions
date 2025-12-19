# Production environment profile
# Applied to hosts tagged with "prod"
{ config, lib, ... }:

{
  # Shared kernel configuration (required for container workloads with Docker bridge)
  services.microvm-base.kernel.source = lib.mkDefault "custom";

  # Fireactions prod settings (only if enabled)
  services.fireactions = lib.mkIf config.services.fireactions.enable {
    logLevel = lib.mkDefault "warn";
    metricsEnable = lib.mkDefault true;
  };

  # Fireteact prod settings (only if enabled)
  services.fireteact = lib.mkIf config.services.fireteact.enable {
    logLevel = lib.mkDefault "warn";
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
    enable = lib.mkDefault false; # Disabled - use colmena for controlled updates
    allowReboot = false;
  };
}
