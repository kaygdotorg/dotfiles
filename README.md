# Dotfiles

Configuration files and a management script for a personalized development environment.

## Usage

### Clone

Clone the repository to any path you like — the `dot` script resolves its own location, so nothing depends on where it lives. The examples below use `${HOME}/.config/dotfiles`.

The repository is mirrored on both GitHub and a self-hosted GitLab instance:

#### GitHub (primary)

```bash
git clone https://github.com/kaygdotorg/dotfiles.git "${HOME}/.config/dotfiles"
```

#### Self-hosted GitLab (mirror)

```bash
git clone https://git.kayg.org/kayg/dotfiles.git "${HOME}/.config/dotfiles"
```

Both remotes are kept in sync. Use whichever is more convenient or accessible.

### Setup

The `dot` script handles all linking and installation. Start by symlinking it into your PATH:

```bash
"${HOME}/.config/dotfiles/scripts/dot" setup dot
export PATH="${HOME}/.local/bin:${PATH}"
```

Then set up whichever apps you need:

```bash
dot setup nix          # reuse/install Nix, configure caches, apply this repo
export PATH="${HOME}/.nix-profile/bin:${PATH}"
dot setup zsh
dot setup zellij
dot setup doom
dot setup atuin
dot setup ssh
dot setup karabiner    # macOS only; open Karabiner once and create "Default profile" first
```

Each `dot setup <app>` command creates the necessary directories and links or generates application configuration. Zellij plugins use hash-pinned artifacts from its lockfile; zsh plugins are cloned during their first setup. Repeated setup reuses existing zsh plugins and verified Zellij downloads.

**Division of responsibility:** Home Manager owns packages and the daily Nix updater on both macOS and Linux. `dot` deploys the remaining application configuration and bootstraps Home Manager. `dot setup nix` uses sudo only to install Nix when missing or change root-owned cache configuration. Daily package updates run as your user.

**Pre-existing files are never destroyed.** If a real file (rather than one of our symlinks) already sits at a destination — a distro-provided `~/.zshenv`, an `~/.ssh/config` you wrote by hand — it is moved to `<file>.bak.<timestamp>` before the symlink is created, and the backup is announced as it happens.

**When something fails**, `dot` prints the failing command and its output rather than a bare `failed`. Set `DOT_LOG` to also keep a transcript of every command:

```bash
DOT_LOG=/tmp/dot.log dot setup zsh
```

### Command format and validation

The `dot` CLI takes an action and an application. Nix setup also accepts `--yes` to authorize installing Nix when it is missing; existing installations are reused:

```bash
dot <setup|update> <dot|zsh|zellij|doom|atuin|ssh|karabiner|nix>
```

If arguments are missing or invalid, `dot` prints usage and exits with a non-zero status.

### Re-running setup commands

- `dot setup zsh` reuses valid plugin checkouts and rejects incomplete or unrelated plugin directories before changing shell configuration. `dot update zsh` pulls plugin changes; Nix manages the Zsh support binaries.
- `dot setup zellij` renders the tracked `config.kdl` for your home directory, links `kayg.kdl`, then downloads only the exact hash-pinned Zellij plugins listed in `zellij/plugins.lock`. A checksum mismatch aborts rather than installing unverified bytes.
- `dot update zellij` never fetches a moving "latest" release. To upgrade a plugin, update its entry in `zellij/plugins.lock` (version, URL, sha256) after review, then rerun setup on each machine.
- `dot setup doom` installs the Doom framework into `~/.config/emacs`, copies this repository's configuration into `~/.config/doom`, and synchronizes packages. Emacs must already be installed. Setup and update explicitly use those directories and accept Doom's installer prompts automatically. Use `doom doctor` to verify the environment.
- `dot setup atuin` links an existing Atuin install into `~/.local/bin` and refreshes its config; the binary itself comes from Home Manager/Nix.
- `dot setup dot`, `dot setup ssh`, and `dot setup karabiner` are symlink/generation-based and can be run repeatedly.
- `dot setup ssh` seeds `~/.ssh/config.local` from `.ssh/config.local.example` the first time only — your machine-local hosts are never overwritten. A dangling link or directory at that path causes an error before setup changes anything.
- `dot setup karabiner` requires npm and an existing Karabiner configuration containing `Default profile`. It refuses to run anywhere but macOS. Changed profiles are backed up before an atomic write; identical reruns do not create another backup. Device settings and other profiles are preserved.
- `dot setup nix` applies the repository's existing lock. It skips Nix installation when already present and only replaces cache settings when their contents change.
- `dot update nix` prepares updated flake inputs and an OmniWM release pin in a temporary candidate, validates packages, then activates and retains the new pins. A failed candidate does not replace the repository's working pins.
- `dot update dot` uses Git's autostash while pulling, so a generated OmniWM pin or another local edit is reapplied after the repository update. If reapplying local edits causes conflicts, the command reports failure and leaves Git's recovery state intact.

