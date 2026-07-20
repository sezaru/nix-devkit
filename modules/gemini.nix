{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.modules.gemini;
in {
  options = {
    modules.gemini = {
      enable = mkEnableOption "Gemini development";

      package = mkOption {
        type = types.package;
        default = pkgs.gemini-cli-bin;
        defaultText = literalMD "pkgs.gemini-cli-bin";
        description = "The Gemini package to use";
      };
    };
  };

  config = mkIf cfg.enable {
    packages = [cfg.package];
  };
}
