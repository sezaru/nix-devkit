{
  pkgs,
  pkgs-unstable,
  inputs,
}: let
  claude-agent-acp = pkgs.callPackage ./claude_agent_mcp.nix {};
in {
  inherit claude-agent-acp;

  tidewave-cli = pkgs.callPackage ./tidewave_cli.nix {
    inherit claude-agent-acp;
  };

  mempalace = pkgs-unstable.callPackage ./mempalace.nix {};

  open-design = import ./open_design.nix {inherit pkgs pkgs-unstable inputs;};
}
