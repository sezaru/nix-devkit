{
  lib,
  stdenv,
  buildNpmPackage,
  fetchFromGitHub,
  makeWrapper,
  autoPatchelfHook,
  nghttp2,
}: let
  version = "0.81.0";
  packageHash = "sha256-id/r62NuwdmgnBGpv+b6oG0oFsiUmRJgQUe8UQKryR0=";
  depsHash = "sha256-yqVLSZbFb7IcW9C6caqHwREK40eK3YQdl5AR9k8dCPk=";
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
