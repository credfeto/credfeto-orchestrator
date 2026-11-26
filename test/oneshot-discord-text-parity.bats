#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are read by the sourced oneshot functions, where shellcheck cannot trace them

# Golden parity cases for the lib/discord text functions in the .NET rewrite (#252): record_item_status,
# serialize_item_status_log, _build_no_work_item_breakdown and truncate_for_display. test/fixtures/discord-text-parity.json
# holds, for each case, the function, its arguments (printf %b text: only \\, \n, \r, \t and \xHH escapes, so an
# argument can hold bytes that are not UTF-8), REPO_FULL when the case sets it (unset otherwise), the locale when the
# case needs one (C, where bash counts bytes; otherwise it runs in C.UTF-8, and in en_GB.UTF-8 where the host has it),
# whether the tool answers, refuses or is not asked, and what the function printed (stdout, exact text) and returned
# (status) in bash. This file checks the shell functions against the fixture, and Credfeto.Orchestrator.Discord.Tests
# (src/) runs the tool on the same cases, given what lib/discord hands it, and checks it against the same file.
#
# To regenerate the recorded results after a change to the cases or to a function, run the last test with
# DISCORD_TEXT_PARITY_REGENERATE set to the file to write; it keeps the cases and records what the shell prints and
# returns.

bats_require_minimum_version 1.5.0

load test_helper
load oneshot_helper

DISCORD_TEXT_FIXTURE="${BATS_TEST_DIRNAME}/fixtures/discord-text-parity.json"

