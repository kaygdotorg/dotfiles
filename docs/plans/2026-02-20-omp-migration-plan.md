# Oh My Posh Migration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace Powerlevel10k with Oh My Posh using a Catppuccin Mocha YAML theme.

**Architecture:** Create an OMP YAML config at `zsh/.config/zsh/omp.yaml`, update `.zshrc` to init OMP instead of p10k, update the `dot` install script to install OMP instead of cloning p10k, and add a cursor-shape vi-mode hook.

**Tech Stack:** Oh My Posh (Go binary), YAML config, zsh

---

### Task 1: Create the OMP theme config

**Files:**
- Create: `zsh/.config/zsh/omp.yaml`

**Step 1: Create the OMP YAML config**

Write `zsh/.config/zsh/omp.yaml` with this exact content:

```yaml
# yaml-language-server: $schema=https://raw.githubusercontent.com/JanDeDobbeleer/oh-my-posh/main/themes/schema.json

version: 3
final_space: true
streaming: 100

palette:
  rosewater: "#f5e0dc"
  flamingo: "#f2cdcd"
  pink: "#f5c2e7"
  mauve: "#cba6f7"
  red: "#f38ba8"
  maroon: "#eba0ac"
  peach: "#fab387"
  yellow: "#f9e2af"
  green: "#a6e3a1"
  teal: "#94e2d5"
  sky: "#89dceb"
  sapphire: "#74c7ec"
  blue: "#89b4fa"
  lavender: "#b4befe"
  text: "#cdd6f4"
  subtext1: "#bac2de"
  subtext0: "#a6adc8"
  overlay2: "#9399b2"
  overlay1: "#7f849c"
  overlay0: "#6c7086"
  surface2: "#585b70"
  surface1: "#45475a"
  surface0: "#313244"
  base: "#1e1e2e"
  mantle: "#181825"
  crust: "#11111b"

blocks:
  # ── Line 1 ──────────────────────────────────────────────────
  - type: prompt
    alignment: left
    segments:
      # Directory
      - type: path
        style: plain
        foreground: "p:blue"
        template: "{{ .Path }}"
        properties:
          style: unique
          home_icon: "~"

      # Git status
      - type: git
        style: plain
        foreground: "p:green"
        foreground_templates:
          - "{{ if or (.Working.Changed) (.Staging.Changed) }}p:yellow{{ end }}"
          - "{{ if .Merge }}p:red{{ end }}"
        template: " {{ .HEAD }}{{ if .BranchStatus }} {{ .BranchStatus }}{{ end }}{{ if .Working.Changed }} !{{ .Working.Modified }}{{ end }}{{ if .Staging.Changed }} +{{ .Staging.Added }}{{ end }}{{ if gt .StashCount 0 }} *{{ .StashCount }}{{ end }}"
        properties:
          branch_max_length: 32
          fetch_status: true
          fetch_stash_count: true

  - type: prompt
    alignment: right
    segments:
      # Node.js version
      - type: node
        style: plain
        foreground: "p:green"
        template: " {{ .Full }}"

      # Python version / virtualenv
      - type: python
        style: plain
        foreground: "p:yellow"
        template: " {{ if .Venv }}{{ .Venv }} {{ end }}{{ .Full }}"

      # Go version
      - type: go
        style: plain
        foreground: "p:blue"
        template: " {{ .Full }}"

      # Kubernetes context
      - type: kubectl
        style: plain
        foreground: "p:mauve"
        template: " {{ .Context }}{{ if .Namespace }}/{{ .Namespace }}{{ end }}"

      # AWS profile
      - type: aws
        style: plain
        foreground: "p:yellow"
        template: " {{ .Profile }}{{ if .Region }} ({{ .Region }}){{ end }}"

      # Terraform workspace
      - type: terraform
        style: plain
        foreground: "p:mauve"
        template: " {{ .WorkspaceName }}"

      # Command execution time
      - type: executiontime
        style: plain
        foreground: "p:subtext0"
        template: " {{ .FormattedMs }}"
        properties:
          threshold: 3000
          style: round

      # Exit status (non-zero only)
      - type: status
        style: plain
        foreground: "p:red"
        template: " {{ reason .Code }}"
        properties:
          always_enabled: false

  # ── Line 2 ──────────────────────────────────────────────────
  - type: prompt
    alignment: left
    newline: true
    segments:
      # Prompt character
      - type: text
        style: plain
        foreground: "p:green"
        foreground_templates:
          - "{{ if gt .Code 0 }}p:red{{ end }}"
        template: "❯"

transient_prompt:
  foreground: "p:green"
  foreground_templates:
    - "{{ if gt .Code 0 }}p:red{{ end }}"
  background: transparent
  template: "❯ "
```

