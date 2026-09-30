{
  config,
  lib,
  pkgs,
  flakeInputs,
  ...
}:
with lib; let
  # Dedicated nixos-unstable just for Codex. See the input comment in flake.nix:
  # the plugin marketplace CLI this module drives needs >= 0.154, which neither
  # pinned channel has, and codex-acp must track the same release.
  pkgs-codex = import flakeInputs.nixpkgs-codex {
    system = pkgs.stdenv.system;
    config.allowUnfree = true;
  };

  cfg = config.modules.codex;

  codex_dir = "${config.env.DEVENV_STATE}/codex";

  # Desired plugin state, flattened to one string. The sync below is skipped
  # while this is unchanged, so shell entry stays free after the first run.
  spec = concatStringsSep "\n" (cfg.marketplaces ++ cfg.plugins);

  syncPlugins = ''
    export CODEX_HOME="${codex_dir}"
    _stamp="${codex_dir}/.devkit-plugin-stamp"

    if [ "$(cat "$_stamp" 2>/dev/null)" != ${escapeShellArg spec} ]; then
      _ok=1
      ${concatMapStringsSep "\n" (m: ''
        ${cfg.package}/bin/codex plugin marketplace add ${escapeShellArg m} >/dev/null || _ok=0
      '')
      cfg.marketplaces}
      ${concatMapStringsSep "\n" (p: ''
        ${cfg.package}/bin/codex plugin add ${escapeShellArg p} >/dev/null || _ok=0
      '')
      cfg.plugins}

      # Stamp only on a clean pass, so a failed clone retries next shell entry.
      [ "$_ok" = 1 ] && printf '%s' ${escapeShellArg spec} > "$_stamp"
    fi
  '';

  managedDir = "${codex_dir}/managed";

  stagingDir = "${codex_dir}/.managed-staging";

  hooksEnabled = cfg.hooks != {} || cfg.trustedPluginHooks != [];

  managedEnabled = hooksEnabled || cfg.sharedAuth;

  # Merges any number of Claude-shaped hook files, concatenating the arrays under
  # each event rather than letting a later file replace an earlier one.
  mergeHooks = ''    ${pkgs.jq}/bin/jq -s 'reduce .[] as $f ({};
          reduce (($f.hooks // {}) | to_entries[]) as $e (.;
            .[$e.key] = ((.[$e.key] // []) + $e.value)))
        | {hooks: .}' '';

  staticHooks = pkgs.writeText "codex-static-hooks.json" (builtins.toJSON {hooks = cfg.hooks;});

  # Codex only honours policy — trusted hooks, the credential store — from its
  # system directory. bwrap fakes that directory per project, so nothing lands in
  # the real /etc and nothing is written to the project's own config.toml, which
  # Codex owns and rewrites.
  renderManaged = ''
    # Codex reads EVERY file in the managed directory, so intermediates are staged
    # outside it — one left there registers the same hooks a second time.
    mkdir -p "${managedDir}" "${stagingDir}"

    ${optionalString cfg.sharedAuth ''
      printf 'cli_auth_credentials_store = "keyring"\n' > "${managedDir}/config.toml"
    ''}

    ${optionalString hooksEnabled renderHooks}
  '';

  renderHooks = ''
    _parts=(${staticHooks})

    ${concatMapStringsSep "\n" (ref: let
        plugin = head (splitString "@" ref);
        marketplace = last (splitString "@" ref);
      in ''
        _root=$(ls -d "${codex_dir}"/plugins/cache/${escapeShellArg marketplace}/${escapeShellArg plugin}/*/ 2>/dev/null | sort -V | tail -1)
        _root=''${_root%/}
        if [ -n "$_root" ] && [ -f "$_root/hooks/hooks.json" ]; then
          # Plugin hook files reference their own root through a variable Codex only
          # expands for plugin-sourced hooks, so bake the resolved path in.
          sed -e "s|\''${CLAUDE_PLUGIN_ROOT}|$_root|g" \
              -e "s|\''${PLUGIN_ROOT}|$_root|g" \
              "$_root/hooks/hooks.json" > "${stagingDir}/${plugin}.json"
          _parts+=("${stagingDir}/${plugin}.json")
        fi
      '')
      cfg.trustedPluginHooks}

    ${mergeHooks} "''${_parts[@]}" > "${stagingDir}/hooks.json.new"
    ${pkgs.diffutils}/bin/cmp -s "${stagingDir}/hooks.json.new" "${managedDir}/hooks.json" \
      || mv "${stagingDir}/hooks.json.new" "${managedDir}/hooks.json"
    rm -f "${stagingDir}/hooks.json.new"

    # A promoted plugin hook would otherwise register twice and run the gate twice:
    # once from here, and again from the plugin's own copy, which Codex auto-trusts
    # once an identical managed definition exists. This also means hooks written by
    # hand into $CODEX_HOME or a repo's .codex/ no longer run.
    printf '[config]\nallow_managed_hooks_only = true\n' > "${managedDir}/requirements.toml"
  '';

  # --dev-bind / / keeps the session otherwise untouched: this is a mount trick to
  # place one directory, not a security boundary. Codex's own sandbox still applies
  # inside it.
  mkLauncher = pkg: bin:
    pkgs.writeShellScript "${bin}-managed" ''
      mkdir -p "${managedDir}"
      exec ${pkgs.bubblewrap}/bin/bwrap \
        --dev-bind / / \
        --overlay-src /etc --tmp-overlay /etc \
        --ro-bind "${managedDir}" /etc/codex \
        -- ${pkg}/bin/${bin} "$@"
    '';

  sandboxed = pkg: bin:
    pkgs.symlinkJoin {
      name = "${bin}-managed";
      paths = [pkg];
      postBuild = ''
        rm $out/bin/${bin}
        ln -s ${mkLauncher pkg bin} $out/bin/${bin}
      '';
    };
in {
  options = {
    modules.codex = {
      enable = mkEnableOption "Codex CLI development";

      package = mkOption {
        type = types.package;
        default = pkgs-codex.codex;
        defaultText = literalMD "`codex` from the flake's `nixpkgs-codex` input";
        description = "The Codex CLI package to use";
      };

      acpPackage = mkOption {
        type = types.package;
        default = pkgs-codex.codex-acp;
        defaultText = literalMD "`codex-acp` from the flake's `nixpkgs-codex` input";
        description = "The Codex ACP adapter, for agent-shell and other ACP clients";
      };

      marketplaces = mkOption {
        type = types.listOf types.str;
        default = [];
        example = ["sezaru/dev-ai-plugins"];
        description = ''
          Plugin marketplaces to register. Each entry is a source accepted by
          `codex plugin marketplace add`: an `owner/repo[@ref]` shorthand, an
          https/ssh git URL, or an absolute local path.

          Codex derives the marketplace *name* from the source's
          `.claude-plugin/marketplace.json`, not from anything given here — use
          that name on the left of the `@` in `plugins`.
        '';
      };

      plugins = mkOption {
        type = types.listOf types.str;
        default = [];
        example = ["dev-workflow@dev-ai-plugins"];
        description = ''
          Plugins to install and enable, each as `<plugin>@<marketplace>`.
          The marketplace must be registered through `marketplaces`.

          Codex snapshots the plugin into `$CODEX_HOME` at install time, so
          edits to a local marketplace checkout are not picked up until
          `codex plugin add <plugin>@<marketplace>` is re-run.
        '';
      };

      sharedAuth = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Keep the Codex credential in the system keyring instead of
          `$CODEX_HOME/auth.json`, so every project signs in once rather than
          per project. Nothing else is shared: config, sessions, plugins and
          skills all stay in this project's `CODEX_HOME`.

          OpenAI issues no long-lived token — plan-backed auth is OAuth only —
          which is what makes a shared store worth having.

          Needs a running Secret Service provider (gnome-keyring, KWallet).
          Codex does not migrate an existing `auth.json`, so the first project
          to enable this has to `codex login` once.
        '';
      };

      hooks = mkOption {
        type = types.attrsOf types.anything;
        default = {};
        example = literalExpression ''
          {
            PreToolUse = [
              {
                matcher = "Bash";
                hooks = [{type = "command"; command = "''${./guard.sh}";}];
              }
            ];
          }
        '';
        description = ''
          Claude-shaped hooks, keyed by event name, rendered as managed hooks.

          Managed hooks run without the per-hash trust review that Codex applies
          to every other hook source, so nothing has to be approved by hand.
          Commands must use absolute paths.
        '';
      };

      trustedPluginHooks = mkOption {
        type = types.listOf types.str;
        default = [];
        example = ["dev-workflow@dev-ai-plugins"];
        description = ''
          Installed plugins whose bundled `hooks/hooks.json` should be promoted
          to managed hooks, as `<plugin>@<marketplace>`.

          Without this a plugin's hooks are discovered but skipped until approved
          through `/hooks` in the TUI, and any edit to them re-arms that review.
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    packages =
      if managedEnabled
      then [(sandboxed cfg.package "codex") (sandboxed cfg.acpPackage "codex-acp") pkgs.jq]
      else [cfg.package cfg.acpPackage];

    # Scopes Codex's config, auth and sessions to this project. Codex rejects
    # CODEX_HOME from a repo .env (hardened after an RCE report) but honours a
    # real env var: config.toml, auth.json and the sandbox helpers all follow it.
    # codex-acp embeds codex-core, so it reads the same CODEX_HOME.
    env.CODEX_HOME = codex_dir;

    # Codex refuses to create PATH aliases and warns on every launch if
    # CODEX_HOME does not already exist.
    enterShell = ''
      mkdir -p "${codex_dir}"
      # Codex's only global instructions file lives in CODEX_HOME, which is per
      # project here, so point it at the host's machine-wide agent rules.
      if [ -e /etc/agents/AGENTS.md ] && { [ -L "${codex_dir}/AGENTS.md" ] || [ ! -e "${codex_dir}/AGENTS.md" ]; }; then
        ln -sfn /etc/agents/AGENTS.md "${codex_dir}/AGENTS.md"
      fi
      ${optionalString (cfg.marketplaces != [] || cfg.plugins != []) syncPlugins}
      ${optionalString managedEnabled renderManaged}
    '';
  };
}
