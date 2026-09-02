# Builds the vendored open-design `daemon` and `web` derivations straight from
# the `open-design` source input (flake = false). Ports the source-filtering,
# workspace lists and pnpm_10 override that used to live in upstream's flake.nix
# (retired in #7644).
{
  lib,
  bpkgs, # nixpkgs set providing the node/pnpm toolchain (nodejs_24, pnpm_10, fetchPnpmDeps…)
  src0, # raw open-design source tree (inputs.open-design)
}: let
  nodejs = bpkgs.nodejs_24;

  version = (lib.importJSON "${src0}/package.json").version;

  filterProjectSource = includePaths:
    lib.cleanSourceWith {
      src = src0;
      filter = path: type: let
        root = toString src0;
        pathStr = toString path;
        rel = lib.removePrefix (root + "/") pathStr;
        matches = includePath:
          rel
          == includePath
          || lib.hasPrefix (includePath + "/") rel
          || (type == "directory" && lib.hasPrefix (rel + "/") includePath);
      in
        rel == "" || builtins.any matches includePaths;
    };

  workspacePackageManifests = map (workspacePath: "${workspacePath}/package.json");

  # Keep in sync with upstream's daemon/web workspace scopes.
  daemonWorkspacePaths = [
    "packages/release"
    "packages/contracts"
    "packages/registry-protocol"
    "packages/agui-adapter"
    "packages/plugin-runtime"
    "packages/sidecar-proto"
    "packages/launcher-proto"
    "packages/sidecar"
    "packages/platform"
    "packages/diagnostics"
    "apps/daemon"
  ];
  webWorkspacePaths = [
    "packages/release"
    "packages/components"
    "packages/contracts"
    "packages/host"
    "packages/platform"
    "packages/sidecar"
    "packages/sidecar-proto"
    "apps/web"
  ];

  daemonSrc = filterProjectSource ([
      "package.json"
      "pnpm-lock.yaml"
      "pnpm-workspace.yaml"
      "tsconfig.json"
      "assets"
      "plugins"
      "skills"
      "design-systems"
      "design-templates"
      "craft"
      "prompt-templates"
    ]
    ++ daemonWorkspacePaths);
  webSrc = filterProjectSource ([
      "package.json"
      "pnpm-lock.yaml"
      "pnpm-workspace.yaml"
      "tsconfig.json"
    ]
    ++ webWorkspacePaths);

  pnpmDepsBaseInputs = [
    "package.json"
    "pnpm-lock.yaml"
    "pnpm-workspace.yaml"
  ];
  daemonPnpmDepsSrc = filterProjectSource (
    pnpmDepsBaseInputs ++ workspacePackageManifests daemonWorkspacePaths
  );
  webPnpmDepsSrc = filterProjectSource (
    pnpmDepsBaseInputs ++ workspacePackageManifests webWorkspacePaths
  );

  # nixpkgs ships an older pnpm; the repo's package.json declares
  # `engines.pnpm: ">=10.33.2 <11"` and pnpm refuses to install against an older
  # binary. Override to the exact version pinned by `packageManager`. Bump the
  # version + hash in lockstep with upstream package.json#packageManager (get a
  # new hash with:
  #   nix store prefetch-file --hash-type sha256 \
  #     https://registry.npmjs.org/pnpm/-/pnpm-<VER>.tgz).
  pnpm_10 = bpkgs.pnpm_10.overrideAttrs (_old: rec {
    version = "10.33.2";
    src = bpkgs.fetchurl {
      url = "https://registry.npmjs.org/pnpm/-/pnpm-${version}.tgz";
      hash = "sha256-envPE9f2zrOUbAOXg3PZm+n94cr8MAC9/tTE95EWdhA=";
    };
  });

  daemon = bpkgs.callPackage ./package-daemon.nix {
    inherit nodejs pnpm_10 version;
    src = daemonSrc;
    pnpmDepsSrc = daemonPnpmDepsSrc;
    workspacePaths = daemonWorkspacePaths;
  };
  web = bpkgs.callPackage ./package-web.nix {
    inherit nodejs pnpm_10 version;
    src = webSrc;
    pnpmDepsSrc = webPnpmDepsSrc;
    workspacePaths = webWorkspacePaths;
  };
in {
  inherit daemon web;
}
