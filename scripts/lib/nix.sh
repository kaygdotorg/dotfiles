#!/usr/bin/env bash
#
# Nix bootstrap used by `dot setup nix`.
#
# The bootstrap is deliberately small and convergent:
#
#   1. Validate the host and find an existing Nix installation.
#   2. Install Nix only when it is missing, then configure the Numtide cache.
#   3. Point the Home Manager updater at this checkout and apply the locked
#      configuration with `nix-unstable-update --setup`.
#   4. Run the updater's read-only check and verify the Nix binary.
#
# An existing Nix installation is never reinstalled, its registry is never
# repinned, and its flake lock is never refreshed by this bootstrap. The
# updater owns update operations; this file only asks it to apply the current
# lock during setup.

set -o errexit
set -o nounset
set -o pipefail

# `scripts/dot` supplies these helpers. Keep standalone execution useful too.
if ! command -v run_cmd >/dev/null 2>&1; then
    run_cmd() {
        if [ "${#}" -eq 0 ]; then
            printf '%s\n' "No arguments provided. Exiting." >&2
            return 1
        fi
        if "$@"; then
            printf '%s\n' "  done"
        else
            printf '%s\n' "  FAILED: $*" >&2
            return 1
        fi
    }
fi

# Resolve the repository from this file when sourced outside scripts/dot. The
# parent dispatcher already has the canonical path, so use it when available.
wizard_source_path="${BASH_SOURCE[0]}"
wizard_script_dir="$(cd "$(dirname "${wizard_source_path}")" && pwd -P)"
if [ "${repo_path+x}" = x ] && [ -n "${repo_path}" ]; then
    wizard_repo_path="${repo_path}"
else
    wizard_repo_path="$(cd "${wizard_script_dir}/../.." && pwd -P)"
fi

# The profile path is the fallback used by both official and Determinate Nix
# installations. DOT_NIX_PROFILE_BIN is intentionally a narrow test seam for
# a fake installation; normal operation always uses the standard path.
wizard_profile_bin="${DOT_NIX_PROFILE_BIN:-/nix/var/nix/profiles/default/bin}"
export NIX_PROFILE_BIN="${wizard_profile_bin}"

# DOT_NIX_SYSTEM_DIR lets tests use a temporary system configuration directory.
# It is also useful for an administrator who has mounted /etc elsewhere. All
# root operations below still use fixed commands and fixed destination names.
wizard_system_dir="${DOT_NIX_SYSTEM_DIR:-/etc/nix}"
wizard_cache_name="dotfiles-cache.conf"
wizard_cache_file="${wizard_system_dir}/${wizard_cache_name}"
wizard_reload_pending_file="${wizard_system_dir}/dotfiles-cache.reload-pending"
wizard_nix_bin=""
wizard_yes=0
wizard_cache_changed=0
wizard_daemon_reloaded=0

# -----------------------------------------------------------------------------
# General helpers
# -----------------------------------------------------------------------------

wizard_usage() {
    printf '%s\n' "Usage: $(basename "${wizard_source_path}") [--yes]"
    printf '%s\n' "  --yes  install missing Nix without prompting"
}

wizard_parse_args() {
    wizard_yes=0
    while [ "${#}" -gt 0 ]; do
        case "${1}" in
            --yes)
                wizard_yes=1
                ;;
            -h|--help)
                wizard_usage
                return 1
                ;;
            *)
                printf '%s\n' "Unknown option: ${1}" >&2
                wizard_usage >&2
                return 1
                ;;
        esac
        shift
    done
}

wizard_find_nix() {
    local candidate

    candidate="$(command -v nix 2>/dev/null || true)"
    if [ -n "${candidate}" ] && [ -x "${candidate}" ]; then
        printf '%s\n' "${candidate}"
        return 0
    fi

    if [ -x "${wizard_profile_bin}/nix" ]; then
        printf '%s\n' "${wizard_profile_bin}/nix"
        return 0
    fi

    return 1
}

