{
  config,
  lib,
  pkgs,
  flakeInputs,
  ...
}:
with lib; let
  # Separate nixpkgs just for the Flutter SDK (nixos-unstable) so we get Flutter
  # v3_44 / Dart 3.12.2 — required by lib_llama_cpp (>=3.11.5) for the on-device
  # GGUF VLM. Flutter 3.44.2 targets the same NDK 28.2.13676358 / compileSdk 36 /
  # build-tools 36.0.0 that `modules.android` provisions by default, so nothing
  # else needs to move.
  pkgs-flutter = import flakeInputs.nixpkgs-flutter {
    system = pkgs.stdenv.system;
    config.allowUnfree = true;
  };

  state_dir = config.env.DEVENV_STATE;

  pub_cache_dir = "${state_dir}/pub-cache";
  xdg_config_dir = "${state_dir}/xdg-config";
  xdg_data_dir = "${state_dir}/xdg-data";
  xdg_cache_dir = "${state_dir}/xdg-cache";
  dart_server_dir = "${state_dir}/dart-server";
  # Scoped HOME for flutter + dart. The flutter/dart tools write ~/.flutter
  # (legacy clientId) and ~/.dart-tool/ (telemetry) to $HOME directly — these
  # ignore XDG_*_HOME and FLUTTER_SUPPRESS_ANALYTICS, so the only way to keep
  # them out of real home is to run the binaries under a scoped HOME.
  flutter_home_dir = "${state_dir}/flutter-home";

  cfg = config.modules.flutter;

  # The `flutter` shim. Besides HOME-scoping, it makes `flutter run` IMPOSSIBLE to
  # run in the blocking foreground from a non-interactive caller. `flutter run` is
  # interactive and never self-exits, so when an agent/CI invokes it (stdout is a
  # pipe, not a TTY) a foreground run blocks the tool call forever and freezes the
  # session. So we detect that case and background it, fully detached from the
  # caller's stdio: stdin</dev/null and output->log file. It returns immediately.
  #
  # Deliberately NO control FIFO: there is no channel to send hot reload/restart
  # keys, so the whole class of pipe-blocking hangs cannot occur. To apply code
  # changes, restart (pkill + re-run). flutter stays alive on /dev/null stdin —
  # verified: singleCharMode no-ops without a TTY and the keystroke listener just
  # ends on EOF. A human at a real terminal (stdout is a TTY) still gets the normal
  # interactive run with working hot reload. This is the enforcement point — no
  # skill/hook/memory cooperation required, because every `flutter` call goes here.
  flutter_run_shim = pkgs.writeShellScript "flutter" ''
    export HOME="${flutter_home_dir}"
    mkdir -p "$HOME"

    if [ "$1" = run ] && [ ! -t 1 ]; then
      shift
      LOG=/tmp/flutter_run2.log
      pkill -f "flutter_tools.snapshot run" 2>/dev/null || true   # one instance only
      : > "$LOG"
      # stdin</dev/null, stdout+stderr->LOG: nothing keeps the caller's pipe open,
      # so the tool call returns instantly instead of blocking on the run.
      ${cfg.package}/bin/flutter run "$@" </dev/null >"$LOG" 2>&1 &
      echo "flutter run auto-backgrounded (non-interactive) — it cannot block the caller."
      echo "  logs:    tail -n 50 $LOG    or    grep -i error $LOG"
      echo "  restart: pkill -f 'flutter_tools.snapshot run'   then re-run: flutter run -d <device>"
      echo "  (hot reload/restart is unavailable here: stdin is /dev/null, no key channel)"
      exit 0
    fi

    exec ${cfg.package}/bin/flutter "$@"
  '';

  # Wrap flutter + dart so they run under a scoped HOME, keeping ~/.flutter and
  # ~/.dart-tool/ out of the real home. Mirror the package via symlinks and
  # replace only bin/flutter and bin/dart with HOME-scoping shims. The real
  # flutter/dart wrapper scripts resolve FLUTTER_ROOT from their own store path
  # (not $0 of the shim), so exec'ing the absolute store path works. Child
  # processes flutter spawns (its bundled dart, gradle, the wrapped adb) inherit
  # the scoped HOME too.
  flutter_wrapped = pkgs.runCommand "flutter-homescoped" {} ''
    raw=${cfg.package}
    mkdir -p "$out/bin"
    for f in "$raw"/bin/*; do
      base=$(basename "$f")
      case "$base" in
        flutter)
          cp ${flutter_run_shim} "$out/bin/flutter"
          chmod +x "$out/bin/flutter"
          ;;
        dart)
          {
            printf '#!%s\n' "${pkgs.runtimeShell}"
            printf 'export HOME="%s"\n' "${flutter_home_dir}"
            printf 'mkdir -p "$HOME"\n'
            printf 'exec "%s" "$@"\n' "$f"
          } > "$out/bin/dart"
          chmod +x "$out/bin/dart"
          ;;
        *)
          ln -s "$f" "$out/bin/$base"
          ;;
      esac
    done
    for d in "$raw"/*; do
      base=$(basename "$d")
      [ "$base" = "bin" ] && continue
      ln -s "$d" "$out/$base"
    done
  '';

  # The npm @playwright/mcp bundles its own playwright-core whose browser
  # registry expects a "chrome-for-testing" entry, which it can't resolve
  # against the nix-provided $PLAYWRIGHT_BROWSERS_PATH (dir is named
  # chromium-<rev>). Point it straight at the nix chromium binary so it
  # skips registry resolution entirely. Glob the revision so a Playwright
  # bump in nixpkgs doesn't break this.
  playwright-mcp = pkgs.writeShellScriptBin "playwright-mcp" ''
    chrome=$(echo "$PLAYWRIGHT_BROWSERS_PATH"/chromium-*/chrome-linux64/chrome | cut -d' ' -f1)
    exec npx @playwright/mcp --executable-path "$chrome" "$@"
  '';
