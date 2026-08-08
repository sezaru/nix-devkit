{
  config,
  lib,
  pkgs,
  flakeInputs,
  ...
}:
with lib; let
  pkgs-unstable = import flakeInputs.nixpkgs-unstable {
    system = pkgs.stdenv.system;
    config.allowUnfree = true;
    config.android_sdk.accept_license = true;
  };

  # Separate nixpkgs just for the Flutter SDK (nixos-unstable) so we get Flutter
  # v3_44 / Dart 3.12.2 — required by lib_llama_cpp (>=3.11.5) for the on-device
  # GGUF VLM. Flutter 3.44.2 targets the same NDK 28.2.13676358 / compileSdk 36 /
  # build-tools 36.0.0 the Android SDK below already provisions, so nothing else
  # needs to move.
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
  android_user_dir = "${state_dir}/android";
  # Scoped HOME for adb + emulator. adb 36 ignores ANDROID_USER_HOME/ANDROID_SDK_HOME
  # and only honors $HOME for its key dir (~/.android), so the adb binary and the
  # emulator are forced to use this dir instead of the real home.
  android_home_dir = "${state_dir}/android-home";
  gradle_dir = "${state_dir}/gradle";
  java_prefs_dir = "${state_dir}/java-prefs";

  cfg = config.modules.flutter;

  isX86 = pkgs.stdenv.hostPlatform.isx86_64;
  # On x86_64 hosts use x86_64 system images for KVM acceleration; otherwise
  # fall back to arm64 (e.g. aarch64 host).
  emulatorAbi =
    if isX86
    then "x86_64"
    else "arm64-v8a";
  systemImageId = "system-images;android-${cfg.android.apiLevel};${cfg.android.systemImageType};${emulatorAbi}";

  # Google ships the emulator host binary only for x86_64-linux — there is no
  # aarch64-linux archive in the SDK repo, so the androidenv emulator derivation
  # dies in unpackPhase ("did not have any sources available for os=linux,
  # arch=aarch64"). meta.available is misleadingly true, so it only surfaces at
  # build time. Force the emulator off on non-x86 hosts regardless of the option;
  # on aarch64 use a physical device via adb. Warn only when explicitly requested.
  emulatorEnabled =
    cfg.android.emulator.enable
    && (isX86
      || warn "modules.flutter.android.emulator: no aarch64-linux Android emulator exists; disabling it on ${pkgs.stdenv.hostPlatform.system} (attach a physical device via adb)." false);

  android_sdk_raw =
    (pkgs-unstable.androidenv.composeAndroidPackages {
      # Some plugins (e.g. path_provider_android / jni) pin build-tools 35.0.0,
      # so provision it alongside the project default. The Nix SDK is read-only,
      # so every required build-tools version must be listed here.
      # 34.0.0: lib_llama_cpp's transitive plugin `large_file_handler` compiles
      # against android-34 / build-tools 34, which Gradle can't auto-install into
      # the read-only Nix SDK.
      buildToolsVersions = unique (["34.0.0" "35.0.0"] ++ [cfg.android.buildToolsVersion]);
      # android-33: the onnxruntime plugin (com.gtbluesky.onnxruntime) sets
      # compileSdkVersion 33, so Gradle needs platform android-33 — which it can't
      # auto-install into the read-only Nix SDK. (It pins no buildToolsVersion, so
      # the app's build-tools are reused; only the platform must be provisioned.)
      platformVersions = unique (["33" "34" "35"] ++ [cfg.android.apiLevel] ++ optional cfg.android.emulator.rooted.enable cfg.android.emulator.rooted.apiLevel);
      includeNDK = true;
      ndkVersions = [cfg.android.ndkVersion];
      # The jni plugin compiles native C++ via CMake, which AGP would otherwise
      # try to auto-install into the read-only store.
      cmakeVersions = [cfg.android.cmakeVersion];
      includeEmulator = emulatorEnabled;
      includeSystemImages = emulatorEnabled;
      systemImageTypes = [cfg.android.systemImageType];
      abiVersions = [emulatorAbi];
      # accept_license (set on the pkgs-unstable import) covers android-sdk-license;
      # the rest must be listed explicitly or flutter reports "N licenses not accepted".
      extraLicenses = [
        "android-sdk-preview-license"
        "android-googletv-license"
        "android-googlexr-license"
        "android-sdk-arm-dbt-license"
        "google-gdk-license"
        "intel-android-extra-license"
        "intel-android-sysimage-license"
        "mips-android-sysimage-license"
      ];
    }).androidsdk;

  # Wrap platform-tools/adb so it always uses the scoped HOME. flutter and the
  # emulator both exec $ANDROID_SDK_ROOT/platform-tools/adb directly (not via
  # PATH), so wrapping must happen inside the SDK tree. composeAndroidPackages
  # makes platform-tools a symlink into the read-only store and its own fixup
  # phase doesn't compose with overrideAttrs, so we build a clean overlay with
  # runCommand: mirror the SDK via symlinks, replacing only platform-tools/adb
  # with a HOME-scoping wrapper. The $out/bin tool wrappers hardcode absolute
  # paths to the raw SDK internally, so symlinking them through is safe.
  android_sdk = pkgs.runCommand "androidsdk-adbwrapped" {} ''
    raw=${android_sdk_raw}
    mkdir -p "$out/libexec/android-sdk"
    for f in "$raw"/libexec/android-sdk/*; do
      base=$(basename "$f")
      [ "$base" = "platform-tools" ] && continue
      ln -s "$f" "$out/libexec/android-sdk/$base"
    done

    real=$(readlink -f "$raw/libexec/android-sdk/platform-tools")
    mkdir -p "$out/libexec/android-sdk/platform-tools"
    for f in "$real"/*; do
      base=$(basename "$f")
      [ "$base" = "adb" ] && continue
      ln -s "$f" "$out/libexec/android-sdk/platform-tools/$base"
    done
    {
      printf '#!%s\n' "${pkgs.runtimeShell}"
      printf 'export HOME="%s"\n' "${android_home_dir}"
      printf 'mkdir -p "$HOME/.android"\n'
      printf 'exec "%s/adb" "$@"\n' "$real"
    } > "$out/libexec/android-sdk/platform-tools/adb"
    chmod +x "$out/libexec/android-sdk/platform-tools/adb"

    if [ -d "$raw/bin" ]; then
      mkdir -p "$out/bin"
      for f in "$raw"/bin/*; do
        base=$(basename "$f")
        if [ "$base" = "adb" ]; then
          ln -s "$out/libexec/android-sdk/platform-tools/adb" "$out/bin/adb"
        else
          ln -s "$f" "$out/bin/$base"
        fi
      done
    fi
  '';

  android_sdk_root = "${android_sdk}/libexec/android-sdk";

  # Create the AVD if it doesn't exist. AVD lives in ANDROID_AVD_HOME (writable
  # state dir); system image is read from the read-only Nix store SDK.
  avd-create = pkgs.writeShellScriptBin "avd-create" ''
    set -euo pipefail
    name="''${1:-${cfg.android.avdName}}"
    if avdmanager list avd 2>/dev/null | grep -q "Name: $name"; then
      echo "AVD '$name' already exists"
    else
      echo "Creating AVD '$name' (${systemImageId}, device=${cfg.android.device})"
      echo "no" | avdmanager create avd \
        --name "$name" \
        --package "${systemImageId}" \
        --device "${cfg.android.device}" \
        --force
    fi

    # avdmanager writes `hw.keyboard = no`, which disables host-keyboard
    # passthrough — physical-keyboard keystrokes never reach the guest, only the
    # on-screen keyboard works. Force it on. Applied unconditionally (not just on
    # first create) so pre-existing AVDs get fixed on the next avd-run too.
    cfg_ini="''${ANDROID_AVD_HOME:-${android_user_dir}/avd}/$name.avd/config.ini"
    if [ -f "$cfg_ini" ]; then
      if grep -q '^hw\.keyboard' "$cfg_ini"; then
        sed -i 's/^hw\.keyboard *=.*/hw.keyboard = yes/' "$cfg_ini"
      else
        echo 'hw.keyboard = yes' >> "$cfg_ini"
      fi
    fi
  '';

  # Boot the emulator. Ensures the AVD exists first.
  avd-run = pkgs.writeShellScriptBin "avd-run" ''
    set -euo pipefail
    name="''${1:-${cfg.android.avdName}}"
    ${avd-create}/bin/avd-create "$name"
    shift || true
    # The emulator's bundled Qt ships no wayland plugin; force xcb so it renders
    # via XWayland on Wayland compositors (niri, sway, etc.). Must be set
    # UNCONDITIONALLY: a Wayland session exports QT_QPA_PLATFORM=wayland globally,
    # so a ":-" default would never apply and the bundled Qt aborts. Also hide the
    # Wayland socket so Qt can't auto-detect and re-pick it.
    export QT_QPA_PLATFORM=xcb
    unset WAYLAND_DISPLAY
    # Qt >= 6.5 (the emulator bundles 6.5+) loads the xcb platform plugin only if
    # libxcb-cursor is present ("xcb-cursor0 or libxcb-cursor0 is needed to load
    # the Qt xcb platform plugin"); it is not in the emulator's bundled lib dir nor
    # on NixOS's default loader path, so the plugin init aborts. Put it on the path.
    export LD_LIBRARY_PATH="${pkgs.libxcb-cursor}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    # Scope HOME so the emulator's own adbkey gen + ~/.android writes stay in the
    # state dir, matching the wrapped adb binary.
    export HOME="${android_home_dir}"
    mkdir -p "$HOME/.android"

    # Hardware GPU acceleration. The emulator's auto-detect wrongly blocklists
    # this host's Mesa driver ("Your GPU drivers may have a bug") and drops to the
    # SwiftShader software renderer, which is slow. -gpu host uses the real GPU via
    # XWayland, but on NixOS the emulator can't load the host GL stack out of the
    # box. Two pieces are needed:
    #   1. LD_LIBRARY_PATH: the Mesa driver libs live in /run/opengl-driver/lib,
    #      but the GLVND dispatch lib (libGL.so.1) that the emulator's GLX path
    #      dlopens lives in the separate libglvnd package. Without it GL init fails
    #      ("libGL library could[n't] be loaded / Could not query GLX version").
    # Vulkan is deliberately NOT pointed at the host RADV ICD: the emulator's
    # gfxstream Vulkan path is unstable on Mesa/RADV (the emulator itself warns
    # "your GPU drivers may have a bug" and hard-crashes mid-init). GLES rendering
    # goes through host GL above, which is the real perf win for Flutter's
    # Skia/GLES; Vulkan stays on the bundled SwiftShader ICD (software but stable).
    if [ -d /run/opengl-driver/lib ]; then
      export LD_LIBRARY_PATH="${pkgs.libglvnd}/lib:/run/opengl-driver/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    fi
    case " $* " in
      *" -gpu "*) exec emulator -avd "$name" "$@" ;;
      *) exec emulator -avd "$name" -gpu host "$@" ;;
    esac
  '';

  # ── Rooted emulator (Magisk, systemless) ────────────────────────────────────
  # A companion AVD whose ramdisk is Magisk-patched at BUILD TIME. magiskboot is
  # a static Android binary that hangs on the glibc host, so magisk-ramdisk-patch.py
  # reimplements its ramdisk cpio transform with plain host tools (lz4-legacy +
  # concatenated-cpio + inject magiskinit/overlay.d/.backup). The output is an
  # ordinary read-only store artifact the emulator boots via `-ramdisk` — no
  # writable-copy dance, no on-device patch step. Validated on API 33 + Magisk
  # 25.2 (newer Magisk changed the ramdisk layout the patcher expects).
  cfgRoot = cfg.android.emulator.rooted;

  magiskApk = pkgs.fetchurl {
    url = "https://github.com/topjohnwu/Magisk/releases/download/v${cfgRoot.magiskVersion}/Magisk-v${cfgRoot.magiskVersion}.apk";
    hash = cfgRoot.magiskHash;
  };

  rootedSystemImageId = "system-images;android-${cfgRoot.apiLevel};${cfg.android.systemImageType};${emulatorAbi}";

  rootedRamdisk = pkgs.runCommand "magisk-rooted-ramdisk-api${cfgRoot.apiLevel}" {
    nativeBuildInputs = [pkgs.lz4 pkgs.python3 pkgs.unzip];
  } ''
    python3 ${./magisk-ramdisk-patch.py} \
      ${android_sdk_raw}/libexec/android-sdk/system-images/android-${cfgRoot.apiLevel}/${cfg.android.systemImageType}/${emulatorAbi}/ramdisk.img \
      ${magiskApk} "$out"
  '';

  # Boot the rooted AVD, creating it on the rooted-API image first if needed
  # (avd-run's own avd-create targets the main apiLevel image, so create here and
  # avd-run then just boots). Post-boot: install the Magisk app and persist an
  # "allow" su policy for the adb shell. A fully baked zero-tap seed isn't
  # possible — MagiskSU's DB write needs the full u:r:magisk:s0 (su) domain, but a
  # boot service running `magisk` lands in the restricted u:r:magisk_client:s0
  # domain (SELinux blocks it). So on a BRAND-NEW AVD the first su shows one Grant
  # prompt in the emulator; this write then makes it stick. On an existing AVD
  # it's a silent no-op → turnkey.
  rooted-emulator = pkgs.writeShellScriptBin "rooted-emulator" ''
    set -euo pipefail
    name="''${1:-${cfgRoot.avdName}}"
    if ! avdmanager list avd 2>/dev/null | grep -q "Name: $name"; then
      echo "Creating rooted AVD '$name' (${rootedSystemImageId}, device=${cfg.android.device})"
      echo "no" | avdmanager create avd --name "$name" --package "${rootedSystemImageId}" --device "${cfg.android.device}" --force
      cfg_ini="''${ANDROID_AVD_HOME:-${android_user_dir}/avd}/$name.avd/config.ini"
      if [ -f "$cfg_ini" ]; then
        if grep -q '^hw\.keyboard' "$cfg_ini"; then
          sed -i 's/^hw\.keyboard *=.*/hw.keyboard = yes/' "$cfg_ini"
        else
          echo 'hw.keyboard = yes' >> "$cfg_ini"
        fi
      fi
    fi
    ( adb wait-for-device
      until [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do sleep 2; done
      adb install -r ${magiskApk} >/dev/null 2>&1 || true
      adb shell su -c 'magisk --sqlite "REPLACE INTO policies (uid,policy,until,logging,notification) VALUES(2000,2,0,1,1)"' >/dev/null 2>&1 || true
    ) &
    exec ${avd-run}/bin/avd-run "$name" -ramdisk ${rootedRamdisk} -no-snapshot-load
  '';

  # Copy an installed app's private data (/data/data/<pkg>) off a rooted
  # emulator/device into ./<pkg>/. Prompts for the package if not given; refuses
  # to overwrite; stages the transfer archive in a temp dir removed on exit.
  adb-pull-app-data = pkgs.writeShellScriptBin "adb-pull-app-data" ''
    set -euo pipefail

    pkg="''${1:-}"
    if [ -z "$pkg" ]; then
      printf 'App package name: '
      read -r pkg
    fi
    [ -n "$pkg" ] || { echo "error: no package name given" >&2; exit 1; }

    dest="./$pkg"
    if [ -e "$dest" ]; then
      echo "error: '$dest' already exists — refusing to overwrite" >&2
      exit 1
    fi

    if ! adb get-state >/dev/null 2>&1; then
      echo "error: no adb device connected" >&2; exit 1
    fi
    # Capture output before matching — piping into `grep -q` under `pipefail`
    # makes grep close the pipe on first match, adb gets SIGPIPE, pipeline "fails".
    id_out="$(adb shell su -c id 2>/dev/null || true)"
    case "$id_out" in
      *uid=0*) ;;
      *) echo "error: root not available (adb shell su failed) — is this the rooted AVD?" >&2; exit 1 ;;
    esac
    pkg_list="$(adb shell pm list packages 2>/dev/null | tr -d '\r')"
    if ! grep -qx "package:$pkg" <<<"$pkg_list"; then
      echo "error: package '$pkg' is not installed on the device" >&2; exit 1
    fi

    tmp="$(mktemp -d)"
    host_tgz="$tmp/$pkg.tgz"
    dev_tgz="/data/local/tmp/adb-pull-app-data.$$.tgz"
    cleanup() {
      rm -rf "$tmp"
      adb shell su -c "rm -f '$dev_tgz'" >/dev/null 2>&1 || true
    }
    trap cleanup EXIT

    echo "archiving /data/data/$pkg on device (as root)..."
    # Root writes the archive to a device file (never stream binary through the su
    # PTY — it corrupts it), make it readable, then adb pull (binary-clean).
    adb exec-out su -c "tar -c -C /data/data '$pkg' 2>/dev/null | gzip > '$dev_tgz'; chmod 644 '$dev_tgz'"

    echo "pulling..."
    adb pull "$dev_tgz" "$host_tgz" >/dev/null

    echo "verifying + extracting..."
    gzip -t "$host_tgz"
    tar -xzf "$host_tgz" -C .

    echo "done → $dest"
    du -sh "$dest"
  '';

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
  options = {
    modules.flutter = {
      enable = mkEnableOption "Flutter development";

      package = mkOption {
        type = types.package;
        default = pkgs-flutter.flutterPackages.v3_44;
        defaultText = literalMD "pkgs-flutter.flutterPackages.v3_44";
        description = "The Flutter package to use (v3_44 / Dart 3.12.2)";
      };

      android = {
        enable = mkEnableOption "Enable Android development (CLI SDK, no IDE)";

        apiLevel = mkOption {
          type = types.str;
          default = "36";
          description = "Android platform API level for SDK and system image";
        };

        buildToolsVersion = mkOption {
          type = types.str;
          default = "36.0.0";
          description = "Android build-tools version";
        };

        cmakeVersion = mkOption {
          type = types.str;
          default = "3.22.1";
          description = ''
            Android CMake version. The jni plugin's native build requests this
            exact CMake; provision it here since the Nix SDK is read-only.
          '';
        };

        ndkVersion = mkOption {
          type = types.str;
          default = "28.2.13676358";
          description = ''
            Android NDK version. Must match flutter.ndkVersion for the current
            Flutter release: the `jni` plugin (pulled in by path_provider_android)
            and the app project both request this exact NDK at Gradle
            configuration time. The Nix SDK is read-only, so Gradle cannot
            auto-install it — it must be provisioned here.
          '';
        };

        systemImageType = mkOption {
          type = types.str;
          default = "google_apis_playstore";
          description = ''
            System image type. Defaults to google_apis_playstore — the fullest
            "real phone" image: Google Play services (GMS) PLUS the Play Store
            app, Google Play Billing, and the Google account manager. Needed by
            apps that hard-require Billing at startup (e.g. RevenueCat-backed
            ones), which a plain google_apis image can't provide.

            Options (availability varies by apiLevel/abi):
              - google_apis_playstore : GMS + Play Store + Billing (default)
              - google_apis           : GMS only, no Play Store / Billing
              - default               : AOSP, no Google services at all

            Trade-off: Play Store images are production ("user") builds, so
            `adb root` is disabled. `run-as <pkg>` still works for debuggable
            builds, so pulling a debug app's internal DB/files is unaffected. To
            fully activate Play/Billing, sign into a Google account in the AVD.

            Note: on-device Google AI (Gemini Nano via AICore / ML Kit GenAI) is
            NOT provided by any emulator system image — AICore ships only on
            specific physical devices — so it cannot be enabled here.
          '';
        };

        device = mkOption {
          type = types.str;
          default = "pixel";
          description = "AVD hardware profile (see `avdmanager list device`)";
        };

        avdName = mkOption {
          type = types.str;
          default = "flutter";
          description = "Default AVD name created by avd-create/avd-run";
        };

        emulator = {
          enable =
            mkEnableOption "Android emulator + system images (x86_64 hosts only, needs KVM; auto-disabled on aarch64 — no emulator binary exists there)"
            // {default = true;};

          rooted = {
            enable = mkEnableOption ''
              a Magisk-rooted companion AVD. Adds the `rooted-emulator` command
              (boots an AVD whose ramdisk is Magisk-patched at build time) and
              `adb-pull-app-data` (copy an app's private /data/data off it). Lets
              you inspect another app's private data — `adb root` is unavailable on
              the Play Store images and `run-as` only works for debuggable apps.
            '';

            apiLevel = mkOption {
              type = types.str;
              default = "33";
              description = ''
                Android API level for the rooted image. Defaults to 33 (Android 13),
                the level validated with the pinned Magisk. Newer Magisk changed the
                ramdisk layout the build-time patcher reimplements, so bumping this
                generally also means bumping magiskVersion + magiskHash and
                re-validating a boot.
              '';
            };

            avdName = mkOption {
              type = types.str;
              default = "root33";
              description = "Name of the rooted AVD created/booted by rooted-emulator";
            };

            magiskVersion = mkOption {
              type = types.str;
              default = "25.2";
              description = "Magisk release to patch into the ramdisk";
            };

            magiskHash = mkOption {
              type = types.str;
              default = "sha256-C9wykYtupQLcp2mxxwiSANpR6h3vFwgkwoEpJbQm1Qk=";
              description = "SRI hash of Magisk-v<magiskVersion>.apk from the GitHub release";
            };
          };
        };

        jdk = mkOption {
          type = types.package;
          default = pkgs.jdk21;
          defaultText = literalMD "pkgs.jdk21";
          description = "JDK package for Android builds";
        };
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

    (mkIf (cfg.enable && cfg.android.enable) {
      packages =
        [android_sdk cfg.android.jdk]
        ++ optionals emulatorEnabled [avd-create avd-run]
        ++ optionals (emulatorEnabled && cfgRoot.enable) [rooted-emulator adb-pull-app-data];

      env.ANDROID_HOME = android_sdk_root;
      env.ANDROID_SDK_ROOT = android_sdk_root;
      env.ANDROID_NDK_ROOT = "${android_sdk_root}/ndk/${cfg.android.ndkVersion}";
      env.ANDROID_USER_HOME = android_user_dir;
      env.ANDROID_AVD_HOME = "${android_user_dir}/avd";
      env.GRADLE_USER_HOME = gradle_dir;
      env.JAVA_HOME = "${cfg.android.jdk}";

      # Redirect java.util.prefs from ~/.java to state dir.
      # JDK_JAVA_OPTIONS is Java 9+ only and avoids the noisy
      # "Picked up JAVA_TOOL_OPTIONS" message that JAVA_TOOL_OPTIONS prints.
      env.JDK_JAVA_OPTIONS = "-Djava.util.prefs.userRoot=${java_prefs_dir}";

      enterShell = ''
        mkdir -p ${android_user_dir}/avd
        mkdir -p ${android_home_dir}/.android
        mkdir -p ${gradle_dir}
        mkdir -p ${java_prefs_dir}
        export PATH="${android_sdk_root}/platform-tools:${android_sdk_root}/cmdline-tools/latest/bin:${android_sdk_root}/emulator:$PATH"

        # The Android Gradle Plugin downloads its own aapt2 from Maven, which is
        # not patched for NixOS's dynamic linker and fails to start ("AAPT2
        # Daemon startup failed"). Point AGP at the patchelf'd aapt2 from the Nix
        # build-tools instead. Written to the writable GRADLE_USER_HOME so the
        # (rebuild-specific) store path stays out of the committed repo.
        cat > ${gradle_dir}/gradle.properties <<EOF
        android.aapt2FromMavenOverride=${android_sdk_root}/build-tools/${cfg.android.buildToolsVersion}/aapt2
        EOF
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
