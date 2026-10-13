{
  lib,
  src,
  blender,
  python3Packages,
  makeWrapper,
  runCommand,
  writeText,
}: let
  blender-mcp = python3Packages.buildPythonApplication {
    pname = "blender-mcp";
    version = (lib.importTOML "${src}/mcp/pyproject.toml").project.version;
    pyproject = true;

    src = "${src}/mcp";

    build-system = [python3Packages.setuptools];

    dependencies = with python3Packages;
      [docutils mcp pyyaml] ++ mcp.optional-dependencies.cli;

    doCheck = false;

    meta.mainProgram = "blender-mcp";
  };

  # Blender reads the "System" extension repo from $BLENDER_SYSTEM_EXTENSIONS/system,
  # so the add-on loads from the store as `bl_ext.system.mcp` without touching the
  # user's own extensions.
  extensions = runCommand "blender-mcp-extensions" {} ''
    mkdir -p $out/system
    cp -r ${src}/addon/blender_mcp_addon $out/system/mcp
  '';

  # `--addons bl_ext.system.mcp` is a silent no-op for extensions. The add-on
  # refuses to open its socket unless online access is allowed, hence --online-mode.
  enable-mcp = writeText "enable-blender-mcp.py" ''
    import addon_utils, bpy
    if "bl_ext.system.mcp" not in bpy.context.preferences.addons:
        addon_utils.enable("bl_ext.system.mcp", default_set=True)
  '';

  blender-with-mcp =
    runCommand "blender-with-mcp-${blender.version}" {
      nativeBuildInputs = [makeWrapper];
      inherit (blender) meta;
    } ''
      mkdir -p $out
      ln -s ${blender}/share $out/share
      makeWrapper ${lib.getExe blender} $out/bin/blender \
        --set BLENDER_SYSTEM_EXTENSIONS ${extensions} \
        --add-flags "--online-mode --python ${enable-mcp}"
    '';
in {
  inherit blender-mcp blender-with-mcp;
}
