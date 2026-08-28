# ============================================================================
# PATH Configuration
# ============================================================================

# Base PATH: user local binaries take precedence
export PATH="${HOME}/.local/bin:${PATH}"

# Package manager PATH - nix first, then brew (only where present)
case "${OSTYPE}" in
    darwin*)
        # Nix (per-user) takes precedence, then Homebrew (Apple Silicon or Intel)
        if [[ -d "${HOME}/.nix-profile/bin" ]]; then
            export PATH="${HOME}/.nix-profile/bin:${PATH}"
        fi
        if [[ -d "/nix/var/nix/profiles/default/bin" ]]; then
            export PATH="/nix/var/nix/profiles/default/bin:${PATH}"
        fi
        if [[ -d "/opt/homebrew/bin" ]]; then
            eval "$(/opt/homebrew/bin/brew shellenv)"
        elif [[ -d "/usr/local/bin" ]]; then
            eval "$(/usr/local/bin/brew shellenv)"
        fi
        ;;
    *)
        # Nix - system-wide packages (installed via nix, shared by all users)
        if [[ -d "/nix/var/nix/profiles/default/bin" ]]; then
            export PATH="/nix/var/nix/profiles/default/bin:${PATH}"
        fi
        ;;
esac

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
# SAFETY: nested multiplexer check + auto-start (zellij primary, tmux fallback)
# ============================================================================
# Why: running a multiplexer inside an existing one produces confusing nested
# sessions that are hard to exit. This prevents auto-starting either tool when
# already inside one.
#
# The guards, in order:
#   $- == *i*             interactive only (not scp/rsync/sftp transfers)
#   -z ${TMUX}/${ZELLIJ}  not already inside tmux or zellij
#   -z ${DOT_NO_AUTOMUX}  manual escape hatch: `DOT_NO_AUTOMUX=1 ssh host`
#   -z ${SSH_ORIGINAL_COMMAND}
#                         a forced command (VS Code Remote, `ssh host cmd`,
#                         editor and agent remotes) must not be hijacked into
#                         a session — it will hang or garble its protocol
#
# PRIMARY: zellij (trial since 2026-08). Attaching semantics differ from tmux:
#   zellij attach --c reuses or creates; the "work" session name keeps parity
#   with the old tmux layout. ZELLIJ_CLIENT_NAME is the zellij analogue of
#   TMUX_CLIENT_NAME, but zellij has no grouped sessions — each name is its
#   own session, so the per-device grouping is lost there (tmux fallback via
#   DOT_NO_AUTOMUX=1 zellij-less shells still supports it).
#
# FALLBACK: tmux keeps its original behaviour when zellij is absent.
# ============================================================================
if [[ $- == *i* ]] && [[ -z "${TMUX:-}" ]] && [[ -z "${ZELLIJ:-}" ]] \
    && [[ -z "${DOT_NO_AUTOMUX:-}" ]] && [[ -z "${SSH_ORIGINAL_COMMAND:-}" ]]; then
    if [[ -n "$(command -v zellij)" ]] && [[ -d "${HOME}/.config/zellij" ]]; then
        exec zellij attach --create work
    elif [[ -d "${HOME}/.config/tmux" && "$(command -v tmux)" ]]; then
        if [[ -n "${TMUX_CLIENT_NAME:-}" ]] && [[ "${TMUX_CLIENT_NAME}" != work ]] \
            && tmux has-session -t work 2>/dev/null; then
            exec tmux new-session -A -s "${TMUX_CLIENT_NAME}" -t work
        elif tmux has-session 2>/dev/null; then
            exec tmux attach-session
        else
            exec tmux new-session -s work
        fi
    fi
fi

# ============================================================================
# History
# ============================================================================
HISTFILE="${ZDOTDIR}/.zsh_history"
HISTSIZE=50000
SAVEHIST=50000

setopt extended_history        # Record timestamp of command
setopt hist_expire_dups_first  # Delete duplicates first when HISTFILE exceeds HISTSIZE
setopt hist_ignore_dups        # Ignore duplicated commands in history list
setopt hist_ignore_space       # Ignore commands that start with space
setopt hist_verify             # Show command before executing from history
setopt hist_reduce_blanks      # Remove superfluous blanks from history entries
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

