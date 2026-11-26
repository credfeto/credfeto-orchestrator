#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are read by the sourced oneshot functions, where shellcheck cannot trace them
# shellcheck disable=SC2016  # the stand-in scripts written here expand their own variables

# Golden parity cases for the session-outcome text heuristics in the .NET rewrite (#252):
# claude_result_indicates_background_stall, claude_result_indicates_diagnostic_refusal,
# claude_result_indicates_tool_denied_quit, review_result_marker and claude_result_indicates_clean_review
# (lib/podman). test/fixtures/podman-text-parity.json holds the messages (printf %b text, so a message can hold bytes
# that are not UTF-8) and, for each case, the function, the message, the locale it runs in (none: every locale this
# file checks, which ASCII messages get the same answer in), any pattern or marker globals set first, what the
# function printed (stdout) and returned (status) in bash, and whether the tool answers, refuses or is not asked
# (not-called: the length cap or the empty test in bash decides first). "functions" records the query and the
# arguments each function passes to the tool after the locale, and a case with globals records its own (args).
# This file checks the shell functions against the fixture, and Credfeto.Orchestrator.Podman.Tests (src/) runs the
# tool's heuristics over the same messages and checks them against the same fixture.
#
# To regenerate the recorded results after a change to the cases or to the patterns in lib/globals, run the last
# test with PODMAN_TEXT_PARITY_REGENERATE set to the file to write; it keeps the fixture's messages and cases and
# records what the shell prints, returns and passes.

bats_require_minimum_version 1.5.0

load test_helper
load oneshot_helper

PODMAN_TEXT_FIXTURE="${BATS_TEST_DIRNAME}/fixtures/podman-text-parity.json"

PODMAN_TEXT_FUNCTIONS=(
    claude_result_indicates_background_stall
    claude_result_indicates_diagnostic_refusal
    claude_result_indicates_tool_denied_quit
    review_result_marker
    claude_result_indicates_clean_review
)

# Prints every case in one jq pass, each ended by \x1e, its fields separated by \x1f: index, function, the message's
# printf %b text, locale, globals (compact JSON or empty), tool, stdout, status and the message's name
_text_parity_cases() {
    jq -j '.messages as $m | .cases | to_entries[]
        | [(.key | tostring), .value.function, $m[.value.message].text, (.value.locale // ""),
            (if .value.globals then (.value.globals | tojson) else "" end), .value.tool, (.value.stdout // ""),
            ((.value.status // "") | tostring), $m[.value.message].name]
        | join("\u001f") + "\u001e"' "${PODMAN_TEXT_FIXTURE}"
}

# Sets the pattern arrays and marker strings named in the JSON object $1, as a case's globals give them
_text_parity_set_globals() {
    local globals="$1" name
    [ -n "${globals}" ] || return 0
    while IFS= read -r -d '' name; do
        case "${name}" in
            TOOL_DENIAL_MENTION_PATTERNS | TOOL_DENIED_GIVE_UP_PATTERNS | TOOL_DENIED_WORKAROUND_PATTERNS | \
                TOOL_DENIED_NEGATED_WORKAROUND_PATTERNS | CLEAN_REVIEW_PATTERNS | REVIEW_FINDINGS_PATTERNS | \
                REVIEW_FINDINGS_NEGATED_PATTERNS)
                mapfile -d '' -t "${name}" < <(jq -j --arg n "${name}" '.[$n][] + "\u0000"' <<< "${globals}")
                ;;
            REVIEW_RESULT_CLEAN_MARKER | REVIEW_RESULT_FINDINGS_MARKER)
                printf -v "${name}" '%s' "$(jq -j --arg n "${name}" '.[$n]' <<< "${globals}")"
                ;;
            *) return 1 ;;
        esac
    done < <(jq -j 'keys[] + "\u0000"' <<< "${globals}")
}

# Runs function $1 over the printf %b message $2 in locale $3, with the globals in $4 set first. Prints the
# function's output, then a dot and its status; its stderr goes to $5.
_text_parity_call() {
    local function="$1" message="$2" locale="$3" globals="$4" stderr_file="$5" text
    case " ${PODMAN_TEXT_FUNCTIONS[*]} " in
        *" ${function} "*) ;;
        *) return 1 ;;
    esac
    (
        _text_parity_set_globals "${globals}" || exit 99
        LC_ALL="${locale}"
        printf -v text '%b' "${message}"
        "${function}" "${text}"
        printf '.%s' "$?"
    ) 2> "${stderr_file}"
}

