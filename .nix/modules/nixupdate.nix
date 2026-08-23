# devenv module: the `nixupdate` command.
#
# Refreshes the by-hand packages in ./packages that `nix flake update` does NOT
# touch (they pin their own rev/hash/cargoHash/npmDepsHash), then bumps the flake
# inputs.
#   nixupdate            # update all automatable pkgs, then `nix flake update`
#   nixupdate <pkg>...   # update just those, skip the flake bump
{pkgs, ...}: {
  packages = [pkgs.nix-update];

  scripts.nixupdate.exec = ''
    set -euo pipefail
    cd "$(git rev-parse --show-toplevel)"

    # Custom packages that follow GitHub release tags — nix-update finds the
    # newest release and rewrites version + src hash (+ cargoHash/npmDepsHash).
    release_pkgs=(claude-agent-acp tidewave-cli)

    # Excluded — nix-update can't reach these; handle by hand:
    #   open-design   — a flake INPUT (open-design.url); `nix flake update` bumps it.
    #   mempalace     — the flake output is a runCommand wrapper around an inner
    #                   buildPythonPackage, so nix-update finds no `src`. The repo
    #                   tags releases (github.com/MemPalace/mempalace); bump
    #                   version + rev + hash by hand in packages/mempalace.nix.
    #   pg-textsearch — not a flake output (callPackage'd in modules/postgresql.nix)
    #                   and postgresqlBuildExtension is absent in this nixpkgs;
    #                   bump version + hash by hand in packages/pg_textsearch.nix.

    if [ "$#" -gt 0 ]; then
      for p in "$@"; do echo ">>> $p"; nix-update --flake "$p"; done
    else
      for p in "''${release_pkgs[@]}"; do echo ">>> $p (latest release)"; nix-update --flake "$p"; done
      echo "==> nix flake update"
      nix flake update || echo "!! nix flake update failed (GitHub API rate limit?). The package bumps above are saved; re-run 'nix flake update' once unblocked — see 'access-tokens' below."
    fi

    echo
    echo "Review 'git diff', then build each changed pkg: nix build .#<pkg>"
    echo "(tidewave-cli carries Cargo.lock perl-surgery patches — re-check them after a bump.)"
  '';
}
