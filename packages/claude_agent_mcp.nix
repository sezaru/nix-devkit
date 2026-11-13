{
  lib,
  stdenv,
  buildNpmPackage,
  fetchFromGitHub,
  makeWrapper,
  autoPatchelfHook,
  nghttp2,
}: let
  version = "0.107.0";
  packageHash = "sha256-egXaj0YPZtZE0rklOwjaZljsfbHH6mwJ17mERra8ouE=";
  depsHash = "sha256-AgCxbBMdqXHxnU/xIDNDoklEySgL2sTpHpWYkVOLZn8=";
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
      # The SDK ships both glibc and musl prebuilt binaries. Our hosts are
      # glibc-only (Node loads the -gnu variant at runtime), and autoPatchelf
      # can't satisfy the musl binary's libc.musl-*.so.1 — drop the unused musl
      # variants before the fixup phase patches them.
      find $out -type d -name 'claude-agent-sdk-*-musl' -exec rm -rf {} +

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
