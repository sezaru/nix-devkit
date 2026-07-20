{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.modules.aws;

  wrapped_aws = pkgs.symlinkJoin {
    name = "aws-wrapped";
    paths = [cfg.package];
    nativeBuildInputs = [pkgs.makeWrapper];
    postBuild = ''
      wrapProgram $out/bin/aws \
        --run 'export HOME="$DEVENV_STATE/aws"'
    '';
  };
in {
  options = {
    modules.aws = {
      enable = mkEnableOption "AWS CLI (with HOME redirected to project state)";

      package = mkOption {
        type = types.package;
        default = pkgs.awscli2;
        defaultText = literalMD "pkgs.awscli2";
        description = "The AWS CLI package to use";
      };
    };
  };

  config = mkIf cfg.enable {
    packages = [wrapped_aws];
  };
}