in {
  # Android used to live inside this module, so a Flutter project reached the SDK
  # through `modules.flutter.android.*`. It is its own module now — an Elixir or
  # Rust project has no business enabling Flutter just to get an emulator. These
  # aliases keep existing consumers evaluating unchanged; they can move to
  # `modules.android.*` whenever, and then these can go.
  imports = [
    (mkRenamedOptionModule ["modules" "flutter" "android" "enable"] ["modules" "android" "enable"])
    (mkRenamedOptionModule ["modules" "flutter" "android" "apiLevel"] ["modules" "android" "apiLevel"])
    (mkRenamedOptionModule ["modules" "flutter" "android" "buildToolsVersion"] ["modules" "android" "buildToolsVersion"])
    (mkRenamedOptionModule ["modules" "flutter" "android" "cmakeVersion"] ["modules" "android" "cmakeVersion"])
    (mkRenamedOptionModule ["modules" "flutter" "android" "ndkVersion"] ["modules" "android" "ndkVersion"])
    (mkRenamedOptionModule ["modules" "flutter" "android" "systemImageType"] ["modules" "android" "systemImageType"])
    (mkRenamedOptionModule ["modules" "flutter" "android" "device"] ["modules" "android" "device"])
    (mkRenamedOptionModule ["modules" "flutter" "android" "avdName"] ["modules" "android" "avdName"])
    (mkRenamedOptionModule ["modules" "flutter" "android" "jdk"] ["modules" "android" "jdk"])
    (mkRenamedOptionModule ["modules" "flutter" "android" "emulator" "enable"] ["modules" "android" "emulator" "enable"])
    (mkRenamedOptionModule ["modules" "flutter" "android" "emulator" "rooted" "enable"] ["modules" "android" "emulator" "rooted" "enable"])
    (mkRenamedOptionModule ["modules" "flutter" "android" "emulator" "rooted" "apiLevel"] ["modules" "android" "emulator" "rooted" "apiLevel"])
    (mkRenamedOptionModule ["modules" "flutter" "android" "emulator" "rooted" "avdName"] ["modules" "android" "emulator" "rooted" "avdName"])
    (mkRenamedOptionModule ["modules" "flutter" "android" "emulator" "rooted" "magiskVersion"] ["modules" "android" "emulator" "rooted" "magiskVersion"])
    (mkRenamedOptionModule ["modules" "flutter" "android" "emulator" "rooted" "magiskHash"] ["modules" "android" "emulator" "rooted" "magiskHash"])
  ];

  options = {
    modules.flutter = {
      enable = mkEnableOption "Flutter development";

      package = mkOption {
        type = types.package;
        default = pkgs-flutter.flutterPackages.v3_44;
        defaultText = literalMD "pkgs-flutter.flutterPackages.v3_44";
        description = "The Flutter package to use (v3_44 / Dart 3.12.2)";
      };

      mcp = {
        playwright = {
          enable = mkEnableOption "Enable Playwright MCP for HTML mockup screenshots";
        };
      };

      skills = {
        enable = mkEnableOption "Install Flutter agent skills into .agents/skills";
      };
    };
  };

  config = mkMerge [
    (mkIf cfg.enable {
      packages = [flutter_wrapped];

      env.PUB_CACHE = pub_cache_dir;

      # All three XDG dirs scoped — covers Flutter, Dart, and any other
      # XDG-compliant tool that would otherwise write to ~/.config, ~/.local/share, ~/.cache
      env.XDG_CONFIG_HOME = xdg_config_dir;
      env.XDG_DATA_HOME = xdg_data_dir;
      env.XDG_CACHE_HOME = xdg_cache_dir;

      # Dart analysis server state — confirmed via live test this fully overrides ~/.dartServer
      env.ANALYZER_STATE_LOCATION_OVERRIDE = dart_server_dir;

      env.FLUTTER_SUPPRESS_ANALYTICS = "1";

      enterShell = ''
        mkdir -p ${pub_cache_dir}/bin
        mkdir -p ${xdg_config_dir}/flutter
        mkdir -p ${xdg_data_dir}
        mkdir -p ${xdg_cache_dir}
        mkdir -p ${dart_server_dir}
        mkdir -p ${flutter_home_dir}
        export PATH="${pub_cache_dir}/bin:$PATH"

        # Write disable flag to $XDG_CONFIG_HOME/dart/ so dart telemetry never
        # writes to ~/.dart_tool/. Idempotent — no-op if already disabled.
        dart --disable-analytics > /dev/null 2>&1 || true
      '';
    })

    (mkIf (cfg.enable && cfg.skills.enable) {
      modules.node.enable = mkForce true;

      enterShell = ''
        if [ ! -d "$DEVENV_ROOT/.agents/skills/flutter-apply-architecture-best-practices" ]; then
          echo "Installing Flutter agent skills..."
          npx skills add flutter/skills --skill '*' --agent universal --yes
        fi
      '';
    })

    (mkIf (cfg.enable && cfg.mcp.playwright.enable) {
      packages = [pkgs.playwright-driver.browsers playwright-mcp];

      env.PLAYWRIGHT_BROWSERS_PATH = "${pkgs.playwright-driver.browsers}";
      env.PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1";

      modules.node.enable = mkForce true;
    })
  ];
}
