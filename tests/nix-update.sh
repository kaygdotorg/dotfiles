#!/usr/bin/env bash
# Focused tests for nix/nix-unstable-update.  Every Nix and activation call is
# mocked; this script never installs, switches, schedules, or contacts Nix.

set -euo pipefail

script_dir="$(CDPATH='' cd -P "$(dirname "$0")" && pwd -P)"
updater_source="${script_dir}/../nix/nix-unstable-update"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/nix-update-tests.XXXXXX")"
repo_dir="${test_root}/repo"
bin_dir="${test_root}/bin"
state_dir="${test_root}/state"
tmp_dir="${test_root}/tmp"
output_dir="${test_root}/nix-update-output"
log_file="${test_root}/commands.log"
helper_log="${test_root}/helper.log"
activation_marker="${test_root}/activated"
first_output="${test_root}/first.out"
second_output="${test_root}/second.out"
term_sentinel="${test_root}/term-sentinel"
real_mv="$(command -v mv)"

cleanup() {
    status=$?
    rm -rf "${test_root}"
    return "${status}"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

mkdir -p "${repo_dir}/nix" "${repo_dir}/home-manager/omniwm" \
    "${bin_dir}" "${state_dir}" "${tmp_dir}" "${output_dir}/bin"
repo_real="$(CDPATH='' cd -P "${repo_dir}" && pwd -P)"
cp "${updater_source}" "${repo_dir}/nix/nix-unstable-update"
chmod +x "${repo_dir}/nix/nix-unstable-update"
ln -s "${repo_dir}/nix/nix-unstable-update" "${bin_dir}/run-update"

cat > "${repo_dir}/nix/realize-home" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'helper %s repo=%s\n' "$*" "${DOTFILES_REPO-}" >> "${MOCK_HELPER_LOG}"
case "${NIX_CONFIG-}" in
    *"allow-import-from-derivation = false"*) ;;
    *)
        printf '%s\n' 'helper was not given the no-IFD policy' >&2
        exit 96
        ;;
esac

has_check=0
before_activate=
expect_before_activate=0
previous_argument=
for argument in "$@"; do
    if [ "${argument}" = --check ]; then
        has_check=1
    fi
    if [ "${previous_argument}" = --before-activate ]; then
        before_activate="${argument}"
        expect_before_activate=1
    fi
    previous_argument="${argument}"
done

if [ "${MOCK_HELPER_SLEEP:-0}" != 0 ]; then
    sleep "${MOCK_HELPER_SLEEP}"
fi
if [ "${MOCK_HELPER_EDIT:-0}" = 1 ]; then
    printf '%s\n' concurrent-source-edit >> "${DOTFILES_REPO}/home-manager/omniwm/package.nix"
fi
if [ "${MOCK_HELPER_EDIT_THIRD:-0}" = 1 ]; then
    printf '%s\n' helper-third-file-edit >> "${DOTFILES_REPO}/home-manager/extra.nix"
fi
if [ "${MOCK_HELPER_FAIL:-0}" = 1 ]; then
    exit 42
fi
if [ "${has_check}" -eq 0 ] && [ "${expect_before_activate}" -eq 1 ]; then
    "${before_activate}"
fi
if [ "${has_check}" -eq 0 ] && [ -n "${MOCK_ACTIVATION_MARKER:-}" ]; then
    printf '%s\n' activated > "${MOCK_ACTIVATION_MARKER}"
fi
EOF
chmod +x "${repo_dir}/nix/realize-home"

cat > "${bin_dir}/uname" <<'EOF'
#!/bin/sh
case "${1-}" in
    -s) printf '%s\n' "${MOCK_UNAME_S:-Darwin}" ;;
    -m) printf '%s\n' "${MOCK_UNAME_M:-arm64}" ;;
    *) exit 2 ;;
esac
EOF
chmod +x "${bin_dir}/uname"

cat > "${bin_dir}/hostname" <<'EOF'
#!/bin/sh
printf '%s\n' "${MOCK_HOSTNAME:-mba}"
EOF
chmod +x "${bin_dir}/hostname"

cat > "${bin_dir}/nix" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'nix %s\n' "$*" >> "${MOCK_LOG}"
printf 'nix-config %s\n' "${NIX_CONFIG-}" >> "${MOCK_LOG}"
case "${NIX_CONFIG-}" in
    *"allow-import-from-derivation = false"*) ;;
    *)
        printf '%s\n' 'nix was not given the no-IFD policy' >&2
        exit 96
        ;;
