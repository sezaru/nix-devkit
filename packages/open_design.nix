{
  pkgs,
  pkgs-unstable,
  inputs,
}: let
  system = pkgs.stdenv.system;

  odPkgs = inputs.open-design.packages.${system};
  daemon = odPkgs.default; # open-design-daemon (`od` CLI)
  web = odPkgs.web; # Next.js static SPA (apps/web/out)

  # The nix daemon package ships the Express API only; it serves the web UI
  # from `<root>/apps/web/out`, which upstream leaves empty (production wires a
  # separate static server via the NixOS module). Bare `od` therefore answers
  # "Cannot GET /". This repackages the daemon with `web` dropped into that
  # path so a single `od` serves both.
  #
  # `server.js` derives the web root from its own realpath, so `apps` must be
  # real files (not symlinks) in the output. Only the 747M `node_modules` stays
  # shared via a symlink (imported, never staged).
  #
  # od stages skills into the project data dir with `fs.cp` (which preserves
  # the store's read-only 0555 dir mode), then on the next turn `rm`s the old
  # copy to refresh it — that unlink EACCES-fails because the staged dir has no
  # write bit. The store source can't be made writable (Nix strips write bits
  # on import), so we patch the staging helper to force staged trees writable
  # before removal and after copy. This self-heals both fresh and already-
  # broken project data dirs.
in
  pkgs.runCommand "open-design-${daemon.version}" {
    nativeBuildInputs = [pkgs.makeWrapper];
  } ''
    root=$out/lib/open-design
    mkdir -p "$root"

    for entry in ${daemon}/lib/open-design/*; do
      name=$(basename "$entry")
      if [ "$name" = node_modules ]; then
        ln -s "$entry" "$root/$name"
      else
        cp -a "$entry" "$root/$name"
        # -R skips symlinks by default, so the shared node_modules links
        # inside apps/daemon are left untouched (no read-only store writes).
        chmod -R u+w "$root/$name"
      fi
    done

    mkdir -p "$root/apps/web/out"
    cp -a ${web}/. "$root/apps/web/out/"
    chmod -R u+w "$root/apps/web/out"

    aliases="$root/apps/daemon/dist/cwd-aliases.js"
    substituteInPlace "$aliases" \
      --replace-fail \
      "import { chmod, cp, lstat, mkdir, readdir, rm, stat, utimes } from 'node:fs/promises';" \
      "import { chmod, cp, lstat, mkdir, readdir, rm, stat, utimes } from 'node:fs/promises'; async function odForceWritable(t){try{const s=await lstat(t);if(s.isSymbolicLink())return;await chmod(t,s.mode|0o700);if(s.isDirectory()){for(const e of await readdir(t))await odForceWritable(path.join(t,e));}}catch{}} async function odForceRemove(t){await odForceWritable(t);await rm(t,{recursive:true,force:true});}"
    substituteInPlace "$aliases" \
      --replace-quiet \
      "await rm(stagedPath, { recursive: true, force: true });" \
      "await odForceRemove(stagedPath);"
    substituteInPlace "$aliases" \
      --replace-fail \
      "return { staged: true, stagedPath };" \
      "await odForceWritable(stagedPath); return { staged: true, stagedPath };"

    makeWrapper ${pkgs-unstable.nodejs_24}/bin/node $out/bin/od \
      --set NODE_ENV production \
      --add-flags "$root/apps/daemon/dist/cli.js"
  ''
