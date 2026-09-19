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
    then
      (
        exts: let
          base =
            if cfg.extensions == null
            then []
            else cfg.extensions exts;
        in
          base ++ [pg_textsearch]
      )
    else cfg.extensions;

  # Each entry recycles a different timestamp field, so the number of distinct
  # filenames is fixed and a file is reused — truncated — once its field wraps.
  # The rotation age has to match the field, otherwise the file is reopened and
  # appended to instead of being truncated.
  rotations = {
    hour = {
      filename = "postgresql-%M.log"; # 60 files, one per minute of the hour
      age = "1min";
    };

    day = {
      filename = "postgresql-%H.log"; # 24 files, one per hour of the day
      age = "60min";
    };

    week = {
      filename = "postgresql-%a.log"; # 7 files, Mon through Sun
      age = "1d";
    };
  };

  rotation = rotations.${cfg.log.retention};
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

      log = {
        statements = mkEnableOption ''
          logging every statement and its bind parameters

          Off by default because it is expensive on disk: a test suite that
          inserts rows in a loop writes every INSERT and every parameter, and
          a busy afternoon can produce several GB. Slow queries are still
          logged without it — `log_min_duration_statement` stays at 100ms, and
          that logs the statement text too, so this is only needed when you
          want to watch *every* query go by (`pg_log`)
        '';

        retention = mkOption {
          type = types.enum ["hour" "day" "week"];
          default = "day";
          description = ''
            How much log history to keep. Older logs are not deleted, they are
            overwritten: the log filename is a recycling timestamp field, so
            "day" writes `postgresql-<hour>.log` and the file for 14:00 is
            truncated when 14:00 comes around again a day later. That bounds
            the log directory to a fixed number of files — 60, 24 or 7 — where
            it was previously unbounded and grew forever.

            Raise this only if you also keep `statements` off; a week of
            statement logging is exactly the case that fills a disk.
          '';
        };
      };

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
        log_timezone = "UTC";
        logging_collector = "on";

        log_statement =
          if cfg.log.statements
          then "all"
          else "none";

        # Only meaningful next to the statement text; on its own it logs a
        # duration per statement with nothing to attribute it to.
        log_duration =
          if cfg.log.statements
          then "on"
          else "off";

        log_filename = rotation.filename;
        log_rotation_age = rotation.age;
        log_truncate_on_rotation = "on";

        # Not a safety net, and switching it on defeats the recycling above:
        # Postgres truncates an existing log file only on *time*-based
        # rotation. A size-based rotation recomputes the same filename and
        # appends to it, so the file grows past the limit anyway.
        log_rotation_size = 0;
      };
    };
  };
}
