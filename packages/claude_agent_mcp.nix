{
  lib,
  stdenv,
  buildNpmPackage,
  fetchFromGitHub,
  makeWrapper,
  autoPatchelfHook,
  nghttp2,
}: let
  version = "0.66.0";
  packageHash = "sha256-B6oB0xrDHFm46YfgTc/VlxPjHhCdSNlriq1zGe6XyU4=";
  depsHash = "sha256-7c9+Q+HkoUeL38EzEbu+KePA/aN+If9tGr7C/lWluhU=";
in
  buildNpmPackage (finalAttrs: {
    pname = "claude-agent-acp";
    version = version;

    src = fetchFromGitHub {
      owner = "agentclientprotocol";
      repo = "claude-agent-acp";
      tag = "v${finalAttrs.version}";
      hash = packageHash;
    };

    npmDepsHash = depsHash;

    nativeBuildInputs = [makeWrapper autoPatchelfHook];

    buildInputs = [stdenv.cc.cc.lib];

    postInstall = ''
      wrapProgram $out/bin/claude-agent-acp \
        --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [nghttp2.lib]}
    '';

    meta = {
      description = "ACP-compatible coding agent powered by the Claude Code SDK";
      homepage = "https://github.com/zed-industries/claude-agent-acp";
      license = lib.licenses.asl20;
      maintainers = with lib.maintainers; [storopoli];
      mainProgram = "claude-agent-acp";
    };
  })
