#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are read by the sourced oneshot functions, where shellcheck cannot trace them

# Golden parity cases for the lib/state writes in the .NET rewrite (#252). test/fixtures/state-writes-parity.json holds,
# for each case, the lib/state function, its arguments, the umask it runs under (022 unless given), the files it finds
# under ORCHESTRATOR_STATE_DIR (each a regular file with its content and mode, a directory with its mode, a symbolic
# link or a hard link to another of the files; owner/repo, which is SESSION_BASE_DIR, is made first unless the case
# says no_session_dir), the globals it reads, and what it printed (stdout), returned (status) and left behind (left:
# every path under ORCHESTRATOR_STATE_DIR afterwards, with its type (f, d or l), the mode of a file or directory, the
# content of a file and the target of a link). Arguments, contents, link targets and the recorded stdout are printf %b
# text (only \\, \n, \r, \t and \xHH escapes), so a case can hold bytes that are not UTF-8, and the fixture stays ASCII.
# Every case runs in C.UTF-8 and en_GB.UTF-8. This file checks the shell functions against the fixture, and
# Credfeto.Orchestrator.State.Tests (src/) builds the same files, asks the tool's writes and checks them against the
# same file. A case marked "refuses" is one the tool must refuse (or fail on without touching anything), so bash writes
# it.
#
# To regenerate the recorded results after a change to the cases, run the last test with STATE_WRITES_PARITY_REGENERATE
# set to the file to write; it keeps the fixture's cases and records what the shell prints, returns and leaves behind.

bats_require_minimum_version 1.5.0

load test_helper
load oneshot_helper

STATE_WRITES_FIXTURE="${BATS_TEST_DIRNAME}/fixtures/state-writes-parity.json"

# Prints field $2 (a jq path) of case $1
_state_writes_case() {
    jq -j --argjson i "$1" ".cases[\$i]$2" "${STATE_WRITES_FIXTURE}"
}

# Prints printf %b text $1 decoded, trailing newlines kept
_state_writes_decode() {
    local text
    text=$(
        printf '%b' "$1"
        printf x
    )
    printf '%s' "${text%x}"
}

# Builds case $2's files under the state directory $1, then sets their modes, last file first, so a directory's own
# mode comes after the files made in it
_state_writes_files() {
    local state_dir="$1" index="$2" count file path target modes=()
    count=$(_state_writes_case "${index}" '.files | length')
    for ((file = 0; file < count; file++)); do
        path="${state_dir}/$(_state_writes_decode "$(_state_writes_case "${index}" ".files[${file}].path")")"
        mkdir -p "${path%/*}"
        if [ "$(_state_writes_case "${index}" ".files[${file}].dir // false")" = true ]; then
            mkdir -p "${path}"
        elif target=$(_state_writes_case "${index}" ".files[${file}].link // empty") && [ -n "${target}" ]; then
            ln -s "$(_state_writes_decode "${target}")" "${path}"
        elif target=$(_state_writes_case "${index}" ".files[${file}].hardlink // empty") && [ -n "${target}" ]; then
            ln "${state_dir}/$(_state_writes_decode "${target}")" "${path}"
        else
            # printf writes a NUL byte the content holds, which a command substitution would drop
            printf '%b' "$(_state_writes_case "${index}" ".files[${file}].content")" > "${path}"
        fi
        modes=("$(_state_writes_case "${index}" ".files[${file}].mode // empty")" "${path}" "${modes[@]}")
    done
    while [ "${#modes[@]}" -gt 0 ]; do
        [ -z "${modes[0]}" ] || chmod "${modes[0]}" "${modes[1]}"
        modes=("${modes[@]:2}")
    done
}

# Removes directory $1 and everything under it, read-only directories included
_state_writes_clear() {
    [ -e "$1" ] || return 0
    chmod -R u+rwx "$1"
    rm -rf "$1"
}

# Runs case $2's lib/state function over its files, built afresh in directory $1, under the case's umask. Prints what
# the function printed, then a dot and its status (1 when it died); its stderr goes to $3.
_state_writes_call() {
    local root="$1" index="$2" stderr_file="$3" function count arg decoded args=() name value case_umask output
    function=$(_state_writes_case "${index}" '.function')
    case_umask=$(_state_writes_case "${index}" '.umask // "022"')
    count=$(_state_writes_case "${index}" '.args | length')
    for ((arg = 0; arg < count; arg++)); do
        # printf -v keeps an argument's trailing newlines, which a command substitution would drop
        printf -v decoded '%b' "$(_state_writes_case "${index}" ".args[${arg}]")"
        args+=("${decoded}")
    done
    _state_writes_clear "${root}"
    umask 022
    mkdir -p "${root}/state"
    if [ "$(_state_writes_case "${index}" '.no_session_dir // false')" != true ]; then
        mkdir -p "${root}/state/owner/repo"
    fi
    _state_writes_files "${root}/state" "${index}"
    output=$(
        (
            umask "${case_umask}"
            ORCHESTRATOR_STATE_DIR="${root}/state"
            OWNER=owner
            REPO=repo
            REPO_FULL=owner/repo
            SESSION_BASE_DIR="${root}/state/owner/repo"
            while IFS=$'\x1f' read -r name value; do
                [ -n "${name}" ] && printf -v "${name}" '%s' "${value}"
            done < <(jq -r --argjson i "${index}" '.cases[$i].globals // {} | to_entries[] | "\(.key)\u001f\(.value)"' \
                "${STATE_WRITES_FIXTURE}")
            case "${function}" in
                save_infra_failure_count | save_pr_invocation_counts | save_issue_invocation_counts | \
                    save_env_unblock_attempts | save_rate_limit | save_precheck_result | save_last_diagnostic)
                    "${function}" "${args[@]}"
                    ;;
                *) exit 99 ;;
            esac
        ) 2> "${stderr_file}"
        printf '.%s' "$?"
    )
    printf '%s' "${output}"
}

