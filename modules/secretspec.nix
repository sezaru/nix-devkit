{
  config,
  lib,
  pkgs,
  flakeInputs,
  ...
}:
with lib; let
  # Dedicated nixos-unstable just for secretspec: the sops:// provider was added
  # in secretspec 0.17, but the pinned nixos-25.11 (nixpkgs-unstable) only ships
  # 0.16 and the devenv-nixpkgs rolling channel ships 0.10. nixos-unstable has
  # 0.17.0, which is enough for our sops + env-token workflow (no 0.18-only
  # provider is used). Kept as its own input so secretspec's version does not
  # ride along with any other toolchain channel.
  pkgs-secretspec = import flakeInputs.nixpkgs-secretspec {
    system = pkgs.stdenv.system;
    config.allowUnfree = true;
  };

  cfg = config.modules.secretspec;
in {
  options = {
    modules.secretspec = {
      enable = mkEnableOption "secretspec + sops secret loading";

      profile = mkOption {
        type = types.str;
        default = "personal";
        example = "work";
        description = ''
          Default secretspec profile to load when SECRETSPEC_PROFILE is unset.
          Switch per-shell with `export SECRETSPEC_PROFILE=<name>` (e.g. to pick
          a different Claude account).
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    # secretspec 0.17 resolves the manifest; the sops CLI is the decryption
    # backend used by any sops:// provider (age key read from the default
    # ~/.config/sops/age/keys.txt, so nothing extra to configure here).
    packages = [pkgs-secretspec.secretspec pkgs.sops];

    # Load every declared secret into the shell env at entry, if a manifest is
    # present. `secretspec export` prints `export KEY='value'` lines on stdout
    # (its audit note goes to stderr, so stdout is safe to eval). The profile
    # selects the active value set — e.g. which Claude account's OAuth token.
    enterShell = ''
      if [ -f "${config.env.DEVENV_ROOT}/secretspec.toml" ] && command -v secretspec > /dev/null; then
        if ! eval "$(secretspec export --profile "''${SECRETSPEC_PROFILE:-${cfg.profile}}" 2> /dev/null)"; then
          echo "secretspec: failed to load secrets (check the sops age key and the '$SECRETSPEC_PROFILE' profile)" >&2
        fi
      fi
    '';
  };
}
