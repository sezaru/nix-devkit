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

  # Bump the Claude Code CLI ahead of nixpkgs so the `/model` picker offers
  # Fable 5.1 (claude-fable-5-1), which the pinned nixpkgs version predates.
  # Manifest = the upstream release manifest (version + per-platform checksums)
  # from downloads.claude.ai; refresh packages/claude-code-manifest.json to bump.
  claude-code = pkgs.claude-code.override {
    manifest = lib.importJSON ../packages/claude-code-manifest.json;
  };

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
        # jq is used by the Claude PreToolUse log-guard hook (.claude/hooks).
        [claude-code pkgs.ast-grep pkgs.bubblewrap pkgs.jq customPackages.claude-agent-acp]
        ++ optionals cfg.postgres.enable [postgres-mcp]
        ++ optionals cfg.mempalace.enable [customPackages.mempalace];

      env.CLAUDE_CONFIG_DIR = claude_dir;

      env.TIDEWAVE_CLAUDE_AGENT_ACP_EXECUTABLE = "${customPackages.claude-agent-acp}/bin/claude-agent-acp";

      # Force-enable the Fable models in the `/model` picker (CLI + agent-shell).
      # Fable is gated by a server-side rollout that fills
      # `additionalModelOptionsCache` in .claude.json; config dirs bucketed out of
      # the rollout never get it (varies per project despite the same account).
      # Seed the entries ourselves. Idempotent, and the cache is sticky (Claude's
      # fetch never clears it). The `value` is what the picker keys on and must be
      # a model id the running binary knows: Fable 5.1 (claude-fable-5-1) needs
      # claude-code >= 2.1.250 (see the manifest override above) and the latest
      # claude-agent-acp; the current acp (0.73.0) only surfaces 5.0 in the picker.
      # Only patches an existing file, so a fresh project seeds from the second
      # shell entry onward.
      enterShell = ''
        if [ -f "${claude_dir}/.claude.json" ] && command -v jq >/dev/null 2>&1; then
          _tmp=$(mktemp)
          if jq '.additionalModelOptionsCache = ((.additionalModelOptionsCache // [])
                   | (if any(.value == "claude-fable-5[1m]") then . else . + [{"value":"claude-fable-5[1m]","label":"Fable 5","description":"Fable 5 · Most capable for your hardest and longest-running tasks"}] end)
                   | (if any(.value == "claude-fable-5-1") then . else . + [{"value":"claude-fable-5-1","label":"Fable 5.1","description":"Fable 5.1 · Most capable for your hardest and longest-running tasks"}] end))' "${claude_dir}/.claude.json" > "$_tmp" 2>/dev/null; then
            mv "$_tmp" "${claude_dir}/.claude.json"
          else
            rm -f "$_tmp"
          fi
        fi
      '';
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
