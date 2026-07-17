# nix-devkit

Personal, reusable [devenv](https://devenv.sh) modules and custom Nix packages,
shared across projects from a single flake. Bump a version here once, then pull
it into every project — no more copy-pasted module files drifting out of sync.

## What's inside

**`devenvModule`** — one bundle importing every feature module below. Each module
is gated behind a `modules.<name>.enable` flag, so importing the bundle does
nothing until you flip the flags you want.

| Module | Enable flag | Provides |
| --- | --- | --- |
| claude | `modules.claude.enable` | Claude Code, ast-grep, bubblewrap, claude-agent-acp; optional hexdocs / postgres / mempalace MCP |
| elixir | `modules.elixir.enable` | Elixir + Erlang (version options), Phoenix deps, optional Expert LSP |
| node | `modules.node.enable` | Node + npm, optional TypeScript, prettier |
| rust | `modules.rust.enable` | Rust toolchain + Tauri GUI system libs |
| tidewave | `modules.tidewave.enable` | tidewave CLI |
| open-design | `modules.open-design.enable` | `od` daemon + web UI (repackaged, self-healing skill staging) |
| devenv_utils | *(always on)* | `dev` wrapper script + shell banner |

**`packages.<system>`** — the custom packages, usable standalone:
`claude-agent-acp`, `tidewave-cli`, `mempalace`, `open-design`.

## Use in a project

Add the input to your project `flake.nix`:

```nix
{
  inputs = {
    devkit.url = "github:sezaru/nix-devkit";
    # ... your other inputs (devenv, nixpkgs, ...)
  };
}
```

Import the bundle in your devenv config and flip the flags:

```nix
# .nix/devenv.nix (or wherever your devenv module lives)
{inputs, ...}: {
  imports = [
    inputs.devkit.devenvModule
  ];

  modules.claude = {
    enable = true;
    hexdocs.enable = true;
    mempalace.enable = true;
  };

  modules.elixir = {
    enable = true;
    package = pkgs-unstable.elixir_1_19; # override versions per project
    erlang.package = pkgs-unstable.erlang_28;
    phoenix.enable = true;
  };

  modules.rust.enable = true;
  modules.tidewave.enable = true;
  modules.open-design.enable = true;
}
```

The bundle is passed to `devenv.lib.mkShell` via your flake's `modules` list, e.g.:

```nix
devShells.default = devenv.lib.mkShell {
  inherit inputs pkgs;
  modules = [./.nix/devenv.nix];
};
```

### Just a package, no module

```nix
packages = [inputs.devkit.packages.${pkgs.stdenv.system}.tidewave-cli];
```

## How the single-input trick works

devkit owns the heavy transitive inputs (`nixpkgs-unstable`, `expert`,
`open-design`). The bundle injects them into every module via
`_module.args.flakeInputs = inputs`, and modules read `flakeInputs.<x>` instead
of the consumer's inputs. So a consuming project only ever declares `devkit` as
an input — those upstream versions live here, in one place.

Custom packages are referenced inside modules as
`flakeInputs.self.packages.${pkgs.stdenv.system}.<name>`.

> Project-specific choices (which Elixir version, etc.) still belong in the
> consuming project via the module `options` — that's config, not shared drift.

## Updating

Bump the version string in the relevant `packages/*.nix`, then:

```sh
# here
git commit -am "bump claude-agent-acp to X.Y.Z" && git push

# in each consuming project
nix flake update devkit
```

## Layout

```
flake.nix          # inputs + `packages.<system>` + `devenvModule` bundle
modules/           # one file per feature module (option-gated)
packages/
  default.nix      # assembles the package set
  *.nix            # individual package derivations
```

## Adding a module

1. Drop `modules/<name>.nix` — signature `{config, lib, pkgs, flakeInputs, ...}`,
   guard config with `mkIf config.modules.<name>.enable`.
2. Add it to the `imports` list in `flake.nix`'s `devenvModule`.

## Adding a package

1. Drop `packages/<name>.nix` (a `callPackage`-style derivation).
2. Wire it into `packages/default.nix`.
3. Reference it from a module via `flakeInputs.self.packages.${system}.<name>`
   if a module should install it.
