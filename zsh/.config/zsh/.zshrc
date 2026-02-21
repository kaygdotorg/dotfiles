# ============================================================================
# PATH Configuration
# ============================================================================

# Base PATH: user local binaries take precedence
export PATH="${HOME}/.local/bin:${PATH}"

# macOS Homebrew (Apple Silicon) - only on macOS and only if installed
if [[ "${OSTYPE}" == "darwin"* && -d "/opt/homebrew/bin" ]]; then
    export PATH="/opt/homebrew/bin:${PATH}"
fi

# Spicetify (Spotify CLI) - only if installed
if [[ -d "${HOME}/.spicetify" ]]; then
    export PATH="${HOME}/.spicetify:${PATH}"
fi

# opencode - only if installed
if [[ -d "${HOME}/.opencode/bin" ]]; then
    export PATH="${HOME}/.opencode/bin:${PATH}"
fi

# --- Go Configuration ---
# Only set Go environment variables if Go is installed
# This avoids polluting PATH and environment when Go isn't being used
if command -v go 2>/dev/null 1>&2; then
    export GOBIN="${HOME}/.local/bin"
    export GOPATH="${HOME}/.local/lib/go"
fi

# ============================================================================
# SAFETY: Nested tmux check
# ============================================================================
# Why: If you accidentally run `tmux` inside an existing tmux session,
# you get nested sessions which are confusing and hard to exit.
# This prevents auto-starting tmux if we're already inside one.
# ============================================================================
# Only auto-start tmux in interactive shells (not iOS/Shellfish scp, etc.)
if [[ $- == *i* ]] && [[ -z "${TMUX}" ]] && [[ -d "${HOME}/.config/tmux" && "$(command -v tmux)" ]]; then
    # iTerm2 Control Mode: Uses native iTerm2 tmux integration
    # -CC flag tells tmux to run in "control mode" where iTerm2 handles the UI
    # Benefits: Native scrollback, mouse support, copy/paste, better rendering
    if [[ "${TERM_PROGRAM}" == "iTerm.app" ]]; then
        exec tmux -CC new-session -As work
    else
        exec tmux new-session -As work
    fi
fi

# ============================================================================
# History
# ============================================================================
HISTFILE="${ZDOTDIR}/.zsh_history"
HISTSIZE=50000
SAVEHIST=10000

setopt extended_history        # Record timestamp of command
setopt hist_expire_dups_first  # Delete duplicates first when HISTFILE exceeds HISTSIZE
setopt hist_ignore_dups        # Ignore duplicated commands in history list
setopt hist_ignore_space       # Ignore commands that start with space
setopt hist_verify             # Show command before executing from history
setopt inc_append_history      # Add commands incrementally, not just at exit
setopt share_history           # Share command history between sessions

# ============================================================================
# Completion System
# ============================================================================
# Load additional completions from plugin before compinit
fpath=(${ZDOTDIR}/plugins/zsh-completions/src $fpath)

