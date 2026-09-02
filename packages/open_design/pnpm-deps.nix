{
  # Vendored pnpm store hashes for the daemon and web derivations.
  # GENERATED — do not hand-edit. `nixupdate` regenerates both whenever the
  # open-design input rev (or its pnpm-lock.yaml) changes:
  #   1. sets the consuming hash to lib.fakeHash
  #   2. builds .#open-design-daemon / .#open-design-web
  #   3. writes back the `got:` hash Nix prints on the FOD mismatch
  #
  # The daemon and web derivations build from different filtered source trees,
  # so each fetchPnpmDeps invocation needs its own fixed-output hash.
  daemonHash = "sha256-savky4G+gZZzKa4vUmJ34f+bugqNRhiNEjZ8sRJd+e0=";
  webHash = "sha256-k9vqAcDO6kv+QPu8sUTPHtu08BhEZq1xCzU1dIaXJPM=";
}
