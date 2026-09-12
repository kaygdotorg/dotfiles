#!/usr/bin/env bash

set -euo pipefail

repo_path="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/dot-regressions.XXXXXX")"
trap 'rm -rf "${test_root}"' EXIT
mock_bin="${test_root}/mock-bin"
mkdir -p "${mock_bin}"
for mock_name in zellij curl sha256sum emacs git doom cp atuin; do
    ln -s "${repo_path}/scripts/tests/mock-command" "${mock_bin}/${mock_name}"
done
real_cp="$(command -v cp)"
real_git="$(command -v git)"

fixture_git() {
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "${real_git}" "$@"
}

assert() {
    if ! "$@"; then
        printf 'assertion failed: %s\n' "$*" >&2
        exit 1
    fi
}

assert_equal() {
    if [ "${1}" != "${2}" ]; then
        printf 'assertion failed: expected <%s>, got <%s>\n' "${1}" "${2}" >&2
        exit 1
    fi
}

assert_contains() {
    printf '%s' "${1}" | grep -Fq -- "${2}"
}

assert_not_contains() {
    ! printf '%s' "${1}" | grep -Fq -- "${2}"
}

test_zellij_config_rendering() {
    local test_home="${test_root}/home&pipe|slash\\home"
    local zellij_dest="${test_home}/.config/zellij"
    local config_path="${zellij_dest}/config.kdl"
    local expected_sha="1ca92abefdb173906f391ec613e446906a2d59c3b38e15175b8980a7ce503f8f"
    local zjstatus_sha="282ceab219e56e1908c9fac33907241fe6c3e1ef7d85faab3e5f438cef87b8fe"
    local first_backup_count second_backup_count rendered_config expected_kdl_home

    mkdir -p "${zellij_dest}"
    printf '%s\n' 'user-owned zellij config' > "${config_path}"

    if ! PATH="${mock_bin}:${PATH}" DOT_TEST_EXPECTED_SHA="${expected_sha}" \
        DOT_TEST_ZJSTATUS_SHA="${zjstatus_sha}" DOT_TEST_TABULA_SHA="${expected_sha}" \
        HOME="${test_home}" "${repo_path}/scripts/dot" setup zellij; then
        printf '%s\n' 'zellij setup mock failed' >&2
        exit 1
    fi

    first_backup_count="$(find "${zellij_dest}" -maxdepth 1 -name 'config.kdl.bak.*' -type f | wc -l | tr -d ' ')"
    assert_equal 1 "${first_backup_count}"
    rendered_config="$(<"${config_path}")"
    expected_kdl_home="${test_home//\\/\\\\}"
    assert assert_not_contains "${rendered_config}" '@@HOME@@'
    assert assert_contains "${rendered_config}" "${expected_kdl_home}"
    assert_equal 0 "$(find "${zellij_dest}" -maxdepth 1 -name 'config.kdl.tmp.*' -type f | wc -l | tr -d ' ')"

    if ! PATH="${mock_bin}:${PATH}" DOT_TEST_EXPECTED_SHA="${expected_sha}" \
        DOT_TEST_ZJSTATUS_SHA="${zjstatus_sha}" DOT_TEST_TABULA_SHA="${expected_sha}" \
        HOME="${test_home}" "${repo_path}/scripts/dot" setup zellij; then
        printf '%s\n' 'second zellij setup mock failed' >&2
        exit 1
    fi

    second_backup_count="$(find "${zellij_dest}" -maxdepth 1 -name 'config.kdl.bak.*' -type f | wc -l | tr -d ' ')"
    assert_equal "${first_backup_count}" "${second_backup_count}"

    # Divergent user content is preserved on every replacement, even when two
    # replacements happen within the same timestamp second.
    printf '%s\n' 'first user edit' > "${config_path}"
    PATH="${mock_bin}:${PATH}" DOT_TEST_EXPECTED_SHA="${expected_sha}" \
        DOT_TEST_ZJSTATUS_SHA="${zjstatus_sha}" DOT_TEST_TABULA_SHA="${expected_sha}" \
        HOME="${test_home}" "${repo_path}/scripts/dot" setup zellij >/dev/null
    assert_equal 2 "$(find "${zellij_dest}" -maxdepth 1 -name 'config.kdl.bak.*' -type f | wc -l | tr -d ' ')"
    printf '%s\n' 'second user edit' > "${config_path}"
    PATH="${mock_bin}:${PATH}" DOT_TEST_EXPECTED_SHA="${expected_sha}" \
        DOT_TEST_ZJSTATUS_SHA="${zjstatus_sha}" DOT_TEST_TABULA_SHA="${expected_sha}" \
        HOME="${test_home}" "${repo_path}/scripts/dot" setup zellij >/dev/null
    assert_equal 3 "$(find "${zellij_dest}" -maxdepth 1 -name 'config.kdl.bak.*' -type f | wc -l | tr -d ' ')"
}