esac
case "${1-}" in
    --version)
        printf '%s\n' "${MOCK_NIX_VERSION:-nix (Determinate Nix 3.22.1) 2.35.2}"
        ;;
    build)
        # The updater must use the locked, no-local-build invocation.  Any
        # missing or reordered argument makes the mock fail the test.
        [ "${2-}" = --no-link ]
        [ "${3-}" = --print-out-paths ]
        [ "${4-}" = --max-jobs ]
        [ "${5-}" = 0 ]
        [ "${6-}" = --option ]
        [ "${7-}" = builders ]
        [ "${8-}" = '' ]
        [ "${9-}" = --option ]
        [ "${10-}" = external-builders ]
        [ "${11-}" = '[]' ]
        [ "${12-}" = --option ]
        [ "${13-}" = allow-import-from-derivation ]
        [ "${14-}" = false ]
        case "${15-}" in
            path:*#nix-update) ;;
            *) exit 91 ;;
        esac
        printf '%s\n' "${MOCK_OUT}"
        ;;
    eval)
        [ "${2-}" = --option ]
        [ "${3-}" = allow-import-from-derivation ]
        [ "${4-}" = false ]
        [ "${5-}" = --raw ]
        case "${6-}" in
            path:*#packages.aarch64-darwin.omniwm.src.url)
                printf '%s\n' 'https://github.com/BarutSRB/OmniWM/releases/download/v0.6.10/OmniWM-v0.6.10.zip'
                ;;
            *) exit 94 ;;
        esac
        ;;
    store)
        [ "${2-}" = prefetch-file ]
        [ "${3-}" = --option ]
        [ "${4-}" = allow-import-from-derivation ]
        [ "${5-}" = false ]
        [ "${6-}" = --json ]
        [ "${7-}" = --no-pretty ]
        [ -n "${8-}" ] || exit 95
        printf '%s\n' '{"hash":"sha256-new-hash"}'
        ;;
    flake)
        [ "${2-}" = update ]
        [ "${3-}" = --option ]
        [ "${4-}" = allow-import-from-derivation ]
        [ "${5-}" = false ]
        [ "${6-}" = --flake ]
        candidate_ref="${7-}"
        case "${candidate_ref}" in
            path:*) candidate_dir="${candidate_ref#path:}" ;;
            *) exit 92 ;;
        esac
        printf '%s\n' new-lock > "${candidate_dir}/flake.lock"
        if [ "${MOCK_FLAKE_EDIT_SOURCE:-0}" = 1 ]; then
            printf '%s\n' flake-phase-source-edit >> "${DOTFILES_REPO}/home-manager/extra.nix"
        fi
        if [ "${MOCK_FLAKE_CHMOD:-0}" = 1 ]; then
            chmod -x "${DOTFILES_REPO}/home-manager/extra.nix"
        fi
        if [ "${MOCK_FLAKE_RETARGET:-0}" = 1 ]; then
            ln -sf alternate.nix "${DOTFILES_REPO}/home-manager/linked.nix"
        fi
        ;;
    *)
        exit 93
        ;;
esac
EOF
chmod +x "${bin_dir}/nix"

cat > "${output_dir}/bin/nix-update" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'nix-update %s cwd=%s\n' "$*" "${PWD}" >> "${MOCK_LOG}"
printf 'nix-update-config %s\n' "${NIX_CONFIG-}" >> "${MOCK_LOG}"
case "${NIX_CONFIG-}" in
    *"allow-import-from-derivation = false"*) ;;
    *)
        printf '%s\n' 'nix-update was not given the no-IFD policy' >&2
        exit 96
        ;;
esac
if [ "${MOCK_UPDATE_FAIL:-0}" = 1 ]; then
    exit 37
fi
[ "${1-}" = --flake ]
[ "${2-}" = --system ]
[ "${3-}" = aarch64-darwin ]
[ "${4-}" = --use-github-releases ]
[ "${5-}" = omniwm ]
[ "${6-}" = --no-src ]
printf '%s\n' 'version = "0.6.10";' 'hash = "old-hash";' > omniwm/package.nix
EOF
chmod +x "${output_dir}/bin/nix-update"

