#!/usr/bin/env bats

load test_helper

SCRIPT="${REPO_ROOT}/containers/base/development-full/scripts/pre-commit-check"

setup() {
    setup_isolated_env
    # Never trust whatever /etc/gitconfig happens to be on the host running the
    # suite - the script's own hook-resolution order includes "system", and a
    # host that legitimately has a core.hooksPath configured must not leak in.
    export GIT_CONFIG_SYSTEM=/dev/null
    REPO_DIR="${TEST_TMP}/repo"
    git init -q "${REPO_DIR}"
}

teardown() {
    cleanup_stubs
}

write_hook() {
    local path="$1" body="$2"
    mkdir -p "$(dirname "${path}")"
    {
        printf '#!/bin/sh\n'
        printf '%s\n' "${body}"
    } > "${path}"
    chmod +x "${path}"
}

@test "dies when no pre-commit hook is found in any hooksPath" {
    run bash -c 'cd "$1" && "$2"' _ "${REPO_DIR}" "${SCRIPT}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"No pre-commit hook found in the repo's hooks folder, system hooksPath, or global hooksPath"* ]]
}

@test "runs the repo's own hooks/pre-commit with --all-files and reports success" {
    write_hook "${REPO_DIR}/.git/hooks/pre-commit" 'echo "args: $*"'
    run bash -c 'cd "$1" && "$2"' _ "${REPO_DIR}" "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"args: --all-files"* ]]
    [[ "${output}" == *"Pre-commit checks passed"* ]]
}

@test "dies when the resolved hook exits non-zero" {
    write_hook "${REPO_DIR}/.git/hooks/pre-commit" 'exit 1'
    run bash -c 'cd "$1" && "$2"' _ "${REPO_DIR}" "${SCRIPT}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"pre-commit hook failed"* ]]
}

@test "falls back to the system hooksPath when the repo has no hooks/pre-commit" {
    write_hook "${TEST_TMP}/system-hooks/pre-commit" 'echo "system hook ran"'
    local sys_gitconfig="${TEST_TMP}/system-gitconfig"
    git config --file "${sys_gitconfig}" core.hooksPath "${TEST_TMP}/system-hooks"
    run bash -c 'export GIT_CONFIG_SYSTEM="$1"; cd "$2" && "$3"' \
        _ "${sys_gitconfig}" "${REPO_DIR}" "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"system hook ran"* ]]
}

@test "falls back to the global hooksPath when neither repo nor system provide one" {
    write_hook "${TEST_TMP}/global-hooks/pre-commit" 'echo "global hook ran"'
    git config --global core.hooksPath "${TEST_TMP}/global-hooks"
    run bash -c 'cd "$1" && "$2"' _ "${REPO_DIR}" "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"global hook ran"* ]]
}

@test "a non-executable repo hook is skipped in favour of the global hooksPath" {
    write_hook "${REPO_DIR}/.git/hooks/pre-commit" 'echo "should not run"'
    chmod -x "${REPO_DIR}/.git/hooks/pre-commit"
    write_hook "${TEST_TMP}/global-hooks/pre-commit" 'echo "global hook ran"'
    git config --global core.hooksPath "${TEST_TMP}/global-hooks"
    run bash -c 'cd "$1" && "$2"' _ "${REPO_DIR}" "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"global hook ran"* ]]
    [[ "${output}" != *"should not run"* ]]
}
