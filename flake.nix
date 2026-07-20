{
  description = "Personal devenv modules and custom packages, shared across projects";

  inputs = {
    nixpkgs.url = "github:cachix/devenv-nixpkgs/rolling";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-25.11";

    flake-utils.url = "github:numtide/flake-utils";

    expert.url = "github:elixir-lang/expert";
    open-design.url = "github:nexu-io/open-design";
  };

  nixConfig = {
    extra-trusted-public-keys = "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=";
    extra-substituters = "https://devenv.cachix.org";
  };

  outputs = {
    self,
    nixpkgs,
    nixpkgs-unstable,
    flake-utils,
    ...
  } @ inputs: let
    # Single devenv module bundling every feature module. Each module is
    # option-gated (modules.<name>.enable), so importing the bundle is inert
    # until a consuming project flips the flags it wants.
    #
    # `_module.args.flakeInputs = inputs` injects THIS flake's inputs (nixpkgs-
    # unstable, expert, open-design, self, ...) into every module. That is what
    # lets a consuming project depend on this flake alone — it never has to
    # declare those transitive inputs itself, so versions live here only.
    devenvModule = {...}: {
      imports = [
        ./modules/aws.nix
        ./modules/claude.nix
        ./modules/devenv_utils.nix
        ./modules/elixir.nix
        ./modules/gemini.nix
        ./modules/node.nix
        ./modules/open_design.nix
        ./modules/postgresql.nix
        ./modules/rust.nix
        ./modules/tidewave.nix
      ];

      _module.args.flakeInputs = inputs;
    };
  in
    (flake-utils.lib.eachDefaultSystem (system: let
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
      pkgs-unstable = import nixpkgs-unstable {
        inherit system;
        config.allowUnfree = true;
      };
    in {
      packages = import ./packages {inherit pkgs pkgs-unstable inputs;};
    }))
    // {
      inherit devenvModule;
    };
}
