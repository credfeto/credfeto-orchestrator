#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are read by the sourced oneshot functions, where shellcheck cannot trace them

# Golden parity cases for the read-only lib/state queries in the .NET rewrite (#252). test/fixtures/state-parity.json
# holds, for each case, the lib/state function, its arguments, the state files it finds (each a regular file with its
# content, a directory or a symbolic link, under ORCHESTRATOR_STATE_DIR, whose owner/repo directory is
# SESSION_BASE_DIR), the globals it reads, and what it printed (stdout, or the global it sets), returned (status) and
# left behind (remaining: every path under ORCHESTRATOR_STATE_DIR afterwards) in bash. Arguments, contents, link
# targets and the recorded stdout are printf %b text (only \\, \n, \r, \t and \xHH escapes), so a case can hold bytes
# that are not UTF-8, and the fixture stays ASCII. A case with a locale runs only in that locale; the others run in
# C.UTF-8 and en_GB.UTF-8. This file checks the shell functions against the fixture, and
# Credfeto.Orchestrator.State.Tests (src/) builds the same state files, asks the tool's queries and checks them against
# the same file. A case marked "refuses" is one the tool must refuse, so bash answers it.
#
# To regenerate the recorded results after a change to the cases, run the last test with STATE_PARITY_REGENERATE set
# to the file to write; it keeps the fixture's cases and records what the shell prints, returns and leaves behind.

bats_require_minimum_version 1.5.0

load test_helper
load oneshot_helper

STATE_FIXTURE="${BATS_TEST_DIRNAME}/fixtures/state-parity.json"

# Prints field $2 (a jq path) of case $1
_state_case() {
    jq -j --argjson i "$1" ".cases[\$i]$2" "${STATE_FIXTURE}"
}

# Prints printf %b text $1 decoded, trailing newlines kept
_state_decode() {
    local text
    text=$(
        printf '%b' "$1"
        printf x
    )
    printf '%s' "${text%x}"
}

# Builds case $2's state files under the state directory $1
_state_parity_files() {
    local state_dir="$1" index="$2" count file path target
    count=$(_state_case "${index}" '.files | length')
    for ((file = 0; file < count; file++)); do
        path="${state_dir}/$(_state_decode "$(_state_case "${index}" ".files[${file}].path")")"
        mkdir -p "${path%/*}"
        if [ "$(_state_case "${index}" ".files[${file}].dir // false")" = true ]; then
            mkdir -p "${path}"
        elif target=$(_state_case "${index}" ".files[${file}].link // empty") && [ -n "${target}" ]; then
            ln -s "$(_state_decode "${target}")" "${path}"
        else
            # printf writes a NUL byte the content holds, which a command substitution would drop
            printf '%b' "$(_state_case "${index}" ".files[${file}].content")" > "${path}"
        fi
    done
}

# Runs case $2's lib/state function over its state files, built afresh in directory $1. Prints what the function
# printed (or the global it sets), then a dot and its status; its stderr goes to $3.
_state_parity_call() {
    local root="$1" index="$2" stderr_file="$3" function count arg args=() name value
    function=$(_state_case "${index}" '.function')
    count=$(_state_case "${index}" '.args | length')
    for ((arg = 0; arg < count; arg++)); do
        args+=("$(_state_decode "$(_state_case "${index}" ".args[${arg}]")")")
    done
    rm -rf "${root}"
    mkdir -p "${root}/state/owner/repo"
    _state_parity_files "${root}/state" "${index}"
    (
        ORCHESTRATOR_STATE_DIR="${root}/state"
        OWNER=owner
        REPO=repo
        REPO_FULL=owner/repo
        SESSION_BASE_DIR="${root}/state/owner/repo"
        while IFS=$'\x1f' read -r name value; do
            [ -n "${name}" ] && printf -v "${name}" '%s' "${value}"
        done < <(jq -r --argjson i "${index}" '.cases[$i].globals // {} | to_entries[] | "\(.key)\u001f\(.value)"' \
            "${STATE_FIXTURE}")
        case "${function}" in
            load_infra_failure_count)
                load_infra_failure_count "${args[@]}"
                printf '%s.%s' "${INFRA_FAILURE_COUNT}" "$?"
                ;;
            load_env_unblock_attempts)
                load_env_unblock_attempts "${args[@]}"
                printf '%s.%s' "${ENV_UNBLOCK_ATTEMPTS}" "$?"
                ;;
            load_pr_invocation_counts)
                load_pr_invocation_counts "${args[@]}"
                printf '%s %s.%s' "${PR_INVOCATION_TOTAL}" "${PR_INVOCATION_IDLE}" "$?"
                ;;
            load_issue_invocation_counts)
                load_issue_invocation_counts "${args[@]}"
                printf '%s %s.%s' "${ISSUE_INVOCATION_TOTAL}" "${ISSUE_INVOCATION_IDLE}" "$?"
                ;;
            summarise_session_denials_day)
                summarise_session_denials_day "${ORCHESTRATOR_STATE_DIR}/${args[0]}"
                printf '.%s' "$?"
                ;;
            issue_plan_block_marked | issue_blocked_replan_marked | background_stall_marked | load_last_diagnostic | \
                load_precheck_result | pull_duration_baseline | is_owner_rate_limited)
                "${function}" "${args[@]}"
                printf '.%s' "$?"
                ;;
            *) return 1 ;;
        esac
    ) 2> "${stderr_file}"
}