wizard_refresh_nix_bin() {
    wizard_nix_bin="$(wizard_find_nix || true)"
    [ -n "${wizard_nix_bin}" ]
}

wizard_nix_present() {
    wizard_find_nix >/dev/null 2>&1
}

wizard_nix_version() {
    local output

    if [ -z "${wizard_nix_bin}" ]; then
        printf '%s\n' "not installed"
        return 0
    fi

    output="$("${wizard_nix_bin}" --version 2>/dev/null || true)"
    if [ -z "${output}" ]; then
        printf '%s\n' "not installed"
    else
        printf '%s\n' "${output}" | sed -n '1p'
    fi
}

wizard_nix_version_number() {
    local output

    [ -n "${wizard_nix_bin}" ] || return 1
    output="$("${wizard_nix_bin}" --version 2>/dev/null || true)"
    # Nix prints its underlying version as the last dotted numeric token. This
    # also handles Determinate's `nix (Determinate Nix 3.22.1) 2.35.2` form.
    printf '%s\n' "${output}" | awk '
        {
            for (i = NF; i > 0; i--) {
                token = $i
                sub(/[^0-9.].*$/, "", token)
                if (token ~ /^[0-9]+[.][0-9]+([.][0-9]+)?$/) {
                    print token
                    exit
                }
            }
        }
    '
}

wizard_nix_meets_minimum() {
    local version major minor remainder

    version="$(wizard_nix_version_number || true)"
    [ -n "${version}" ] || return 1
    major="${version%%.*}"
    remainder="${version#*.}"
    minor="${remainder%%.*}"

    if [ "${major}" -gt 2 ]; then
        return 0
    fi
    if [ "${major}" -eq 2 ] && [ "${minor}" -ge 35 ]; then
        return 0
    fi
    return 1
}

wizard_require_supported_nix() {
    if wizard_nix_meets_minimum; then
        return 0
    fi

    printf '%s\n' "Nix 2.35 or newer is required; found $(wizard_nix_version)." >&2
    printf '%s\n' "Upgrade Nix first, then rerun setup; no cache or Home Manager changes were made." >&2
    return 1
}

wizard_is_determinate() {
    [ -n "${wizard_nix_bin}" ] || return 1
    if "${wizard_nix_bin}" --version 2>/dev/null | grep -qi determinate; then
        return 0
    fi
    return 1
}

