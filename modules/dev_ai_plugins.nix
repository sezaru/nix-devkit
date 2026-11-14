{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.modules.dev-ai-plugins;

  deps_dir = "${config.env.DEVENV_STATE}/dev-ai-plugins";

  # From the repo's branch, not a flake input: a lock would hold each project at
  # the rev it was last bumped to. Nix re-resolves the branch at most every
  # tarball-ttl (1h by default).
  build = pkgs.writeShellScript "dev-ai-plugins-deps" ''
    for n in ${escapeShellArgs cfg.deps}; do
      nix build "github:Hexhound/dev-ai-plugins#$n-deps" --out-link "$1/$n-deps" || exit 1
    done
  '';
in {
  options.modules.dev-ai-plugins.deps = mkOption {
    type = types.listOf types.str;
    default = [];
    example = ["mobile-dev"];
    description = ''
      dev-ai-plugins plugins whose `<name>-deps` bundle goes on PATH, tracking
      the repo's latest commit (rebuilt at most hourly) instead of a lock.
    '';
  };

  config = mkIf (cfg.deps != []) {
    # Right after the devenv profile: the project's own elixir/python/node still
    # win, but the bundles beat the system's, whose python3 lacks their packages.
    # The first entry builds in the foreground so the tools are there; later
    # ones refresh detached so entry never waits.
    enterShell = ''
      mkdir -p "${deps_dir}"
      export PATH="$DEVENV_PROFILE/bin:${concatMapStringsSep ":" (n: "${deps_dir}/${n}-deps/bin") cfg.deps}:$PATH"
      if ! { ${concatMapStringsSep " && " (n: ''[ -e "${deps_dir}/${n}-deps" ]'') cfg.deps}; }; then
        touch "${deps_dir}/.refreshed"
        ${build} "${deps_dir}" || echo "dev-ai-plugins: building ${concatStringsSep ", " cfg.deps} deps failed" >&2
      elif [ -z "$(find "${deps_dir}/.refreshed" -mmin -60 2>/dev/null)" ]; then
        touch "${deps_dir}/.refreshed"
        ${pkgs.util-linux}/bin/setsid -f ${build} "${deps_dir}" \
          </dev/null >"${deps_dir}/.refresh.log" 2>&1
      fi
    '';
  };
}
