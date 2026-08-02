{
  config,
  lib,
  pkgs,
  flakeInputs,
  ...
}:
with lib; let
  cfg = config.modules.gleam;

  # Gleam has no dedicated cache env var: it (and the `erl` shell history and
  # `rebar3` it spawns for BEAM/hex deps) follow the XDG base dirs. Wrap the
  # binary so ONLY gleam and its children get their XDG dirs redirected into the
  # devenv state dir, keeping $HOME clean without hijacking XDG for the whole
  # shell. DEVENV_STATE is read at runtime (falls back if run outside the shell).
  base = ''"''${DEVENV_STATE:-$PWD/.devenv/state}/gleam"'';

  gleam-wrapped = pkgs.symlinkJoin {
    name = "gleam-devkit-${cfg.package.version}";
    paths = [cfg.package];
    nativeBuildInputs = [pkgs.makeWrapper];
    postBuild = ''
      wrapProgram $out/bin/gleam \
        --run 'export XDG_CACHE_HOME=${base}/cache' \
        --run 'export XDG_DATA_HOME=${base}/data' \
        --run 'export XDG_CONFIG_HOME=${base}/config' \
        --run 'export XDG_STATE_HOME=${base}/state'
    '';
  };
in {
  options = {
    modules.gleam = {
      enable = mkEnableOption "Gleam development";

      package = mkOption {
        type = types.package;
        default = pkgs.gleam;
        defaultText = literalMD "pkgs.gleam";
        description = "The Gleam package to use";
      };

      erlang.package = mkOption {
        type = types.package;
        default = pkgs.erlang;
        defaultText = literalMD "pkgs.erlang";
        description = "The Erlang/OTP package to use (BEAM target + `gleam shell`/`test`)";
      };

      rebar3.package = mkOption {
        type = types.package;
        default = pkgs.rebar3;
        defaultText = literalMD "pkgs.rebar3";
        description = "rebar3, used by gleam to build rebar/erlang hex deps";
      };
    };
  };

  config = mkIf cfg.enable {
    packages = [gleam-wrapped cfg.erlang.package cfg.rebar3.package];
  };
}