# Prints one line per case: its name, function, tool, status, locale, whether REPO_FULL is set and its value, then its
# arguments, each field ended by \x1f (so an empty last argument survives read), as printf %b text
_discord_text_parity_cases() {
    jq -r '.cases[] | [.name, .function, .tool, (.status // -1 | tostring), (.locale // ""),
        (if has("repo_full") then "set" else "unset" end), (.repo_full // "")] + .args | map(. + "\u001f") | add' \
        "${DISCORD_TEXT_FIXTURE}"
}

# Runs function $3 in locale $1 with REPO_FULL set to the printf %b text $2 ("" leaves it unset, a leading "=" sets
# it to what follows) and the printf %b arguments that follow decoded. Prints what it printed, then a dot and its
# status; its stderr goes to DISCORD_TEXT_PARITY_STDERR.
_discord_text_parity_call() {
    local locale="$1" repo_full="$2" function="$3" arg decoded args=()
    shift 3
    for arg in "$@"; do
        printf -v decoded '%b' "${arg}"
        args+=("${decoded}")
    done
    # An assignment, not an environment prefix, so bash itself switches locale for ${#var}
    LC_ALL="${locale}"
    unset REPO_FULL
    if [ -n "${repo_full}" ]; then
        printf -v REPO_FULL '%b' "${repo_full#=}"
    fi
    "${function}" "${args[@]}" 2> "${DISCORD_TEXT_PARITY_STDERR}"
    printf '.%s' "$?"
}

# The locales a case runs in: its own when it names one, else C.UTF-8, and en_GB.UTF-8 as well where the host has it
_discord_text_parity_locales() {
    if [ -n "$1" ]; then
        printf '%s\n' "$1"
        return 0
    fi
    printf 'C.UTF-8\n'
    if locale -a 2> /dev/null | grep -qix 'en_GB.utf-\?8'; then
        printf 'en_GB.UTF-8\n'
    fi
}

# Runs every case in each of its locales, as the caller has set ORCHESTRATOR_DOTNET_DISCORD, and prints one line for
# each whose output or status differs from the fixture. Switched on, it also checks that the tool answered exactly
# the "answers" cases (lib/discord warns when bash runs instead) and that their stderr is empty, as the switched-off
# run's is.
_check_discord_text_parity_cases() {
    local root="$1" index=0 failures=0 fields name function tool status locale repo_full result warned expected=()
    mapfile -d '' -t expected < <(jq -j '.cases[] | .stdout + "\u0000"' "${DISCORD_TEXT_FIXTURE}")
    [ "${#expected[@]}" -gt 0 ] || return 1
    while IFS=$'\x1f' read -r -a fields; do
        name=${fields[0]}
        function=${fields[1]}
        tool=${fields[2]}
        status=${fields[3]}
        repo_full=""
        [ "${fields[5]}" = unset ] || repo_full="=${fields[6]}"
        DISCORD_TEXT_PARITY_STDERR="${root}/stderr-${index}"
        while IFS= read -r locale; do
            result=$(_discord_text_parity_call "${locale}" "${repo_full}" "${function}" "${fields[@]:7}")
            if [ "${result%.*}" != "${expected[index]}" ] || [ "${result##*.}" != "${status}" ]; then
                printf 'case %d (%s, %s): printed [%s] status %s, expected [%s] status %s\n' "${index}" "${name}" \
                    "${locale}" "${result%.*}" "${result##*.}" "${expected[index]}" "${status}"
                failures=$((failures + 1))
            fi
            if [ "${ORCHESTRATOR_DOTNET_DISCORD}" = 1 ]; then
                warned=answers
                if grep -q 'running it in bash instead' "${DISCORD_TEXT_PARITY_STDERR}"; then
                    warned=refuses
                fi
                if [ "${tool}" != not-called ] && [ "${warned}" != "${tool}" ]; then
                    printf 'case %d (%s, %s): the tool %s it, not %s\n' "${index}" "${name}" "${locale}" "${warned}" "${tool}"
                    failures=$((failures + 1))
                elif [ "${warned}" = answers ] && [ -s "${DISCORD_TEXT_PARITY_STDERR}" ]; then
                    printf 'case %d (%s, %s): stderr [%s], expected none\n' "${index}" "${name}" "${locale}" \
                        "$(cat "${DISCORD_TEXT_PARITY_STDERR}")"
                    failures=$((failures + 1))
                fi
            fi
        done < <(_discord_text_parity_locales "${fields[4]}")
        index=$((index + 1))
    done < <(_discord_text_parity_cases)
    [ "${index}" -eq "${#expected[@]}" ] || return 1
    [ "${failures}" -eq 0 ]
}

@test "the lib/discord text functions print and return what the fixture records for every discord text parity case (#252)" {
    ORCHESTRATOR_DOTNET_DISCORD=0
    run _check_discord_text_parity_cases "${BATS_TEST_TMPDIR}"
    printf '%s\n' "${output}"
    [ "${status}" -eq 0 ]
}

# The end-to-end check the plan asks for before each phase's PR: the same cases through the freshly built tool, given
# as ORCHESTRATOR_PARITY_CMD (for example a wrapper running the Release build of src/Credfeto.Orchestrator.Cmd).
# Skipped when it is not set, as in CI, which has no tool on PATH.
@test "every discord text parity case prints and returns the same through ORCHESTRATOR_CMD when switched on (#252)" {
    [ -n "${ORCHESTRATOR_PARITY_CMD:-}" ] || skip "ORCHESTRATOR_PARITY_CMD is not set"
    ORCHESTRATOR_DOTNET_DISCORD=1
    ORCHESTRATOR_CMD="${ORCHESTRATOR_PARITY_CMD}"
    run _check_discord_text_parity_cases "${BATS_TEST_TMPDIR}"
    printf '%s\n' "${output}"
    [ "${status}" -eq 0 ]
}

@test "the discord text parity fixture covers each text function, answered and refused, with recorded results (#252)" {
    local function
    for function in record_item_status serialize_item_status_log _build_no_work_item_breakdown truncate_for_display; do
        [ "$(jq --arg f "${function}" '[.cases[] | select(.function == $f and .tool == "answers")] | length' "${DISCORD_TEXT_FIXTURE}")" -gt 0 ]
        [ "$(jq --arg f "${function}" '[.cases[] | select(.function == $f and .tool == "refuses")] | length' "${DISCORD_TEXT_FIXTURE}")" -gt 0 ]
    done
    [ "$(jq '[.cases[] | select(.stdout == null or .status == null)] | length' "${DISCORD_TEXT_FIXTURE}")" -eq 0 ]
    [ "$(jq '[.cases[] | select(.tool == "answers" and .status != 0)] | length' "${DISCORD_TEXT_FIXTURE}")" -eq 0 ]
    [ "$(jq '[.cases[] | select(.tool == "not-called" and (.function != "serialize_item_status_log" or (.args | length) != 0))] | length' \
        "${DISCORD_TEXT_FIXTURE}")" -eq 0 ]
}

# Rewrites the fixture's recorded results from the shell functions: DISCORD_TEXT_PARITY_REGENERATE names the file to
# write. The fixture is written with --ascii-output, so it holds no raw U+2028, NBSP or other character a JSON linter
# flags.
@test "regenerate the discord text parity fixture when DISCORD_TEXT_PARITY_REGENERATE is set (#252)" {
    [ -n "${DISCORD_TEXT_PARITY_REGENERATE:-}" ] || skip "DISCORD_TEXT_PARITY_REGENERATE is not set"
    local fields result repo_full results="${BATS_TEST_TMPDIR}/results"
    ORCHESTRATOR_DOTNET_DISCORD=0
    DISCORD_TEXT_PARITY_STDERR=/dev/null
    : > "${results}"
    while IFS=$'\x1f' read -r -a fields; do
        repo_full=""
        [ "${fields[5]}" = unset ] || repo_full="=${fields[6]}"
        result=$(_discord_text_parity_call "${fields[4]:-C.UTF-8}" "${repo_full}" "${fields[1]}" "${fields[@]:7}")
        jq -n -c --arg stdout "${result%.*}" --argjson status "${result##*.}" \
            '{stdout: $stdout, status: $status}' >> "${results}"
    done < <(_discord_text_parity_cases)
    jq -a --slurpfile r "${results}" '.cases |= [to_entries[] | .value + $r[.key]]' "${DISCORD_TEXT_FIXTURE}" \
        > "${DISCORD_TEXT_PARITY_REGENERATE}"
}
