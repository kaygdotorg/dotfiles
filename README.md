# Dotfiles

Configuration files and management script for a personalized development environment.

## Usage

### Clone

Clone the repo to any path you like. I keep mine at `${HOME}/.config/dotfiles`.

This repository is mirrored on both GitHub and a self-hosted GitLab instance:

#### GitHub (Primary)

```bash
git clone https://github.com/kaygdotorg/dotfiles.git "${HOME}/.config/dotfiles"
```

#### Self-hosted GitLab (Mirror)

```bash
git clone https://git.kayg.org/kayg/dotfiles.git "${HOME}/.config/dotfiles"
```

Both remotes are kept in sync. Use whichever is more convenient or accessible.

### Setup

Make `dot` do all the dirty work.

**Symlink `dot` to `${HOME}/.local/bin` assuming the directory is in your PATH:**

```bash
"${HOME}/.config/dotfiles/dot" setup dot
```

**Setup programs:**

```bash
dot setup zsh
dot setup tmux
dot setup atuin
dot setup ssh
dot setup karabiner  # macOS only, requires npx
```

## Features

- **Zsh**: Standalone config with Oh My Posh prompt, vi-mode, and lazy-loaded nvm
- **Tmux**: Standalone config with Catppuccin Mocha theme, OSC 52 clipboard (nested tmux support), vi-mode, and mouse support
- **Atuin**: Shell history with sync to self-hosted server
- **SSH**: Managed SSH config
- **Karabiner**: Advanced keyboard customization with Colemak-DH layout and hyper layers
- **Dot script**: POSIX-compliant shell script for automated setup and updates

## Repository Structure

Config files are stored flat under each tool's directory. The `dot` script handles creating directories and symlinking to the correct system paths.

```
.
├── dot                      # Main setup/management script
├── zsh/
│   ├── .zshenv              # → ~/.zshenv
│   ├── .zshrc               # → ~/.config/zsh/.zshrc
│   └── omp.yaml             # → ~/.config/zsh/omp.yaml
├── tmux/
│   └── .tmux.conf           # → ~/.config/tmux/tmux.conf
├── atuin/
│   └── config.toml          # → ~/.config/atuin/config.toml
├── .ssh/
│   └── config               # → ~/.ssh/config
├── karabiner-ts/
│   └── index.ts             # generates ~/.config/karabiner/karabiner.json
└── scripts/
    └── toggle-menu-bar-visibility.applescript
```

## Notes

### Nested tmux clipboard (inner SSH → outer Mac → iTerm2)

Copying from tmux copy mode doesn't use the built-in `set-clipboard on` OSC 52 emission — it's broken when nested (`TERM=tmux-256color`). Instead, all copy-mode bindings explicitly pipe selections through `printf` to write OSC 52 directly to `#{client_tty}`. Application-originated OSC 52 (e.g. from vim) still works via `set-clipboard on` passthrough. See the clipboard section in `tmux/.tmux.conf` for details.

### Shift+Enter in Claude Code inside tmux

Shift+Enter for newlines doesn't work inside tmux because tmux only forwards extended key sequences (kitty keyboard protocol) to apps that explicitly request them, and Claude Code doesn't opt in. The `extended-keys always` setting fixes this but causes breakage in other apps (Shift+Tab, neovim paste, fish completions). **Use `\` + Enter** for newlines in Claude Code instead.

## License

See [LICENSE](LICENSE) file for details.
