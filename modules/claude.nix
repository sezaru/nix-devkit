{
  config,
  lib,
  pkgs,
  flakeInputs,
  ...
}:
with lib; let
  state_dir = config.env.DEVENV_STATE;
  root_dir = config.env.DEVENV_ROOT;

  claude_dir = "${state_dir}/claude";
  hexdocs_dir = "${state_dir}/hexdocs";

  customPackages = flakeInputs.self.packages.${pkgs.stdenv.system};

  cfg = config.modules.claude;

  pg = cfg.postgres;

  # Connection parts are passed in as values by the project. Each may be a
  # literal ("myuser") or a shell reference ("$DATABASE_USER"): the URL
  # is assembled in the shell AFTER .env is sourced, so shell refs expand at
  # runtime. Only the reference (not the secret) ever lands in the store.
  postgres-mcp = pkgs.writeShellScriptBin "postgres-mcp" ''
    set -euo pipefail

    # Auto-load .env if present (supports both KEY=VAL and export KEY=VAL formats)
    if [[ -f ".env" ]]; then
      set -a
      source .env
      set +a
    fi

    DATABASE_URL="postgresql://${pg.user}:${pg.password}@${pg.hostname}:${pg.port}/${pg.name}"

    exec npx -y @modelcontextprotocol/server-postgres "$DATABASE_URL"
  '';
in {
  imports = [
    ./node.nix
  ];

  options = {
    modules.claude = {
      enable = mkEnableOption "Claude Code development";
      hexdocs.enable = mkEnableOption "Enable hexdocs MCP";
      mempalace.enable = mkEnableOption "Enable mempalace memory MCP";

      postgres = {
        enable = mkEnableOption "Enable postgres MCP";

        user = mkOption {
          type = types.str;
          default = "postgres";
          example = "$DATABASE_USER";
          description = "DB user. Literal, or a shell ref expanded at runtime (e.g. \"$DATABASE_USER\").";
        };

        password = mkOption {
          type = types.str;
          default = "postgres";
          example = "$DATABASE_PASSWORD";
          description = "DB password. Literal, or a shell ref expanded at runtime.";
        };

        hostname = mkOption {
          type = types.str;
          default = "localhost";
          example = "$DATABASE_HOSTNAME";
          description = "DB hostname. Literal, or a shell ref expanded at runtime.";
        };

        port = mkOption {
          type = types.str;
          default = "5432";
          example = "$DATABASE_PORT";
          description = "DB port. Literal, or a shell ref expanded at runtime.";
        };

        name = mkOption {
          type = types.str;
          default = "postgres";
          example = "$DATABASE_NAME";
          description = "DB name. Literal, or a shell ref expanded at runtime.";
        };
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      packages =
        [pkgs.claude-code pkgs.ast-grep pkgs.bubblewrap customPackages.claude-agent-acp]
        ++ optionals cfg.postgres.enable [postgres-mcp]
        ++ optionals cfg.mempalace.enable [customPackages.mempalace];

      env.CLAUDE_CONFIG_DIR = claude_dir;

      env.TIDEWAVE_CLAUDE_AGENT_ACP_EXECUTABLE = "${customPackages.claude-agent-acp}/bin/claude-agent-acp";
    }

    (mkIf cfg.hexdocs.enable {
      env.HEXDOCS_MCP_PATH = hexdocs_dir;
      env.HEXDOCS_MCP_MIX_PROJECT_PATHS = root_dir;

      modules.node = {
        enable = mkForce true;
      };
    })
  ]);
}
