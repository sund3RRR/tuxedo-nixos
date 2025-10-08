{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.hardware.tuxedo-control-center;
  tuxedo-drivers = config.boot.kernelPackages.tuxedo-keyboard;
in
{
  options.hardware.tuxedo-control-center = {
    enable = mkEnableOption ''
      Tuxedo Control Center, the official fan and power management UI
      for Tuxedo laptops.

      This module does not offer any hardcoded configuration. So you
      will get the default configuration until you change it in the
      Tuxedo Control Center.
    '';

    package = mkOption {
      type = types.package;
      default = pkgs.tuxedo-control-center;
      defaultText = "pkgs.tuxedo-control-center";
      description = ''
        Which package to use for tuxedo-control-center.
      '';
    };
  };

  config = mkIf cfg.enable (
    lib.mkMerge [
      {
        hardware.tuxedo-drivers.enable = true;

        boot.kernelModules = [
          # Tuxedo Control Center has a requirement on the minimum version
          # of "tuxedo_io" kernel module.
          # The exact requirement is currently in the
          # "src/native-lib/tuxedo_io_lib/tuxedo_io_ioctl.h" file of tuxedo-control-center
          # (i.e. the #define of MOD_API_MIN_VERSION).
          # The respective version of the module itself is in the
          # "src/tuxedo_io/tuxedo_io.c" file of tuxedo-drivers
          # (i.e. the #define of MODULE_VERSION).
          (warnIf ((builtins.compareVersions tuxedo-drivers.version "4.12.1") < 0)
            "Tuxedo Control Center requires at least version 4.12.1 of tuxedo-drivers; current version is ${tuxedo-drivers.version}"
            "tuxedo_io"
          )
        ];

        environment.systemPackages = [ cfg.package ];
        services.dbus.packages = [ cfg.package ];
        services.udev.packages = [ cfg.package ];

        systemd = {
          packages = [ cfg.package ];
          services."tccd".wantedBy = [ "multi-user.target" ];
          services."tccd-sleep" = {
            wantedBy = [ "sleep.target" ];
            path = [ pkgs.systemd ];
          };
        };

        meta.maintainers = with lib.maintainers; [ sund3RRR ];
      }

      (lib.mkIf (lib.elem "nvidia" config.services.xserver.videoDrivers) {
        systemd.services."tccd".path = [ config.hardware.nvidia.package ];
      })
    ]
  );
}