cat > "${bin_dir}/nix-build" <<'EOF'
#!/bin/sh
printf 'nix-build %s\n' "$*" >> "${MOCK_LOG}"
printf '%s\n' 'unexpected source build' >&2
exit 97
EOF
chmod +x "${bin_dir}/nix-build"

# Delegate ordinary moves to the host utility.  The signal case targets only
# the first live commit rename, leaving owner-record and candidate moves alone.
cat > "${bin_dir}/mv" <<'EOF'
#!/usr/bin/env bash
set -u

if "${MOCK_REAL_MV}" "$@"; then
    move_status=0
else
    move_status=$?
fi
last_argument=
for argument in "$@"; do
    last_argument="${argument}"
done
if [ "${move_status}" -eq 0 ] \
    && [ "${MOCK_TERM_ON_COMMIT_LOCK:-0}" = 1 ] \
    && [ "${last_argument}" = "${MOCK_TERM_TARGET:-}" ] \
    && [ ! -e "${MOCK_TERM_SENTINEL:-}" ]; then
    : > "${MOCK_TERM_SENTINEL}"
    kill -TERM "${PPID}"
fi
exit "${move_status}"
EOF
chmod +x "${bin_dir}/mv"

run_update() {
    PATH="${bin_dir}:/usr/bin:/bin" \
    HOME="${test_root}/home" \
    TMPDIR="${tmp_dir}" \
    XDG_STATE_HOME="${state_dir}" \
    MOCK_LOG="${log_file}" \
    MOCK_HELPER_LOG="${helper_log}" \
    MOCK_OUT="${output_dir}" \
    MOCK_ACTIVATION_MARKER="${activation_marker}" \
    NIX_CONFIG='experimental-features = nix-command flakes' \
    MOCK_REAL_MV="${real_mv}" \
    MOCK_TERM_TARGET="${repo_real}/home-manager/flake.lock" \
    MOCK_TERM_SENTINEL="${term_sentinel}" \
    "${bin_dir}/run-update" "$@"
}

reset_fixture() {
    rm -rf "${state_dir}"
    mkdir -p "${state_dir}"
    printf '%s\n' flake > "${repo_dir}/home-manager/flake.nix"
    printf '%s\n' flake > "${repo_dir}/home-manager/alternate.nix"
    printf '%s\n' old-lock > "${repo_dir}/home-manager/flake.lock"
    printf '%s\n' baseline > "${repo_dir}/home-manager/extra.nix"
    chmod +x "${repo_dir}/home-manager/extra.nix"
    ln -sf flake.nix "${repo_dir}/home-manager/linked.nix"
    printf '%s\n' 'version = "0.6.9";' 'hash = "old-hash";' > "${repo_dir}/home-manager/omniwm/package.nix"
    : > "${log_file}"
    : > "${helper_log}"
    rm -f "${activation_marker}" "${first_output}" "${second_output}" "${term_sentinel}"
    MOCK_UNAME_S=Darwin
    MOCK_UNAME_M=arm64
    MOCK_HOSTNAME=mba
    MOCK_NIX_VERSION='nix (Determinate Nix 3.22.1) 2.35.2'
    MOCK_HELPER_SLEEP=0
    MOCK_HELPER_EDIT=0
    MOCK_HELPER_EDIT_THIRD=0
    MOCK_HELPER_FAIL=0
    MOCK_UPDATE_FAIL=0
    MOCK_FLAKE_EDIT_SOURCE=0
    MOCK_FLAKE_CHMOD=0
    MOCK_FLAKE_RETARGET=0
    MOCK_TERM_ON_COMMIT_LOCK=0
    export MOCK_UNAME_S MOCK_UNAME_M MOCK_HOSTNAME MOCK_NIX_VERSION MOCK_HELPER_SLEEP
    export MOCK_HELPER_EDIT MOCK_HELPER_EDIT_THIRD MOCK_HELPER_FAIL MOCK_UPDATE_FAIL
    export MOCK_FLAKE_EDIT_SOURCE MOCK_FLAKE_CHMOD MOCK_FLAKE_RETARGET MOCK_TERM_ON_COMMIT_LOCK
}

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_content() {
    expected=$1
    file_path=$2
    actual="$(tr -d '\n' < "${file_path}")"
    [ "${actual}" = "${expected}" ] || fail "${file_path}: expected ${expected}, got ${actual}"
}

assert_contains() {
    needle=$1
    file_path=$2
    grep -F -- "${needle}" "${file_path}" >/dev/null || fail "${file_path}: missing ${needle}"
}