# Cached compinit — only regenerate once per day
autoload -Uz compinit
if [[ -n ${ZDOTDIR}/.zcompdump(#qN.mh+24) ]]; then
    compinit
else
    compinit -C
fi

# Completion styles
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{[:lower:][:upper:]-_}={[:upper:][:lower:]_-}' 'r:|=*' 'l:|=* r:|=*'
zstyle ':completion:*' special-dirs true
zstyle ':completion:*' list-colors ''

# ============================================================================
# Colors
# ============================================================================
autoload -U colors && colors
(( $+commands[dircolors] )) && eval "$(dircolors -b)"

# ============================================================================
# ZSH Options
# ============================================================================
setopt auto_cd                 # Type directory name to cd into it
setopt extended_glob           # Enable advanced globbing patterns
setopt nocaseglob              # Case-insensitive globbing
setopt auto_pushd              # Push directories onto the stack automatically
setopt pushd_ignore_dups       # Don't push duplicate directories
setopt pushdminus              # Swap + and - for pushd
setopt correct                 # Enable command auto-correction
setopt multios                 # Allow multiple redirections
setopt interactivecomments     # Allow comments in interactive shell

# ============================================================================
# Vi Mode
# ============================================================================
bindkey -v
export KEYTIMEOUT=1

# ============================================================================
# Plugins
# ============================================================================

# --- zsh-autosuggestions configuration ---
export ZSH_AUTOSUGGEST_USE_ASYNC=1
export ZSH_AUTOSUGGEST_STRATEGY=(match_prev_cmd completion)
export ZSH_AUTOSUGGEST_BUFFER_MAX_SIZE=20

# Source plugins
source "${ZDOTDIR}/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh"
source "${ZDOTDIR}/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
source "${ZDOTDIR}/plugins/zsh-history-substring-search/zsh-history-substring-search.zsh"

# Keybindings for history-substring-search (must be after sourcing)
bindkey '^[[A' history-substring-search-up
bindkey '^[[B' history-substring-search-down
bindkey -M vicmd 'k' history-substring-search-up
bindkey -M vicmd 'j' history-substring-search-down

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

# check_if_installed(): Check if a command exists (silent)
# Usage: check_if_installed <command>
check_if_installed() {
    command -v "${1}" 2>/dev/null 1>&2;
}

# ============================================================================
# cdr: Recent Directories
# ============================================================================
# Tracks recently visited directories and allows quick jumping
# Usage: `cdr` shows recent dirs, `cdr <number>` jumps to that dir
# Or use `cd -<TAB>` to see and select recent directories
# ============================================================================
autoload -Uz chpwd_recent_dirs cdr add-zsh-hook
add-zsh-hook chpwd chpwd_recent_dirs

# ============================================================================
# PLATFORM-SPECIFIC SETTINGS
# ============================================================================

# WSL2 X11 over VSOCK (Linux only) - for running Linux GUI apps on Windows
if [[ "${OSTYPE}" == "linux-gnu"* ]]; then
    export DISPLAY=:0
fi

# ============================================================================
# ALIASES
# ============================================================================

# kitty terminal image display
if check_if_installed kitty; then
    alias icat="kitty +kitten icat"
fi

# Create "real" vim/nvim aliases if they exist (in case they're overridden)
if check_if_installed vim; then
    alias vimreally=$(command -v vim)
fi

if check_if_installed nvim; then
    alias nvimreally=$(command -v nvim)
fi

# rust utils - modern replacements for classic tools
# Only alias if the tool exists (checked by check_if_installed)
check_if_installed bat && alias cat=bat    # Syntax highlighting cat
check_if_installed eza && alias ls=eza     # Modern ls with git integration
check_if_installed fd && alias find=fd     # Fast, user-friendly find
check_if_installed rg && alias grep=rg     # Fast recursive grep

# macOS DNS cache flush
alias flush_dns='sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder'

# ============================================================================
# EXTERNAL TOOL INTEGRATIONS
# ============================================================================

# iTerm2 shell integration (provides features like semantic history, etc.)
if [[ -f "${ZDOTDIR}/.iterm2_shell_integration.zsh" ]]; then
    source "${ZDOTDIR}/.iterm2_shell_integration.zsh"
fi

# nvm (Node Version Manager) - LAZY LOADING for performance
# ============================================================================
# Why lazy load? Sourcing nvm.sh adds 200-500ms to every shell startup.
# Instead, stub functions load nvm on first use then call through to the real
# command. _nvm_load() is a shared helper so the stubs stay terse.
# ============================================================================
export NVM_DIR="${HOME}/.nvm"
if [[ -f "${NVM_DIR}/nvm.sh" ]]; then
    _nvm_load() {
        unset -f nvm node npm npx _nvm_load 2>/dev/null
        source "${NVM_DIR}/nvm.sh"
        [[ -f "${NVM_DIR}/bash_completion" ]] && source "${NVM_DIR}/bash_completion"
    }
    nvm()  { _nvm_load && nvm  "$@"; }
    node() { _nvm_load && node "$@"; }
    npm()  { _nvm_load && npm  "$@"; }
    npx()  { _nvm_load && npx  "$@"; }
fi

# Atuin (shell history with sync and search)
if [[ -f "$HOME/.atuin/bin/env" ]]; then
    . "$HOME/.atuin/bin/env"
    eval "$(atuin init zsh)"
fi

# zoxide (smart directory jumper, replaces z)
if command -v zoxide 2>/dev/null 1>&2; then
    eval "$(zoxide init zsh)"
fi

# shellfish (if installed) - only for interactive shells
if [[ $- == *i* ]] && [[ -f "${HOME}/.shellfishrc" ]]; then
    # When inside tmux, SSH_TTY points to the parent SSH session's tty
    # which is not writable from tmux panes, causing "permission denied" errors.
    # Unset it so shellfish falls back to stdout instead.
    if [[ -n "${TMUX}" ]]; then
        unset SSH_TTY
    fi
    source "${HOME}/.shellfishrc"
    # Suppress "Standard output is not tty" errors from ios_sequence
    # by renaming the original function and creating a silent wrapper
    if typeset -f ios_sequence >/dev/null 2>&1; then
        functions[_ios_sequence_orig]=$functions[ios_sequence]
        ios_sequence() {
            _ios_sequence_orig "$@" 2>/dev/null
        }
    fi
fi

# ============================================================================
# PROMPT — Oh My Posh
# ============================================================================
if command -v oh-my-posh 2>/dev/null 1>&2; then
    eval "$(oh-my-posh init zsh --config "${ZDOTDIR}/omp.yaml")"
fi

# ============================================================================
# VI-MODE CURSOR SHAPE
# ============================================================================
# Beam cursor in insert mode, block cursor in normal mode.
zle-keymap-select() {
    case "${KEYMAP}" in
        vicmd)      print -n '\e[2 q' ;; # block
        viins|main) print -n '\e[6 q' ;; # beam
    esac
}
zle -N zle-keymap-select

# Reset to beam on each new prompt
zle-line-init() { print -n '\e[6 q' }
zle -N zle-line-init

# bun completions
[ -s "${HOME}/.bun/_bun" ] && source "${HOME}/.bun/_bun"
