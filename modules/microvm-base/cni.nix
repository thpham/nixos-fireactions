# microvm-base/cni.nix - CNI plugins setup
#
# Provides CNI plugin symlinks to standard /opt/cni/bin path

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.microvm-base;
  tcRedirectTapPkg = cfg._internal.tcRedirectTapPkg;
in
{
  config = lib.mkIf cfg.enable {
    #
    # CNI Plugins Setup
    #

    # Symlink CNI plugins to standard /opt/cni/bin path
    # CNI libraries often use this as a fallback regardless of config
    systemd.services.microvm-cni-plugins-setup = {
      description = "Setup CNI plugins in /opt/cni/bin";
      wantedBy = [ "multi-user.target" ];
      before = lib.mapAttrsToList (name: _: "${name}.service") cfg.bridges;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        mkdir -p /opt/cni/bin
        # Link all CNI plugins
        for plugin in ${pkgs.cni-plugins}/bin/*; do
          ln -sf "$plugin" /opt/cni/bin/
        done
        # Link tc-redirect-tap
        ln -sf ${tcRedirectTapPkg}/bin/tc-redirect-tap /opt/cni/bin/
      '';
    };
  };
}