# Cache expensive completions (package lists, remote hosts) — `dot setup zsh`
# creates this directory, which until now nothing ever wrote to.
zstyle ':completion:*' use-cache on
zstyle ':completion:*' cache-path "${ZDOTDIR}/cache"

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
setopt no_beep                 # Disable terminal bell on errors

# Word characters: remove / so Ctrl+W and Alt+B/F stop at path separators
WORDCHARS=${WORDCHARS//[\/]/}

# ============================================================================
# Vi Mode
# ============================================================================
bindkey -v
# KEYTIMEOUT is in hundredths of a second: how long zle waits for the rest of a
# multi-byte key sequence. At 1 (10ms) an arrow key whose bytes arrive split
# across packets — routine on a cellular link — is read as a bare Escape
# followed by junk, which is where mangled arrows and vi-mode surprises on
# mobile come from. 20 is still imperceptible for the Escape-to-normal-mode
# switch but survives a slow link.
export KEYTIMEOUT=20

# Emacs-style shortcuts in vi insert mode (viins)
# These keys are unbound (self-insert) by default in vi mode, so no conflicts.
bindkey -M viins '^A' beginning-of-line
bindkey -M viins '^E' end-of-line
bindkey -M viins '^F' forward-char
bindkey -M viins '^B' backward-char
bindkey -M viins '^N' down-history
bindkey -M viins '^P' up-history
bindkey -M viins '^K' kill-line
bindkey -M viins '^U' kill-whole-line
bindkey -M viins '^W' backward-kill-word
bindkey -M viins '^D' delete-char-or-list

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
#
# Both encodings are bound on purpose. ^[[A is what a terminal sends in normal
# cursor mode; ^[OA is what it sends in APPLICATION cursor mode, which tmux and
# many full-screen apps switch on. With only the first pair bound, the up arrow
# silently falls back to plain history in exactly those contexts.
bindkey '^[[A' history-substring-search-up
bindkey '^[[B' history-substring-search-down
bindkey '^[OA' history-substring-search-up
bindkey '^[OB' history-substring-search-down
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
check_if_installed rg && alias grep=rg     # Fast recursive grep

# NOT aliased: find=fd. fd's argument grammar is not find's — `find . -name
# '*.c'` means something entirely different to fd, and the failure is silent
# rather than loud. Call fd by its own name.

# DNS cache flush (OS-specific)
if [[ "${OSTYPE}" == "darwin"* ]]; then
    alias flush_dns='sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder'
elif [[ "${OSTYPE}" == "linux-gnu"* ]]; then
    alias flush_dns='sudo systemd-resolve --flush-caches 2>/dev/null || sudo resolvectl flush-caches'
fi

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
# --disable-up-arrow: keep up/down for zsh-history-substring-search
# ATUIN_TMUX_POPUP: run search in a tmux popup (own PTY, avoids ZLE fd issues)
if [[ -f "$HOME/.atuin/bin/env" ]]; then
    . "$HOME/.atuin/bin/env"
    eval "$(atuin init zsh --disable-up-arrow)"
    export ATUIN_TMUX_POPUP=true
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
# OMP streaming mode renders the prompt in two phases: fast segments appear
# immediately, slow ones (git, kubectl) re-render when ready. However,
# _omp_start_streaming uses `exec {fd}< <(cmd) 2>/dev/null` which in zsh
# permanently redirects stderr to /dev/null (bare exec applies ALL redirections).
# Workaround: wrap _omp_start_streaming to save/restore stderr around the exec.
# See: https://github.com/JanDeDobbeleer/oh-my-posh/issues/5492
if command -v oh-my-posh 2>/dev/null 1>&2; then
    eval "$(oh-my-posh init zsh --config "${ZDOTDIR}/omp.yaml")"

    # Patch _omp_start_streaming to preserve stderr (upstream bug workaround)
    if typeset -f _omp_start_streaming >/dev/null 2>&1; then
        functions[_omp_start_streaming_orig]=$functions[_omp_start_streaming]
        _omp_start_streaming() {
            local _omp_stderr_save
            exec {_omp_stderr_save}>&2
            _omp_start_streaming_orig
            local ret=$?
            exec 2>&${_omp_stderr_save}
            exec {_omp_stderr_save}>&-
            return $ret
        }
    fi
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
[[ -s "${HOME}/.bun/_bun" ]] && source "${HOME}/.bun/_bun"