# Prints stdin as printf %b text: printable ASCII as itself (a backslash doubled), \n, \r and \t, and any other byte
# as \xHH, so a recorded output can hold bytes that are not UTF-8
_state_parity_escape() {
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

# Prints every path under the state directory $1 (links not followed) as one compact JSON array, sorted bytewise, the
# names as printf %b text
_state_parity_remaining() {
    local path
    while IFS= read -r -d '' path; do
        printf '%s' "${path}" | _state_parity_escape
        printf '\n'
    done < <(cd "$1" && find . -mindepth 1 -print0 | LC_ALL=C sort -z) | jq -R -s -c 'split("\n") | map(select(length > 0))'
}

# Runs every case for the locale the caller set in LC_ALL, as the caller has set ORCHESTRATOR_DOTNET_STATE, and prints
# one line for each whose output, status or remaining files differ from the fixture. Switched on, it also checks that
# the tool answered exactly the "answers" cases (lib/state warns when bash answers instead) and that the stderr
# matches what the switched-off run left in $1/stderr-0-<case>.
_check_state_parity_cases() {
    local root="$1" count index name tool locale result expected expected_status remaining failures=0 warned
    count=$(jq '.cases | length' "${STATE_FIXTURE}")
    [ "${count}" -gt 0 ] || return 1
    for ((index = 0; index < count; index++)); do
        locale=$(_state_case "${index}" '.locale // empty')
        [ -z "${locale}" ] || [ "${locale}" = "${LC_ALL}" ] || continue
        name=$(_state_case "${index}" '.name')
        tool=$(_state_case "${index}" '.tool')
        expected=$(
            printf '%b' "$(_state_case "${index}" '.stdout')"
            printf x
        )
        expected_status=$(_state_case "${index}" '.status')
        result=$(_state_parity_call "${root}/case" "${index}" "${root}/stderr-${ORCHESTRATOR_DOTNET_STATE}-${index}")
        if [ "${result%.*}x" != "${expected}" ] || [ "${result##*.}" != "${expected_status}" ]; then
            printf 'case %d (%s): printed [%s] status %s, expected [%s] status %s\n' "${index}" "${name}" \
                "$(printf '%s' "${result%.*}" | _state_parity_escape)" "${result##*.}" \
                "$(_state_case "${index}" '.stdout')" "${expected_status}"
            failures=$((failures + 1))
        fi
        remaining=$(_state_parity_remaining "${root}/case/state")
        if [ "${remaining}" != "$(_state_case "${index}" '.remaining | tojson')" ]; then
            printf 'case %d (%s): left %s, expected %s\n' "${index}" "${name}" "${remaining}" \
                "$(_state_case "${index}" '.remaining | tojson')"
            failures=$((failures + 1))
        fi
        if [ "${ORCHESTRATOR_DOTNET_STATE}" = 1 ]; then
            warned=answers
            if grep -q 'answering in bash instead' "${root}/stderr-1-${index}"; then
                warned=refuses
            fi
            if [ "${warned}" != "${tool}" ]; then
                printf 'case %d (%s): the tool %s it, not %s\n' "${index}" "${name}" "${warned}" "${tool}"
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
_state_parity_locales() {
    printf 'C.UTF-8\n'
    if locale -a 2> /dev/null | grep -qix 'en_GB.utf-\?8'; then
        printf 'en_GB.UTF-8\n'
    fi
}

@test "the lib/state queries print, return and leave what the fixture records for every state parity case (#252)" {
    local root="${BATS_TEST_TMPDIR}/root" locale
    mkdir -p "${root}"
    ORCHESTRATOR_DOTNET_STATE=0
    while IFS= read -r locale; do
        LC_ALL="${locale}" run _check_state_parity_cases "${root}"
        if [ "${status}" -ne 0 ]; then
            printf '%s: %s\n' "${locale}" "${output}"
        fi
        [ "${status}" -eq 0 ]
    done < <(_state_parity_locales)
}

# The end-to-end check the plan asks for before each phase's PR: the same cases through the freshly built tool, given
# as ORCHESTRATOR_PARITY_CMD (for example a wrapper running the Release build of src/Credfeto.Orchestrator.Cmd), with
# the stderr compared with the switched-off run's. Skipped when it is not set, as in CI, which has no tool on PATH.
@test "every state parity case prints, returns and leaves the same through ORCHESTRATOR_CMD when switched on (#252)" {
    [ -n "${ORCHESTRATOR_PARITY_CMD:-}" ] || skip "ORCHESTRATOR_PARITY_CMD is not set"
    local root="${BATS_TEST_TMPDIR}/root" locale
    mkdir -p "${root}"
    while IFS= read -r locale; do
        ORCHESTRATOR_DOTNET_STATE=0
        LC_ALL="${locale}" run _check_state_parity_cases "${root}"
        [ "${status}" -eq 0 ]
        ORCHESTRATOR_DOTNET_STATE=1
        ORCHESTRATOR_CMD="${ORCHESTRATOR_PARITY_CMD}"
        LC_ALL="${locale}" run _check_state_parity_cases "${root}"
        if [ "${status}" -ne 0 ]; then
            printf '%s: %s\n' "${locale}" "${output}"
        fi
        [ "${status}" -eq 0 ]
    done < <(_state_parity_locales)
}

@test "the state parity fixture covers every lib/state query the tool answers, each answered and refused (#252)" {
    local function
    for function in load_infra_failure_count load_env_unblock_attempts load_pr_invocation_counts \
        load_issue_invocation_counts load_last_diagnostic load_precheck_result pull_duration_baseline \
        is_owner_rate_limited summarise_session_denials_day; do
        [ "$(jq --arg f "${function}" '[.cases[] | select(.function == $f and .tool == "answers")] | length' "${STATE_FIXTURE}")" -gt 0 ]
        [ "$(jq --arg f "${function}" '[.cases[] | select(.function == $f and .tool == "refuses")] | length' "${STATE_FIXTURE}")" -gt 0 ]
    done
    for function in issue_plan_block_marked issue_blocked_replan_marked background_stall_marked; do
        [ "$(jq --arg f "${function}" '[.cases[] | select(.function == $f and .tool == "answers")] | length' "${STATE_FIXTURE}")" -gt 0 ]
    done
    [ "$(jq '[.cases[] | select(.stdout == null or .status == null or .remaining == null)] | length' "${STATE_FIXTURE}")" -eq 0 ]
}

# Rewrites the fixture's recorded results from the shell functions: STATE_PARITY_REGENERATE names the file to write.
@test "regenerate the state parity fixture when STATE_PARITY_REGENERATE is set (#252)" {
    [ -n "${STATE_PARITY_REGENERATE:-}" ] || skip "STATE_PARITY_REGENERATE is not set"
    local root="${BATS_TEST_TMPDIR}/root" count index result results="${BATS_TEST_TMPDIR}/results" locale
    mkdir -p "${root}"
    ORCHESTRATOR_DOTNET_STATE=0
    count=$(jq '.cases | length' "${STATE_FIXTURE}")
    : > "${results}"
    for ((index = 0; index < count; index++)); do
        locale=$(_state_case "${index}" '.locale // "C.UTF-8"')
        result=$(LC_ALL="${locale}" _state_parity_call "${root}/case" "${index}" /dev/null)
        jq -n -c --arg stdout "$(printf '%s' "${result%.*}" | _state_parity_escape)" --argjson status "${result##*.}" \
            --argjson remaining "$(_state_parity_remaining "${root}/case/state")" \
            '{stdout: $stdout, status: $status, remaining: $remaining}' >> "${results}"
    done
    jq --slurpfile r "${results}" '.cases |= [to_entries[] | .value + $r[.key]]' "${STATE_FIXTURE}" > "${STATE_PARITY_REGENERATE}"
}
