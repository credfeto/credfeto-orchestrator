#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are read by the sourced oneshot functions, where shellcheck cannot trace them

# Golden parity cases for the read-only lib/podman queries in the .NET rewrite (#252). test/fixtures/podman-parity.json
# holds a podman stand-in (stub) and, for each case, the lib/podman function, its argument (ORCHESTRATOR_IMAGE for
# current_agent_image_sha), the podman calls it may make with what each prints and returns, and what the function
# printed (stdout), returned (status) and called (calls) in bash. The argument, every podman argument, the scripted
# output and the recorded stdout are printf %b text (only \\, \n, \r, \t and \xHH escapes), so a case can hold
# bytes that are not UTF-8. This file checks the shell functions against the fixture, and
# Credfeto.Orchestrator.Podman.Tests (src/) runs the tool's podman queries with the same stub and checks them against
# the same file. A case marked "refuses" is one the tool must refuse, so bash answers it.
#
# To regenerate the recorded results after a change to the cases, run the last test with PODMAN_PARITY_REGENERATE set
# to the file to write; it keeps the fixture's stub and cases and records what the shell prints, returns and calls.

bats_require_minimum_version 1.5.0

load test_helper
load oneshot_helper

PODMAN_FIXTURE="${BATS_TEST_DIRNAME}/fixtures/podman-parity.json"

# Prints field $2 (a jq path) of case $1
_podman_case() {
    jq -j --argjson i "$1" ".cases[\$i]$2" "${PODMAN_FIXTURE}"
}

# Writes the fixture's podman stand-in over the podman stub in STUB_BIN
_podman_parity_stub() {
    jq -j '.stub' "${PODMAN_FIXTURE}" > "${STUB_BIN}/podman"
    chmod +x "${STUB_BIN}/podman"
}

# Scripts case $2's podman responses into the empty directory $1, as the stub reads them
_podman_parity_responses() {
    local dir="$1" index="$2" count response arg
    count=$(_podman_case "${index}" '.podman | length')
    for ((response = 0; response < count; response++)); do
        : > "${dir}/response-${response}.args"
        while IFS= read -r -d '' arg; do
            printf '%b\0' "${arg}" >> "${dir}/response-${response}.args"
        done < <(jq -j --argjson i "${index}" --argjson r "${response}" \
            '.cases[$i].podman[$r].args[] | "\(.)\u0000"' "${PODMAN_FIXTURE}")
        _podman_case "${index}" ".podman[${response}].stdout" > "${dir}/response-${response}.stdout"
        _podman_case "${index}" ".podman[${response}].stderr" > "${dir}/response-${response}.stderr"
        _podman_case "${index}" ".podman[${response}].status" > "${dir}/response-${response}.status"
    done
}

# Runs case $2's lib/podman function with the stub answering from directory $1 (emptied first), the case's argument
# decoded from printf %b text. Prints the function's output, then a dot and its status; its stderr goes to $3, and the
# stub logs the podman calls to $1/calls.
_podman_parity_call() {
    local dir="$1" index="$2" stderr_file="$3" function arg
    function=$(_podman_case "${index}" '.function')
    case "${function}" in
        current_agent_image_sha | agent_container_exists | agent_container_running | agent_image_cached) ;;
        *) return 1 ;;
    esac
    arg=$(
        printf '%b' "$(_podman_case "${index}" '.arg')"
        printf x
    )
    arg=${arg%x}
    rm -rf "${dir}"
    mkdir -p "${dir}"
    _podman_parity_responses "${dir}" "${index}"
    (
        export PODMAN_PARITY_DIR="${dir}"
        if [ "${function}" = current_agent_image_sha ]; then
            ORCHESTRATOR_IMAGE="${arg}"
            current_agent_image_sha
        else
            "${function}" "${arg}"
        fi
        printf '.%s' "$?"
    ) 2> "${stderr_file}"
}

