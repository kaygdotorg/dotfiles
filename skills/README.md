# Kayg Skills

This repository is the version-controlled collection of skills authored for the harness. Each tracked skill lives in its own directory under `skills/` and contains a `SKILL.md` plus any sibling files it references.

The harness discovers skills under `~/.claude/skills`. Authored skills are kept in this repository and exposed at their discovery paths through symlinks:

```text
$HOME/.claude/skills/<name> -> $HOME/.config/dotfiles/skills/<name>
```

To add a new authored skill, create it in the repository, then link its discovery path:

```sh
name="my-skill"
repo="${DOTFILES_REPO:-${HOME}/.config/dotfiles}"
mkdir -p "${repo}/skills/${name}" "${HOME}/.claude/skills"
$EDITOR "${repo}/skills/${name}/SKILL.md"
ln -s "${repo}/skills/${name}" "${HOME}/.claude/skills/${name}"
git -C "${repo}" add "skills/${name}" "skills/README.md"
git -C "${repo}" commit -m "Add ${name} skill"
git -C "${repo}" push origin main
```

The `~/.claude/skills` directory also contains untracked third-party skills. Their licensing and provenance are separate from this repository; do not add them here unless explicitly chosen for authorship and tracking.