assert_not_contains() {
    needle=$1
    file_path=$2
    if grep -F -- "${needle}" "${file_path}" >/dev/null; then
        fail "${file_path}: unexpectedly contains ${needle}"
    fi
}

assert_link_target() {
    expected=$1
    file_path=$2
    actual="$(readlink "${file_path}")"
    [ "${actual}" = "${expected}" ] \
        || fail "${file_path}: expected link target ${expected}, got ${actual}"
}

test_check_does_not_activate() {
    reset_fixture
    run_update --check
    assert_contains '--flake path:' "${helper_log}"
    assert_contains '--host kayg-mba --check' "${helper_log}"
    [ ! -e "${activation_marker}" ] || fail '--check activated a profile'
    assert_not_contains 'nix flake update' "${log_file}"
    assert_not_contains 'nix build' "${log_file}"
    assert_content old-lock "${repo_dir}/home-manager/flake.lock"
    assert_contains 'version = "0.6.9";' "${repo_dir}/home-manager/omniwm/package.nix"
    assert_contains 'hash = "old-hash";' "${repo_dir}/home-manager/omniwm/package.nix"
    printf '%s\n' 'ok: --check evaluates without activation'
}

test_setup_uses_current_lock() {
    reset_fixture
    run_update --setup
    assert_contains '--host kayg-mba' "${helper_log}"
    assert_not_contains '--check' "${helper_log}"
    assert_not_contains 'nix flake update' "${log_file}"
    assert_not_contains 'nix build' "${log_file}"
    assert_content old-lock "${repo_dir}/home-manager/flake.lock"
    assert_contains 'version = "0.6.9";' "${repo_dir}/home-manager/omniwm/package.nix"
    assert_contains 'hash = "old-hash";' "${repo_dir}/home-manager/omniwm/package.nix"
    printf '%s\n' 'ok: --setup applies current lock'
}

test_success_commits_only_allowed_files() {
    reset_fixture
    run_update
    assert_content new-lock "${repo_dir}/home-manager/flake.lock"
    assert_contains 'version = "0.6.10";' "${repo_dir}/home-manager/omniwm/package.nix"
    assert_contains 'hash = "sha256-new-hash";' "${repo_dir}/home-manager/omniwm/package.nix"
    assert_contains 'nix build --no-link --print-out-paths --max-jobs 0' "${log_file}"
    assert_contains '--option builders  --option external-builders [] --option allow-import-from-derivation false' "${log_file}"
    assert_contains 'nix-update --flake --system aarch64-darwin --use-github-releases omniwm' "${log_file}"
    assert_contains 'nix flake update --option allow-import-from-derivation false --flake path:' "${log_file}"
    assert_contains 'experimental-features = nix-command flakes' "${log_file}"
    assert_contains 'allow-import-from-derivation = false' "${log_file}"
    repo_real="$(CDPATH='' cd -P "${repo_dir}" && pwd -P)"
    assert_contains 'repo='"${repo_real}" "${helper_log}"
    assert_contains '--before-activate ' "${helper_log}"
    [ -e "${activation_marker}" ] || fail 'successful update did not activate'
    printf '%s\n' 'ok: successful candidate commits lock and OmniWM package'
}

test_failed_update_leaves_source_untouched() {
    reset_fixture
    MOCK_UPDATE_FAIL=1
    export MOCK_UPDATE_FAIL
    if run_update > "${test_root}/failed.out" 2>&1; then
        fail 'failed nix-update unexpectedly succeeded'
    fi
    assert_content old-lock "${repo_dir}/home-manager/flake.lock"
    assert_contains 'version = "0.6.9";' "${repo_dir}/home-manager/omniwm/package.nix"
    assert_contains 'hash = "old-hash";' "${repo_dir}/home-manager/omniwm/package.nix"
    [ ! -s "${helper_log}" ] || fail 'activation ran after failed nix-update'
    unset MOCK_UPDATE_FAIL
    printf '%s\n' 'ok: failed update leaves source untouched'
}

