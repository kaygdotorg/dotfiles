# Dotfiles

Configuration files and management script for a personalized development environment.

## Usage

### Clone

Clone the repo to any path you like. I keep mine at `${HOME}/.config/.dotfiles`.

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
"${HOME}/.config/.dotfiles/dot" setup dot
```

**Setup programs:**

```bash
dot setup zsh
dot setup tmux
# ...
```

## Features

- **Zsh**: Oh My Zsh with Powerlevel10k theme, vi-mode, and optimized performance
- **Tmux**: oh-my-tmux with improved copy/paste, vi-mode, and mouse support
- **Karabiner**: Advanced keyboard customization with Colemak-DH layout and hyper layers
- **Dot script**: POSIX-compliant shell script for automated setup and updates

## Repository Structure

```
.
├── dot                      # Main setup/management script
├── zsh/                     # Zsh configuration
├── tmux/                    # Tmux configuration (client & server)
├── karabiner-ts/           # Keyboard mapping configuration
└── scripts/                # Utility scripts
```

## License

See [LICENSE](LICENSE) file for details.
