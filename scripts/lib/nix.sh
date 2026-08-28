#!/usr/bin/env bash
#
# dot nix wizard — install/update Nix and wire up the unstable auto-update on
# both macOS and Linux.
#
# What it does:
#   1. Detects the OS and architecture, explains the consequences.
#   2. Installs Determinate Nix if nix is missing (interactive confirmation;
#      the installer itself runs with --no-confirm after the user agrees).
#   3. Re-pins flake:nixpkgs to nixpkgs-unstable HEAD (Determinate's default
#      is a weekly snapshot that silently serves stale versions).
#   4. Platform wiring:
#        Linux : user profile + systemd user timer (daily pin refresh +
#                  `nix profile upgrade --all`), via dotfiles/nix/ units.
#        macOS : verifies the home-manager flake resolves and prints the
#                  switch command (profiles are managed by the flake, not
#                  `nix profile`).
#   5. Verifies end to end (daemon up, nix --version, flake resolves).
#
# Rollback (Linux): nix profile history → nix profile rollback <gen>
# Rollback (macOS): home-manager generations (home-manager switch --rollback)

set -o errexit
set -o nounset

# shellcheck source=/dev/null
# helpers (run_cmd, backup_if_real, check_if_installed...) are defined by the
# sourcing dot script; when run standalone, define minimal fallbacks.
if ! command -v run_cmd >/dev/null 2>&1; then
    run_cmd() {
        if [ "${#}" -eq 0 ]; then
            printf '%s\n' "No arguments provided. Exiting."
            exit 1
        fi
        if "$@"; then
            printf '%s\n' "  done"
        else
            printf '%s\n' "  FAILED: $*"
            exit 1
        fi
    }
    backup_if_real() {
        if [ -e "${1}" ] && [ ! -L "${1}" ]; then
            printf '%s\n' "Backing up existing ${1}"
            mv "${1}" "${1}.bak.$(date +%Y%m%d%H%M%S)"
        fi
    }
    script_path="$(dirname "$(realpath "${0}")")"
    repo_path="$(dirname "${script_path}")"
fi

# ----------------------------------------------------------------------------
# prompts
# ----------------------------------------------------------------------------

ask() {
    # ask <prompt> <default>  → echoes the answer
    local prompt="${1}" default="${2}" answer
    printf '%s [%s]: ' "${prompt}" "${default}"
    read -r answer
    printf '%s' "${answer:-${default}}"
}

ask_yes_no() {
    # ask_yes_no <prompt> <default y|n>  → returns 0 for yes
    local answer
    answer="$(ask "${1} (y/n)" "${2}")"
    case "${answer}" in
        [Yy]|[Yy][Ee][Ss]) return 0 ;;
        *) return 1 ;;
    esac
}

# ----------------------------------------------------------------------------
# detection
# ----------------------------------------------------------------------------

wizard_os="$(uname -s)"                     # Darwin | Linux
wizard_arch="$(uname -m)"                   # arm64/aarch64 | x86_64
NIX_PROFILE_BIN="/nix/var/nix/profiles/default/bin"

wizard_nix_present() {
    command -v nix >/dev/null 2>&1 || [ -x /nix/var/nix/profiles/default/bin/nix ]
}

wizard_nix_version() {
    if command -v nix >/dev/null 2>&1; then
        nix --version 2>/dev/null | head -1
    elif [ -x /nix/var/nix/profiles/default/bin/nix ]; then
        /nix/var/nix/profiles/default/bin/nix --version 2>/dev/null | head -1
    else
        echo "not installed"
    fi
}

wizard_is_determinate() {
    wizard_nix_version | grep -qi determinate
}

# ----------------------------------------------------------------------------
# step 1: install nix (Determinate installer on both platforms)
# ----------------------------------------------------------------------------

wizard_install_nix() {
    printf '%s\n' ""
    printf '%s\n' "nix is not installed on this ${wizard_os} host."
    printf '%s\n' ""
    printf '%s\n' "Installer choice — this wizard installs Determinate Nix, because:"
    printf '%s\n' "  - it ships the SAME upstream nix (not a fork),"
    printf '%s\n' "  - it handles SELinux (the official installer has never supported"
    printf '%s\n' "    SELinux-enforcing Linux hosts — NixOS/nix#2374),"
    printf '%s\n' "  - it configures the daemon and handles upgrades itself."
    if [ "$(getenforce 2>/dev/null || echo Disabled)" = "Enforcing" ]; then
        printf '%s\n' "  - THIS HOST is SELinux-enforcing: the official installer WILL"
        printf '%s\n' "    fail at 'systemctl enable nix-daemon'. Determinate is required."
    fi
    printf '%s\n' ""

    if ! ask_yes_no "Install Determinate Nix now?" "y"; then
        printf '%s\n' "Aborting nix setup (nothing was changed)."
        exit 1
    fi

    printf '%s' "Downloading + running the Determinate Nix installer"
    case "${wizard_os}" in
        Linux)
            if [ "$(id -u)" -eq 0 ]; then
                run_cmd sh -c "curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install --no-confirm"
            else
                # multi-user install needs root; sudo -E keeps the env clean
                run_cmd sh -c "curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install --no-confirm" --sudo
            fi
            ;;
        Darwin)
            run_cmd sh -c "curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install --no-confirm"
            ;;
    esac

    # make nix visible to THIS shell immediately
    # shellcheck disable=SC1091
    [ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ] \
        && . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh || true
}