test_concurrent_edit_is_not_committed() {
    reset_fixture
    MOCK_HELPER_EDIT=1
    export MOCK_HELPER_EDIT
    if run_update > "${test_root}/concurrent.out" 2>&1; then
        fail 'concurrent edit unexpectedly succeeded'
    fi
    assert_content old-lock "${repo_dir}/home-manager/flake.lock"
    assert_contains concurrent-source-edit "${repo_dir}/home-manager/omniwm/package.nix"
    assert_not_contains 'version = "0.6.10";' "${repo_dir}/home-manager/omniwm/package.nix"
    unset MOCK_HELPER_EDIT
    printf '%s\n' 'ok: concurrent source edit blocks write-back'
}

test_source_edit_during_update_blocks_activation() {
    reset_fixture
    MOCK_FLAKE_EDIT_SOURCE=1
    export MOCK_FLAKE_EDIT_SOURCE
    if run_update > "${test_root}/flake-edit.out" 2>&1; then
        fail 'source edit during flake update unexpectedly succeeded'
    fi
    [ ! -s "${helper_log}" ] || fail 'activation ran after source edit during update'
    [ ! -e "${activation_marker}" ] || fail 'activation marker exists after source edit during update'
    assert_content old-lock "${repo_dir}/home-manager/flake.lock"
    assert_contains 'version = "0.6.9";' "${repo_dir}/home-manager/omniwm/package.nix"
    assert_contains flake-phase-source-edit "${repo_dir}/home-manager/extra.nix"
    unset MOCK_FLAKE_EDIT_SOURCE
    printf '%s\n' 'ok: source edit during update blocks activation'
}

test_manifest_tracks_mode_and_symlink_target() {
    reset_fixture
    MOCK_FLAKE_CHMOD=1
    export MOCK_FLAKE_CHMOD
    if run_update > "${test_root}/chmod-edit.out" 2>&1; then
        fail 'executable-bit edit unexpectedly succeeded'
    fi
    [ ! -s "${helper_log}" ] || fail 'activation ran after executable-bit edit'
    [ ! -x "${repo_dir}/home-manager/extra.nix" ] || fail 'executable-bit fixture did not change'

    reset_fixture
    MOCK_FLAKE_RETARGET=1
    export MOCK_FLAKE_RETARGET
    if run_update > "${test_root}/symlink-edit.out" 2>&1; then
        fail 'symlink-target edit unexpectedly succeeded'
    fi
    [ ! -s "${helper_log}" ] || fail 'activation ran after symlink-target edit'
    assert_link_target alternate.nix "${repo_dir}/home-manager/linked.nix"
    unset MOCK_FLAKE_CHMOD MOCK_FLAKE_RETARGET
    printf '%s\n' 'ok: manifest tracks executable bits and literal symlink targets'
}

test_third_source_edit_blocks_writeback() {
    reset_fixture
    MOCK_HELPER_EDIT_THIRD=1
    export MOCK_HELPER_EDIT_THIRD
    if run_update > "${test_root}/third-edit.out" 2>&1; then
        fail 'third-file edit unexpectedly succeeded'
    fi
    assert_content old-lock "${repo_dir}/home-manager/flake.lock"
    assert_contains 'version = "0.6.9";' "${repo_dir}/home-manager/omniwm/package.nix"
    assert_contains helper-third-file-edit "${repo_dir}/home-manager/extra.nix"
    unset MOCK_HELPER_EDIT_THIRD
    printf '%s\n' 'ok: third source-file edit blocks write-back'
}

test_signal_rolls_back_two_file_commit() {
    reset_fixture
    MOCK_TERM_ON_COMMIT_LOCK=1
    export MOCK_TERM_ON_COMMIT_LOCK
    if run_update > "${test_root}/term.out" 2>&1; then
        fail 'TERM during commit unexpectedly succeeded'
    fi
    [ -e "${term_sentinel}" ] || fail 'commit signal injection did not run'
    assert_content old-lock "${repo_dir}/home-manager/flake.lock"
    assert_contains 'version = "0.6.9";' "${repo_dir}/home-manager/omniwm/package.nix"
    assert_contains 'hash = "old-hash";' "${repo_dir}/home-manager/omniwm/package.nix"
    unset MOCK_TERM_ON_COMMIT_LOCK
    printf '%s\n' 'ok: TERM during commit rolls back both targets'
}

