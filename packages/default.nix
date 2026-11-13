{
  pkgs,
  pkgs-unstable,
  inputs,
}: let
  claude-agent-acp = pkgs.callPackage ./claude_agent_mcp.nix {};
  openDesign = import ./open_design {inherit pkgs pkgs-unstable inputs;};
in {
  inherit claude-agent-acp;

  # The Claude Code CLI, pinned here rather than taken from each project's
  # nixpkgs: new models need a CLI that knows their ids, and projects lock
  # nixpkgs at different dates. claude-code-manifest.json is the upstream
  # release manifest (manifest.zst.json: version + per-platform checksums of
  # the zstd-compressed binaries, which this nixpkgs' package unpacks);
  # `nixupdate claude-code` refreshes it to the latest release.
  claude-code = pkgs.claude-code.override {
    manifest = pkgs.lib.importJSON ./claude-code-manifest.json;
  };

  tidewave-cli = pkgs.callPackage ./tidewave_cli.nix {
    inherit claude-agent-acp;
  };

  mempalace = pkgs-unstable.callPackage ./mempalace.nix {};

  inherit
    (pkgs.callPackage ./blender_mcp.nix {src = inputs.blender-mcp;})
    blender-mcp
    blender-with-mcp
    ;

  open-design = openDesign.od;
  # daemon/web exposed so `nixupdate` can rebuild each with a fakeHash to
  # regenerate its pnpm-deps hash after an input bump.
  open-design-daemon = openDesign.daemon;
  open-design-web = openDesign.web;
}
