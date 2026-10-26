#!/bin/sh
#
# tmux keybindings cheatsheet — bound to  prefix + ?  in tmux.conf.
#
# Merges the human-readable notes set with `bind -N` (which `list-keys -N`
# prints cleanly) into the full `list-keys` output, so EVERY binding appears —
# including plugin bindings, which carry no notes. Anything without a note has
# its raw tmux command humanized instead.
#
# Lived inside tmux.conf as a single escaped one-liner until it became
# unreviewable; as a file it is shellcheck-able and editable without counting
# backslashes.
#
# Output is piped through less for search (/) and scrolling (j/k, arrows).

set -u

# Label prefix bindings with the prefix that is actually configured.
prefix="$(tmux show-options -gv prefix 2>/dev/null || echo 'C-b')"

heading() {
    printf '\033[1;35m── %s %s\033[0m\n' "$1" \
        "$(printf '%*s' $((54 - ${#1})) '' | tr ' ' '─')"
}

# Bindings reachable after the prefix key.
prefix_bindings() {
    tmux list-keys -T prefix | awk -v prefix="${prefix}" '
        BEGIN {
            while (("tmux list-keys -N -T prefix" | getline line) > 0) {
                split(line, field, " ")
                key = field[1]
                sub(/^[^ ]+ +/, "", line)
                note[key] = line
            }
        }
        {
            sub(/^bind-key +/, "")
            sub(/-r +/, "")
            sub(/-T +[^ ]+ +/, "")
            key = $1
            sub(/^[^ ]+ +/, "")

            name = key
            gsub(/\\/, "", name)

            if (name in note) {
                description = note[name]
            } else {
                description = $0
                if (description ~ /tmux-fingers.*jump/)
                    description = "Hint-jump mode (tmux-fingers)"
                else if (description ~ /tmux-fingers/)
                    description = "Hint-copy patterns (tmux-fingers)"
                else if (description ~ /\/tpm\//)
                    description = "TPM plugin manager"
                else if (length(description) > 55)
                    description = substr(description, 1, 52) "..."
            }

            printf "  %s %-12s %s\n", prefix, name, description
        }'
}

# Bindings that need no prefix. Mouse bindings are filtered out: they are
# default behaviour and just noise in a printed list.
root_bindings() {
    tmux list-keys -T root | awk '
        BEGIN {
            while (("tmux list-keys -N -T root" | getline line) > 0) {
                split(line, field, " ")
                key = field[1]
                sub(/^[^ ]+ +/, "", line)
                note[key] = line
            }
        }
        {
            sub(/^bind-key +/, "")
            sub(/-r +/, "")
            sub(/-T +[^ ]+ +/, "")
            key = $1
            sub(/^[^ ]+ +/, "")

            name = key
            gsub(/\\/, "", name)
            if (name ~ /^Mouse|^Wheel|^Double|^Triple|^M-Mouse/) next

            if (name in note) {
                description = note[name]
            } else {
                description = $0
                if (length(description) > 55)
                    description = substr(description, 1, 52) "..."
            }

            printf "  %-16s %s\n", name, description
        }'
}

# Copy mode. Most of these are raw `send-keys -X <command>`, so the command
# name itself is turned into the description when no note exists.
copy_mode_bindings() {
    tmux list-keys -T copy-mode-vi | awk '
        BEGIN {
            while (("tmux list-keys -N -T copy-mode-vi" | getline line) > 0) {
                split(line, field, " ")
                key = field[1]
                sub(/^[^ ]+ +/, "", line)
                note[key] = line
            }
        }
        {
            sub(/^bind-key +/, "")
            sub(/-r +/, "")
            sub(/-T +[^ ]+ +/, "")
            key = $1
            sub(/^[^ ]+ +/, "")

            name = key
            gsub(/\\/, "", name)

            if (name in note) {
                description = note[name]
            } else {
                description = $0

                if (description ~ /^send-keys -F?X /) {
                    sub(/^send-keys -F?X /, "", description)
                    sub(/ .*/, "", description)

                    if (description == "copy-pipe-and-cancel")
                        description = "Copy selection and exit"
                    else if (description == "copy-pipe-end-of-line-and-cancel")
                        description = "Copy to end of line and exit"
                    else if (description == "append-selection-and-cancel")
                        description = "Append to selection and exit"
                    else {
                        gsub(/-/, " ", description)
                        description = toupper(substr(description, 1, 1)) substr(description, 2)
                    }
                } else if (description ~ /command-prompt/ && match(description, /\([^)]+\)/)) {
                    description = substr(description, RSTART + 1, RLENGTH - 2)
                    description = toupper(substr(description, 1, 1)) substr(description, 2)
                    if (description == "Repeat") description = "Repeat count prefix"
                } else if (name == "MouseDrag1Pane")    description = "Begin mouse selection"
                else if (name == "MouseDragEnd1Pane")   description = "Copy mouse selection and exit"
                else if (name == "MouseDown1Pane")      description = "Select pane"
                else if (name == "WheelUpPane")         description = "Scroll up"
                else if (name == "WheelDownPane")       description = "Scroll down"
                else if (name == "DoubleClick1Pane")    description = "Select and copy word"
                else if (name == "TripleClick1Pane")    description = "Select and copy line"
                else if (length(description) > 55)
                    description = substr(description, 1, 52) "..."
            }

            printf "  %-16s %s\n", name, description
        }'
}

{
    heading "Prefix Bindings"
    prefix_bindings
    printf '\n'

    heading "Root Bindings"
    root_bindings
    printf '\n'

    heading "Copy Mode (vi)"
    copy_mode_bindings
} | less -R
