{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  state_dir = config.env.DEVENV_STATE;

  cfg = config.modules.postgresql;

  pg_textsearch = pkgs.callPackage ../packages/pg_textsearch.nix {
    postgresql = cfg.package;
  };

  wrappedExtensions =
    if cfg.pg_textsearch.enable
    then (
      exts: let
        base =
          if cfg.extensions == null
          then []
          else cfg.extensions exts;
      in
        base ++ [pg_textsearch]
    )
    else cfg.extensions;
in {
  options = {
    modules.postgresql = {
      enable = mkEnableOption "PostgresSQL database";

      package = mkOption {
        type = types.package;
        default = pkgs.postgresql;
        defaultText = literalMD "pkgs.postgresql";
        description = "The PostgreSQL package to use";
      };

      port = mkOption {
        type = types.int;
        default = 5432;
        description = "The PostgreSQL port";
      };

      extensions = lib.mkOption {
        type = with types; nullOr (functionTo (listOf package));
        default = null;
        example = literalExpression ''
          extensions: [
            extensions.pg_cron
            extensions.postgis
            extensions.timescaledb
          ];
        '';
        description = "Additional PostgreSQL extensions to install";
      };

      pg_textsearch.enable = mkEnableOption "Enable pg_textsearch extension (BM25 full-text search)";

      defaultDatabase = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "The default database to login with psql.";
      };
    };
  };

  config = mkIf cfg.enable {
    scripts.pg.exec = ''
      mkdir -p ${config.devenv.runtime}/postgres

      pg_ctl $@
    '';

    scripts.pg_log = {
      exec = ''
        set log_path "$(echo (cat .devenv/state/postgres/current_logfiles | string split ' ')[2])"

        tail -f ${state_dir}/postgres/$log_path
      '';

      package = pkgs.fish;
    };

    enterShell = ''
      echo "PostgreSQL usage:"
      echo -e "\tRun 'pg start' to start the database"
      echo -e "\tRun 'pg stop' to stop the database"
      echo ""
      pg_ctl status
      echo ""
    '';

    env.PGDATABASE = cfg.defaultDatabase;

    env.PSQL_HISTORY = "${state_dir}/psql_history";

    services.postgres = {
      enable = true;

      package = cfg.package;

      extensions = wrappedExtensions;

      initdbArgs = [
        "--locale=C"
        "--encoding=UTF8"
      ];

      listen_addresses = "127.0.0.1";

      port = cfg.port;

      settings = {
        max_connections = 300;
        log_min_messages = "warning";
        log_min_error_statement = "error";
        log_min_duration_statement = 100;
        log_connections = "on";
        log_disconnections = "on";
        log_duration = "on";
        log_timezone = "UTC";
        log_statement = "all";
        logging_collector = "on";
      };
    };
  };
}