# ----------------------------------------------------------------------------
# step 2: pin flake:nixpkgs to unstable HEAD
# ----------------------------------------------------------------------------

wizard_pin_unstable() {
    printf '%s' "Pinning flake:nixpkgs to nixpkgs-unstable HEAD"
    run_cmd nix registry pin nixpkgs github:NixOS/nixpkgs/nixpkgs-unstable

    printf '%s' "Verifying the pin"
    # nix colorizes output (bold "Locked URL:") when it thinks stderr is a tty,
    # so strip ANSI escapes before parsing.
    rev="$(nix flake metadata nixpkgs 2>/dev/null \
        | sed $'s/\x1b\\[[0-9;]*m//g' \
        | awk '/^Locked URL:/{print $3}')"
    case "${rev}" in
        github:NixOS/nixpkgs/*)
            printf ' done (%s)\n' "${rev##*/}"
            ;;
        *)
            printf ' failed (locked to %s)\n' "${rev:-nothing}"
            exit 1
            ;;
    esac
}

# ----------------------------------------------------------------------------
# step 3a: Linux — profile upgrade timer
# ----------------------------------------------------------------------------

wizard_linux_timer() {
    local nix_src="${repo_path}/nix"
    local systemd_dir="${HOME}/.config/systemd/user"

    printf '%s' "Linking nix-unstable-update into ~/.local/bin"
    run_cmd mkdir -p "${HOME}/.local/bin"
    backup_if_real "${HOME}/.local/bin/nix-unstable-update"
    run_cmd ln -sf "${nix_src}/nix-unstable-update" "${HOME}/.local/bin/nix-unstable-update"

    printf '%s' "Installing systemd user units"
    run_cmd mkdir -p "${systemd_dir}"
    local unit
    for unit in nix-unstable-update.service nix-unstable-update.timer; do
        backup_if_real "${systemd_dir}/${unit}"
        run_cmd ln -sf "${nix_src}/${unit}" "${systemd_dir}/${unit}"
    done

    printf '%s' "Reloading systemd user units"
    run_cmd systemctl --user daemon-reload

    printf '%s' "Enabling + starting the daily timer"
    run_cmd systemctl --user enable --now nix-unstable-update.timer
}

# ----------------------------------------------------------------------------
# step 3b: macOS — home-manager flake + launchd auto-update
# ----------------------------------------------------------------------------

wizard_macos_flake() {
    local flake_dir="${repo_path}/home-manager"
    local nix_src="${repo_path}/nix"
    local agents_dir="${HOME}/Library/LaunchAgents"
    local plist_id="org.kayg.dotfiles.nix-unstable-update"
    local plist_src="${nix_src}/${plist_id}.plist"
    local plist_dst="${agents_dir}/${plist_id}.plist"

    printf '%s\n' ""
    printf '%s\n' "macOS: packages are managed by the home-manager flake, not by"
    printf '%s\n' "\`nix profile install\`. The flake lives in the repo at:"
    printf '%s\n' "  ${flake_dir}"

    printf '%s' "Checking the flake evaluates on this host"
    if run_cmd nix flake check "${flake_dir}" >/dev/null 2>&1; then
        printf '%s\n' "flake OK"
    fi

    # launchd daily update (the macOS equivalent of the Linux systemd timer):
    # re-pin unstable, flake update, home-manager switch, GC old generations.
    printf '%s' "Installing the daily auto-update LaunchAgent"
    run_cmd mkdir -p "${agents_dir}"
    backup_if_real "${plist_dst}"
    run_cmd ln -sf "${plist_src}" "${plist_dst}"
    run_cmd launchctl bootout "gui/$(id -u)/${plist_id}" 2>/dev/null || true
    run_cmd launchctl bootstrap "gui/$(id -u)" "${plist_dst}"
    run_cmd launchctl enable "gui/$(id -u)/${plist_id}"

    printf '%s\n' ""
    printf '%s\n' "To apply the package set on this Mac (the agent does this daily):"
    printf '%s\n' "  nix run home-manager/master -- switch --flake ${flake_dir}"
    printf '%s\n' ""
    printf '%s\n' "Rollback if a switch misbehaves:"
    printf '%s\n' "  home-manager generations   (then switch to a prior generation)"
    printf '%s\n' ""
    if ask_yes_no "Run the home-manager switch now?" "n"; then
        run_cmd nix run home-manager/master -- switch --flake "${flake_dir}"
        printf '%s\n' "home-manager switch complete."
    else
        printf '%s\n' "Skipping the switch (run the command above when ready)."
    fi
}

