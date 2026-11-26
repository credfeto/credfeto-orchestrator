#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are read by the sourced oneshot functions, where shellcheck cannot trace them

# Golden parity cases for the two reads of the permission denials in a Claude JSON result in the .NET rewrite (#252):
# claude_result_permission_denials_summary and claude_result_denied_command_names (lib/podman).
# test/fixtures/podman-result-parity.json holds, for each case, the function, the result file's content, what the
# function printed (stdout) and returned (status) in bash, and whether the tool answers or refuses it. The content and
# the recorded stdout are printf %b text (only \\, \n, \r, \t and \xHH escapes), so a case can hold bytes that are not
# UTF-8. This file checks the shell functions against the fixture, and Credfeto.Orchestrator.Podman.Tests (src/) runs
# the tool's reads over the same files and checks them against the same fixture. A case marked "refuses" is one the
# tool must refuse, so bash answers it.
#
# To regenerate the recorded results after a change to the cases, run the last test with
# PODMAN_RESULT_PARITY_REGENERATE set to the file to write; it keeps the fixture's cases and records what the shell
# prints and returns.

bats_require_minimum_version 1.5.0

load test_helper
load oneshot_helper

PODMAN_RESULT_FIXTURE="${BATS_TEST_DIRNAME}/fixtures/podman-result-parity.json"

# Prints field $2 (a jq path) of case $1
_result_case() {
    jq -j --argjson i "$1" ".cases[\$i]$2" "${PODMAN_RESULT_FIXTURE}"
}

# Runs case $2's function over its result file, written to $1 from the case's printf %b content. Prints the function's
# output, then a dot and its status; its stderr goes to $3.
_result_parity_call() {
    local result_file="$1" index="$2" stderr_file="$3" function
    function=$(_result_case "${index}" '.function')
    case "${function}" in
        claude_result_permission_denials_summary | claude_result_denied_command_names) ;;
        *) return 1 ;;
    esac
    printf '%b' "$(_result_case "${index}" '.result')" > "${result_file}"
    (
        "${function}" "${result_file}"
        printf '.%s' "$?"
    ) 2> "${stderr_file}"
}

# Prints stdin as printf %b text: printable ASCII as itself (a backslash doubled), \n, \r and \t, and any other byte
# as \xHH, so a recorded output can hold bytes that are not UTF-8
_result_parity_escape() {
    local hex byte
    hex=$(od -An -v -tx1 | tr -d ' \n')
    while [ -n "${hex}" ]; do
        byte=${hex:0:2}
        hex=${hex:2}
        case "${byte}" in
            0a) printf '\\n' ;;
            0d) printf '\\r' ;;
            09) printf '\\t' ;;
            5c) printf '%s' "\\\\" ;;
            2[0-9a-f] | [3-6][0-9a-f] | 7[0-9a-e]) printf '%b' "\\x${byte}" ;;
            *) printf '\\x%s' "${byte}" ;;
        esac
    done
}

# Runs every case, as the caller has set ORCHESTRATOR_DOTNET_PODMAN, and prints one line for each whose output or
# status differs from the fixture. Switched on, it also checks that the tool answered exactly the "answers" cases
# (lib/podman warns when bash answers instead) and that the stderr matches what the switched-off run left in
# $1/stderr-0-<case>.
_check_result_parity_cases() {
    local root="$1" count index name tool result expected expected_status failures=0 warned
    count=$(jq '.cases | length' "${PODMAN_RESULT_FIXTURE}")
    [ "${count}" -gt 0 ] || return 1
    for ((index = 0; index < count; index++)); do
        name=$(_result_case "${index}" '.name')
        tool=$(_result_case "${index}" '.tool')
        expected=$(
            printf '%b' "$(_result_case "${index}" '.stdout')"
            printf x
        )
        expected_status=$(_result_case "${index}" '.status')
        result=$(_result_parity_call "${root}/result.json" "${index}" "${root}/stderr-${ORCHESTRATOR_DOTNET_PODMAN}-${index}")
        if [ "${result%.*}x" != "${expected}" ] || [ "${result##*.}" != "${expected_status}" ]; then
            printf 'case %d (%s, %s): printed [%s] status %s, expected [%s] status %s\n' "${index}" "${name}" \
                "$(_result_case "${index}" '.function')" "$(printf '%s' "${result%.*}" | _result_parity_escape)" \
                "${result##*.}" "$(_result_case "${index}" '.stdout')" "${expected_status}"
            failures=$((failures + 1))
        fi
        if [ "${ORCHESTRATOR_DOTNET_PODMAN}" = 1 ]; then
            warned=answers
            if grep -q 'running jq in bash instead' "${root}/stderr-1-${index}"; then
                warned=refuses
            fi
            if [ "${warned}" != "${tool}" ]; then
                printf 'case %d (%s, %s): the tool %s it, not %s\n' "${index}" "${name}" \
                    "$(_result_case "${index}" '.function')" "${warned}" "${tool}"
                failures=$((failures + 1))
            fi
            if [ "${warned}" = answers ] && ! cmp -s "${root}/stderr-0-${index}" "${root}/stderr-1-${index}"; then
                printf 'case %d (%s): stderr differs from bash\n' "${index}" "${name}"
                failures=$((failures + 1))
            fi
        fi
    done
    [ "${failures}" -eq 0 ]
}

