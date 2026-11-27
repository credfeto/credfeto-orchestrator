#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are read by the sourced oneshot functions, where shellcheck cannot trace them

# Golden parity cases for the lib/github-status routing and label reads and priority_for_labels (lib/workflow-board)
# in the .NET rewrite (#252). test/fixtures/checks-parity.json holds, for each case, the shell function, its
# arguments, whether the tool answers the case or refuses it (exit 3, so bash answers), the locale it was recorded in
# when the answer depends on it, and the status (0, 2 for "no phase", 1 for any other failure) and output the function
# gives. This file checks the shell functions against it, and Credfeto.Orchestrator.Predicates.Tests (src/) runs the
# tool's `checks <query>` over the same cases, so a change to what either side answers fails that side's own suite
# until the fixture and the other side agree. An argument that is a JSON string is passed as its text, any other JSON
# value as jq -c prints it.
#
# Regenerate the recorded status and output of every case (about a minute) with
#   CHECKS_PARITY_REGENERATE=<file to write> bats -f regenerate test/oneshot-checks-parity.bats
# CHECKS_PARITY_INPUT=<file> takes the cases from another file of the same shape; a case without a locale whose
# answer differs between the locales is written once for each.

bats_require_minimum_version 1.5.0

load test_helper
load oneshot_helper

PARITY_FIXTURE="${BATS_TEST_DIRNAME}/fixtures/checks-parity.json"

# The locales a case without one runs in: C.UTF-8, en_GB.UTF-8 where the host has it, and C
_checks_parity_locales() {
    printf 'C.UTF-8\n'
    if locale -a 2> /dev/null | grep -qix 'en_GB.utf-\?8'; then
        printf 'en_GB.UTF-8\n'
    fi
    printf 'C\n'
}

