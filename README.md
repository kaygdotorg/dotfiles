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

```
.
├── dot                      # Main setup/management script
├── zsh/                     # Zsh configuration
├── tmux/                    # Tmux configuration
├── atuin/                   # Atuin shell history configuration
├── .ssh/                    # SSH configuration
├── karabiner-ts/            # Keyboard mapping configuration
└── scripts/                 # Utility scripts
```

## License

See [LICENSE](LICENSE) file for details.
