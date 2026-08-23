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

  state_dir = config.env.DEVENV_STATE;

  android_user_dir = "${state_dir}/android";
  # Scoped HOME for adb + emulator. adb 36 ignores ANDROID_USER_HOME/ANDROID_SDK_HOME
  # and only honors $HOME for its key dir (~/.android), so the adb binary and the
  # emulator are forced to use this dir instead of the real home.
  android_home_dir = "${state_dir}/android-home";
  gradle_dir = "${state_dir}/gradle";
  java_prefs_dir = "${state_dir}/java-prefs";

  cfg = config.modules.android;
  cfgRoot = cfg.emulator.rooted;

  isX86 = pkgs.stdenv.hostPlatform.isx86_64;
  # On x86_64 hosts use x86_64 system images for KVM acceleration; otherwise
  # fall back to arm64 (e.g. aarch64 host).
  emulatorAbi =
    if isX86
    then "x86_64"
    else "arm64-v8a";
  systemImageId = "system-images;android-${cfg.apiLevel};${cfg.systemImageType};${emulatorAbi}";

  # Google ships the emulator host binary only for x86_64-linux — there is no
  # aarch64-linux archive in the SDK repo, so the androidenv emulator derivation
  # dies in unpackPhase ("did not have any sources available for os=linux,
  # arch=aarch64"). meta.available is misleadingly true, so it only surfaces at
  # build time. Force the emulator off on non-x86 hosts regardless of the option;
  # on aarch64 use a physical device via adb. Warn only when explicitly requested.
  emulatorEnabled =
    cfg.emulator.enable
    && (isX86
      || warn "modules.android.emulator: no aarch64-linux Android emulator exists; disabling it on ${pkgs.stdenv.hostPlatform.system} (attach a physical device via adb)." false);

  android_sdk_raw =
    (pkgs-unstable.androidenv.composeAndroidPackages {
      buildToolsVersions = unique ([cfg.buildToolsVersion] ++ cfg.extraBuildToolsVersions);
      platformVersions =
        unique ([cfg.apiLevel]
          ++ cfg.extraPlatformVersions
          ++ optional cfgRoot.enable cfgRoot.apiLevel);
      includeNDK = true;
      ndkVersions = [cfg.ndkVersion];
      cmakeVersions = [cfg.cmakeVersion];
      includeEmulator = emulatorEnabled;
      includeSystemImages = emulatorEnabled;
      systemImageTypes = [cfg.systemImageType];
      abiVersions = [emulatorAbi];
      # accept_license (set on the pkgs-unstable import) covers android-sdk-license;
      # the rest must be listed explicitly or the SDK reports "N licenses not accepted".
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

  # ── The emulator launch environment ─────────────────────────────────────────
  # Prebuilt vendor binary meets a non-FHS distro. Three separate discovery gaps,
  # each measured on charmander (Intel Iris Xe, Mesa 26.1.5, niri/XWayland):
  #
  #  1. Qt platform plugin. The bundled Qt ships ONLY xcb/minimal/offscreen/vnc/
  #     linuxfb — there is no wayland plugin. A Wayland session exports
  #     QT_QPA_PLATFORM=wayland globally, so this must be set UNCONDITIONALLY (a
  #     ":-" default would never apply) and WAYLAND_DISPLAY hidden so Qt cannot
  #     auto-detect and re-pick it.
  #  2. libxcb-cursor. Qt >= 6.5 loads the xcb plugin only if it is present
  #     ("xcb-cursor0 or libxcb-cursor0 is needed"); it is in neither the
  #     emulator's bundled lib dir nor NixOS's default loader path.
  #  3. Host GL, for -gpu host. Needs BOTH halves of the glvnd split:
  #     /run/opengl-driver/lib carries the Mesa *vendor* libs (libGLX_mesa.so,
  #     libEGL_mesa.so) but NOT the *dispatch* libGL.so.1 that the emulator
  #     dlopens — that lives in the libglvnd package. With neither, -gpu host
  #     SIGSEGVs in ~5s ("Could not query GLX version!"); with both it boots in
  #     ~12s. Guarded on the directory so this is inert off NixOS.
  #
  # Applied by wrapping the emulator binary itself rather than exporting into the
  # shell: every caller gets it — avd-run, a human, and a program that execs
  # `emulator` off PATH (which is how handset's Elixir side launches it) — and the
  # GL paths stay scoped to this one process instead of leaking into the shell.
  emulator_env = ''
    export HOME="${android_home_dir}"
    mkdir -p "$HOME/.android"

    export QT_QPA_PLATFORM=xcb
    unset WAYLAND_DISPLAY

    export LD_LIBRARY_PATH="${pkgs.libxcb-cursor}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    if [ -d /run/opengl-driver/lib ]; then
      export LD_LIBRARY_PATH="${pkgs.libglvnd}/lib:/run/opengl-driver/lib:$LD_LIBRARY_PATH"
    fi
  ''
  # Host Vulkan is off by default. -gpu host does NOT need it: without an ICD the
  # Vulkan instance simply fails to create, the guest gets no hardware Vulkan
  # ("GPU device local memory = 0MB"), and GLES still goes through host GL — same
  # 12.4s boot either way, measured. Turning it on is a real win where it works
  # (guest gets the physical GPU) but the emulator's gfxstream Vulkan path has
  # been seen to hard-crash mid-init on Mesa/RADV, so it stays opt-in per project.
  + optionalString cfg.emulator.hostVulkan.enable ''
    icd_dir=/run/opengl-driver/share/vulkan/icd.d
    if [ -d "$icd_dir" ]; then
      icds=""
      for f in "$icd_dir"/*.json; do
        [ -e "$f" ] || continue
        icds="''${icds:+$icds:}$f"
      done
      if [ -n "$icds" ]; then
        # Both names: VK_ICD_FILENAMES is the legacy one, VK_DRIVER_FILES the
        # current. The emulator bundles its own loader, whose vintage is not ours
        # to assume, so set both.
        export VK_ICD_FILENAMES="$icds"
        export VK_DRIVER_FILES="$icds"
      fi
    fi
  ''
  # crashReportPreference=0 means ASK, and ASK means the emulator raises a modal
  # consent dialog during startup and blocks its Qt event loop there — before the
  # VM starts. The symptom is indistinguishable from a hang: no window, 0% CPU,
  # console port never bound, never appears in `adb devices`, forever. Seed the
  # setting to 2 (NEVER) so a fresh state dir can never land in that state, and
  # repair an existing 0 for the same reason. Qt honours XDG_CONFIG_HOME when set,
  # so follow that rather than assuming $HOME/.config.
  + ''
    conf_dir="''${XDG_CONFIG_HOME:-$HOME/.config}/Android Open Source Project"
    conf="$conf_dir/Emulator.conf"
    if [ ! -f "$conf" ]; then
      mkdir -p "$conf_dir"
      printf '[General]\nshowGpuWarning=false\n\n[set]\ncrashReportPreference=2\n' > "$conf"
    elif grep -q '^crashReportPreference=0$' "$conf"; then
      sed -i 's/^crashReportPreference=0$/crashReportPreference=2/' "$conf"
    fi
  '';

  # Exec the raw SDK's own emulator, not the mirrored one: the binary locates
  # .emulator-wrapped, qemu/ and lib64/ relative to its own directory, and the
  # raw tree is the one that has them.
  emulator_wrapper = pkgs.writeShellScript "emulator" ''
    ${emulator_env}
    exec ${android_sdk_raw}/libexec/android-sdk/emulator/emulator "$@"
  '';

  # Overlay the SDK, replacing two binaries with wrappers. composeAndroidPackages
  # makes platform-tools/emulator symlinks into the read-only store and its own
  # fixup phase doesn't compose with overrideAttrs, so build a clean mirror with
  # runCommand instead: symlink everything, then shadow only the two entries.
  # Wrapping must happen INSIDE the SDK tree because callers (flutter, the
  # emulator itself) exec $ANDROID_SDK_ROOT/platform-tools/adb directly rather
  # than going through PATH. The $out/bin tool wrappers hardcode absolute paths to
  # the raw SDK internally, so symlinking those through is safe.
  android_sdk = pkgs.runCommand "androidsdk-wrapped" {} ''
    raw=${android_sdk_raw}
    mkdir -p "$out/libexec/android-sdk"
    for f in "$raw"/libexec/android-sdk/*; do
      base=$(basename "$f")
      case "$base" in
        platform-tools|emulator) continue ;;
      esac
      ln -s "$f" "$out/libexec/android-sdk/$base"
    done

    # platform-tools/adb → HOME-scoping wrapper.
    real_pt=$(readlink -f "$raw/libexec/android-sdk/platform-tools")
    mkdir -p "$out/libexec/android-sdk/platform-tools"
    for f in "$real_pt"/*; do
      base=$(basename "$f")
      [ "$base" = "adb" ] && continue
      ln -s "$f" "$out/libexec/android-sdk/platform-tools/$base"
    done
    {
      printf '#!%s\n' "${pkgs.runtimeShell}"
      printf 'export HOME="%s"\n' "${android_home_dir}"
      printf 'mkdir -p "$HOME/.android"\n'
      printf 'exec "%s/adb" "$@"\n' "$real_pt"
    } > "$out/libexec/android-sdk/platform-tools/adb"
    chmod +x "$out/libexec/android-sdk/platform-tools/adb"

    ${optionalString emulatorEnabled ''
      # emulator/emulator → GL + Qt + crash-dialog wrapper.
      real_emu=$(readlink -f "$raw/libexec/android-sdk/emulator")
      mkdir -p "$out/libexec/android-sdk/emulator"
      for f in "$real_emu"/*; do
        base=$(basename "$f")
        [ "$base" = "emulator" ] && continue
        ln -s "$f" "$out/libexec/android-sdk/emulator/$base"
      done
      cp ${emulator_wrapper} "$out/libexec/android-sdk/emulator/emulator"
      chmod +x "$out/libexec/android-sdk/emulator/emulator"
    ''}

    if [ -d "$raw/bin" ]; then
      mkdir -p "$out/bin"
      for f in "$raw"/bin/*; do
        base=$(basename "$f")
        case "$base" in
          adb) ln -s "$out/libexec/android-sdk/platform-tools/adb" "$out/bin/adb" ;;
          emulator)
            if [ -e "$out/libexec/android-sdk/emulator/emulator" ]; then
              ln -s "$out/libexec/android-sdk/emulator/emulator" "$out/bin/emulator"
            else
              ln -s "$f" "$out/bin/emulator"
            fi
            ;;
          *) ln -s "$f" "$out/bin/$base" ;;
        esac
      done
    fi
  '';

  android_sdk_root = "${android_sdk}/libexec/android-sdk";

  # Create the AVD if it doesn't exist. AVD lives in ANDROID_AVD_HOME (writable
  # state dir); system image is read from the read-only Nix store SDK.
  avd-create = pkgs.writeShellScriptBin "avd-create" ''
    set -euo pipefail
    name="''${1:-${cfg.avdName}}"
    if avdmanager list avd 2>/dev/null | grep -q "Name: $name"; then
      echo "AVD '$name' already exists"
    else
      echo "Creating AVD '$name' (${systemImageId}, device=${cfg.device})"
      echo "no" | avdmanager create avd \
        --name "$name" \
        --package "${systemImageId}" \
        --device "${cfg.device}" \
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

  # Boot the emulator. Ensures the AVD exists first. The GL/Qt/crash-dialog
  # environment lives in the wrapped `emulator` binary, not here, so that a
  # caller who skips avd-run still gets it.
  avd-run = pkgs.writeShellScriptBin "avd-run" ''
    set -euo pipefail
    name="''${1:-${cfg.avdName}}"
    ${avd-create}/bin/avd-create "$name"
    shift || true
    # The emulator's own auto-detect blocklists this host's Mesa driver ("your GPU
    # drivers may have a bug") and silently drops to the SwiftShader software
    # renderer, which is slow. Default to -gpu host unless the caller picked.
    case " $* " in
      *" -gpu "*) exec ${android_sdk_root}/emulator/emulator -avd "$name" "$@" ;;
      *) exec ${android_sdk_root}/emulator/emulator -avd "$name" -gpu host "$@" ;;
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
  magiskApk = pkgs.fetchurl {
    url = "https://github.com/topjohnwu/Magisk/releases/download/v${cfgRoot.magiskVersion}/Magisk-v${cfgRoot.magiskVersion}.apk";
    hash = cfgRoot.magiskHash;
  };

  rootedSystemImageId = "system-images;android-${cfgRoot.apiLevel};${cfg.systemImageType};${emulatorAbi}";

  rootedRamdisk = pkgs.runCommand "magisk-rooted-ramdisk-api${cfgRoot.apiLevel}" {
    nativeBuildInputs = [pkgs.lz4 pkgs.python3 pkgs.unzip];
  } ''
    python3 ${./magisk-ramdisk-patch.py} \
      ${android_sdk_raw}/libexec/android-sdk/system-images/android-${cfgRoot.apiLevel}/${cfg.systemImageType}/${emulatorAbi}/ramdisk.img \
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
      echo "Creating rooted AVD '$name' (${rootedSystemImageId}, device=${cfg.device})"
      echo "no" | avdmanager create avd --name "$name" --package "${rootedSystemImageId}" --device "${cfg.device}" --force
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
in {
  options = {
    modules.android = {
      enable = mkEnableOption "Android development (CLI SDK, no IDE)";

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

      extraBuildToolsVersions = mkOption {
        type = types.listOf types.str;
        default = ["34.0.0" "35.0.0"];
        description = ''
          Additional build-tools versions to provision. The Nix SDK is read-only,
          so Gradle cannot auto-install a version a dependency pins — every one
          needed must be listed. The default is a historical superset kept for
          Flutter projects whose plugins pin 34/35 (path_provider_android, jni,
          large_file_handler); set to `[]` on a project that doesn't need them.
        '';
      };

      extraPlatformVersions = mkOption {
        type = types.listOf types.str;
        default = ["33" "34" "35"];
        description = ''
          Additional platform versions to provision, for the same read-only-SDK
          reason as extraBuildToolsVersions. The default is a historical superset
          (the onnxruntime plugin compiles against 33, etc.); set to `[]` on a
          project that only needs `apiLevel`.
        '';
      };

      cmakeVersion = mkOption {
        type = types.str;
        default = "3.22.1";
        description = ''
          Android CMake version, for native builds driven by AGP. Provisioned
          here since the Nix SDK is read-only.
        '';
      };

      ndkVersion = mkOption {
        type = types.str;
        default = "28.2.13676358";
        description = ''
          Android NDK version. On a Flutter project this must match
          flutter.ndkVersion for the current release: the `jni` plugin and the app
          project both request that exact NDK at Gradle configuration time, and
          the read-only Nix SDK cannot auto-install it.
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
        default = "android";
        description = "Default AVD name created by avd-create/avd-run";
      };

      jdk = mkOption {
        type = types.package;
        default = pkgs.jdk21;
        defaultText = literalMD "pkgs.jdk21";
        description = "JDK package for Android builds";
      };

      emulator = {
        enable =
          mkEnableOption "Android emulator + system images (x86_64 hosts only, needs KVM; auto-disabled on aarch64 — no emulator binary exists there)"
          // {default = true;};

        hostVulkan = {
          enable = mkEnableOption ''
            handing the host's Vulkan ICDs to the emulator, so the guest gets the
            physical GPU for Vulkan as well as GLES.

            Off by default because `-gpu host` does not need it: with no ICD the
            Vulkan instance simply fails to create and GLES still runs on host GL
            — measured at the same ~12.4s boot either way on Intel/Mesa. Turn it
            on for a guest that actually uses Vulkan, but note the emulator's
            gfxstream Vulkan path has been seen to hard-crash mid-init on
            Mesa/RADV, which is why it isn't the default.
          '';
        };

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

      # Read-only outputs, so a consuming module (modules.flutter) or project can
      # reach the composed SDK without recomposing it.
      sdk = mkOption {
        type = types.package;
        readOnly = true;
        default = android_sdk;
        defaultText = literalMD "the composed, wrapped Android SDK";
        description = "The wrapped Android SDK package";
      };

      sdkRoot = mkOption {
        type = types.str;
        readOnly = true;
        default = android_sdk_root;
        defaultText = literalMD "\${sdk}/libexec/android-sdk";
        description = "ANDROID_SDK_ROOT — the SDK tree inside the package";
      };
    };
  };

  config = mkIf cfg.enable {
    packages =
      [android_sdk cfg.jdk]
      ++ optionals emulatorEnabled [avd-create avd-run]
      ++ optionals (emulatorEnabled && cfgRoot.enable) [rooted-emulator adb-pull-app-data];

    env.ANDROID_HOME = android_sdk_root;
    env.ANDROID_SDK_ROOT = android_sdk_root;
    env.ANDROID_NDK_ROOT = "${android_sdk_root}/ndk/${cfg.ndkVersion}";
    env.ANDROID_USER_HOME = android_user_dir;
    env.ANDROID_AVD_HOME = "${android_user_dir}/avd";
    env.GRADLE_USER_HOME = gradle_dir;
    env.JAVA_HOME = "${cfg.jdk}";

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
      android.aapt2FromMavenOverride=${android_sdk_root}/build-tools/${cfg.buildToolsVersion}/aapt2
      EOF
    '';
  };
}
