{
  config,
  lib,
  pkgs,
  flakeInputs,
  ...
}:
with lib; let
  cfg = config.modules.open-design;

  open-design = flakeInputs.self.packages.${pkgs.stdenv.system}.open-design;
in {
  options = {
    modules.open-design.enable = mkEnableOption "Open Design daemon + web UI (`od` CLI)";
  };

  config = mkIf cfg.enable {
    # zenity backs the native folder picker used by the Open Design web UI
    packages = [open-design pkgs.zenity];

    # od defaults its data dir to <install>/.od, which is the read-only Nix
    # store path and crashes on first mkdir. Redirect to a writable,
    # project-local state dir.
    enterShell = ''
      export OD_DATA_DIR="''${OD_DATA_DIR:-$DEVENV_STATE/open-design}"
    '';
  };
}
