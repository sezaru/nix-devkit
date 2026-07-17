{
  lib,
  python3,
  python3Packages,
  fetchFromGitHub,
  runCommand,
  ...
}: let
  version = "3.4.0";
  rev = "939a076baf0b349e1f5b3a7e27ad1d545364f18b";

  mempalace = python3Packages.buildPythonPackage {
    pname = "mempalace";
    inherit version;
    pyproject = true;

    src = fetchFromGitHub {
      owner = "MemPalace";
      repo = "mempalace";
      inherit rev;
      hash = "sha256-lu8gUEanlY2BeieZc9gnBMeh6j7D4p2t/A7Dd6Zkg0U=";
    };

    nativeBuildInputs = [python3Packages.pythonRelaxDepsHook];

    # nixpkgs ships chromadb 1.3.5; mempalace pins >=1.5.4.
    pythonRelaxDeps = ["chromadb"];

    build-system = [python3Packages.hatchling];

    dependencies = with python3Packages; [
      chromadb
      pyyaml
      huggingface-hub
      tokenizers
      numpy
      python-dateutil
      # chromadb's pydantic-v1 Settings reads the project .env at runtime.
      python-dotenv
    ];

    doCheck = false;
  };

  pythonWithMempalace = python3.withPackages (_: [mempalace]);
in
  # Expose both console scripts: `mempalace-mcp` (MCP server) and
  # `mempalace` (CLI — needed by the auto-save Stop/PreCompact hooks).
  runCommand "mempalace-${version}" {
    meta = {
      description = "Local-first AI memory — mine projects and conversations into a searchable palace";
      homepage = "https://github.com/MemPalace/mempalace";
      license = lib.licenses.mit;
      mainProgram = "mempalace-mcp";
    };
  } ''
    mkdir -p $out/bin
    ln -s ${pythonWithMempalace}/bin/mempalace $out/bin/mempalace
    ln -s ${pythonWithMempalace}/bin/mempalace-mcp $out/bin/mempalace-mcp
  ''