# Prints stdin as printf %b text: printable ASCII as itself (a backslash doubled), \n, \r and \t, and any other byte
# as \xHH, so a recorded output can hold bytes that are not UTF-8
_state_writes_escape() {
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

# Prints every path under the state directory $1 (links not followed) as one compact JSON array of {path, type, mode,
# content} (a file), {path, type, mode} (a directory) or {path, type, target} (a link), sorted bytewise by path, the
# names, contents and targets as printf %b text
_state_writes_left() {
    local path type mode
    while IFS= read -r -d '' path; do
        type=$(cd "$1" && find "${path}" -maxdepth 0 -printf '%y')
        mode=$(cd "$1" && find "${path}" -maxdepth 0 -printf '%m')
        case "${type}" in
            f)
                jq -n -c --arg path "$(printf '%s' "${path}" | _state_writes_escape)" --arg mode "$(printf '%04d' "${mode}")" \
                    --arg content "$(_state_writes_escape < "$1/${path}")" \
                    '{path: $path, type: "f", mode: $mode, content: $content}'
                ;;
            d)
                jq -n -c --arg path "$(printf '%s' "${path}" | _state_writes_escape)" --arg mode "$(printf '%04d' "${mode}")" \
                    '{path: $path, type: "d", mode: $mode}'
                ;;
            *)
                jq -n -c --arg path "$(printf '%s' "${path}" | _state_writes_escape)" --arg type "${type}" \
                    --arg target "$(readlink -n "$1/${path}" | _state_writes_escape)" \
                    '{path: $path, type: $type, target: $target}'
                ;;
        esac
    done < <(cd "$1" && find . -mindepth 1 -print0 | LC_ALL=C sort -z) | jq -s -c '.'
}

# Runs every case for the locale the caller set in LC_ALL, as the caller has set ORCHESTRATOR_DOTNET_STATE, and prints
# one line for each whose output, status or files left behind differ from the fixture. Switched on, it also checks
# that the tool wrote exactly the "answers" cases (lib/state warns when bash writes instead) and that the stderr
# matches what the switched-off run left in $1/stderr-0-<case>.
_check_state_writes_cases() {
    local root="$1" count index name tool result expected expected_status left failures=0 warned
    count=$(jq '.cases | length' "${STATE_WRITES_FIXTURE}")
    [ "${count}" -gt 0 ] || return 1
    for ((index = 0; index < count; index++)); do
        name=$(_state_writes_case "${index}" '.name')
        tool=$(_state_writes_case "${index}" '.tool')
        expected=$(
            printf '%b' "$(_state_writes_case "${index}" '.stdout')"
            printf x
        )
        expected_status=$(_state_writes_case "${index}" '.status')
        result=$(_state_writes_call "${root}/case" "${index}" "${root}/stderr-${ORCHESTRATOR_DOTNET_STATE}-${index}")
        if [ "${result%.*}x" != "${expected}" ] || [ "${result##*.}" != "${expected_status}" ]; then
            printf 'case %d (%s): printed [%s] status %s, expected [%s] status %s\n' "${index}" "${name}" \
                "$(printf '%s' "${result%.*}" | _state_writes_escape)" "${result##*.}" \
                "$(_state_writes_case "${index}" '.stdout')" "${expected_status}"
            failures=$((failures + 1))
        fi
        left=$(_state_writes_left "${root}/case/state")
        if [ "${left}" != "$(_state_writes_case "${index}" '.left | tojson')" ]; then
            printf 'case %d (%s): left %s, expected %s\n' "${index}" "${name}" "${left}" \
                "$(_state_writes_case "${index}" '.left | tojson')"
            failures=$((failures + 1))
        fi
        if [ "${ORCHESTRATOR_DOTNET_STATE}" = 1 ]; then
            warned=answers
            if grep -q 'writing it in bash instead' "${root}/stderr-1-${index}"; then
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
    _state_writes_clear "${root}/case"
    [ "${failures}" -eq 0 ]
}

