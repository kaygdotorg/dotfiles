#!/usr/bin/env bash

set -euo pipefail

repo_path="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/dot-regressions.XXXXXX")"
trap 'rm -rf "${test_root}"' EXIT
mock_bin="${test_root}/mock-bin"
mkdir -p "${mock_bin}"
for mock_name in git atuin; do
    ln -s "${repo_path}/scripts/tests/mock-command" "${mock_bin}/${mock_name}"
done
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

test_symlink_destinations_are_replaced_safely() {
    local test_home="${test_root}/symlink-home"
    local outside="${test_root}/unrelated-dir"

    mkdir -p "${test_home}/.local/bin" "${outside}"
    ln -s "${outside}" "${test_home}/.local/bin/dot"
    PATH="${mock_bin}:${PATH}" HOME="${test_home}" "${repo_path}/scripts/dot" setup dot >/dev/null
    assert test -L "${test_home}/.local/bin/dot"
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

test_symlink_destinations_are_replaced_safely
test_zsh_plugin_validation
test_zsh_update_uses_real_declared_checkouts
test_atuin_link_is_idempotent
printf '%s\n' 'dot regression tests passed'