# The locales the cases run in: C.UTF-8, and en_GB.UTF-8 as well where the host has it
_result_parity_locales() {
    printf 'C.UTF-8\n'
    if locale -a 2> /dev/null | grep -qix 'en_GB.utf-\?8'; then
        printf 'en_GB.UTF-8\n'
    fi
}

@test "the Claude result reads print and return what the fixture records for every result parity case (#252)" {
    local root="${BATS_TEST_TMPDIR}/root" locale
    mkdir -p "${root}"
    ORCHESTRATOR_DOTNET_PODMAN=0
    while IFS= read -r locale; do
        LC_ALL="${locale}" run _check_result_parity_cases "${root}"
        if [ "${status}" -ne 0 ]; then
            printf '%s: %s\n' "${locale}" "${output}"
        fi
        [ "${status}" -eq 0 ]
    done < <(_result_parity_locales)
}

# The end-to-end check the plan asks for before each phase's PR: the same cases through the freshly built tool, given
# as ORCHESTRATOR_PARITY_CMD (for example a wrapper running the Release build of src/Credfeto.Orchestrator.Cmd), with
# the stderr compared with the switched-off run's. Skipped when it is not set, as in CI, which has no tool on PATH.
@test "every result parity case prints and returns the same through ORCHESTRATOR_CMD when switched on (#252)" {
    [ -n "${ORCHESTRATOR_PARITY_CMD:-}" ] || skip "ORCHESTRATOR_PARITY_CMD is not set"
    local root="${BATS_TEST_TMPDIR}/root" locale
    mkdir -p "${root}"
    while IFS= read -r locale; do
        ORCHESTRATOR_DOTNET_PODMAN=0
        LC_ALL="${locale}" run _check_result_parity_cases "${root}"
        [ "${status}" -eq 0 ]
        ORCHESTRATOR_DOTNET_PODMAN=1
        ORCHESTRATOR_CMD="${ORCHESTRATOR_PARITY_CMD}"
        LC_ALL="${locale}" run _check_result_parity_cases "${root}"
        if [ "${status}" -ne 0 ]; then
            printf '%s: %s\n' "${locale}" "${output}"
        fi
        [ "${status}" -eq 0 ]
    done < <(_result_parity_locales)
}

@test "the result parity fixture covers both reads, each answered and refused (#252)" {
    local function
    for function in claude_result_permission_denials_summary claude_result_denied_command_names; do
        [ "$(jq --arg f "${function}" '[.cases[] | select(.function == $f and .tool == "answers")] | length' "${PODMAN_RESULT_FIXTURE}")" -gt 0 ]
        [ "$(jq --arg f "${function}" '[.cases[] | select(.function == $f and .tool == "refuses")] | length' "${PODMAN_RESULT_FIXTURE}")" -gt 0 ]
    done
    [ "$(jq '[.cases[] | select(.stdout == null or .status == null)] | length' "${PODMAN_RESULT_FIXTURE}")" -eq 0 ]
}

# Rewrites the fixture's recorded results from the shell functions: PODMAN_RESULT_PARITY_REGENERATE names the file to
# write.
@test "regenerate the result parity fixture when PODMAN_RESULT_PARITY_REGENERATE is set (#252)" {
    [ -n "${PODMAN_RESULT_PARITY_REGENERATE:-}" ] || skip "PODMAN_RESULT_PARITY_REGENERATE is not set"
    local root="${BATS_TEST_TMPDIR}/root" count index result results="${BATS_TEST_TMPDIR}/results"
    mkdir -p "${root}"
    ORCHESTRATOR_DOTNET_PODMAN=0
    count=$(jq '.cases | length' "${PODMAN_RESULT_FIXTURE}")
    : > "${results}"
    for ((index = 0; index < count; index++)); do
        result=$(LC_ALL=C.UTF-8 _result_parity_call "${root}/result.json" "${index}" /dev/null)
        jq -n -c --arg stdout "$(printf '%s' "${result%.*}" | _result_parity_escape)" --argjson status "${result##*.}" \
            '{stdout: $stdout, status: $status}' >> "${results}"
    done
    jq --slurpfile r "${results}" '.cases |= [to_entries[] | .value + $r[.key]]' "${PODMAN_RESULT_FIXTURE}" \
        > "${PODMAN_RESULT_PARITY_REGENERATE}"
}
