#!/usr/bin/env bash
# Official user-local agent installers; sourced by scripts/dot.

agents_prepare() {
    local platform
    platform="$(uname -s):$(uname -m)"
    case "${platform}" in
        Darwin:arm64|Darwin:x86_64|Linux:x86_64|Linux:aarch64|Linux:arm64) ;;
        *) printf 'Unsupported agent platform: %s\n' "${platform}" >&2; return 1 ;;
    esac
    if [ "$(id -u)" -eq 0 ]; then
        printf '%s\n' 'Run agent installation as your normal user, without sudo.' >&2
        return 1
    fi
    # Prefer the writable native binaries even while a legacy Nix package
    # still exists. Never invoke a self-updater against the Nix store.
    export PATH="${HOME}/.local/bin:${PATH}"
    mkdir -p "${HOME}/.local/bin"
}

agents_native_present() {
    local binary="${HOME}/.local/bin/${1}" resolved
    [ -x "${binary}" ] || return 1
    resolved="$(realpath "${binary}")"
    case "${resolved}" in /nix/store/*) return 1 ;; esac
}

agents_install() (
    # A subshell keeps cleanup local even when run_cmd aborts on failure.
    local agent="${1}" installer url interpreter binary resolved
    binary="${HOME}/.local/bin/${agent}"
    if [ -L "${binary}" ]; then
        resolved="$(realpath "${binary}" 2>/dev/null || true)"
        case "${resolved}" in
            /nix/store/*) rm -f "${binary}" ;;
        esac
    fi
    if [ -e "${binary}" ] && [ ! -f "${binary}" ]; then
        printf 'Cannot install %s: %s is not a regular file.\n' "${agent}" "${binary}" >&2
        return 1
    fi
    case "${agent}" in
        claude) url=https://claude.ai/install.sh; interpreter=/bin/bash ;;
        codex) url=https://chatgpt.com/codex/install.sh; interpreter=/bin/sh ;;
        agy) url=https://antigravity.google/cli/install.sh; interpreter=/bin/bash ;;
        *) return 2 ;;
    esac
    check_if_installed_and_exit curl
    installer="$(mktemp "${TMPDIR:-/tmp}/dot-agents.XXXXXX")"
    trap 'rm -f "${installer}"' EXIT
    printf 'Downloading official %s installer' "${agent}"
    run_cmd curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
        "${url}" --output "${installer}"
    if [ ! -s "${installer}" ]; then
        printf 'The %s installer download was empty.\n' "${agent}" >&2
        return 1
    fi
    printf 'Installing %s' "${agent}"
    run_cmd "${interpreter}" "${installer}"
    if ! agents_native_present "${agent}"; then
        printf 'Installer completed but %s is not an executable installation outside the Nix store.\n' "${binary}" >&2
        return 1
    fi
)

agents_manage() {
    local mode="${1}" agent
    agents_prepare
    for agent in claude codex agy; do
        if ! agents_native_present "${agent}"; then
            agents_install "${agent}"
        elif [ "${mode}" = setup ]; then
            printf '%s already installed at %s/.local/bin/%s\n' "${agent}" "${HOME}" "${agent}"
        elif [ "${agent}" = codex ]; then
            # OpenAI documents rerunning its native installer for upgrades.
            agents_install codex
        else
            printf 'Updating %s' "${agent}"
            run_cmd "${HOME}/.local/bin/${agent}" update
        fi
    done
    printf '%s\n' 'Agents ready in ~/.local/bin. Run claude, codex, or agy to sign in.'
}