wizard_prepare_nix_path() {
    local nix_dir

    [ -n "${wizard_nix_bin}" ] || return 0
    case "${wizard_nix_bin}" in
        */*)
            nix_dir="${wizard_nix_bin%/*}"
            case ":${PATH:-}:" in
                *":${nix_dir}:"*) ;;
                *) PATH="${nix_dir}:${PATH:-}"; export PATH ;;
            esac
            ;;
    esac
}

wizard_run_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
        return
    fi

    if ! command -v sudo >/dev/null 2>&1; then
        printf '%s\n' "Root privileges are required; sudo is not available." >&2
        return 1
    fi

    # Do not preserve arbitrary caller environment variables and do not use
    # `sh -c`: root receives only this fixed command and its arguments.
    sudo "$@"
}

wizard_temp_file() {
    mktemp "${TMPDIR:-/tmp}/dotfiles-nix.XXXXXX"
}

# -----------------------------------------------------------------------------
# Host detection and installation
# -----------------------------------------------------------------------------

wizard_detect_host() {
    wizard_os="$(uname -s)"
    wizard_arch="$(uname -m)"

    case "${wizard_os}:${wizard_arch}" in
        Darwin:arm64|Linux:x86_64|Linux:aarch64|Linux:arm64)
            return 0
            ;;
        *)
            printf '%s\n' "Unsupported Nix host: ${wizard_os} ${wizard_arch}." >&2
            printf '%s\n' "Supported hosts: Darwin arm64, Linux x86_64, or Linux arm64." >&2
            return 1
            ;;
    esac
}

wizard_expected_user() {
    printf '%s\n' "kayg"
}

wizard_expected_home() {
    case "${wizard_os}" in
        Darwin) printf '%s\n' "/Users/kayg" ;;
        Linux) printf '%s\n' "/home/kayg" ;;
        *) return 1 ;;
    esac
}

wizard_preflight_identity() {
    local current_user expected_user expected_home

    current_user="$(id -un 2>/dev/null || true)"
    expected_user="$(wizard_expected_user)"
    expected_home="$(wizard_expected_home)"

    if [ "${current_user}" != "${expected_user}" ]; then
        printf '%s\n' "Nix setup must run as ${expected_user}; current user is ${current_user:-unknown}." >&2
        return 1
    fi
    if [ "${HOME:-}" != "${expected_home}" ]; then
        printf '%s\n' "Nix setup requires HOME=${expected_home}; current HOME is ${HOME:-unset}." >&2
        return 1
    fi
    return 0
}

wizard_preflight_existing_nix() {
    wizard_detect_host
    if ! wizard_refresh_nix_bin; then
        printf '%s\n' "Nix is required before installing the cache configuration." >&2
        return 1
    fi
    wizard_require_supported_nix
    wizard_prepare_nix_path
}

wizard_ask_yes_no() {
    local prompt="${1}" answer

    # A missing controlling terminal must resolve to no. Piped stdin is never
    # treated as affirmative input because installation changes the system.
    if [ ! -t 0 ] && [ ! -t 1 ] && [ ! -t 2 ]; then
        return 1
    fi

    printf '%s [n]: ' "${prompt}" >&2
    if ! IFS= read -r answer < /dev/tty; then
        return 1
    fi

    case "${answer}" in
        y|Y|yes|Yes|YES)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

wizard_confirm_install() {
    if [ "${wizard_yes}" -eq 1 ]; then
        return 0
    fi

    if wizard_ask_yes_no "Install Determinate Nix now?"; then
        return 0
    fi

    printf '%s\n' "Nix installation was not confirmed; setup stopped without installing Nix." >&2
    printf '%s\n' "Re-run interactively and answer yes, or pass --yes explicitly." >&2
    return 1
}

wizard_install_nix() {
    local installer_file installer_status

    printf '%s\n' "  Nix is not installed. The Determinate installer will be downloaded."
    if ! wizard_confirm_install; then
        return 1
    fi

    if ! command -v curl >/dev/null 2>&1; then
        printf '%s\n' "curl is required to download the Nix installer." >&2
        return 1
    fi

    installer_file="$(wizard_temp_file)"
    if ! curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
        "https://install.determinate.systems/nix" --output "${installer_file}"; then
        rm -f "${installer_file}"
        printf '%s\n' "Nix installer download failed." >&2
        return 1
    fi
    if [ ! -s "${installer_file}" ]; then
        rm -f "${installer_file}"
        printf '%s\n' "Nix installer download was empty." >&2
        return 1
    fi

    # Download and execution are separate commands so a successful `sh` cannot
    # mask a failed curl pipeline. The installer receives no caller `-E` env.
    if [ "${wizard_os}" = "Linux" ] && [ "$(id -u)" -ne 0 ]; then
        if wizard_run_root /bin/sh "${installer_file}" install --no-confirm; then
            installer_status=0
        else
            installer_status=$?
        fi
    else
        if /bin/sh "${installer_file}" install --no-confirm; then
            installer_status=0
        else
            installer_status=$?
        fi
    fi
    rm -f "${installer_file}"

    if [ "${installer_status}" -ne 0 ]; then
        printf '%s\n' "Nix installer failed (status ${installer_status})." >&2
        return "${installer_status}"
    fi

    # Make the newly installed binary available in this shell if the installer
    # created the standard profile. If it did not, the refresh below gives a
    # clear failure rather than silently continuing without Nix.
    if [ -f "${wizard_profile_bin}/../etc/profile.d/nix-daemon.sh" ]; then
        # shellcheck disable=SC1091
        . "${wizard_profile_bin}/../etc/profile.d/nix-daemon.sh"
    fi
    if ! wizard_refresh_nix_bin; then
        printf '%s\n' "Nix installation completed but its binary was not found." >&2
        return 1
    fi
    wizard_prepare_nix_path
    printf '%s\n' "  Installed: $(wizard_nix_version)"
}

# -----------------------------------------------------------------------------
# Numtide cache configuration
# -----------------------------------------------------------------------------

wizard_cache_config_path() {
    if wizard_is_determinate; then
        printf '%s\n' "${wizard_system_dir}/nix.custom.conf"
    else
        printf '%s\n' "${wizard_system_dir}/nix.conf"
    fi
}

wizard_atomic_root_install() {
    local source_file="${1}" destination_file="${2}" temporary_file

    if ! wizard_run_root mkdir -p "$(dirname "${destination_file}")"; then
        return 1
    fi

    # The parent directory is /etc/nix (root-owned on a real install), so this
    # temporary name cannot be redirected by an unprivileged user. `install`
    # creates a root-owned 0644 file; rename is atomic on the same filesystem.
    temporary_file="${destination_file}.dotfiles.tmp.$$"
    if ! wizard_run_root install -m 0644 "${source_file}" "${temporary_file}"; then
        wizard_run_root rm -f "${temporary_file}" >/dev/null 2>&1 || true
        return 1
    fi
    if ! wizard_run_root mv -f "${temporary_file}" "${destination_file}"; then
        wizard_run_root rm -f "${temporary_file}" >/dev/null 2>&1 || true
        return 1
    fi
    return 0
}

wizard_mark_reload_pending() {
    local staged_file

    if [ -f "${wizard_reload_pending_file}" ]; then
        wizard_cache_changed=1
        return 0
    fi

    staged_file="$(wizard_temp_file)"
    printf '%s\n' 'dotfiles cache configuration requires a daemon reload' > "${staged_file}"
    if ! wizard_atomic_root_install "${staged_file}" "${wizard_reload_pending_file}"; then
        rm -f "${staged_file}"
        printf '%s\n' "Could not create ${wizard_reload_pending_file}." >&2
        return 1
    fi
    rm -f "${staged_file}"
    wizard_cache_changed=1
}

wizard_install_cache_file() {
    local source_file="${wizard_repo_path}/nix/cache.conf" staged_file

    if [ ! -f "${source_file}" ]; then
        printf '%s\n' "Missing cache definition: ${source_file}" >&2
        return 1
    fi

    if [ -f "${wizard_cache_file}" ] && cmp -s "${source_file}" "${wizard_cache_file}"; then
        printf '%s\n' "  Cache file already matches (skip)."
        return 0
    fi

    # Record the pending reload before changing any root-owned cache file. A
    # failed daemon restart leaves this marker for the next setup invocation.
    wizard_mark_reload_pending

    staged_file="$(wizard_temp_file)"
    if ! cp "${source_file}" "${staged_file}"; then
        rm -f "${staged_file}"
        printf '%s\n' "Could not stage the cache definition." >&2
        return 1
    fi
    if ! wizard_atomic_root_install "${staged_file}" "${wizard_cache_file}"; then
        rm -f "${staged_file}"
        printf '%s\n' "Could not install ${wizard_cache_file}." >&2
        return 1
    fi
    rm -f "${staged_file}"
    wizard_cache_changed=1
    printf '%s\n' "  Installed ${wizard_cache_file}."
}

wizard_install_cache_include() {
    local config_file="${1}" include_line staged_file

    include_line="!include ${wizard_cache_file}"
    staged_file="$(wizard_temp_file)"

    # Keep every existing setting and collapse duplicate copies of our exact
    # include line. Missing files receive only the include required by us.
    if [ -f "${config_file}" ]; then
        if ! awk -v include_line="${include_line}" '
            $0 == include_line {
                if (seen) next
                seen = 1
            }
            { print }
            END {
                if (!seen) print include_line
            }
        ' "${config_file}" > "${staged_file}"; then
            rm -f "${staged_file}"
            printf '%s\n' "Could not stage ${config_file}." >&2
            return 1
        fi
    else
        printf '%s\n' "${include_line}" > "${staged_file}"
    fi

    if [ -f "${config_file}" ] && cmp -s "${staged_file}" "${config_file}"; then
        rm -f "${staged_file}"
        printf '%s\n' "  Cache include already present in ${config_file} (skip)."
        return 0
    fi

    # If this is the first changed target, the marker is written before the
    # root-owned config replacement. It is idempotent when cache.conf changed
    # first or when a previous restart failed.
    wizard_mark_reload_pending

    if ! wizard_atomic_root_install "${staged_file}" "${config_file}"; then
        rm -f "${staged_file}"
        printf '%s\n' "Could not install ${config_file}." >&2
        return 1
    fi
    rm -f "${staged_file}"
    wizard_cache_changed=1
    printf '%s\n' "  Added the cache include to ${config_file}."
}

wizard_systemd_unit_installed() {
    local unit="${1}" state listing

    state="$(systemctl show "${unit}" --property=LoadState 2>/dev/null || true)"
    case "${state}" in
        *"LoadState=loaded"*)
            return 0
            ;;
    esac

    listing="$(systemctl list-unit-files "${unit}" --no-legend 2>/dev/null || true)"
    case "${listing}" in
        *"${unit}"*)
            return 0
            ;;
    esac
    return 1
}

wizard_restart_linux_daemon() {
    local unit

    if ! command -v systemctl >/dev/null 2>&1; then
        printf '%s\n' "  No systemd command found; daemon restart skipped."
        return 0
    fi

    # Both installers use nix-daemon.service for Nix itself. Newer Determinate
    # installs may expose only determinate-nixd.service, so inspect before
    # restarting instead of guessing or starting an unrelated service.
    for unit in nix-daemon.service determinate-nixd.service; do
        if wizard_systemd_unit_installed "${unit}"; then
            printf '%s\n' "  Restarting ${unit} after cache change."
            if ! wizard_run_root systemctl restart "${unit}"; then
                printf '%s\n' "Could not restart ${unit}." >&2
                return 1
            fi
            wizard_daemon_reloaded=1
            return 0
        fi
    done

    printf '%s\n' "  No installed Nix systemd daemon found; restart skipped."
}

wizard_launchd_label_installed() {
    local label listing

    if ! command -v launchctl >/dev/null 2>&1; then
        return 1
    fi

    for label in systems.determinate.nix-daemon org.nixos.nix-daemon; do
        if launchctl print "system/${label}" >/dev/null 2>&1; then
            printf '%s\n' "${label}"
            return 0
        fi
    done

    listing="$(launchctl list 2>/dev/null || true)"
    for label in systems.determinate.nix-daemon org.nixos.nix-daemon; do
        case "${listing}" in
            *"${label}"*)
                printf '%s\n' "${label}"
                return 0
                ;;
        esac
    done
    return 1
}

wizard_restart_darwin_daemon() {
    local label

    if ! label="$(wizard_launchd_label_installed)"; then
        printf '%s\n' "  No installed Nix launchd daemon found; restart skipped."
        return 0
    fi

    printf '%s\n' "  Restarting ${label} after cache change."
    if ! wizard_run_root launchctl kickstart -k "system/${label}"; then
        printf '%s\n' "Could not restart ${label}." >&2
        return 1
    fi
    wizard_daemon_reloaded=1
}

wizard_restart_daemon_if_needed() {
    [ "${wizard_cache_changed}" -eq 1 ] || return 0

    case "${wizard_os:-}" in
        Linux)
            wizard_restart_linux_daemon
            ;;
        Darwin)
            wizard_restart_darwin_daemon
            ;;
        *)
            printf '%s\n' "  Daemon restart skipped on an unsupported host."
            ;;
    esac

    if [ "${wizard_daemon_reloaded}" -eq 1 ]; then
        if ! wizard_run_root rm -f "${wizard_reload_pending_file}"; then
            printf '%s\n' "Could not clear ${wizard_reload_pending_file}." >&2
            return 1
        fi
    fi
}

dot_nix_install_cache() {
    wizard_system_dir="${DOT_NIX_SYSTEM_DIR:-/etc/nix}"
    wizard_cache_file="${wizard_system_dir}/${wizard_cache_name}"
    wizard_reload_pending_file="${wizard_system_dir}/dotfiles-cache.reload-pending"
    wizard_cache_changed=0
    wizard_daemon_reloaded=0

    if [ -f "${wizard_reload_pending_file}" ]; then
        wizard_cache_changed=1
        printf '%s\n' "  Pending daemon reload found; retrying it."
    fi

    if [ -z "${wizard_nix_bin}" ]; then
        wizard_refresh_nix_bin >/dev/null 2>&1 || true
    fi

    wizard_config_file="$(wizard_cache_config_path)"
    wizard_install_cache_file
    wizard_install_cache_include "${wizard_config_file}"
    wizard_restart_daemon_if_needed
}

# -----------------------------------------------------------------------------
# Home Manager updater wiring and legacy cleanup
# -----------------------------------------------------------------------------

wizard_update_helper="${wizard_repo_path}/nix/nix-unstable-update"

wizard_backup_conflict() {
    local target="${1}" backup timestamp attempt

    timestamp="$(date +%Y%m%d%H%M%S)"
    attempt=0
    backup="${target}.bak.${timestamp}.$$"
    while [ -e "${backup}" ] || [ -L "${backup}" ]; do
        attempt=$((attempt + 1))
        backup="${target}.bak.${timestamp}.$$.${attempt}"
    done
    if ! mv "${target}" "${backup}"; then
        printf '%s\n' "Could not preserve conflicting ${target}." >&2
        return 1
    fi
    printf '%s\n' "  Preserved conflicting ${target} as ${backup}."
}

wizard_ensure_update_link() {
    local destination="${HOME}/.local/bin/dotfiles-nix-update" temporary_file existing

    if [ ! -f "${wizard_update_helper}" ]; then
        printf '%s\n' "Missing Nix updater: ${wizard_update_helper}" >&2
        return 1
    fi

    mkdir -p "${HOME}/.local/bin"
    if [ -L "${destination}" ]; then
        existing="$(readlink "${destination}" 2>/dev/null || true)"
        if [ "${existing}" = "${wizard_update_helper}" ]; then
            printf '%s\n' "  Updater link already points to this checkout (skip)."
            return 0
        fi
        wizard_backup_conflict "${destination}"
    elif [ -e "${destination}" ]; then
        wizard_backup_conflict "${destination}"
    fi

    temporary_file="${destination}.dotfiles.tmp.$$"
    rm -f "${temporary_file}"
    if ! ln -s "${wizard_update_helper}" "${temporary_file}"; then
        rm -f "${temporary_file}"
        printf '%s\n' "Could not create the Nix updater link." >&2
        return 1
    fi
    if ! mv -f "${temporary_file}" "${destination}"; then
        rm -f "${temporary_file}"
        printf '%s\n' "Could not install ${destination}." >&2
        return 1
    fi
    printf '%s\n' "  Linked ${destination} to this checkout."
}

wizard_remove_our_symlink() {
    local destination="${1}" expected="${2}"

    if wizard_symlink_matches "${destination}" "${expected}"; then
        rm -f "${destination}"
        printf '%s\n' "  Removed legacy symlink ${destination}."
    fi
}

wizard_symlink_matches() {
    local destination="${1}" expected="${2}" existing

    if [ ! -L "${destination}" ]; then
        return 1
    fi
    existing="$(readlink "${destination}" 2>/dev/null || true)"
    [ "${existing}" = "${expected}" ]
}

wizard_cleanup_legacy_schedule() {
    local old_link

    if [ "${wizard_os}" = "Linux" ]; then
        old_link="${HOME}/.config/systemd/user/nix-unstable-update.timer"
        if wizard_symlink_matches "${old_link}" \
            "${wizard_repo_path}/nix/nix-unstable-update.timer"; then
            # The old unit belongs to this repository, but disabling it is
            # harmless if a prior setup left it loaded after a path move.
            systemctl --user disable --now nix-unstable-update.timer >/dev/null 2>&1 || true
            wizard_remove_our_symlink "${old_link}" \
                "${wizard_repo_path}/nix/nix-unstable-update.timer"
        fi
        wizard_remove_our_symlink "${HOME}/.local/bin/nix-unstable-update" \
            "${wizard_repo_path}/nix/nix-unstable-update"
        wizard_remove_our_symlink "${HOME}/.config/systemd/user/nix-unstable-update.service" \
            "${wizard_repo_path}/nix/nix-unstable-update.service"
    elif [ "${wizard_os}" = "Darwin" ]; then
        old_link="${HOME}/Library/LaunchAgents/org.kayg.dotfiles.nix-unstable-update.plist"
        if wizard_symlink_matches "${old_link}" \
            "${wizard_repo_path}/nix/org.kayg.dotfiles.nix-unstable-update.plist"; then
            if command -v launchctl >/dev/null 2>&1; then
                launchctl bootout "gui/$(id -u)/org.kayg.dotfiles.nix-unstable-update" \
                    >/dev/null 2>&1 || true
            fi
            wizard_remove_our_symlink "${old_link}" \
                "${wizard_repo_path}/nix/org.kayg.dotfiles.nix-unstable-update.plist"
        fi
    fi
}

wizard_run_update_helper() {
    local mode="${1}"

    if [ ! -f "${wizard_update_helper}" ]; then
        printf '%s\n' "Missing Nix updater: ${wizard_update_helper}" >&2
        return 1
    fi

    if [ -x "${wizard_update_helper}" ]; then
        "${wizard_update_helper}" "${mode}"
    else
        /bin/bash "${wizard_update_helper}" "${mode}"
    fi
}

# -----------------------------------------------------------------------------
# Bootstrap flow
# -----------------------------------------------------------------------------

dot_nix_main() {
    wizard_parse_args "$@"
    wizard_detect_host
    wizard_preflight_identity

    printf '%s\n' "=============================================="
    printf '%s\n' " dot nix bootstrap — ${wizard_os} (${wizard_arch})"
    printf '%s\n' "=============================================="

    printf '%s\n' "Step 1/4: Detecting Nix"
    if wizard_refresh_nix_bin; then
        printf '%s\n' "  Found: $(wizard_nix_version)"
        printf '%s\n' "  Install (skip: Nix is already present)."
    else
        wizard_install_nix
    fi
    wizard_require_supported_nix
    wizard_prepare_nix_path

    printf '%s\n' "Step 2/4: Configuring the Numtide binary cache"
    dot_nix_install_cache

    printf '%s\n' "Step 3/4: Applying the locked Home Manager configuration"
    # Home Manager declares the recurring schedule. The link must exist before
    # activation so the generated service points at the current checkout.
    wizard_ensure_update_link
    wizard_prepare_nix_path
    printf '%s\n' "  Running ${wizard_update_helper} --setup"
    wizard_run_update_helper --setup
    wizard_cleanup_legacy_schedule

    printf '%s\n' "Step 4/4: Verifying Nix and the locked configuration"
    if ! "${wizard_nix_bin}" --version; then
        printf '%s\n' "Nix version verification failed." >&2
        return 1
    fi
    printf '%s\n' "  Running ${wizard_update_helper} --check"
    wizard_run_update_helper --check

    printf '%s\n' "nix setup complete."
}

# The cache installer sources this file and calls dot_nix_install_cache. Direct
# execution runs the complete four-step bootstrap.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    dot_nix_main "$@"
fi