**Step 2: Commit**

```bash
git add zsh/.config/zsh/omp.yaml
git commit -m "feat(zsh): add Oh My Posh theme config with Catppuccin Mocha"
```

---

### Task 2: Update .zshrc to use OMP instead of p10k

**Files:**
- Modify: `zsh/.config/zsh/.zshrc`

**Step 1: Remove the p10k instant prompt block (lines 1-63)**

Replace everything from line 1 through line 63 (the comment header about PATH + the PATH config + the p10k instant prompt block) with just the PATH configuration (no p10k instant prompt):

```
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
```

This removes:
- The comment about "PATH must be set BEFORE p10k instant prompt"
- The entire p10k instant prompt block (lines 56-63)

**Step 2: Remove the `ZSH_THEME` line**

Delete this line:
```
ZSH_THEME="powerlevel10k/powerlevel10k"
```

**Step 3: Replace the p10k source block at the bottom with OMP init + vi-mode cursor**

Replace the block at lines 253-258 (the p10k source block):
```
# ============================================================================
# PROMPT CUSTOMIZATION
# ============================================================================
# To customize prompt, run `p10k configure` or edit ${ZDOTDIR}/.p10k.zsh
if [[ -f "${ZDOTDIR}/.p10k.zsh" ]]; then
    source "${ZDOTDIR}/.p10k.zsh"
fi
```

With:
```
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
# This replaces p10k's vi-mode prompt character indicators.
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
```

**Step 4: Commit**

```bash
git add zsh/.config/zsh/.zshrc
git commit -m "feat(zsh): replace Powerlevel10k with Oh My Posh"
```

---

### Task 3: Update the `dot` install script

**Files:**
- Modify: `dot`

**Step 1: Remove p10k from `setup_zsh()`**

In the `setup_zsh()` function, remove these lines:
```sh
    # installing powerlevel10k
    printf '%s' 'Installing powerlevel10k'
    run_cmd git -C "${zsh_dest_custom_themes}" clone --depth=1 https://github.com/romkatv/powerlevel10k.git
```

And add OMP install in their place:
```sh
    # install oh-my-posh
    printf '%s' 'Installing oh-my-posh'
    run_cmd curl -s https://ohmyposh.dev/install.sh | bash -s -- -d "${HOME}/.local/bin"
```

**Step 2: Remove the `zsh_dest_custom_themes` variable**

Delete this line (no longer needed since p10k was the only custom theme):
```sh
zsh_dest_custom_themes="${HOME}/.config/zsh/custom/themes"
```

**Step 3: Commit**

```bash
git add dot
git commit -m "feat(dot): replace p10k install with oh-my-posh"
```

---

### Task 4: Verify and clean up

**Step 1: Check the config file is valid YAML**

Run:
```bash
oh-my-posh config export --config zsh/.config/zsh/omp.yaml --format json > /dev/null 2>&1 && echo "Config valid" || echo "Config invalid"
```

If OMP is not installed yet, install it first:
```bash
curl -s https://ohmyposh.dev/install.sh | bash -s -- -d "${HOME}/.local/bin"
```

**Step 2: Preview the prompt**

Run:
```bash
oh-my-posh print primary --config zsh/.config/zsh/omp.yaml
```

This renders the prompt without sourcing it in zsh. Verify the output shows the path segment and prompt character.

**Step 3: Verify no remaining p10k references**

Run:
```bash
grep -r "p10k\|powerlevel10k\|powerlevel9k" zsh/ dot
```

Expected: no matches.

**Step 4: Final commit if any fixes were needed**

```bash
git add -A && git commit -m "fix(zsh): address OMP config issues from validation"
```

Only commit if there were changes. Skip if validation passed cleanly.
