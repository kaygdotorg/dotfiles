#!/bin/sh
#
# Per-client tmux tuning — run from the `client-attached` and
# `client-session-changed` hooks in tmux.conf.
#
# WHY THIS IS NOT `if-shell` IN THE CONFIG:
#   if-shell evaluates its command against the tmux SERVER's environment, which
#   is frozen when the server first starts. Since .zshrc auto-starts tmux, the
#   server is almost always started by a local client — so a later attach from
#   an SSH/iPad client was still judged "local", and even `prefix + r` could not
#   change the verdict.
#
#   tmux's `update-environment` option (SSH_CONNECTION is in the default list)
#   copies the attaching client's SSH_CONNECTION into the SESSION environment on
#   every attach, and marks it removed ("-SSH_CONNECTION") on a local attach.
#   Reading it back here gives a per-client answer that re-evaluates every time.
#
# Options set here are session-scoped on purpose: with grouped sessions (see
# TMUX_CLIENT_NAME in .zshrc) each device gets its own status bar treatment
# while sharing the same windows.

# errexit matters here: run-shell discards this script's output, so a command
# that fails is invisible. Stopping on the first failure at least prevents a
# half-applied layout (padding row logic running after `status` did not take).
set -eu

# usage: client-tune.sh [<client_height> <client_session>...]
#
# The hooks pass tmux's own #{client_height} and #{client_session}, because
# asking tmux from in here with an untargeted `display-message -p` is RACY: on
# client-session-changed it sometimes reports the session being switched away
# from, and then the wrong session gets tuned. Height comes first because it is
# always a bare number; the session name is taken as the remaining arguments so
# that a name containing spaces survives word splitting.
height="${1:-}"
[ "$#" -eq 0 ] || shift
session="$*"

# Fallbacks for a call with no client in scope (e.g. the one at config load
# time, before anything has attached).
if [ -z "${session}" ]; then
    session="$(tmux display-message -p '#{session_name}' 2>/dev/null || true)"
fi
[ -n "${session}" ] || exit 0

# Height decides whether we can afford the padding row. Anything non-numeric
# (no client attached yet) falls back to a desktop-ish size.
case "${height}" in
    '' | *[!0-9]*) height=40 ;;
esac

set_opt() {
    tmux set-option -t "${session}" "$@"
}

# `show-environment` prints "-SSH_CONNECTION" for a variable that was explicitly
# removed on attach, so match on the assignment form rather than exit status.
case "$(tmux show-environment -t "${session}" SSH_CONNECTION 2>/dev/null)" in
    SSH_CONNECTION=*)
        # Remote: bar at the bottom (nearer the thumbs on a phone) and fewer
        # refreshes, since every redraw is bytes over a mobile link.
        position=bottom
        set_opt status-position bottom
        set_opt status-interval 60
        ;;
    *)
        position=top
        set_opt status-position top
        set_opt status-interval 15
        ;;
esac

# Padding row between the status bar and the pane content. Pleasant on a
# desktop; on a phone at ~20 rows it costs a tenth of the screen, so drop it.
#
# NOTE: the single-line value of `status` is "on", NOT "1" — tmux rejects 1 as
# an unknown value, and because this runs under run-shell the error would be
# swallowed, silently leaving the padding row in place.
if [ "${height}" -lt 30 ]; then
    rows=1
    set_opt status on
else
    rows=2
    set_opt status 2
fi

# status-format[0] is the bar, [1] the padding row. Reset to the defaults first
# so re-attaching never stacks changes, then put the bar in whichever slot keeps
# it on the outer edge:
#   top:    [0] = bar      [1] = padding
#   bottom: [0] = padding  [1] = bar
set_opt -u status-format

# Subscripts are quoted so the option name survives a shell that globs (zsh
# would treat status-format[1] as a character class and refuse the command).
if [ "${rows}" = 2 ]; then
    if [ "${position}" = bottom ]; then
        set_opt "status-format[1]" "$(tmux show-options -gv 'status-format[0]')"
        set_opt "status-format[0]" ""
    else
        # Setting one session-level array element shadows the entire inherited
        # status-format array, so copy the global bar explicitly before adding
        # the blank padding row.
        set_opt "status-format[0]" "$(tmux show-options -gv 'status-format[0]')"
        set_opt "status-format[1]" ""
    fi
fi