# Prints each case of the fixture $1 as one line of fields ended by \x1f: index, function, locale, tool, status and
# output (base64), then the arguments, each base64 (- for an empty one) and separated by spaces. A field the case
# does not have is -.
_checks_parity_case_lines() {
    jq -r '.cases | to_entries[] | [
            (.key | tostring),
            .value.function,
            (.value.locale // "-"),
            (.value.tool // "-"),
            (.value.status // "-" | tostring),
            (.value.output // "" | if . == "" then "-" else @base64 end),
            (.value.args | map(if type == "string" then . else tojson end | if . == "" then "-" else @base64 end) | join(" "))
        ] | join("\u001f")' "$1"
}

# Decodes one base64 field (- for empty) into the variable named $2, keeping trailing newlines
_checks_parity_decode() {
    local decoded
    if [ "$1" = "-" ]; then
        printf -v "$2" '%s' ""
        return 0
    fi
    decoded=$(
        printf '%s' "$1" | base64 -d
        printf x
    )
    printf -v "$2" '%s' "${decoded%x}"
}

# Runs the function $2 with the remaining arguments in the locale $1, its stderr in ${TEST_TMP}/case-stderr, and
# prints its output, \001 and its status: 0, 2 (pr_next_phase_for_board_status's "no phase") or 1 for any other
# failure, as the callers only test for 0 and 2 (pr_merge_state_allows_settled returns jq's own status, which is 1
# whatever went wrong when ORCHESTRATOR_DOTNET_PREDICATES is on)
_checks_parity_run() {
    local locale="$1" fn="$2" status=0
    shift 2
    (
        export LC_ALL="${locale}"
        "${fn}" "$@" 2> "${TEST_TMP}/case-stderr" || status=$?
        case "${status}" in
            0 | 2) ;;
            *) status=1 ;;
        esac
        printf '\001%d' "${status}"
    )
}

# Runs every case through its shell function, in its locale or in each of _checks_parity_locales, as the caller has
# set ORCHESTRATOR_DOTNET_CHECKS, and prints one line for each case whose status or output differs from the golden
# one. With $1 = on, also checks that the tool answered each case it answers and was asked and refused each case it
# refuses. Returns 1 when any case differs.
_check_checks_parity_cases() {
    local switched="${1:-off}" index fn case_locale tool expected_status encoded_output encoded expected_output
    local result status output arg locale failures=0 count=0
    local -a args locales all_locales
    mapfile -t all_locales < <(_checks_parity_locales)
    while IFS=$'\x1f' read -r index fn case_locale tool expected_status encoded_output encoded; do
        args=()
        for arg in ${encoded}; do
            _checks_parity_decode "${arg}" arg
            args+=("${arg}")
        done
        _checks_parity_decode "${encoded_output}" expected_output
        if [ "${case_locale}" = "-" ]; then
            locales=("${all_locales[@]}")
        else
            locales=("${case_locale}")
        fi
        for locale in "${locales[@]}"; do
            result=$(_checks_parity_run "${locale}" "${fn}" "${args[@]}")
            status="${result##*$'\001'}"
            output="${result%$'\001'*}"
            if [ "${status}" != "${expected_status}" ] || [ "${output}" != "${expected_output}" ]; then
                printf 'case %d (%s, %s): expected %s %q, got %s %q\n' "${index}" "${fn}" "${locale}" \
                    "${expected_status}" "${expected_output}" "${status}" "${output}"
                failures=$((failures + 1))
            elif [ "${switched}" = on ] && [ "${tool}" = answers ] \
                && grep -q 'answering it in bash instead' "${TEST_TMP}/case-stderr"; then
                printf 'case %d (%s, %s): the tool did not answer it: %s\n' "${index}" "${fn}" "${locale}" \
                    "$(cat "${TEST_TMP}/case-stderr")"
                failures=$((failures + 1))
            elif [ "${switched}" = on ] && [ "${tool}" = refuses ] \
                && ! grep -q 'failed (exit 3); answering it in bash instead' "${TEST_TMP}/case-stderr"; then
                printf 'case %d (%s, %s): the tool did not refuse it\n' "${index}" "${fn}" "${locale}"
                failures=$((failures + 1))
            fi
            count=$((count + 1))
        done
    done < <(_checks_parity_case_lines "${PARITY_FIXTURE}")
    [ "${count}" -gt 0 ] && [ "${failures}" -eq 0 ]
}

@test "the checks parity fixture covers every ported function, and both tool outcomes (#252)" {
    run jq -r '[.cases[].function] | unique | join(" ")' "${PARITY_FIXTURE}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "issue_json_has_blocked_label pr_clean_review_status_comment pr_json_has_blocked_label pr_merge_state_allows_settled pr_next_phase_for_board_status pr_session_progress_reason priority_for_labels" ]
    run jq -r '[.cases[].tool] | unique | join(" ")' "${PARITY_FIXTURE}"
    [ "${output}" = "answers refuses" ]
}

@test "every checks parity case gives the golden status and output, in each locale (#252)" {
    unset ORCHESTRATOR_DOTNET_CHECKS
    run _check_checks_parity_cases
    if [ "${status}" -ne 0 ]; then
        printf '%s\n' "${output}"
    fi
    [ "${status}" -eq 0 ]
}

# The same cases with the switch on and the freshly built tool, given as ORCHESTRATOR_PARITY_CMD (for example a
# wrapper running the Release build of src/Credfeto.Orchestrator.Cmd by its absolute path). Skipped when it is not
# set, as in CI, which has no tool on PATH.
@test "every checks parity case gives the golden status and output through ORCHESTRATOR_CMD when switched on (#252)" {
    [ -n "${ORCHESTRATOR_PARITY_CMD:-}" ] || skip "ORCHESTRATOR_PARITY_CMD is not set"
    ORCHESTRATOR_DOTNET_CHECKS=1
    ORCHESTRATOR_CMD="${ORCHESTRATOR_PARITY_CMD}"
    run _check_checks_parity_cases on
    if [ "${status}" -ne 0 ]; then
        printf '%s\n' "${output}"
    fi
    [ "${status}" -eq 0 ]
}

@test "regenerate the checks parity fixture (#252)" {
    [ -n "${CHECKS_PARITY_REGENERATE:-}" ] || skip "CHECKS_PARITY_REGENERATE is not set"
    local input="${CHECKS_PARITY_INPUT:-${PARITY_FIXTURE}}" records="${TEST_TMP}/records"
    local index fn case_locale tool expected_status encoded_output encoded result status output arg locale encoded_run
    local -a args locales all_locales
    unset ORCHESTRATOR_DOTNET_CHECKS
    mapfile -t all_locales < <(_checks_parity_locales)
    : > "${records}"
    while IFS=$'\x1f' read -r index fn case_locale tool expected_status encoded_output encoded; do
        args=()
        for arg in ${encoded}; do
            _checks_parity_decode "${arg}" arg
            args+=("${arg}")
        done
        if [ "${case_locale}" = "-" ]; then
            locales=("${all_locales[@]}")
        else
            locales=("${case_locale}")
        fi
        for locale in "${locales[@]}"; do
            result=$(_checks_parity_run "${locale}" "${fn}" "${args[@]}")
            status="${result##*$'\001'}"
            output="${result%$'\001'*}"
            encoded_run="-"
            [ -z "${output}" ] || encoded_run=$(printf '%s' "${output}" | base64 -w0)
            printf '%s\t%s\t%s\t%s\n' "${index}" "${locale}" "${status}" "${encoded_run}" >> "${records}"
        done
    done < <(_checks_parity_case_lines "${input}")
    jq -a --indent 2 --rawfile records "${records}" '
        ($records | split("\n") | map(select(. != "") | split("\t")
            | {index: (.[0] | tonumber), locale: .[1], status: (.[2] | tonumber),
               output: (if .[3] == "-" then "" else .[3] | @base64d end)})) as $runs
        | .cases |= [to_entries[] | .key as $key | .value as $case
            | [$runs[] | select(.index == $key)] as $mine
            | if $case.locale != null or ($mine | map([.status, .output]) | unique | length) == 1
              then $case + {status: $mine[0].status, output: $mine[0].output}
              else $mine[] | $case + {locale: .locale, status: .status, output: .output}
              end]
    ' "${input}" > "${CHECKS_PARITY_REGENERATE}"
}
