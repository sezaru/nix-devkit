{
  config,
  lib,
  pkgs,
  flakeInputs,
  ...
}:
with lib; let
  expert = flakeInputs.expert.packages.${pkgs.stdenv.system}.default;

  state_dir = config.env.DEVENV_STATE;

  mix_dir = "${state_dir}/mix";
  hex_dir = "${state_dir}/hex";

  cfg = config.modules.elixir;
in {
  options = {
    modules.elixir = {
      enable = mkEnableOption "Elixir development";

      package = mkOption {
        type = types.package;
        default = pkgs.beamPackages.elixir;
        defaultText = literalMD "pkgs.beamPackages.elixir";
        description = "The Elixir package to use";
      };

      erlang = {
        package = mkOption {
          type = types.package;
          default = pkgs.beamPackages.erlang;
          defaultText = literalMD "pkgs.beamPackages.erlang";
          description = "The Erlang package to use";
        };
      };

      phoenix = {
        enable = mkEnableOption "Enable phoenix development";
      };

      ash = {
        enable = mkEnableOption "Enable Ash development (adds mermaid-cli for diagrams)";
      };

      lsp = {
        enable = mkEnableOption "Enable Expert LSP";
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      packages =
        (lists.optionals cfg.phoenix.enable [pkgs.watchman pkgs.inotify-tools])
        ++ (lists.optionals cfg.ash.enable [pkgs.mermaid-cli])
        ++ (lists.optionals cfg.lsp.enable [pkgs.emacs-lsp-booster expert])
        ++ [cfg.package cfg.erlang.package pkgs.wxGTK33];

      env.ERL_AFLAGS = "-kernel shell_history enabled -kernel shell_history_path '\"${state_dir}/erlang-history\"'";

      enterShell = ''
        mkdir -p ${mix_dir}/bin
        mkdir -p ${mix_dir}/escripts
        mkdir -p ${hex_dir}/bin

        export PATH="${mix_dir}/bin:${mix_dir}/escripts:${hex_dir}/bin:$PATH"
      '';

      env.MIX_HOME = mix_dir;
      env.HEX_HOME = hex_dir;

      env.ERL_LIBS = "${hex_dir}/lib/erlang/lib";
    }

    # Phoenix asset tooling. Kept in a conditional block (not per-var `mkIf`) so
    # the env keys are entirely ABSENT when phoenix is disabled — a bare
    # `env.X = mkIf cond ...` still registers `X` in devenv's freeform env
    # attrset with no value, which errors ("accessed but no value defined").
    (mkIf cfg.phoenix.enable {
      env.MIX_TAILWINDCSS_PATH = "${pkgs.tailwindcss_4}/bin/tailwindcss";
      env.MIX_ESBUILD_PATH = "${pkgs.esbuild}/bin/esbuild";
      env.MIX_PRETTIER_PATH = "${pkgs.prettier}/bin/prettier";
    })
  ]);
}
