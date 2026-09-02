{
  lib,
  stdenv,
  nodejs,
  pnpm_10,
  fetchPnpmDeps,
  pnpmConfigHook,
  src,
  version,
  pnpmDepsSrc ? src,
  workspacePaths,
}:
# Builds the @open-design/web Next.js static export. Vendored from upstream
# nexu-io/open-design's nix/package-web.nix; `version` is passed in from the
# builder.
#
# Output layout: $out/ contains the contents of `apps/web/out/` (an
# index.html plus _next/ and asset subdirectories).
#
# OD_DAEMON_URL is set to "" at build time so the bundled JS issues
# relative requests (`/api/*`, `/artifacts/*`, `/frames/*`) instead of
# baking a build-time daemon URL into the export.
let
  pname = "open-design-web";

  pnpmDepsHash = (import ./pnpm-deps.nix).webHash;
  pnpmWorkspaceFilters = map (workspacePath: "./${workspacePath}") workspacePaths;
in
  stdenv.mkDerivation (finalAttrs: {
    inherit pname version src;

    pnpmWorkspaces = pnpmWorkspaceFilters;

    nativeBuildInputs = [
      nodejs
      pnpm_10
      pnpmConfigHook
    ];

    pnpmDeps = fetchPnpmDeps {
      inherit (finalAttrs) pname version;
      src = pnpmDepsSrc;
      hash = pnpmDepsHash;
      pnpm = pnpm_10;
      pnpmWorkspaces = pnpmWorkspaceFilters;
      fetcherVersion = 3;
    };

    env = {
      NODE_ENV = "production";
      OD_DAEMON_URL = "";
    };

    buildPhase = ''
      runHook preBuild
      # Topological build (see package-daemon.nix): @open-design/web depends on
      # the other filtered-in packages, so `pnpm -r` builds them first and the
      # web static export (gated on NODE_ENV=production, written to
      # apps/web/out/) last.
      pnpm -r --workspace-concurrency=1 run --if-present build
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -r apps/web/out/. $out/
      runHook postInstall
    '';

    passthru = {
      inherit nodejs;
      pnpmDeps = finalAttrs.pnpmDeps;
    };

    meta = with lib; {
      description = "OpenDesign — Next.js static SPA (apps/web)";
      homepage = "https://github.com/nexu-io/open-design";
      license = licenses.asl20;
      platforms = platforms.linux ++ platforms.darwin;
    };
  })
