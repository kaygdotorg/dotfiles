# ============================================================================
# PERFORMANCE: PATH must be set BEFORE p10k instant prompt
# ============================================================================
# Why: p10k instant prompt renders the prompt immediately while zsh initializes
# in the background. If PATH isn't set first, p10k won't find custom tools
# (like starship, custom git prompt tools, etc.) for the initial render.
# ============================================================================

# --- PATH Configuration ---
# Base PATH: user local binaries take precedence
export PATH="${HOME}/.local/bin:${PATH}"

# macOS Homebrew (Apple Silicon) - only on macOS and only if installed
if [[ "${OSTYPE}" == "darwin"* && -d "/opt/homebrew/bin" ]]; then
    export PATH="/opt/homebrew/bin:${PATH}"
fi

# Spicetify (Spotify CLI) - only on macOS and only if installed
if [[ -d "/Users/kayg/.spicetify" ]]; then
    export PATH="/Users/kayg/.spicetify:${PATH}"
fi

# opencode - only if installed
if [[ -d "/home/kayg/.opencode/bin" ]]; then
    export PATH="/home/kayg/.opencode/bin:${PATH}"
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
# Powerlevel10k Instant Prompt
# ============================================================================
# This renders the prompt immediately while zsh continues loading in background.
# Must stay near the top (after PATH), but before any console input might be needed.
# ============================================================================
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

# ============================================================================
# Oh My Zsh Configuration
# ============================================================================
export ZSH="${ZDOTDIR}"

# Set OMZ theme
ZSH_THEME="powerlevel10k/powerlevel10k"

# Save history at a custom location
HISTFILE="${ZSH}/.zsh_history"

# Save z's db at a custom location
_Z_DATA="${ZSH}/.z"

# _ and - will be interchangeable
HYPHEN_INSENSITIVE="true"

# Enable command auto-correction
ENABLE_CORRECTION="true"

# Display red dots whilst waiting for completion
COMPLETION_WAITING_DOTS="true"

# ============================================================================
# PLUGIN CONFIGURATION (consolidated here for clarity)
# ============================================================================
plugins=(
    copyfile      # Copy file contents to clipboard: `copyfile <filename>`
    git           # Git aliases and functions
    vi-mode       # Vim-style line editing (Esc to enter normal mode)
    z             # Jump to recent directories: `z <pattern>`
    zsh-syntax-highlighting    # Real-time command syntax highlighting
    zsh-autosuggestions        # Suggest commands from history
    history-substring-search   # Search history with Up/Down arrows
)

# --- zsh-autosuggestions configuration ---
# Fetch suggestions asynchronously (non-blocking UI)
export ZSH_AUTOSUGGEST_USE_ASYNC=1
# Order of strategies: try matching previous command first, then completions
export ZSH_AUTOSUGGEST_STRATEGY=(
    match_prev_cmd
    completion
)
# Don't suggest for very long commands (performance)
export ZSH_AUTOSUGGEST_BUFFER_MAX_SIZE=20

source "${ZSH}/oh-my-zsh.sh"

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

# check_if_installed(): Check if a command exists (silent)
# Usage: check_if_installed <command>
check_if_installed() {
    command -v "${1}" 2>/dev/null 1>&2;
}

# ============================================================================
# ZSH OPTIONS
# ============================================================================
# auto_cd: Type directory name to cd into it (no need to type `cd`)
# Example: instead of `cd Documents`, just type `Documents`
setopt auto_cd

# extended_glob: Enable advanced globbing patterns
# Example: `ls ^*.txt` lists all files except .txt files
setopt extended_glob

# NO_CASE_GLOB: Case-insensitive globbing
# Example: `ls *.txt` matches both `file.txt` and `FILE.TXT`
setopt nocaseglob

# APPEND_HISTORY: Multiple zsh sessions append to history file (don't overwrite)
setopt append_history

# SHARE_HISTORY: Share history between all sessions in real-time
setopt share_history

# HIST_IGNORE_DUPS: Don't save duplicate commands
setopt hist_ignore_dups

# HIST_IGNORE_SPACE: Don't save commands starting with space (for secrets)
setopt hist_ignore_space

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

# ============================================================================
# EXTERNAL TOOL INTEGRATIONS
# ============================================================================

# iTerm2 shell integration (provides features like semantic history, etc.)
if [[ -f "${ZDOTDIR}/.iterm2_shell_integration.zsh" ]]; then
    source "${ZDOTDIR}/.iterm2_shell_integration.zsh"
fi

# nvm (Node Version Manager) - LAZY LOADING for performance
# ============================================================================
# Why lazy load? Sourcing nvm init adds 200-500ms to shell startup time.
# Instead, we create wrapper functions that load nvm only when needed.
# ============================================================================
if [[ -f /usr/share/nvm/init-nvm.sh ]]; then
    # Store the actual init script path
    export NVM_DIR="${HOME}/.nvm"
    
    # Wrapper function that loads nvm on first use
    nvm() {
        unset -f nvm node npm npx 2>/dev/null
        source /usr/share/nvm/init-nvm.sh
        nvm "$@"
    }
    
    # Create wrappers for common node commands
    node() {
        unset -f nvm node npm npx 2>/dev/null
        source /usr/share/nvm/init-nvm.sh
        node "$@"
    }
    
    npm() {
        unset -f nvm node npm npx 2>/dev/null
        source /usr/share/nvm/init-nvm.sh
        npm "$@"
    }
    
    npx() {
        unset -f nvm node npm npx 2>/dev/null
        source /usr/share/nvm/init-nvm.sh
        npx "$@"
    }
fi

# Atuin (shell history with sync and search)
if [[ -f "$HOME/.atuin/bin/env" ]]; then
    . "$HOME/.atuin/bin/env"
    eval "$(atuin init zsh)"
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
# PROMPT CUSTOMIZATION
# ============================================================================
# To customize prompt, run `p10k configure` or edit ~/.config/zsh/.p10k.zsh
if [[ -f ~/.config/zsh/.p10k.zsh ]]; then
    source ~/.config/zsh/.p10k.zsh
fi
