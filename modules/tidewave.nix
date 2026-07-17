{
  config,
  lib,
  pkgs,
  flakeInputs,
  ...
}:
with lib; let
  customPackages = flakeInputs.self.packages.${pkgs.stdenv.system};

  cfg = config.modules.tidewave;
in {
  options = {
    modules.tidewave.enable = mkEnableOption "Tidewave development";
  };

  config = mkIf cfg.enable {
    packages = [customPackages.tidewave-cli];
  };
}
