{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.modules.gh;

  ghDir = "${config.env.DEVENV_STATE}/gh";

  # gh keeps config under GH_CONFIG_DIR, but its state (update-check stamps),
  # data (extensions) and cache follow the XDG_* dirs of the process, which a
  # project may or may not redirect. The wrapper pins all four for gh alone,
  # so nothing lands in $HOME whatever the project's env does. Git and ssh
  # spawned by gh only read XDG_CONFIG_HOME, which is left untouched.
  #
  # Auth is a token file, never `gh auth login`: the PAT sops-nix decrypts at
  # login is read into GH_TOKEN when the caller has not set one, so the
  # keyring is never consulted and nothing survives in the config dir.
  wrapped = pkgs.symlinkJoin {
    name = "gh-wrapped";
    paths = [cfg.package];
    nativeBuildInputs = [pkgs.makeWrapper];
    postBuild = ''
      wrapProgram $out/bin/gh \
        --run 'export GH_CONFIG_DIR="${ghDir}/config"' \
        --run 'export XDG_STATE_HOME="${ghDir}/state" XDG_DATA_HOME="${ghDir}/data" XDG_CACHE_HOME="${ghDir}/cache"' \
        --run 'if [ -z "$GH_TOKEN" ] && [ -r "${cfg.tokenFile}" ]; then export GH_TOKEN="$(cat "${cfg.tokenFile}")"; fi'
    '';
  };
in {
  options = {
    modules.gh = {
      enable = mkEnableOption "GitHub CLI (config/state under project state, token from a file)";

      package = mkOption {
        type = types.package;
        default = pkgs.gh;
        defaultText = literalMD "pkgs.gh";
        description = "The gh package to use";
      };

      tokenFile = mkOption {
        type = types.str;
        default = "$HOME/.config/sops-nix/secrets/github/token";
        description = ''
          Shell-expanded path of a file holding a GitHub token. Read into
          GH_TOKEN on every gh call unless GH_TOKEN is already set. The default
          is where the home-manager sops-nix module exposes the
          `github/token` secret.
        '';
      };

      gitProtocol = mkOption {
        type = types.enum ["ssh" "https"];
        default = "ssh";
        description = "git_protocol seeded into the project's gh config on first use";
      };
    };
  };

  config = mkIf cfg.enable {
    packages = [wrapped];

    # A fresh config dir would default to https clones and prompt to pick a
    # protocol on the first `gh repo clone`/`fork`; seed it once.
    enterShell = ''
      if [ ! -f "${ghDir}/config/config.yml" ]; then
        mkdir -p "${ghDir}/config"
        printf 'git_protocol: ${cfg.gitProtocol}\nprompt: disabled\n' > "${ghDir}/config/config.yml"
      fi
    '';
  };
}
