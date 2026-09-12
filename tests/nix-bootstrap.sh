#!/usr/bin/env bash
# Exercise the Nix bootstrap without touching the host's Nix, HOME, sudo, or
# /etc. Every command that could otherwise inspect or mutate system state is a
# temporary fake in this test's PATH.

set -o errexit
set -o nounset
set -o pipefail

test_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-nix-test.XXXXXX")"
trap 'rm -rf "${test_tmp}"' EXIT HUP INT TERM

fail() {
    printf 'FAIL: %s\n' "${1}" >&2
    exit 1
}

assert_file_contains() {
    local pattern="${1}" file="${2}"
    grep -F -- "${pattern}" "${file}" >/dev/null || fail "${file} lacks ${pattern}"
}

assert_file_not_contains() {
    local pattern="${1}" file="${2}"
    if grep -F -- "${pattern}" "${file}" >/dev/null 2>&1; then
        fail "${file} unexpectedly contains ${pattern}"
    fi
}

assert_equal() {
    [ "${1}" = "${2}" ] || fail "expected '${1}', got '${2}'"
}

make_fake_repo() {
    local destination="${1}"
    mkdir -p "${destination}/scripts/lib" "${destination}/nix"
    cp "${test_repo}/scripts/lib/nix.sh" "${destination}/scripts/lib/nix.sh"
    cp "${test_repo}/nix/cache.conf" "${destination}/nix/cache.conf"
    cp "${test_repo}/nix/install-cache" "${destination}/nix/install-cache"
    chmod +x "${destination}/nix/install-cache"
    cat > "${destination}/scripts/bootstrap-fixture" <<'EOF'
#!/usr/bin/env bash
set -o errexit
set -o nounset
fixture_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# Keep the fixture isolated while production retains its fixed identity guard.
. "${fixture_dir}/lib/nix.sh"
wizard_expected_home() {
    printf '%s\n' "${HOME}"
}
dot_nix_main "$@"
EOF
    chmod +x "${destination}/scripts/bootstrap-fixture"
    cat > "${destination}/nix/nix-unstable-update" <<'EOF'
#!/usr/bin/env bash
set -o errexit
set -o nounset
printf '%s\n' "${1}" >> "${FAKE_HELPER_LOG}"
case "${1}" in
    --setup|--check) printf 'fake updater %s\n' "${1}" ;;
    *) exit 2 ;;
esac
EOF
    chmod +x "${destination}/nix/nix-unstable-update"
}

make_fake_bin() {
    local destination="${1}"
    mkdir -p "${destination}"

    cat > "${destination}/uname" <<'EOF'
#!/usr/bin/env bash
case "${1}" in
    -s) printf '%s\n' "${FAKE_UNAME_S:-Darwin}" ;;
    -m) printf '%s\n' "${FAKE_UNAME_M:-arm64}" ;;
    *) exit 1 ;;
esac
EOF

    cat > "${destination}/nix" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_NIX_LOG}"
case "${1:-}" in
    --version)
        printf '%s\n' "${FAKE_NIX_VERSION:-nix (Nix) 2.35.2}"
        ;;
    *)
        printf 'unexpected fake nix command: %s\n' "$*" >&2
        exit 2
        ;;
esac
EOF

    cat > "${destination}/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >> "${FAKE_SUDO_LOG}"
exec "$@"
EOF

    cat > "${destination}/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_CURL_LOG}"
if [ "${FAKE_CURL_STATUS:-0}" -ne 0 ]; then
    exit "${FAKE_CURL_STATUS}"
fi
output=''
previous=''
for argument in "$@"; do
    if [ "${previous}" = "--output" ]; then
        output="${argument}"
    fi
    previous="${argument}"
done
if [ -n "${output}" ]; then
    printf '%s\n' '# fake installer' > "${output}"
fi
EOF

    cat > "${destination}/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_SYSTEMCTL_LOG}"
case "${1:-}" in
    show)
        if [ "${FAKE_SYSTEMCTL_LOADED:-0}" -eq 1 ] && [ "${2:-}" = "nix-daemon.service" ]; then
            printf '%s\n' 'LoadState=loaded'
        else
            printf '%s\n' 'LoadState=not-found'
        fi
        ;;
    list-unit-files)
        if [ "${FAKE_SYSTEMCTL_LOADED:-0}" -eq 1 ] && [ "${2:-}" = "nix-daemon.service" ]; then
            printf '%s\n' 'nix-daemon.service enabled'
        fi
        ;;
    restart)
        exit "${FAKE_SYSTEMCTL_RESTART_STATUS:-0}"
        ;;
    --user)
        # Legacy timer probes intentionally report that the old timer is gone.
        if [ "${2:-}" = "is-enabled" ]; then
            exit 1
        fi
        ;;
