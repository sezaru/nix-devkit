# devenv module: the `nixupdate` command.
#
# Refreshes the by-hand packages in ./packages that `nix flake update` does NOT
# touch (they pin their own rev/hash/cargoHash/npmDepsHash), then bumps the flake
# inputs.
#   nixupdate            # update all automatable pkgs, bump inputs, regen open-design hashes
#   nixupdate <pkg>...   # update just those, skip the flake bump
#                        #   nixupdate open-design  → just regenerate its pnpm-deps hashes
{pkgs, ...}: {
  packages = [pkgs.nix-update];

  scripts.nixupdate.exec = ''
    set -euo pipefail
    cd "$(git rev-parse --show-toplevel)"

    od_rev() {
      nix eval --impure --raw --expr \
        '(builtins.fromJSON (builtins.readFile ./flake.lock)).nodes.open-design.locked.rev'
    }

    # open-design is a flake = false SOURCE input built by vendored derivations
    # (packages/open_design/). `nix flake update` advances its rev; the two
    # fetchPnpmDeps fixed-output hashes then go stale. Regenerate each by
    # building it with lib.fakeHash and capturing the `got:` hash Nix prints —
    # the same dance upstream's retired update-nix-pnpm-deps-hash.ts did.
    regen_open_design_hashes() {
      local hashfile=packages/open_design/pnpm-deps.nix
      local fake="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
      local pair key attr got
      for pair in "daemonHash:open-design-daemon" "webHash:open-design-web"; do
        key="''${pair%%:*}"
        attr="''${pair##*:}"
        echo ">>> open-design: regenerating $key via .#$attr"
        sed -i -E "s|($key = \")sha256-[^\"]+(\";)|\1$fake\2|" "$hashfile"
        got="$(nix build ".#$attr" --no-link 2>&1 \
          | grep -oE 'got:[[:space:]]+sha256-[A-Za-z0-9+/=]+' \
          | grep -oE 'sha256-[A-Za-z0-9+/=]+' | tail -1)" || true
        if [ -z "$got" ]; then
          echo "!! open-design: no 'got:' hash for $key. Either the build already" >&2
          echo "   matched (nothing to do) or it failed for another reason. Restoring." >&2
          git checkout -- "$hashfile" 2>/dev/null || true
          return 1
        fi
        sed -i -E "s|($key = \")sha256-[^\"]+(\";)|\1$got\2|" "$hashfile"
        echo "    $key -> $got"
      done
    }

    # Custom packages that follow GitHub release tags — nix-update finds the
    # newest release and rewrites version + src hash (+ cargoHash/npmDepsHash).
    release_pkgs=(claude-agent-acp tidewave-cli)

    # Excluded from nix-update — handled by hand:
    #   open-design   — flake = false source input; bumped by `nix flake update`,
    #                   then `regen_open_design_hashes` refreshes the pnpm hashes.
    #                   NOTE: if a bump moves upstream's package.json#packageManager
    #                   pnpm version, also bump the pnpm_10 override +hash in
    #                   packages/open_design/builder.nix (build fails on engine mismatch).
    #   mempalace     — the flake output is a runCommand wrapper around an inner
    #                   buildPythonPackage, so nix-update finds no `src`. The repo
    #                   tags releases (github.com/MemPalace/mempalace); bump
    #                   version + rev + hash by hand in packages/mempalace.nix.
    #   pg-textsearch — not a flake output (callPackage'd in modules/postgresql.nix)
    #                   and postgresqlBuildExtension is absent in this nixpkgs;
    #                   bump version + hash by hand in packages/pg_textsearch.nix.

    if [ "$#" -gt 0 ]; then
      for p in "$@"; do
        if [ "$p" = "open-design" ]; then
          echo ">>> open-design (regenerate pnpm-deps hashes)"
          regen_open_design_hashes
        else
          echo ">>> $p"
          nix-update --flake "$p"
        fi
      done
    else
      for p in "''${release_pkgs[@]}"; do echo ">>> $p (latest release)"; nix-update --flake "$p"; done

      echo "==> nix flake update"
      before_od="$(od_rev)"
      if nix flake update; then
        after_od="$(od_rev)"
        if [ "$before_od" != "$after_od" ]; then
          echo "==> open-design bumped $before_od -> $after_od; regenerating pnpm-deps hashes"
          regen_open_design_hashes || echo "!! open-design hash regen failed — fix packages/open_design/pnpm-deps.nix by hand."
        fi
      else
        echo "!! nix flake update failed. The package bumps above are saved; re-run once unblocked."
      fi
    fi

    echo
    echo "Review 'git diff', then build each changed pkg: nix build .#<pkg>"
    echo "(tidewave-cli carries Cargo.lock perl-surgery patches — re-check them after a bump.)"
  '';
}