# Prints stdin as printf %b text: printable ASCII as itself (a backslash doubled), \n, \r and \t, and any other byte
# as \xHH
_text_parity_escape() {
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

# The locales a case without one runs in: C.UTF-8, en_GB.UTF-8 where the host has it, and C
_text_parity_locales() {
    printf 'C.UTF-8\n'
    if locale -a 2> /dev/null | grep -qix 'en_GB.utf-\?8'; then
        printf 'en_GB.UTF-8\n'
    fi
    printf 'C\n'
}

# Writes $1/orch, an ORCHESTRATOR_CMD that notes each call in $1/called and runs $2
_text_parity_counting_cmd() {
    local root="$1" target="$2"
    printf '#!/bin/sh\n: >> "%s/called"\nexec "%s" "$@"\n' "${root}" "${target}" > "${root}/orch"
    chmod 755 "${root}/orch"
}

# Checks one run of a case (index $2, function $3, message $4, locale $5, globals $6, tool $7, stdout $8, status $9,
# name $10) as the caller has set ORCHESTRATOR_DOTNET_PODMAN, printing a line for each difference. Switched on, it
# also checks the tool was asked exactly when the case says, answered exactly the "answers" cases (lib/podman warns
# when bash answers instead), and left the stderr the switched-off run left in $1.
_check_text_parity_run() {
    local root="$1" index="$2" function="$3" message="$4" locale="$5" globals="$6" tool="$7" stdout="$8"
    local status="$9" name="${10}" result expected seen stderr_off stderr_on
    stderr_off="${root}/stderr-0-${index}-${locale}"
    stderr_on="${root}/stderr-1-${index}-${locale}"
    rm -f "${root}/called"
    result=$(_text_parity_call "${function}" "${message}" "${locale}" "${globals}" \
        "${root}/stderr-${ORCHESTRATOR_DOTNET_PODMAN}-${index}-${locale}")
    expected=$(
        printf '%b' "${stdout}"
        printf x
    )
    if [ "${result%.*}x" != "${expected}" ] || [ "${result##*.}" != "${status}" ]; then
        printf 'case %d (%s, %s, %s): printed [%s] status %s, expected [%s] status %s\n' "${index}" "${name}" \
            "${function}" "${locale}" "$(printf '%s' "${result%.*}" | _text_parity_escape)" "${result##*.}" \
            "${stdout}" "${status}"
        return 1
    fi
    [ "${ORCHESTRATOR_DOTNET_PODMAN}" = 1 ] || return 0
    seen=not-called
    if [ -e "${root}/called" ]; then
        seen=answers
        if grep -q 'matching it in bash instead' "${stderr_on}"; then
            seen=refuses
        fi
    fi
    if [ "${seen}" != "${tool}" ]; then
        printf 'case %d (%s, %s, %s): the tool %s it, not %s\n' "${index}" "${name}" "${function}" "${locale}" \
            "${seen}" "${tool}"
        return 1
    fi
    if [ "${seen}" != refuses ] && ! cmp -s "${stderr_off}" "${stderr_on}"; then
        printf 'case %d (%s, %s): stderr differs from bash\n' "${index}" "${name}" "${locale}"
        return 1
    fi
}

# Runs every case in its locale, or in each of _text_parity_locales when it has none
_check_text_parity_cases() {
    local root="$1" index function message locale globals tool stdout status name run_locale failures=0
    local -a locales run_locales
    mapfile -t locales < <(_text_parity_locales)
    while IFS=$'\x1f' read -r -d $'\x1e' index function message locale globals tool stdout status name; do
        run_locales=("${locales[@]}")
        if [ -n "${locale}" ]; then
            run_locales=("${locale}")
        fi
        for run_locale in "${run_locales[@]}"; do
            _check_text_parity_run "${root}" "${index}" "${function}" "${message}" "${run_locale}" "${globals}" \
                "${tool}" "${stdout}" "${status}" "${name}" || failures=$((failures + 1))
        done
    done < <(_text_parity_cases)
    [ "${failures}" -eq 0 ]
}

# Prints, as a JSON object {query, args}, what function $1 passes to ORCHESTRATOR_CMD switched on, with the globals
# in $2 set first: the query, and the arguments after the two locale options
_text_parity_passed() {
    local function="$1" globals="$2" root="${BATS_TEST_TMPDIR}/passed"
    mkdir -p "${root}"
    printf '#!/bin/sh\nfor a in "$@"; do printf "%%s\\0" "$a"; done > "%s/argv"\nexit 3\n' "${root}" > "${root}/orch"
    chmod 755 "${root}/orch"
    rm -f "${root}/argv"
    (
        ORCHESTRATOR_DOTNET_PODMAN=1
        ORCHESTRATOR_CMD="${root}/orch"
        _text_parity_set_globals "${globals}" || exit 99
        "${function}" "message" > /dev/null 2>&1
    )
    jq -R -s -c 'split("\u0000")[:-1] | {query: .[1], args: .[6:]}' "${root}/argv"
}

@test "the text heuristics print and return what the fixture records for every text parity case (#252)" {
    local root="${BATS_TEST_TMPDIR}/root"
    mkdir -p "${root}"
    ORCHESTRATOR_DOTNET_PODMAN=0
    run _check_text_parity_cases "${root}"
    if [ "${status}" -ne 0 ]; then
        printf '%s\n' "${output}"
    fi
    [ "${status}" -eq 0 ]
}

@test "each text heuristic passes the tool the patterns the fixture records, so the fixture is current (#252)" {
    local function expected actual
    for function in "${PODMAN_TEXT_FUNCTIONS[@]}"; do
        expected=$(jq -c --arg f "${function}" '.functions[$f]' "${PODMAN_TEXT_FIXTURE}")
        actual=$(_text_parity_passed "${function}" "")
        if [ "${actual}" != "${expected}" ]; then
            printf '%s passes %s, the fixture has %s: regenerate it (PODMAN_TEXT_PARITY_REGENERATE)\n' \
                "${function}" "${actual}" "${expected}"
        fi
        [ "${actual}" = "${expected}" ]
    done
}

# The end-to-end check the plan asks for before each phase's PR: the same cases through the freshly built tool, given
# as ORCHESTRATOR_PARITY_CMD (for example a wrapper running the Release build of src/Credfeto.Orchestrator.Cmd), with
# the stderr compared with the switched-off run's. Skipped when it is not set, as in CI, which has no tool on PATH.
@test "every text parity case prints and returns the same through ORCHESTRATOR_CMD when switched on (#252)" {
    [ -n "${ORCHESTRATOR_PARITY_CMD:-}" ] || skip "ORCHESTRATOR_PARITY_CMD is not set"
    local root="${BATS_TEST_TMPDIR}/root"
    mkdir -p "${root}"
    ORCHESTRATOR_DOTNET_PODMAN=0
    run _check_text_parity_cases "${root}"
    [ "${status}" -eq 0 ]
    _text_parity_counting_cmd "${root}" "${ORCHESTRATOR_PARITY_CMD}"
    ORCHESTRATOR_DOTNET_PODMAN=1
    ORCHESTRATOR_CMD="${root}/orch"
    run _check_text_parity_cases "${root}"
    if [ "${status}" -ne 0 ]; then
        printf '%s\n' "${output}"
    fi
    [ "${status}" -eq 0 ]
}

@test "the text parity fixture covers each heuristic answered and refused, in C and a UTF-8 locale (#252)" {
    local function
    for function in "${PODMAN_TEXT_FUNCTIONS[@]}"; do
        [ "$(jq --arg f "${function}" '[.cases[] | select(.function == $f and .tool == "answers")] | length' "${PODMAN_TEXT_FIXTURE}")" -gt 0 ]
        [ "$(jq --arg f "${function}" '[.cases[] | select(.function == $f and .tool == "refuses")] | length' "${PODMAN_TEXT_FIXTURE}")" -gt 0 ]
        [ "$(jq --arg f "${function}" '[.cases[] | select(.function == $f and .locale == "C" and .tool == "answers")] | length' "${PODMAN_TEXT_FIXTURE}")" -gt 0 ]
    done
    [ "$(jq '[.cases[] | select(.stdout == null or .status == null)] | length' "${PODMAN_TEXT_FIXTURE}")" -eq 0 ]
}

# Rewrites the fixture's recorded results from the shell functions: PODMAN_TEXT_PARITY_REGENERATE names the file to
# write.
@test "regenerate the text parity fixture when PODMAN_TEXT_PARITY_REGENERATE is set (#252)" {
    [ -n "${PODMAN_TEXT_PARITY_REGENERATE:-}" ] || skip "PODMAN_TEXT_PARITY_REGENERATE is not set"
    local root="${BATS_TEST_TMPDIR}/root" results="${BATS_TEST_TMPDIR}/results" functions="${BATS_TEST_TMPDIR}/functions"
    local index function message locale globals tool stdout status name result args function_name
    mkdir -p "${root}"
    ORCHESTRATOR_DOTNET_PODMAN=0
    : > "${functions}"
    for function_name in "${PODMAN_TEXT_FUNCTIONS[@]}"; do
        jq -n -c --arg f "${function_name}" --argjson p "$(_text_parity_passed "${function_name}" "")" '{($f): $p}' \
            >> "${functions}"
    done
    : > "${results}"
    while IFS=$'\x1f' read -r -d $'\x1e' index function message locale globals tool stdout status name; do
        result=$(_text_parity_call "${function}" "${message}" "${locale:-C.UTF-8}" "${globals}" /dev/null)
        args=null
        if [ -n "${globals}" ]; then
            args=$(_text_parity_passed "${function}" "${globals}" | jq -c '.args')
        fi
        jq -n -c --arg stdout "$(printf '%s' "${result%.*}" | _text_parity_escape)" --argjson status "${result##*.}" \
            --argjson args "${args}" '{stdout: $stdout, status: $status} + (if $args then {args: $args} else {} end)' \
            >> "${results}"
    done < <(_text_parity_cases)
    jq --indent 1 --slurpfile r "${results}" --slurpfile f "${functions}" \
        '{functions: ($f | add), messages: .messages, cases: [.cases | to_entries[] | .value + $r[.key]]}' \
        "${PODMAN_TEXT_FIXTURE}" > "${PODMAN_TEXT_PARITY_REGENERATE}"
}
