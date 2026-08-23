{
  description = "nix-devkit developer shell (direnv-loaded devenv)";

  # Revs pinned to match the nixos repo's .nix devenv (same inputs) so the lock
  # resolves from the local store. Run `nix flake update ./.nix` to move them.
  inputs = {
    devenv.url = "github:cachix/devenv/5f1cf17be0fc48689bd0ecb810de6d2e06d259a1";
    nixpkgs.url = "github:cachix/devenv-nixpkgs/12866ae2dddbc0ab8b329915f8072bb9c75bde89";
    flake-utils.url = "github:numtide/flake-utils/11707dc2f618dd54ca8739b309ec4fc024de578b";
  };

  nixConfig = {
    extra-trusted-public-keys = "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=";
    extra-substituters = "https://devenv.cachix.org";
  };

  outputs = {
    devenv,
    nixpkgs,
    flake-utils,
    ...
  } @ inputs:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
    in {
      devShells.default = devenv.lib.mkShell {
        inherit inputs pkgs;
        modules = [
          ./devenv.nix
        ];
      };
    });
}
