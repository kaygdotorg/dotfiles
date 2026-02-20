# Migrate from Powerlevel10k to Oh My Posh

## Context

Powerlevel10k is unmaintained. Oh My Posh (OMP) was chosen over Starship for:
- Native transient prompt on zsh
- `unique` directory truncation (matches p10k's `truncate_to_unique`)
- Go template engine for custom git formatting
- Experimental async streaming
- YAML configuration

## Prompt Layout

2-line minimal, no frame, transparent background.

```
 ~/projects/myapp  main +2 !1                    v22.1  minikube  3s
 ❯ _
```

- Line 1 left: directory (unique truncation) + git status
- Line 1 right: language versions, cloud context, execution time, exit status
- Line 2: prompt character (`❯`, green/red based on exit code)
- Transient prompt: collapses old prompts to `❯`

## Segments

### Line 1 Left

| Segment | When | Color |
|---------|------|-------|
| `path` | Always | blue `p:blue` (`#89b4fa`) |
| `git` | In git repos | clean=`p:green`, modified=`p:yellow`, conflicted=`p:red` |

### Line 1 Right

| Segment | When | Color |
|---------|------|-------|
| `node` | `.nvmrc`, `package.json`, `.js/.ts` files | `p:green` |
| `python` | `.py`, `venv`, `pyproject.toml` | `p:yellow` |
| `go` | `go.mod` | `p:blue` |
| `kubectl` | kubeconfig active | `p:mauve` |
| `aws` | `AWS_PROFILE` set | `p:yellow` |
| `terraform` | `.tf` files | `p:mauve` |
| `executiontime` | >3s | `p:subtext0` |
| `status` | non-zero exit | `p:red` |

### Line 2 Left

| Segment | Style |
|---------|-------|
| `text` prompt char | green on success, red on error via `.Code` template |

## Color Palette — Catppuccin Mocha

```yaml
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
```

## Additional Features

- **Async streaming:** 100ms timeout, slow segments show placeholder then re-render
- **Transient prompt:** `❯` only
- **Vi-mode:** Cursor shape via `zle-keymap-select` (beam=insert, block=normal)

## File Changes

| Action | File | Description |
|--------|------|-------------|
| Create | `zsh/.config/zsh/omp.yaml` | OMP theme config |
| Edit | `zsh/.config/zsh/.zshrc` | Replace p10k with OMP init, add vi-mode cursor hook, remove instant prompt |
| Edit | `dot` | Replace p10k clone with note about OMP install, remove p10k from setup/update |

## What's Dropped

- p10k instant prompt (no equivalent in OMP)
- Vi-mode prompt character changes (replaced with cursor shape)
- `my_git_formatter()` (replaced with OMP git template)
- ~20 unused contextual segments (ranger, nnn, midnight_commander, todo, timewarrior, etc.)