# The locales the cases run in: C.UTF-8, and en_GB.UTF-8 as well where the host has it
_state_writes_locales() {
    printf 'C.UTF-8\n'
    if locale -a 2> /dev/null | grep -qix 'en_GB.utf-\?8'; then
        printf 'en_GB.UTF-8\n'
    fi
}

# The read-only file and directory cases only fail for a user that permissions apply to
_state_writes_skip_root() {
    [ "$(id -u)" != 0 ] || skip "permissions do not apply to root"
}

@test "the lib/state writes print, return and leave what the fixture records for every state writes parity case (#252)" {
    _state_writes_skip_root
    local root="${BATS_TEST_TMPDIR}/root" locale
    mkdir -p "${root}"
    ORCHESTRATOR_DOTNET_STATE=0
    while IFS= read -r locale; do
        LC_ALL="${locale}" run _check_state_writes_cases "${root}"
        if [ "${status}" -ne 0 ]; then
            printf '%s: %s\n' "${locale}" "${output}"
        fi
        [ "${status}" -eq 0 ]
    done < <(_state_writes_locales)
}

# The end-to-end check the plan asks for before each phase's PR: the same cases through the freshly built tool, given
# as ORCHESTRATOR_PARITY_CMD (for example a wrapper running the Release build of src/Credfeto.Orchestrator.Cmd), with
# the stderr compared with the switched-off run's. Skipped when it is not set, as in CI, which has no tool on PATH.
@test "every state writes parity case prints, returns and leaves the same through ORCHESTRATOR_CMD when switched on (#252)" {
    [ -n "${ORCHESTRATOR_PARITY_CMD:-}" ] || skip "ORCHESTRATOR_PARITY_CMD is not set"
    _state_writes_skip_root
    local root="${BATS_TEST_TMPDIR}/root" locale
    mkdir -p "${root}"
    while IFS= read -r locale; do
        ORCHESTRATOR_DOTNET_STATE=0
        LC_ALL="${locale}" run _check_state_writes_cases "${root}"
        [ "${status}" -eq 0 ]
        ORCHESTRATOR_DOTNET_STATE=1
        ORCHESTRATOR_CMD="${ORCHESTRATOR_PARITY_CMD}"
        LC_ALL="${locale}" run _check_state_writes_cases "${root}"
        if [ "${status}" -ne 0 ]; then
            printf '%s: %s\n' "${locale}" "${output}"
        fi
        [ "${status}" -eq 0 ]
    done < <(_state_writes_locales)
}

@test "the state writes parity fixture covers every lib/state write the tool makes, each written and refused (#252)" {
    local function
    for function in save_infra_failure_count save_pr_invocation_counts save_issue_invocation_counts \
        save_env_unblock_attempts save_rate_limit save_precheck_result save_last_diagnostic; do
        [ "$(jq --arg f "${function}" '[.cases[] | select(.function == $f and .tool == "answers")] | length' "${STATE_WRITES_FIXTURE}")" -gt 0 ]
        [ "$(jq --arg f "${function}" '[.cases[] | select(.function == $f and .tool == "refuses")] | length' "${STATE_WRITES_FIXTURE}")" -gt 0 ]
    done
    [ "$(jq '[.cases[] | select(.stdout == null or .status == null or .left == null)] | length' "${STATE_WRITES_FIXTURE}")" -eq 0 ]
}

# Rewrites the fixture's recorded results from the shell functions: STATE_WRITES_PARITY_REGENERATE names the file to
# write.
@test "regenerate the state writes parity fixture when STATE_WRITES_PARITY_REGENERATE is set (#252)" {
    [ -n "${STATE_WRITES_PARITY_REGENERATE:-}" ] || skip "STATE_WRITES_PARITY_REGENERATE is not set"
    _state_writes_skip_root
    local root="${BATS_TEST_TMPDIR}/root" count index result results="${BATS_TEST_TMPDIR}/results"
    mkdir -p "${root}"
    ORCHESTRATOR_DOTNET_STATE=0
    count=$(jq '.cases | length' "${STATE_WRITES_FIXTURE}")
    : > "${results}"
    for ((index = 0; index < count; index++)); do
        result=$(LC_ALL=C.UTF-8 _state_writes_call "${root}/case" "${index}" /dev/null)
        jq -n -c --arg stdout "$(printf '%s' "${result%.*}" | _state_writes_escape)" --argjson status "${result##*.}" \
            --argjson left "$(_state_writes_left "${root}/case/state")" \
            '{stdout: $stdout, status: $status, left: $left}' >> "${results}"
    done
    _state_writes_clear "${root}/case"
    jq --slurpfile r "${results}" '.cases |= [to_entries[] | .value + $r[.key]]' "${STATE_WRITES_FIXTURE}" \
        > "${STATE_WRITES_PARITY_REGENERATE}"
}