test_zellij_shasum_fallback() {
    local test_home="${test_root}/shasum-home"
    local fallback_bin="${test_root}/shasum-bin"
    local config_path="${test_home}/.config/zellij/config.kdl"
    local expected_sha="1ca92abefdb173906f391ec613e446906a2d59c3b38e15175b8980a7ce503f8f"
    local zjstatus_sha="282ceab219e56e1908c9fac33907241fe6c3e1ef7d85faab3e5f438cef87b8fe"
    local utility utility_path

    mkdir -p "${fallback_bin}" "${test_home}"
    for mock_name in zellij curl shasum; do
        ln -s "${repo_path}/scripts/tests/mock-command" "${fallback_bin}/${mock_name}"
    done
    for utility in bash env realpath dirname pwd basename mkdir mktemp sed cmp mv ln rm awk date; do
        utility_path="$(command -v "${utility}")"
        case "${utility_path}" in
            /*) ln -s "${utility_path}" "${fallback_bin}/${utility}" ;;
        esac
    done

    # Use an explicit utility-only PATH so sha256sum cannot mask the fallback
    # on hosts where it lives in /sbin or /usr/bin.
    PATH="${fallback_bin}" DOT_TEST_EXPECTED_SHA="${expected_sha}" \
        DOT_TEST_ZJSTATUS_SHA="${zjstatus_sha}" DOT_TEST_TABULA_SHA="${expected_sha}" \
        HOME="${test_home}" /bin/bash "${repo_path}/scripts/dot" setup zellij >/dev/null
    assert test -f "${config_path}"
    assert assert_not_contains "$(<"${config_path}")" '@@HOME@@'
    assert test -f "${test_home}/.config/zellij/plugins/zjstatus.wasm"
    assert test -f "${test_home}/.config/zellij/plugins/zellij-tabula.wasm"
}

test_zellij_config_actual_parser() {
    local zellij_path parser_bin test_home config_path expected_sha zjstatus_sha

    if ! zellij_path="$(command -v zellij 2>/dev/null)"; then
        if [ "${DOT_REQUIRE_ZELLIJ:-0}" = 1 ]; then
            printf '%s\n' 'DOT_REQUIRE_ZELLIJ=1 but no zellij executable is available' >&2
            exit 1
        fi
        return 0
    fi

    parser_bin="${test_root}/zellij-parser-bin"
    test_home="${test_root}/parser home&slash\\quote\"x"
    config_path="${test_home}/.config/zellij/config.kdl"
    expected_sha="1ca92abefdb173906f391ec613e446906a2d59c3b38e15175b8980a7ce503f8f"
    zjstatus_sha="282ceab219e56e1908c9fac33907241fe6c3e1ef7d85faab3e5f438cef87b8fe"

    mkdir -p "${parser_bin}" "${test_home}"
    ln -s "${zellij_path}" "${parser_bin}/zellij"
    ln -s "${repo_path}/scripts/tests/mock-command" "${parser_bin}/curl"
    ln -s "${repo_path}/scripts/tests/mock-command" "${parser_bin}/sha256sum"

    if ! PATH="${parser_bin}:${PATH}" \
        DOT_TEST_EXPECTED_SHA="${expected_sha}" DOT_TEST_ZJSTATUS_SHA="${zjstatus_sha}" \
        DOT_TEST_TABULA_SHA="${expected_sha}" HOME="${test_home}" \
        "${repo_path}/scripts/dot" setup zellij >/dev/null; then
        printf '%s\n' 'actual zellij parser rejected rendered config' >&2
        exit 1
    fi
    assert test -f "${config_path}"
    assert assert_contains "$(<"${config_path}")" 'home_dir "'
}

test_zellij_parser_failure_preserves_config() {
    local test_home="${test_root}/zellij-parser-failure-home"
    local zellij_dest="${test_home}/.config/zellij"
    local config_path="${zellij_dest}/config.kdl"
    local expected_sha="1ca92abefdb173906f391ec613e446906a2d59c3b38e15175b8980a7ce503f8f"
    local zjstatus_sha="282ceab219e56e1908c9fac33907241fe6c3e1ef7d85faab3e5f438cef87b8fe"

    mkdir -p "${zellij_dest}"
    printf '%s\n' 'keep this config' > "${config_path}"
    if PATH="${mock_bin}:${PATH}" HOME="${test_home}" DOT_TEST_ZELLIJ_FAIL=1 \
        DOT_TEST_EXPECTED_SHA="${expected_sha}" DOT_TEST_ZJSTATUS_SHA="${zjstatus_sha}" \
        DOT_TEST_TABULA_SHA="${expected_sha}" "${repo_path}/scripts/dot" setup zellij \
        >"${test_root}/zellij-parser-failure.out" 2>&1; then
        printf '%s\n' 'zellij setup unexpectedly accepted parser failure' >&2
        exit 1
    fi
    assert_equal 'keep this config' "$(<"${config_path}")"
    assert_equal 0 "$(find "${zellij_dest}" -maxdepth 1 -name 'config.kdl.bak.*' -print | wc -l | tr -d ' ')"
    assert_equal 0 "$(find "${zellij_dest}" -maxdepth 1 -name 'config.kdl.tmp.*' -print | wc -l | tr -d ' ')"
}

test_symlink_destinations_are_replaced_safely() {
    local test_home="${test_root}/symlink-home"
    local outside="${test_root}/unrelated-zellij-dir"
    local zellij_dest="${test_home}/.config/zellij"
    local expected_sha="1ca92abefdb173906f391ec613e446906a2d59c3b38e15175b8980a7ce503f8f"
    local zjstatus_sha="282ceab219e56e1908c9fac33907241fe6c3e1ef7d85faab3e5f438cef87b8fe"

    mkdir -p "${test_home}/.local/bin" "${zellij_dest}/layouts" "${zellij_dest}/plugins" "${outside}"
    ln -s "${outside}" "${test_home}/.local/bin/dot"
    PATH="${mock_bin}:${PATH}" HOME="${test_home}" "${repo_path}/scripts/dot" setup dot >/dev/null
    assert test -L "${test_home}/.local/bin/dot"
    assert_equal 0 "$(find "${outside}" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d ' ')"

    # Both rendering and linking must remove the link itself before replacing
    # it, so no temporary or linked file lands in the unrelated directory.
    ln -s "${outside}" "${zellij_dest}/config.kdl"
    ln -s "${outside}" "${zellij_dest}/layouts/kayg.kdl"
    mkdir "${zellij_dest}/plugins/zjstatus.wasm"
    PATH="${mock_bin}:${PATH}" HOME="${test_home}" \
        DOT_TEST_EXPECTED_SHA="${expected_sha}" DOT_TEST_ZJSTATUS_SHA="${zjstatus_sha}" \
        DOT_TEST_TABULA_SHA="${expected_sha}" "${repo_path}/scripts/dot" setup zellij >/dev/null
    assert test -f "${zellij_dest}/config.kdl"
    assert test -L "${zellij_dest}/layouts/kayg.kdl"
    assert test -f "${zellij_dest}/plugins/zjstatus.wasm"
    assert test -d "${zellij_dest}"/plugins/zjstatus.wasm.bak.*
    assert_equal 0 "$(find "${outside}" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d ' ')"
}

test_zsh_plugin_validation() {
    local invalid_home="${test_root}/zsh-invalid-home"
    local valid_home="${test_root}/zsh-valid-home"
    local plugin_dir plugin_name

    mkdir -p "${invalid_home}/.config/zsh/plugins/zsh-autosuggestions"
    if PATH="${mock_bin}:${PATH}" HOME="${invalid_home}" \
        "${repo_path}/scripts/dot" setup zsh >"${test_root}/zsh-invalid.out" 2>&1; then
        printf '%s\n' 'zsh setup accepted a non-clone plugin directory' >&2
        exit 1
    fi
    assert test ! -e "${invalid_home}/.zshenv"
    assert_equal 0 "$(find "${invalid_home}/.config/zsh/plugins/zsh-autosuggestions" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d ' ')"
    assert assert_contains "$(<"${test_root}/zsh-invalid.out")" 'is not a git checkout'

    for plugin_name in zsh-autosuggestions zsh-completions zsh-history-substring-search zsh-syntax-highlighting; do
        plugin_dir="${valid_home}/.config/zsh/plugins/${plugin_name}"
        mkdir -p "${plugin_dir}"
        if [ "${plugin_name}" = zsh-syntax-highlighting ]; then
            printf '%s\n' 'gitdir: ../worktree' > "${plugin_dir}/.git"
        else
            mkdir "${plugin_dir}/.git"
        fi
    done
    PATH="${mock_bin}:${PATH}" HOME="${valid_home}" "${repo_path}/scripts/dot" setup zsh >/dev/null
    assert test -L "${valid_home}/.zshenv"
}

test_zsh_update_uses_real_declared_checkouts() {
    local test_home="${test_root}/zsh-real-update-home"
    local plugins_root="${test_home}/.config/zsh/plugins"
    local origins_root="${test_root}/zsh-real-origins"
    local plugin_name plugin_dir origin seed bump marker
    local missing_dir corrupt_git parent_git

    mkdir -p "${plugins_root}" "${origins_root}"
    for plugin_name in zsh-autosuggestions zsh-completions zsh-history-substring-search zsh-syntax-highlighting; do
        origin="${origins_root}/${plugin_name}.git"
        seed="${test_root}/zsh-seed-${plugin_name}"
        plugin_dir="${plugins_root}/${plugin_name}"
        mkdir -p "${seed}"
        fixture_git init --bare -q --initial-branch=main "${origin}"
        fixture_git -C "${seed}" init -q --initial-branch=main
        fixture_git -C "${seed}" config user.name fixture
        fixture_git -C "${seed}" config user.email fixture@example.com
        printf '%s\n' initial > "${seed}/marker"
        fixture_git -C "${seed}" add marker
        fixture_git -C "${seed}" commit -qm initial
        fixture_git -C "${seed}" remote add origin "${origin}"
        fixture_git -C "${seed}" push -q -u origin main

        if [ "${plugin_name}" = zsh-syntax-highlighting ]; then
            fixture_git clone -q "${origin}" "${test_root}/zsh-worktree-base"
            fixture_git -C "${test_root}/zsh-worktree-base" worktree add -q --track \
                -b linked-worktree "${plugin_dir}" origin/main
        else
            fixture_git clone -q "${origin}" "${plugin_dir}"
        fi
    done

    # Publish one update to every local origin before exercising the preflight.
    for plugin_name in zsh-autosuggestions zsh-completions zsh-history-substring-search zsh-syntax-highlighting; do
        origin="${origins_root}/${plugin_name}.git"
        bump="${test_root}/zsh-bump-${plugin_name}"
        fixture_git clone -q "${origin}" "${bump}"
        fixture_git -C "${bump}" config user.name fixture
        fixture_git -C "${bump}" config user.email fixture@example.com
        printf '%s\n' updated > "${bump}/marker"
        fixture_git -C "${bump}" commit -qam updated
        fixture_git -C "${bump}" push -q
    done

    # Missing expected paths fail before the first valid plugin is pulled.
    missing_dir="${plugins_root}/zsh-completions"
    mv "${missing_dir}" "${missing_dir}.missing"
    if GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 HOME="${test_home}" \
        "${repo_path}/scripts/dot" update zsh >"${test_root}/zsh-missing.out" 2>&1; then
        printf '%s\n' 'zsh update accepted a missing declared plugin' >&2
        exit 1
    fi
    assert_equal initial "$(<"${plugins_root}/zsh-autosuggestions/marker")"
    mv "${missing_dir}.missing" "${missing_dir}"

    # A checkout with a corrupt .git directory is rejected before any pull.
    corrupt_git="${plugins_root}/zsh-history-substring-search/.git"
    mv "${corrupt_git}" "${corrupt_git}.corrupt"
    if GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 HOME="${test_home}" \
        "${repo_path}/scripts/dot" update zsh >"${test_root}/zsh-corrupt.out" 2>&1; then
        printf '%s\n' 'zsh update accepted a corrupt declared plugin' >&2
        exit 1
    fi
    assert_equal initial "$(<"${plugins_root}/zsh-autosuggestions/marker")"
    mv "${corrupt_git}.corrupt" "${corrupt_git}"

    # A child directory of a parent repository is not a plugin checkout.
    parent_git="${plugins_root}/.git"
    fixture_git -C "${plugins_root}" init -q --initial-branch=main
    mv "${plugins_root}/zsh-completions" "${plugins_root}/zsh-completions.real"
    mkdir "${plugins_root}/zsh-completions"
    printf '%s\n' 'gitdir: ../.git' > "${plugins_root}/zsh-completions/.git"
    if GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 HOME="${test_home}" \
        "${repo_path}/scripts/dot" update zsh >"${test_root}/zsh-parent.out" 2>&1; then
        printf '%s\n' 'zsh update accepted a parent-repository child path' >&2
        exit 1
    fi
    assert_equal initial "$(<"${plugins_root}/zsh-autosuggestions/marker")"
    mv "${plugins_root}/zsh-completions" "${plugins_root}/zsh-completions.invalid"
    mv "${plugins_root}/zsh-completions.real" "${plugins_root}/zsh-completions"
    mv "${parent_git}" "${parent_git}.saved"

    # All declared paths now pass, including the linked worktree, and each
    # local origin is pulled without touching the network.
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 HOME="${test_home}" \
        "${repo_path}/scripts/dot" update zsh >/dev/null
    for plugin_name in zsh-autosuggestions zsh-completions zsh-history-substring-search zsh-syntax-highlighting; do
        marker="${plugins_root}/${plugin_name}/marker"
        assert_equal updated "$(<"${marker}")"
    done
}

test_doom_install_is_synchronous() {
    local test_home="${test_root}/doom-home"
    local doom_dest="${test_home}/.config/doom"
    local install_marker="${test_root}/doom-install-complete"
    local event_log="${test_root}/doom-events.log"

    mkdir -p "${test_home}"
    : > "${event_log}"

    if ! PATH="${mock_bin}:${PATH}" \
        DOT_TEST_EVENT_LOG="${event_log}" \
        DOT_TEST_INSTALL_MARKER="${install_marker}" \
        DOT_TEST_EXPECTED_DOOMDIR="${doom_dest}" \
        DOT_TEST_EXPECTED_EMACSDIR="${test_home}/.config/emacs" \
        DOT_TEST_REAL_CP="${real_cp}" \
        HOME="${test_home}" ZELLIJ_SESSION_NAME=test \
        "${repo_path}/scripts/dot" setup doom; then
        printf '%s\n' 'doom setup mock failed' >&2
        exit 1
    fi

    assert test -e "${install_marker}"
    assert test -f "${doom_dest}/init.el"
    assert_equal $'install\noverlay\noverlay\noverlay\nsync' "$(<"${event_log}")"

    # A second setup converges without replacing identical files or creating
    # another backup, while still syncing the runtime after the overlay step.
    local first_backup_count second_backup_count
    first_backup_count="$(find "${doom_dest}" -maxdepth 1 -name 'init.el.bak.*' -type f | wc -l | tr -d ' ')"
    PATH="${mock_bin}:${PATH}" DOT_TEST_EVENT_LOG="${event_log}" \
        DOT_TEST_INSTALL_MARKER="${install_marker}" \
        DOT_TEST_EXPECTED_DOOMDIR="${doom_dest}" \
        DOT_TEST_EXPECTED_EMACSDIR="${test_home}/.config/emacs" \
        DOT_TEST_REAL_CP="${real_cp}" \
        HOME="${test_home}" "${repo_path}/scripts/dot" setup doom
    second_backup_count="$(find "${doom_dest}" -maxdepth 1 -name 'init.el.bak.*' -type f | wc -l | tr -d ' ')"
    assert_equal "${first_backup_count}" "${second_backup_count}"
    assert_equal $'install\noverlay\noverlay\noverlay\nsync\nsync' "$(<"${event_log}")"

    # A divergent user file is backed up before the tracked version replaces it.
    local config_backup
    printf '%s\n' 'user-edited config' > "${doom_dest}/config.el"
    PATH="${mock_bin}:${PATH}" DOT_TEST_EVENT_LOG="${event_log}" \
        DOT_TEST_INSTALL_MARKER="${install_marker}" \
        DOT_TEST_EXPECTED_DOOMDIR="${doom_dest}" \
        DOT_TEST_EXPECTED_EMACSDIR="${test_home}/.config/emacs" \
        DOT_TEST_REAL_CP="${real_cp}" \
        HOME="${test_home}" "${repo_path}/scripts/dot" setup doom >/dev/null
    config_backup="$(find "${doom_dest}" -maxdepth 1 -name 'config.el.bak.*' -type f | sort | tail -n 1)"
    assert test -n "${config_backup}"
    assert_equal 'user-edited config' "$(<"${config_backup}")"
    assert cmp "${repo_path}/doom-emacs/config.el" "${doom_dest}/config.el"

    # Updating the framework uses the same protected overlay and sync order.
    local packages_backup
    printf '%s\n' 'user-edited packages' > "${doom_dest}/packages.el"
    PATH="${mock_bin}:${PATH}" DOT_TEST_EVENT_LOG="${event_log}" \
        DOT_TEST_INSTALL_MARKER="${install_marker}" \
        DOT_TEST_EXPECTED_DOOMDIR="${doom_dest}" \
        DOT_TEST_EXPECTED_EMACSDIR="${test_home}/.config/emacs" \
        DOT_TEST_REAL_CP="${real_cp}" \
        HOME="${test_home}" "${repo_path}/scripts/dot" update doom
    packages_backup="$(find "${doom_dest}" -maxdepth 1 -name 'packages.el.bak.*' -type f | sort | tail -n 1)"
    assert test -n "${packages_backup}"
    assert_equal 'user-edited packages' "$(<"${packages_backup}")"
    assert cmp "${repo_path}/doom-emacs/packages.el" "${doom_dest}/packages.el"
    assert_equal $'install\noverlay\noverlay\noverlay\nsync\nsync\noverlay\nsync\noverlay\nsync' "$(<"${event_log}")"
}

test_doom_archive_overlay() {
    local fixture_repo="${test_root}/doom-archive-repo"
    local fixture_src="${fixture_repo}/doom-emacs"
    local fixture_home="${test_root}/doom-archive-home"
    local fixture_event_log="${test_root}/doom-archive-events.log"

    mkdir -p "${fixture_repo}/scripts/lib" "${fixture_src}" "${fixture_home}"
    "${real_cp}" "${repo_path}/scripts/dot" "${fixture_repo}/scripts/dot"
    "${real_cp}" "${repo_path}/scripts/lib/nix.sh" "${fixture_repo}/scripts/lib/nix.sh"
    "${real_cp}" "${repo_path}/doom-emacs"/*.el "${fixture_src}/"
    "${real_git}" -C "${fixture_src}" init -q
    "${real_git}" -C "${fixture_src}" -c user.name=fixture -c user.email=fixture@example.com add .
    "${real_git}" -C "${fixture_src}" -c user.name=fixture -c user.email=fixture@example.com commit -qm fixture
    : > "${fixture_event_log}"

    PATH="${mock_bin}:${PATH}" \
        DOT_TEST_EVENT_LOG="${fixture_event_log}" \
        DOT_TEST_INSTALL_MARKER="${test_root}/doom-archive-install-complete" \
        DOT_TEST_EXPECTED_DOOMDIR="${fixture_home}/.config/doom" \
        DOT_TEST_EXPECTED_EMACSDIR="${fixture_home}/.config/emacs" \
        DOT_TEST_REAL_CP="${real_cp}" DOT_TEST_REAL_GIT="${real_git}" \
        HOME="${fixture_home}" "${fixture_repo}/scripts/dot" setup doom >/dev/null

    assert cmp "${fixture_src}/init.el" "${fixture_home}/.config/doom/init.el"
    assert cmp "${fixture_src}/config.el" "${fixture_home}/.config/doom/config.el"
    assert cmp "${fixture_src}/packages.el" "${fixture_home}/.config/doom/packages.el"
    assert_equal $'install\noverlay\noverlay\noverlay\nsync' "$(<"${fixture_event_log}")"
}

test_atuin_link_is_idempotent() {
    local test_home="${test_root}/atuin-home"
    local destination source first_target second_target

    mkdir -p "${test_home}"
    source="${mock_bin}/atuin"
    destination="${test_home}/.local/bin/atuin"

    PATH="${mock_bin}:${PATH}" HOME="${test_home}" \
        "${repo_path}/scripts/dot" setup atuin >/dev/null
    first_target="$(readlink "${destination}")"
    assert_equal "${source}" "${first_target}"
    assert test -x "${destination}"

    # Put the destination first so command -v resolves to the managed link,
    # reproducing the macOS ln -sf self-link regression on a rerun.
    PATH="${test_home}/.local/bin:${mock_bin}:${PATH}" HOME="${test_home}" \
        "${repo_path}/scripts/dot" setup atuin >/dev/null
    second_target="$(readlink "${destination}")"
    assert_equal "${first_target}" "${second_target}"
    assert test -x "${destination}"
}

test_zellij_config_rendering
test_zellij_shasum_fallback
test_zellij_config_actual_parser
test_zellij_parser_failure_preserves_config
test_symlink_destinations_are_replaced_safely
test_zsh_plugin_validation
test_zsh_update_uses_real_declared_checkouts
test_doom_install_is_synchronous
test_doom_archive_overlay
test_atuin_link_is_idempotent
printf '%s\n' 'dot regression tests passed'