## Apps

- **Zsh** — Standalone configuration with [Oh My Posh](https://ohmyposh.dev) prompt, vi-mode, lazy-loaded nvm, OSC 133 semantic-prompt marks for Zellij, and plugins (autosuggestions, syntax highlighting, history substring search, completions).
- **Zellij** — Catppuccin Mocha theme, a custom bottom `zjstatus` pill bar (`kayg` layout), a background compact-bar that renders contextual mode tooltips without a persistent status row, mouse ergonomics, OSC 52 clipboard, and bounded scrollback resurrection. WASM plugins (`zjstatus`, `zellij-tabula`) are pinned by hash in `zellij/plugins.lock`.
- **Doom Emacs** — Doom configuration copied into `~/.config/doom`; Emacs itself is a Home Manager package.
- **Atuin** — Shell history replacement with sync to a self-hosted server, replacing the default zsh history search.
- **SSH** — Managed SSH client configuration, tuned for mobile links (keepalives, connection multiplexing), with machine-local hosts kept out of the repository in `~/.ssh/config.local`.
- **Karabiner** — Advanced keyboard customization via [karabiner.ts](https://github.com/evan-liu/karabiner.ts) with Colemak-DH layout and hyper key layers.
- **Home Manager / Nix** — User package management for every machine. The shared flake lives in `home-manager/`; `dot setup nix` selects the macOS or Linux host configuration and enables its daily update.

### Nix setup and updates

`dot setup nix` performs these steps in order:

1. Detect the OS, architecture, and existing Nix executable. Install Determinate Nix only when Nix is missing. Installation requires a terminal confirmation or explicit `--yes`; a missing terminal is never treated as consent.
2. Install the tracked `nix/cache.conf` as a root-owned `/etc/nix/dotfiles-cache.conf`. Add its include to Determinate's `/etc/nix/nix.custom.conf` (or standard Nix's `/etc/nix/nix.conf`), preserving other settings. Reload the installed daemon only when necessary. No global build settings are changed.
3. Link `~/.local/bin/dotfiles-nix-update` to this checkout's shared updater. Apply the already locked Home Manager configuration for the host.
4. Retire the previous updater units after successful activation. Home Manager owns the replacement launchd agent or systemd user timer.

Re-running setup converges the same configuration. It does not reinstall Nix, re-pin the registry, or update the lock. Refresh versions explicitly with `dot update nix`, or let the daily user service do it. The default schedule is 09:17 local on macOS and 03:47 UTC plus up to 15 minutes on Linux. A directory lock prevents overlapping setup/update runs.

The configurations are `kayg` and `kayg-mba` for Apple Silicon Macs, `kayg-linux` for x86_64 Linux, and `kayg-linux-arm` for ARM Linux. Other architectures fail with an explanation before setup changes anything. All hosts currently use the username `kayg`.

### Precompiled packages

Claude Code, Codex, Antigravity CLI (`agy`), OMP, and `cli-proxy-api` come from `llm-agents.packages.${system}`, preserving Numtide's own nixpkgs pin so they match its binary cache. Codex and OMP are compiled by Numtide's CI; this machine must download the resulting packages. Ordinary tools use the nixpkgs binary cache. Packages installed separately by earlier versions of this setup are migrated only when both their names and recorded sources match the explicit migration list. Unknown profile entries are preserved.

The deployment helper evaluates `home-manager/deployment.nix`, including packages added by Home Manager modules. It requests external package outputs with local and remote builders disabled for that command. Missing cached packages stop the operation. This does **not** change the global `max-jobs` setting. It requires Nix 2.35 or newer for that command's scheduling behavior; an older installed Nix is reported rather than silently replaced.

Only exact, declared derivations may run locally: Home Manager's configuration generators, the OmniWM release ZIP downloader/unpacker, and Apple's unmodified font unpackers. Their tool dependencies must already exist or download from cache. Temporary Nix GC roots keep those outputs available until activation or rollback finishes. Additional uncached derivations stop the update instead of compiling. This policy is part of the reviewed repository; changing its approved derivations requires the same care as changing the package list.

Before any profile migration, the full candidate generation must be ready. Activation failure triggers an attempt to reactivate the prior Home Manager generation and restore the exact saved package-profile generation. The updater checks for concurrent edits before persisting pins and never uses Git reset, commits, or pulls automatically.

To inspect the configuration without activation:

```bash
~/.config/dotfiles/nix/nix-unstable-update --check
```

For rollback, inspect `nix profile history` and the generations under `~/.local/state/nix/profiles/home-manager`. Run the chosen old generation's `activate` script to restore Home Manager files and packages. Restore the corresponding `home-manager/flake.lock` and OmniWM pin in Git before the next update if you want to retain the old versions. Profile rollback alone does not revert repository files.

### OmniWM releases

OmniWM uses a versioned upstream ZIP and hash because its releases can arrive ahead of nixpkgs. The macOS updater runs the locked `nix-update` tool against a temporary candidate, then downloads and unpacks the approved binary bundle. Generic fixups and stripping are disabled; bundle structure and signature are checked before activation. `home-manager/updates.nix` declares both operating systems' schedules around the same updater.

## Repository Structure

Configuration files are stored flat under each app's directory. The `dot` script is responsible for creating directories at the destination and symlinking files into place. No file in this repository needs to match its final system path.

```
.
├── .github/workflows/
│   └── shellcheck.yml       # Shell, fixture, Python, and Karabiner checks
├── scripts/
│   ├── dot                  # Setup and management script (bash)
│   └── toggle-menu-bar-visibility.applescript
├── zsh/
│   ├── .zshenv              # Sets ZDOTDIR so zsh finds its config
│   ├── .zshrc               # Main shell configuration
│   └── omp.yaml             # Oh My Posh prompt theme
├── zellij/
│   ├── config.kdl           # Zellij configuration
│   ├── layouts/kayg.kdl     # Custom bottom status-bar layout
│   └── plugins.lock         # Hash-pinned Zellij plugin releases
├── doom-emacs/              # Doom Emacs configuration (copied to ~/.config/doom)
├── atuin/
│   └── config.toml          # Atuin shell history configuration
├── .ssh/
│   ├── config               # SSH client configuration
│   └── config.local.example # Tracked template; its config.local copy is untracked
├── karabiner-ts/
│   └── index.ts             # Generates Karabiner-Elements JSON profile
├── skills/                  # Tracked local SKILL.md instructions and utilities
└── home-manager/            # Nix/Home Manager flake (user packages)
```

### Linking map

The `dot` script symlinks each file from this repository into its expected system location. The diagram below shows what goes where:

```mermaid
graph LR
    subgraph Repository
        A["zsh/.zshenv"]
        B["zsh/.zshrc"]
        C["zsh/omp.yaml"]
        D["zellij/config.kdl"]
        D2["zellij/layouts/kayg.kdl"]
        D3["zellij/plugins.lock"]
        E["atuin/config.toml"]
        F[".ssh/config"]
        F2[".ssh/config.local.example"]
        G["karabiner-ts/index.ts"]
        H["scripts/dot"]
        X["doom-emacs/"]
    end

    subgraph System
        A1["~/.zshenv"]
        B1["~/.config/zsh/.zshrc"]
        C1["~/.config/zsh/omp.yaml"]
        D1["~/.config/zellij/config.kdl"]
        D21["~/.config/zellij/layouts/kayg.kdl"]
        D31["~/.config/zellij/plugins/*.wasm"]
        E1["~/.config/atuin/config.toml"]
        F1["~/.ssh/config"]
        F21["~/.ssh/config.local"]
        G1["~/.config/karabiner/karabiner.json"]
        H1["~/.local/bin/dot"]
        X1["~/.config/doom"]
    end

    A -->|symlink| A1
    B -->|symlink| B1
    C -->|symlink| C1
    D -->|render| D1
    D2 -->|symlink| D21
    D3 -->|hash-pinned download| D31
    E -->|symlink| E1
    F -->|symlink| F1
    F2 -->|copy once| F21
    G -->|generates| G1
    H -->|symlink| H1
    X -->|copy| X1
```

> **Note:** Karabiner is the exception — its local npm dependencies are installed and `index.ts` is executed via `tsx`, which writes the profile JSON directly to `~/.config/karabiner/karabiner.json`. It is not symlinked.

## Quirks

### Skipping the Zellij autostart

`.zshrc` opens the Zellij session picker for interactive shells. It stays out of the way when it should: transfers (scp/rsync/sftp) are not interactive, and a forced command — VS Code Remote, `ssh host cmd`, editor and agent remotes — is skipped via `SSH_ORIGINAL_COMMAND`. To opt out by hand for one connection:

```bash
DOT_NO_AUTOMUX=1 ssh somehost
```

## Validation

Run the isolated checks without installing packages or changing your configuration:

```bash
bash scripts/tests/dot-regressions.sh
bash tests/nix-bootstrap.sh
bash tests/nix-update.sh
python3 -m unittest discover -s tests -p 'test_*.py'
(cd karabiner-ts && npm ci && npm run check)
```

With Nix installed, `bash tests/nix-evaluation.sh` evaluates all four hosts and checks that activation cannot restart its own updater. It does not build or activate any packages.

## License

See [LICENSE](LICENSE) file for details.