test_lock_and_stale_lock_are_safe() {
    reset_fixture
    MOCK_HELPER_SLEEP=2
    export MOCK_HELPER_SLEEP
    run_update > "${first_output}" 2>&1 &
    first_pid=$!
    lock_path="${state_dir}/dotfiles/nix-unstable-update.lock"
    attempts=0
    while [ ! -f "${lock_path}/owner" ] && [ "${attempts}" -lt 40 ]; do
        sleep 0.1
        attempts=$((attempts + 1))
    done
    [ -f "${lock_path}/owner" ] || fail 'first run did not acquire lock'
    if run_update --setup > "${second_output}" 2>&1; then
        fail 'overlapping run unexpectedly succeeded'
    fi
    assert_contains 'refusing to remove it' "${second_output}"
    wait "${first_pid}" || fail 'first locked run failed'
    [ ! -d "${lock_path}" ] || fail 'lock was not cleaned after success'

    mkdir -p "${lock_path}"
    boot_id=""
    if [ -r /proc/sys/kernel/random/boot_id ]; then
        boot_id="$(tr -d '[:space:]' < /proc/sys/kernel/random/boot_id)"
    elif command -v sysctl >/dev/null 2>&1; then
        boot_id="$(sysctl -n kern.boottime 2>/dev/null | tr -d '[:space:]{}')"
    elif [ -x /usr/sbin/sysctl ]; then
        boot_id="$(/usr/sbin/sysctl -n kern.boottime 2>/dev/null | tr -d '[:space:]{}')"
    fi
    [ -n "${boot_id}" ] || fail 'test host has no boot identity'
    {
        printf 'pid=999999\n'
        printf 'start=dead-process-start\n'
        printf 'boot=%s\n' "${boot_id}"
        printf 'token=stale-token\n'
    } > "${lock_path}/owner"
    run_update --setup > "${second_output}" 2>&1 \
        || fail 'valid stale lock was not reclaimed'
    [ ! -d "${lock_path}" ] || fail 'valid stale lock was not removed'

    mkdir -p "${lock_path}"
    printf '%s\n' 99999.1.1 > "${lock_path}/owner"
    if run_update --setup > "${second_output}" 2>&1; then
        fail 'ambiguous stale lock unexpectedly succeeded'
    fi
    [ -f "${lock_path}/owner" ] || fail 'ambiguous lock was deleted'
    rm -rf "${state_dir}"
    unset MOCK_HELPER_SLEEP
    printf '%s\n' 'ok: overlapping and stale locks are handled safely'
}

test_host_selection() {
    reset_fixture
    MOCK_UNAME_S=Linux
    MOCK_UNAME_M=x86_64
    MOCK_HOSTNAME=anything
    export MOCK_UNAME_S MOCK_UNAME_M MOCK_HOSTNAME
    run_update --check
    assert_contains '--host kayg-linux --check' "${helper_log}"

    reset_fixture
    MOCK_UNAME_S=Linux
    MOCK_UNAME_M=aarch64
    export MOCK_UNAME_S MOCK_UNAME_M
    run_update --check
    assert_contains '--host kayg-linux-arm --check' "${helper_log}"

    reset_fixture
    MOCK_UNAME_S=Darwin
    MOCK_UNAME_M=arm64
    MOCK_HOSTNAME=mbp
    export MOCK_UNAME_S MOCK_UNAME_M MOCK_HOSTNAME
    run_update --check
    assert_contains '--host kayg --check' "${helper_log}"
    printf '%s\n' 'ok: supported host selection'
}

test_old_nix_is_rejected() {
    reset_fixture
    MOCK_NIX_VERSION='nix (Determinate Nix 3.22.1) 2.34.9'
    export MOCK_NIX_VERSION
    if run_update --check > "${test_root}/old-nix.out" 2>&1; then
        fail 'old Nix version unexpectedly passed the gate'
    fi
    assert_content old-lock "${repo_dir}/home-manager/flake.lock"
    assert_contains 'Nix 2.34.9 is too old' "${test_root}/old-nix.out"
    unset MOCK_NIX_VERSION
    printf '%s\n' 'ok: old Nix versions are rejected'
}

test_check_does_not_activate
test_setup_uses_current_lock
test_success_commits_only_allowed_files
test_failed_update_leaves_source_untouched
test_concurrent_edit_is_not_committed
test_source_edit_during_update_blocks_activation
test_manifest_tracks_mode_and_symlink_target
test_third_source_edit_blocks_writeback
test_signal_rolls_back_two_file_commit
test_lock_and_stale_lock_are_safe
test_host_selection
test_old_nix_is_rejected
printf '%s\n' 'all nix updater tests passed'