# ----------------------------------------------------------------------------
# step 4: verification
# ----------------------------------------------------------------------------

wizard_verify() {
    printf '%s' "nix binary"
    if run_cmd nix --version; then
        printf '%s\n' "  $(nix --version 2>/dev/null | head -1)"
    fi

    if [ "${wizard_os}" = "Linux" ]; then
        printf '%s' "nix-daemon"
        run_cmd systemctl is-active --quiet nix-daemon
        printf '%s\n' "  active"
        printf '%s' "unstable pin resolves"
        pin_rev="$(nix flake metadata nixpkgs 2>/dev/null \
            | sed $'s/\x1b\\[[0-9;]*m//g' \
            | awk '/^Revision:/{print $2}')"
        printf ' done (%s)\n' "${pin_rev:0:12}"
        printf '%s' "timer"
        run_cmd systemctl --user is-enabled --quiet nix-unstable-update.timer
        printf '%s\n' " enabled, next: $(systemctl --user list-timers nix-unstable-update.timer --no-pager 2>/dev/null | awk 'NR==2{print $2, $3}')"
    else
        printf '%s' "flake check"
        run_cmd nix flake check "${repo_path}/home-manager" >/dev/null 2>&1
        printf '%s\n' " ok"
    fi
}

# ----------------------------------------------------------------------------
# main flow
# ----------------------------------------------------------------------------

dot_nix_main() {
    printf '%s\n' "=============================================="
    printf '%s\n' " dot nix wizard — ${wizard_os} (${wizard_arch})"
    printf '%s\n' "=============================================="

    # -- arch notes ------------------------------------------------------------
    case "${wizard_os}:${wizard_arch}" in
        Darwin:arm64)
            printf '%s\n' "Apple Silicon (aarch64-darwin): nixpkgs unstable fully supported."
            ;;
        Darwin:x86_64)
            printf '%s\n' "NOTE: Intel Mac (x86_64-darwin): nixpkgs unstable dropped support."
            printf '%s\n' "      The last supporting branch is nixpkgs-26.05-darwin; pin"
            printf '%s\n' "      home-manager to release-26.05 to match. Continuing, but the"
            printf '%s\n' "      flake input may need adjusting."
            ;;
        Linux:*)
            printf '%s\n' "Linux (${wizard_arch}): standard unstable channel."
            ;;
    esac
    printf '%s\n' ""

    # -- existing install? -------------------------------------------------------
    if wizard_nix_present; then
        if wizard_is_determinate; then
            printf '%s\n' "Found: $(wizard_nix_version)"
            printf '%s\n' "Skipping install (Determinate Nix already present)."
        else
            printf '%s\n' "Found: $(wizard_nix_version)"
            printf '%s\n' "This is NOT Determinate Nix. The wizard will leave it alone;"
            printf '%s\n' "migrating installers is out of scope. Continuing with pin + wiring."
        fi
    else
        wizard_install_nix
    fi
    printf '%s\n' ""

    # -- resilience: every step below is idempotent. re-running the wizard on
    #    an already-set-up machine is safe: install is skipped (nix found),
    #    re-pinning refreshes to current HEAD, re-linking and re-enabling the
    #    timer/agent are no-ops-or-fixes. `dot setup nix` = converge to desired.

    # -- pin unstable (always: HEAD moves daily, this is cheap) -----------------
    wizard_pin_unstable
    printf '%s\n' ""

    # -- platform wiring (idempotent: re-linking + re-enable is harmless) -------
    if [ "${wizard_os}" = "Linux" ]; then
        wizard_linux_timer
    else
        wizard_macos_flake
    fi
    printf '%s\n' ""

    # -- verify ---------------------------------------------------------------------
    wizard_verify

    printf '%s\n' ""
    printf '%s\n' "nix setup complete."
}

# If sourced from the dot dispatcher, expose the setup/update entry points.
# If executed directly, run the wizard.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    dot_nix_main "$@"
fi