# Prints stdin as printf %b text: printable ASCII as itself (a backslash doubled), \n, \r and \t, and any other byte
# as \xHH, so a recorded output can hold bytes that are not UTF-8
_podman_parity_escape() {
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

# Prints the podman calls the stub logged in directory $1 as one compact JSON array of argument arrays
_podman_parity_calls() {
    jq -R -c 'rtrimstr("\u001f") | split("\u001f")' "$1/calls" | jq -s -c '.'
}

# Runs every case, as the caller has set ORCHESTRATOR_DOTNET_PODMAN, and prints one line for each whose output, status
# or podman calls differ from the fixture. Switched on, it also checks that the tool answered exactly the "answers"
# cases (lib/podman warns when bash answers instead) and that the stderr matches what the switched-off run left in
# $1/stderr-0-<case>.
_check_podman_parity_cases() {
    local root="$1" count index name tool result expected expected_status calls failures=0 warned
    count=$(jq '.cases | length' "${PODMAN_FIXTURE}")
    [ "${count}" -gt 0 ] || return 1
    _podman_parity_stub
    for ((index = 0; index < count; index++)); do
        name=$(_podman_case "${index}" '.name')
        tool=$(_podman_case "${index}" '.tool')
        expected=$(
            printf '%b' "$(_podman_case "${index}" '.stdout')"
            printf x
        )
        expected_status=$(_podman_case "${index}" '.status')
        result=$(_podman_parity_call "${root}/case" "${index}" "${root}/stderr-${ORCHESTRATOR_DOTNET_PODMAN}-${index}")
        if [ "${result%.*}x" != "${expected}" ] || [ "${result##*.}" != "${expected_status}" ]; then
            printf 'case %d (%s): printed [%s] status %s, expected [%s] status %s\n' "${index}" "${name}" \
                "$(printf '%s' "${result%.*}" | _podman_parity_escape)" "${result##*.}" \
                "$(_podman_case "${index}" '.stdout')" "${expected_status}"
            failures=$((failures + 1))
        fi
        calls=$(_podman_parity_calls "${root}/case")
        if [ "${ORCHESTRATOR_DOTNET_PODMAN}" = 1 ]; then
            warned=answers
            if grep -q 'running podman in bash instead' "${root}/stderr-1-${index}"; then
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
            # A refused case's calls are the tool's (if it called podman before refusing) and then bash's
            [ "${warned}" = answers ] || continue
        fi
        if [ "${calls}" != "$(_podman_case "${index}" '.calls | tojson')" ]; then
            printf 'case %d (%s): called podman %s, expected %s\n' "${index}" "${name}" "${calls}" \
                "$(_podman_case "${index}" '.calls | tojson')"
            failures=$((failures + 1))
        fi
    done
    [ "${failures}" -eq 0 ]
}

# The locales the cases run in: C.UTF-8, and en_GB.UTF-8 as well where the host has it
_podman_parity_locales() {
    printf 'C.UTF-8\n'
    if locale -a 2> /dev/null | grep -qix 'en_GB.utf-\?8'; then
        printf 'en_GB.UTF-8\n'
    fi
}

@test "the lib/podman queries print, return and call what the fixture records for every podman parity case (#252)" {
    local root="${BATS_TEST_TMPDIR}/root" locale
    mkdir -p "${root}"
    ORCHESTRATOR_DOTNET_PODMAN=0
    while IFS= read -r locale; do
        LC_ALL="${locale}" run _check_podman_parity_cases "${root}"
        if [ "${status}" -ne 0 ]; then
            printf '%s: %s\n' "${locale}" "${output}"
        fi
        [ "${status}" -eq 0 ]
    done < <(_podman_parity_locales)
}

# The end-to-end check the plan asks for before each phase's PR: the same cases through the freshly built tool, given
# as ORCHESTRATOR_PARITY_CMD (for example a wrapper running the Release build of src/Credfeto.Orchestrator.Cmd), with
# the stderr compared with the switched-off run's. Skipped when it is not set, as in CI, which has no tool on PATH.
@test "every podman parity case prints, returns and calls the same through ORCHESTRATOR_CMD when switched on (#252)" {
    [ -n "${ORCHESTRATOR_PARITY_CMD:-}" ] || skip "ORCHESTRATOR_PARITY_CMD is not set"
    local root="${BATS_TEST_TMPDIR}/root" locale
    mkdir -p "${root}"
    while IFS= read -r locale; do
        ORCHESTRATOR_DOTNET_PODMAN=0
        LC_ALL="${locale}" run _check_podman_parity_cases "${root}"
        [ "${status}" -eq 0 ]
        ORCHESTRATOR_DOTNET_PODMAN=1
        ORCHESTRATOR_CMD="${ORCHESTRATOR_PARITY_CMD}"
        LC_ALL="${locale}" run _check_podman_parity_cases "${root}"
        if [ "${status}" -ne 0 ]; then
            printf '%s: %s\n' "${locale}" "${output}"
        fi
        [ "${status}" -eq 0 ]
    done < <(_podman_parity_locales)
}

@test "the podman parity fixture covers every lib/podman query the tool answers, each answered and refused (#252)" {
    local function
    for function in current_agent_image_sha agent_container_exists agent_container_running agent_image_cached; do
        [ "$(jq --arg f "${function}" '[.cases[] | select(.function == $f and .tool == "answers")] | length' "${PODMAN_FIXTURE}")" -gt 0 ]
        [ "$(jq --arg f "${function}" '[.cases[] | select(.function == $f and .tool == "refuses")] | length' "${PODMAN_FIXTURE}")" -gt 0 ]
    done
    [ "$(jq '[.cases[] | select(.stdout == null or .status == null or .calls == null)] | length' "${PODMAN_FIXTURE}")" -eq 0 ]
}

# Rewrites the fixture's recorded results from the shell functions: PODMAN_PARITY_REGENERATE names the file to write.
@test "regenerate the podman parity fixture when PODMAN_PARITY_REGENERATE is set (#252)" {
    [ -n "${PODMAN_PARITY_REGENERATE:-}" ] || skip "PODMAN_PARITY_REGENERATE is not set"
    local root="${BATS_TEST_TMPDIR}/root" count index result results="${BATS_TEST_TMPDIR}/results"
    mkdir -p "${root}"
    _podman_parity_stub
    ORCHESTRATOR_DOTNET_PODMAN=0
    count=$(jq '.cases | length' "${PODMAN_FIXTURE}")
    : > "${results}"
    for ((index = 0; index < count; index++)); do
        result=$(LC_ALL=C.UTF-8 _podman_parity_call "${root}/case" "${index}" /dev/null)
        jq -n -c --arg stdout "$(printf '%s' "${result%.*}" | _podman_parity_escape)" --argjson status "${result##*.}" \
            --argjson calls "$(_podman_parity_calls "${root}/case")" \
            '{stdout: $stdout, status: $status, calls: $calls}' >> "${results}"
    done
    jq --slurpfile r "${results}" '.cases |= [to_entries[] | .value + $r[.key]]' "${PODMAN_FIXTURE}" > "${PODMAN_PARITY_REGENERATE}"
}
