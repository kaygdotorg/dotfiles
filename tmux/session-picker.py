#!/usr/bin/env python3
"""Choose an existing tmux session or a project directory without shell eval."""

import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys


def tmux(*args, check=True):
    return subprocess.run(["tmux", *args], text=True, capture_output=True, check=check)


def projects():
    paths = set()
    current = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                             text=True, capture_output=True)
    if current.returncode == 0:
        paths.add(Path(current.stdout.strip()).resolve())
    roots = os.environ.get("DOT_PROJECT_ROOTS", "~/src:~/code:~/projects:~/Developer:~/repos")
    for root in roots.split(os.pathsep):
        if not root:
            continue
        try:
            paths.update(p.resolve() for p in Path(root).expanduser().iterdir()
                         if p.is_dir() and not p.name.startswith("."))
        except OSError:
            continue
    return sorted(paths)


def session_name(path):
    slug = re.sub(r"[^a-zA-Z0-9_-]+", "-", path.name).strip("-") or "project"
    digest = hashlib.sha256(os.fsencode(path)).hexdigest()[:10]
    return f"{slug[:50]}-{digest}"


def open_project(path):
    name = session_name(path)
    target = "=" + name  # Exact match; do not attach to a prefix match.
    if tmux("has-session", "-t", target, check=False).returncode != 0:
        # -c expands tmux formats even when passed as a literal argv element.
        directory = str(path).replace("#", "##")
        created = tmux("new-session", "-d", "-s", name, "-c", directory, check=False)
        # Another picker may have created this same session concurrently.
        if created.returncode != 0:
            tmux("has-session", "-t", target)
    tmux("switch-client", "-t", target)


def main():
    entries = []
    for line in tmux("list-sessions", "-F", "#{session_id}\t#{session_name}").stdout.splitlines():
        identifier, separator, name = line.partition("\t")
        if separator and re.fullmatch(r"\$\d+", identifier):
            entries.append(("session", identifier, "session  " + name))
    for path in projects():
        entries.append(("project", path, "project  " + str(path)))
    if not entries:
        return
    # Only opaque numeric IDs cross the selection boundary. Labels are never commands.
    rows = []
    for index, (_, _, label) in enumerate(entries):
        label = "".join(c if c.isprintable() else " " for c in label)
        rows.append(f"{index}\t{label}\n")
    selected = subprocess.run(
        ["fzf", "--no-multi", "--delimiter=\t", "--with-nth=2..", "--layout=reverse",
         "--height=100%", "--border", "--prompt=Session/project> "],
        input="".join(rows), text=True, stdout=subprocess.PIPE,
    )
    if selected.returncode in (1, 130):
        return
    selected.check_returncode()
    index = int(selected.stdout.partition("\t")[0])
    if not 0 <= index < len(entries):
        raise ValueError("Invalid picker selection")
    kind, target, _ = entries[index]
    if kind == "session":
        tmux("switch-client", "-t", target)
    else:
        open_project(target)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Session picker failed: {error}", file=sys.stderr)
        sys.exit(1)