esac
EOF

    cat > "${destination}/launchctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_LAUNCHCTL_LOG}"
# No Nix daemon is installed in the Darwin fake environment.
case "${1:-}" in
    print|list) exit 1 ;;
    *) exit 0 ;;
esac
EOF

    chmod +x "${destination}"/*
}

run_bootstrap() {
    local fake_repo="${1}" fake_home="${2}" fake_system="${3}" fake_bin="${4}"
    local fake_profile_bin="${DOT_NIX_PROFILE_BIN:-${fake_repo}/missing-profile}"
    shift 4
    mkdir -p "${fake_home}"
    HOME="${fake_home}" \
    DOT_NIX_SYSTEM_DIR="${fake_system}" \
    DOT_NIX_PROFILE_BIN="${fake_profile_bin}" \
    FAKE_HELPER_LOG="${fake_home}/helper.log" \
    FAKE_NIX_LOG="${fake_home}/nix.log" \
    FAKE_SUDO_LOG="${fake_home}/sudo.log" \
    FAKE_CURL_LOG="${fake_home}/curl.log" \
    FAKE_SYSTEMCTL_LOG="${fake_home}/systemctl.log" \
    FAKE_LAUNCHCTL_LOG="${fake_home}/launchctl.log" \
    PATH="${fake_bin}:/usr/bin:/bin" \
    FAKE_UNAME_S="${FAKE_UNAME_S:-Darwin}" \
    FAKE_UNAME_M="${FAKE_UNAME_M:-arm64}" \
    FAKE_NIX_VERSION="${FAKE_NIX_VERSION:-nix (Nix) 2.35.2}" \
    FAKE_SYSTEMCTL_LOADED="${FAKE_SYSTEMCTL_LOADED:-0}" \
    FAKE_SYSTEMCTL_RESTART_STATUS="${FAKE_SYSTEMCTL_RESTART_STATUS:-0}" \
    FAKE_CURL_STATUS="${FAKE_CURL_STATUS:-0}" \
    /bin/bash "${fake_repo}/scripts/bootstrap-fixture" "$@"
}

new_case() {
    local name="${1}"
    CASE_ROOT="${test_tmp}/${name}"
    mkdir -p "${CASE_ROOT}"
    FAKE_UNAME_S="Darwin"
    FAKE_UNAME_M="arm64"
    FAKE_NIX_VERSION="nix (Nix) 2.35.2"
    FAKE_SYSTEMCTL_LOADED=0
    FAKE_SYSTEMCTL_RESTART_STATUS=0
    FAKE_CURL_STATUS=0
    make_fake_repo "${CASE_ROOT}/repo"
    make_fake_bin "${CASE_ROOT}/bin"
}

# Existing Nix is convergent: setup links the updater, applies/checks the
# current lock, and never asks Nix to pin a registry or update a flake.
new_case existing
run_bootstrap "${CASE_ROOT}/repo" "${CASE_ROOT}/home" "${CASE_ROOT}/etc/nix" "${CASE_ROOT}/bin" > "${CASE_ROOT}/output"
assert_file_contains 'Step 1/4: Detecting Nix' "${CASE_ROOT}/output"
assert_file_contains 'Install (skip: Nix is already present).' "${CASE_ROOT}/output"
assert_file_contains 'Step 4/4: Verifying Nix and the locked configuration' "${CASE_ROOT}/output"
assert_file_contains --setup "${CASE_ROOT}/home/helper.log"
assert_file_contains --check "${CASE_ROOT}/home/helper.log"
assert_file_not_contains 'registry' "${CASE_ROOT}/home/nix.log"
assert_file_not_contains 'flake' "${CASE_ROOT}/home/nix.log"
[ -L "${CASE_ROOT}/home/.local/bin/dotfiles-nix-update" ] || fail 'updater link missing'
expected_helper="$(cd "${CASE_ROOT}/repo/nix" && pwd -P)/nix-unstable-update"
assert_equal "${expected_helper}" "$(readlink "${CASE_ROOT}/home/.local/bin/dotfiles-nix-update")"
assert_file_contains 'https://cache.numtide.com' "${CASE_ROOT}/etc/nix/dotfiles-cache.conf"
assert_file_contains 'extra-trusted-substituters = https://cache.numtide.com' "${CASE_ROOT}/etc/nix/dotfiles-cache.conf"
assert_file_contains 'niks3.numtide.com-1:' "${CASE_ROOT}/etc/nix/dotfiles-cache.conf"
assert_file_contains '!include ' "${CASE_ROOT}/etc/nix/nix.conf"
first_sudo_lines="$(wc -l < "${CASE_ROOT}/home/sudo.log")"
run_bootstrap "${CASE_ROOT}/repo" "${CASE_ROOT}/home" "${CASE_ROOT}/etc/nix" "${CASE_ROOT}/bin" > "${CASE_ROOT}/second-output"
second_sudo_lines="$(wc -l < "${CASE_ROOT}/home/sudo.log")"
assert_equal "${first_sudo_lines}" "${second_sudo_lines}"

# Identity is checked before install/cache/updater work. The fake id reports a
# root caller, while the fixture HOME override keeps the rest of this case
# isolated from the production /Users/kayg path.
new_case wrong-identity
cat > "${CASE_ROOT}/bin/id" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    -un) printf '%s\n' root ;;
    -u) printf '%s\n' 0 ;;
    *) exit 1 ;;
esac
EOF
chmod +x "${CASE_ROOT}/bin/id"
if run_bootstrap "${CASE_ROOT}/repo" "${CASE_ROOT}/home" "${CASE_ROOT}/etc/nix" "${CASE_ROOT}/bin" > "${CASE_ROOT}/output" 2>&1; then
    fail 'wrong identity unexpectedly passed preflight'
fi
assert_file_contains 'must run as kayg' "${CASE_ROOT}/output"
[ ! -e "${CASE_ROOT}/etc/nix" ] || fail 'wrong identity changed system configuration'
[ ! -e "${CASE_ROOT}/home/helper.log" ] || fail 'wrong identity ran the updater'

# Exercise the production expected-HOME branch directly. The fake id keeps the
# username valid, so this failure proves the HOME guard runs before writes.
new_case wrong-home
cat > "${CASE_ROOT}/bin/id" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    -un) printf '%s\n' kayg ;;
    -u) printf '%s\n' 501 ;;
    *) exit 1 ;;
esac
EOF
chmod +x "${CASE_ROOT}/bin/id"
mkdir -p "${CASE_ROOT}/home"
if HOME="${CASE_ROOT}/home" DOT_NIX_SYSTEM_DIR="${CASE_ROOT}/etc/nix" \
DOT_NIX_PROFILE_BIN="${CASE_ROOT}/missing-profile" \
FAKE_HELPER_LOG="${CASE_ROOT}/home/helper.log" FAKE_NIX_LOG="${CASE_ROOT}/home/nix.log" \
FAKE_SUDO_LOG="${CASE_ROOT}/home/sudo.log" FAKE_CURL_LOG="${CASE_ROOT}/home/curl.log" \
FAKE_SYSTEMCTL_LOG="${CASE_ROOT}/home/systemctl.log" FAKE_LAUNCHCTL_LOG="${CASE_ROOT}/home/launchctl.log" \
PATH="${CASE_ROOT}/bin:/usr/bin:/bin" FAKE_UNAME_S="Darwin" FAKE_UNAME_M="arm64" \
/bin/bash "${CASE_ROOT}/repo/scripts/lib/nix.sh" > "${CASE_ROOT}/output" 2>&1; then
    fail 'wrong HOME unexpectedly passed production preflight'
fi
assert_file_contains 'requires HOME=/Users/kayg' "${CASE_ROOT}/output"
[ ! -e "${CASE_ROOT}/etc/nix" ] || fail 'wrong HOME changed system configuration'
[ ! -e "${CASE_ROOT}/home/helper.log" ] || fail 'wrong HOME ran the updater'

# An installed Nix older than the required per-command behavior is rejected
# before cache files, updater links, or Home Manager activation are changed.
new_case old-nix
FAKE_NIX_VERSION='nix (Nix) 2.34.1'
if run_bootstrap "${CASE_ROOT}/repo" "${CASE_ROOT}/home" "${CASE_ROOT}/etc/nix" "${CASE_ROOT}/bin" > "${CASE_ROOT}/output" 2>&1; then
    fail 'old Nix unexpectedly passed the minimum version check'
fi
assert_file_contains 'Nix 2.35 or newer is required' "${CASE_ROOT}/output"
[ ! -e "${CASE_ROOT}/etc/nix" ] || fail 'old Nix changed system configuration'
[ ! -e "${CASE_ROOT}/home/helper.log" ] || fail 'old Nix ran the updater'

# The standalone cache entry point shares host and Nix-version preflight and
# therefore cannot write cache files with an old Nix client.
new_case standalone-old-nix
FAKE_NIX_VERSION='nix (Nix) 2.34.1'
mkdir -p "${CASE_ROOT}/home"
if HOME="${CASE_ROOT}/home" DOT_NIX_SYSTEM_DIR="${CASE_ROOT}/etc/nix" \
FAKE_NIX_LOG="${CASE_ROOT}/home/nix.log" FAKE_SUDO_LOG="${CASE_ROOT}/home/sudo.log" \
FAKE_CURL_LOG="${CASE_ROOT}/home/curl.log" FAKE_SYSTEMCTL_LOG="${CASE_ROOT}/home/systemctl.log" \
FAKE_LAUNCHCTL_LOG="${CASE_ROOT}/home/launchctl.log" PATH="${CASE_ROOT}/bin:/usr/bin:/bin" \
FAKE_UNAME_S="Darwin" FAKE_UNAME_M="arm64" \
FAKE_NIX_VERSION="${FAKE_NIX_VERSION}" /bin/bash "${CASE_ROOT}/repo/nix/install-cache" > "${CASE_ROOT}/output" 2>&1; then
    fail 'standalone cache install unexpectedly accepted old Nix'
fi
assert_file_contains 'Nix 2.35 or newer is required' "${CASE_ROOT}/output"
[ ! -e "${CASE_ROOT}/etc/nix" ] || fail 'standalone old Nix changed system configuration'

# Standalone cache installation also rejects unsupported hosts before writes.
new_case standalone-unsupported
FAKE_UNAME_S="Darwin"
FAKE_UNAME_M="x86_64"
mkdir -p "${CASE_ROOT}/home"
if HOME="${CASE_ROOT}/home" DOT_NIX_SYSTEM_DIR="${CASE_ROOT}/etc/nix" \
FAKE_NIX_LOG="${CASE_ROOT}/home/nix.log" FAKE_SUDO_LOG="${CASE_ROOT}/home/sudo.log" \
FAKE_CURL_LOG="${CASE_ROOT}/home/curl.log" FAKE_SYSTEMCTL_LOG="${CASE_ROOT}/home/systemctl.log" \
FAKE_LAUNCHCTL_LOG="${CASE_ROOT}/home/launchctl.log" PATH="${CASE_ROOT}/bin:/usr/bin:/bin" \
FAKE_UNAME_S="${FAKE_UNAME_S}" FAKE_UNAME_M="${FAKE_UNAME_M}" \
/bin/bash "${CASE_ROOT}/repo/nix/install-cache" > "${CASE_ROOT}/output" 2>&1; then
    fail 'standalone cache install unexpectedly accepted unsupported host'
fi
assert_file_contains 'Supported hosts: Darwin arm64, Linux x86_64, or Linux arm64.' "${CASE_ROOT}/output"
[ ! -e "${CASE_ROOT}/etc/nix" ] || fail 'standalone unsupported host changed system configuration'

# A fallback installation is recognized even when nix is absent from PATH.
new_case fallback
mkdir -p "${CASE_ROOT}/profile"
cp "${CASE_ROOT}/bin/nix" "${CASE_ROOT}/profile/nix"
chmod +x "${CASE_ROOT}/profile/nix"
mkdir -p "${CASE_ROOT}/home"
PATH="${CASE_ROOT}/bin:/usr/bin:/bin" DOT_NIX_PROFILE_BIN="${CASE_ROOT}/profile" \
HOME="${CASE_ROOT}/home" DOT_NIX_SYSTEM_DIR="${CASE_ROOT}/etc/nix" \
FAKE_HELPER_LOG="${CASE_ROOT}/home/helper.log" FAKE_NIX_LOG="${CASE_ROOT}/home/nix.log" \
FAKE_SUDO_LOG="${CASE_ROOT}/home/sudo.log" FAKE_CURL_LOG="${CASE_ROOT}/home/curl.log" \
FAKE_SYSTEMCTL_LOG="${CASE_ROOT}/home/systemctl.log" FAKE_LAUNCHCTL_LOG="${CASE_ROOT}/home/launchctl.log" \
/bin/bash "${CASE_ROOT}/repo/scripts/bootstrap-fixture" > "${CASE_ROOT}/output"
assert_file_contains 'Found: nix (Nix)' "${CASE_ROOT}/output"
assert_file_not_contains 'https://install.determinate.systems/nix' "${CASE_ROOT}/home/curl.log"

# Missing Nix never treats a non-TTY as confirmation, even though curl exists.
new_case missing-no-tty
rm -f "${CASE_ROOT}/bin/nix"
if run_bootstrap "${CASE_ROOT}/repo" "${CASE_ROOT}/home" "${CASE_ROOT}/etc/nix" "${CASE_ROOT}/bin" > "${CASE_ROOT}/output" 2>&1; then
    fail 'missing Nix unexpectedly installed without confirmation'
fi
assert_file_contains 'was not confirmed' "${CASE_ROOT}/output"
[ ! -e "${CASE_ROOT}/etc/nix" ] || fail 'non-TTY install changed system directory'
[ ! -e "${CASE_ROOT}/home/curl.log" ] || fail 'non-TTY install downloaded installer'

# Explicit --yes reaches curl, but a failed download cannot be masked by a
# later shell command and the installer/updater is never run.
new_case curl-failure
rm -f "${CASE_ROOT}/bin/nix"
FAKE_CURL_STATUS=23
if run_bootstrap "${CASE_ROOT}/repo" "${CASE_ROOT}/home" "${CASE_ROOT}/etc/nix" "${CASE_ROOT}/bin" --yes > "${CASE_ROOT}/output" 2>&1; then
    fail 'failed installer download unexpectedly succeeded'
fi
assert_file_contains 'download failed' "${CASE_ROOT}/output"
[ ! -e "${CASE_ROOT}/home/helper.log" ] || fail 'updater ran after failed download'

# Unsupported hosts fail before any prompt or mutation.
new_case unsupported
rm -f "${CASE_ROOT}/bin/nix"
FAKE_UNAME_S="Darwin"
FAKE_UNAME_M="x86_64"
if run_bootstrap "${CASE_ROOT}/repo" "${CASE_ROOT}/home" "${CASE_ROOT}/etc/nix" "${CASE_ROOT}/bin" > "${CASE_ROOT}/output" 2>&1; then
    fail 'unsupported host unexpectedly succeeded'
fi
assert_file_contains 'Supported hosts: Darwin arm64, Linux x86_64, or Linux arm64.' "${CASE_ROOT}/output"
[ ! -e "${CASE_ROOT}/home/curl.log" ] || fail 'unsupported host downloaded installer'

# Determinate installs keep the standard nix.conf untouched and use the
# supported nix.custom.conf extension point.
new_case determinate
FAKE_NIX_VERSION='nix (Determinate Nix 3.22.1) 2.35.2' \
run_bootstrap "${CASE_ROOT}/repo" "${CASE_ROOT}/home" "${CASE_ROOT}/etc/nix" "${CASE_ROOT}/bin" > "${CASE_ROOT}/output"
printf '%s\n' 'keep = this' > "${CASE_ROOT}/etc/nix/nix.conf"
# Re-run after seeding the standard file to prove the custom path remains the
# only file changed by the cache include.
FAKE_NIX_VERSION='nix (Determinate Nix 3.22.1) 2.35.2' \
run_bootstrap "${CASE_ROOT}/repo" "${CASE_ROOT}/home" "${CASE_ROOT}/etc/nix" "${CASE_ROOT}/bin" > "${CASE_ROOT}/second-output"
assert_file_contains 'keep = this' "${CASE_ROOT}/etc/nix/nix.conf"
assert_file_contains '!include ' "${CASE_ROOT}/etc/nix/nix.custom.conf"

# A changed cache restarts the installed daemon exactly once; a converged
# cache does not invoke systemctl restart again.
new_case daemon-restart
FAKE_UNAME_S="Linux"
FAKE_UNAME_M="x86_64"
FAKE_SYSTEMCTL_LOADED=1
run_bootstrap "${CASE_ROOT}/repo" "${CASE_ROOT}/home" "${CASE_ROOT}/etc/nix" "${CASE_ROOT}/bin" > "${CASE_ROOT}/output"
assert_file_contains 'restart nix-daemon.service' "${CASE_ROOT}/home/sudo.log"
restart_count="$(grep -c 'restart nix-daemon.service' "${CASE_ROOT}/home/sudo.log")"
assert_equal 1 "${restart_count}"
run_bootstrap "${CASE_ROOT}/repo" "${CASE_ROOT}/home" "${CASE_ROOT}/etc/nix" "${CASE_ROOT}/bin" > "${CASE_ROOT}/second-output"
restart_count="$(grep -c 'restart nix-daemon.service' "${CASE_ROOT}/home/sudo.log")"
assert_equal 1 "${restart_count}"

# A failed restart leaves a root-owned pending marker. The next setup retries
# the daemon reload even though both target config files already match.
new_case daemon-restart-retry
FAKE_UNAME_S="Linux"
FAKE_UNAME_M="x86_64"
FAKE_SYSTEMCTL_LOADED=1
FAKE_SYSTEMCTL_RESTART_STATUS=1
if run_bootstrap "${CASE_ROOT}/repo" "${CASE_ROOT}/home" "${CASE_ROOT}/etc/nix" "${CASE_ROOT}/bin" > "${CASE_ROOT}/output" 2>&1; then
    fail 'failed daemon restart unexpectedly completed setup'
fi
[ -f "${CASE_ROOT}/etc/nix/dotfiles-cache.reload-pending" ] || fail 'reload marker missing after restart failure'
[ ! -e "${CASE_ROOT}/home/helper.log" ] || fail 'updater ran after restart failure'
FAKE_SYSTEMCTL_RESTART_STATUS=0
run_bootstrap "${CASE_ROOT}/repo" "${CASE_ROOT}/home" "${CASE_ROOT}/etc/nix" "${CASE_ROOT}/bin" > "${CASE_ROOT}/retry-output"
[ ! -e "${CASE_ROOT}/etc/nix/dotfiles-cache.reload-pending" ] || fail 'reload marker remained after successful retry'
assert_file_contains --setup "${CASE_ROOT}/home/helper.log"

# Legacy Linux cleanup is ownership-gated: a different symlink and a regular
# file with the legacy names are preserved and the unit is not disabled.
new_case cleanup-linux-foreign
FAKE_UNAME_S="Linux"
FAKE_UNAME_M="x86_64"
mkdir -p "${CASE_ROOT}/home/.config/systemd/user"
ln -s /tmp/foreign-nix-update "${CASE_ROOT}/home/.config/systemd/user/nix-unstable-update.timer"
printf '%s\n' 'user service' > "${CASE_ROOT}/home/.config/systemd/user/nix-unstable-update.service"
run_bootstrap "${CASE_ROOT}/repo" "${CASE_ROOT}/home" "${CASE_ROOT}/etc/nix" "${CASE_ROOT}/bin" > "${CASE_ROOT}/output"
[ -L "${CASE_ROOT}/home/.config/systemd/user/nix-unstable-update.timer" ] || fail 'foreign timer symlink was removed'
[ -f "${CASE_ROOT}/home/.config/systemd/user/nix-unstable-update.service" ] || fail 'regular service file was removed'
assert_file_not_contains 'disable --now nix-unstable-update.timer' "${CASE_ROOT}/home/systemctl.log"

# The same guard applies to the old macOS LaunchAgent label.
new_case cleanup-darwin-foreign
mkdir -p "${CASE_ROOT}/home/Library/LaunchAgents"
ln -s /tmp/foreign-nix-agent "${CASE_ROOT}/home/Library/LaunchAgents/org.kayg.dotfiles.nix-unstable-update.plist"
run_bootstrap "${CASE_ROOT}/repo" "${CASE_ROOT}/home" "${CASE_ROOT}/etc/nix" "${CASE_ROOT}/bin" > "${CASE_ROOT}/output"
[ -L "${CASE_ROOT}/home/Library/LaunchAgents/org.kayg.dotfiles.nix-unstable-update.plist" ] || fail 'foreign launch agent symlink was removed'
assert_file_not_contains 'bootout gui/' "${CASE_ROOT}/home/launchctl.log"

printf '%s\n' 'nix bootstrap tests passed'
