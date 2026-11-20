#!/usr/bin/env bats

# The memory shellcheck uses grows much faster than the size of the file it checks: the former
# 992 KB test/cfwf.bats ran out of memory under a 6 GB cap and took build hosts down with it
# (#1982). This suite fails when a tracked shell script, bats file or bash helper grows past
# SHELL_FILE_LIMIT, so a file is split while it is still small enough to lint. A file that is
# knowingly bigger is listed in LARGE_SHELL_FILES with its own limit, measured to lint inside the
# capped shellcheck run of the shell-tests workflow.

load test_helper

SHELL_FILE_LIMIT=$((200 * 1024))

declare -gA LARGE_SHELL_FILES=(
    ["containers/base/development-full/scripts/cfwf"]=$((640 * 1024))
)

# Prints every file git knows of (tracked, or new and not ignored) that shellcheck lints: *.bats,
# *.bash and *.sh files, and any other file whose first line is a sh or bash shebang.
shell_files() {
    local file first
    while IFS= read -r -d '' file; do
        [ -f "${REPO_ROOT}/${file}" ] || continue
        case "${file}" in
            *.bats | *.bash | *.sh)
                printf '%s\n' "${file}"
                continue
                ;;
        esac
        IFS= read -r first < "${REPO_ROOT}/${file}" || true
        case "${first}" in
            '#!'*/sh | '#!'*/bash | '#!'*'/env bash' | '#!'*'/env sh' | '#!'*/sh' '* | '#!'*/bash' '*)
                printf '%s\n' "${file}"
                ;;
        esac
    done < <(git -C "${REPO_ROOT}" ls-files -z --cached --others --exclude-standard)
}

# Prints "<file>: <size> bytes (limit <limit>)" for every shell file over its limit.
oversized_shell_files() {
    local file size limit
    while IFS= read -r file; do
        size=$(wc -c < "${REPO_ROOT}/${file}")
        limit="${LARGE_SHELL_FILES["${file}"]:-${SHELL_FILE_LIMIT}}"
        if [ "${size}" -gt "${limit}" ]; then
            printf '%s: %s bytes (limit %s)\n' "${file}" "${size}" "${limit}"
        fi
    done < <(shell_files)
}

setup() {
    if ! git -C "${REPO_ROOT}" rev-parse --is-inside-work-tree > /dev/null 2>&1; then
        skip "not a git checkout, so there is no list of tracked files"
    fi
}

@test "no tracked shell script, bats file or bash helper is bigger than its size limit (#1982)" {
    run oversized_shell_files
    [ "${status}" -eq 0 ]
    if [ -n "${output}" ]; then
        printf 'Split these files, or measure them under the capped shellcheck before raising a limit:\n%s\n' "${output}" >&2
        return 1
    fi
}

@test "the shell file list covers the test files, the helpers and the extensionless scripts (#1982)" {
    run shell_files
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"test/cfwf-help.bats"* ]]
    [[ "${output}" == *"test/cfwf_helper.bash"* ]]
    [[ "${output}" == *"containers/base/development-full/scripts/cfwf"* ]]
    [[ "${output}" == *$'\n'"oneshot"$'\n'* ]]
}

@test "every large-file exception is still a tracked shell file (#1982)" {
    local listed
    listed=$(shell_files)
    local file
    for file in "${!LARGE_SHELL_FILES[@]}"; do
        if ! grep -qxF "${file}" <<< "${listed}"; then
            printf '%s is listed in LARGE_SHELL_FILES but is not a tracked shell file\n' "${file}" >&2
            return 1
        fi
    done
}

@test "the size check reports a file over the limit (#1982)" {
    SHELL_FILE_LIMIT=10
    run oversized_shell_files
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"test/cfwf-help.bats: "*" bytes (limit 10)"* ]]
}
