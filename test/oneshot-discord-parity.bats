#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are read by the sourced oneshot functions, where shellcheck cannot trace them

# Golden parity cases for the lib/discord webhook payload builders in the .NET rewrite (#252).
# test/fixtures/discord-parity.json and test/fixtures/discord-stalled-digest-parity.json (the session-stalled masking
# and daily digest cases, kept apart for the commit hook's file size cap) each hold, under "functions", each
# build_discord_*_payload function they cover with the payload kind and the tool options its arguments become, in
# argument order ("json" names the options whose value is JSON), and under "cases" the function, its arguments
# (printf %b text: only \\, \n, \r, \t and \xHH escapes, so an argument can hold bytes that are not UTF-8), whether the
# tool answers or refuses it, and what the function printed (stdout, exact text, trailing newline included) and
# returned (status) in bash. Every case runs in C.UTF-8, and in en_GB.UTF-8 where the host has it. This file checks
# the shell functions against the fixture, and Credfeto.Orchestrator.Discord.Tests (src/) builds the same payloads
# with the tool and checks them against the same file. A case marked "refuses" is one the tool must refuse, so bash
# builds it.
#
# To regenerate the recorded results after a change to the cases or to a payload, run the last test with
# DISCORD_PARITY_REGENERATE set to the directory to write both fixtures to; it keeps each fixture's functions and
# cases and records what the shell prints and returns.

bats_require_minimum_version 1.5.0

load test_helper
load oneshot_helper

DISCORD_FIXTURES=(
    "${BATS_TEST_DIRNAME}/fixtures/discord-parity.json"
    "${BATS_TEST_DIRNAME}/fixtures/discord-stalled-digest-parity.json"
)

# Prints one line per case of fixture $1: its name, function, tool and status, then its arguments, each field ended
# by \x1f (so an empty last argument survives read), as printf %b text
_discord_parity_cases() {
    jq -r '.cases[] | [.name, .function, .tool, (.status // -1 | tostring)] + .args | map(. + "\u001f") | add' "$1"
}

# Runs function $1 with the printf %b arguments that follow decoded. Prints what it printed, then a dot and its
# status; its stderr goes to DISCORD_PARITY_STDERR.
_discord_parity_call() {
    local function="$1" arg decoded args=()
    shift
    for arg in "$@"; do
        printf -v decoded '%b' "${arg}"
        args+=("${decoded}")
    done
    "${function}" "${args[@]}" 2> "${DISCORD_PARITY_STDERR}"
    printf '.%s' "$?"
}

# Runs every case of fixture $2 for the locale the caller set in LC_ALL, as the caller has set
# ORCHESTRATOR_DOTNET_DISCORD, and prints one line for each whose output or status differs from the fixture. Switched on, it also checks that the tool
# built exactly the "answers" cases (lib/discord warns when bash builds the payload instead) and that their stderr is
# empty, as the switched-off run's is.
_check_discord_parity_cases() {
    local root="$1" fixture="$2" index=0 failures=0 fields name function tool status result warned expected=()
    mapfile -d '' -t expected < <(jq -j '.cases[] | .stdout + "\u0000"' "${fixture}")
    [ "${#expected[@]}" -gt 0 ] || return 1
    while IFS=$'\x1f' read -r -a fields; do
        name=${fields[0]}
        function=${fields[1]}
        tool=${fields[2]}
        status=${fields[3]}
        DISCORD_PARITY_STDERR="${root}/stderr-${index}"
        result=$(_discord_parity_call "${function}" "${fields[@]:4}")
        if [ "${result%.*}" != "${expected[index]}" ] || [ "${result##*.}" != "${status}" ]; then
            printf 'case %d (%s): printed [%s] status %s, expected [%s] status %s\n' "${index}" "${name}" \
                "${result%.*}" "${result##*.}" "${expected[index]}" "${status}"
            failures=$((failures + 1))
        fi
        if [ "${ORCHESTRATOR_DOTNET_DISCORD}" = 1 ]; then
            warned=answers
            if grep -q 'building it in bash instead' "${DISCORD_PARITY_STDERR}"; then
                warned=refuses
            fi
            if [ "${warned}" != "${tool}" ]; then
                printf 'case %d (%s): the tool %s it, not %s\n' "${index}" "${name}" "${warned}" "${tool}"
                failures=$((failures + 1))
            elif [ "${warned}" = answers ] && [ -s "${DISCORD_PARITY_STDERR}" ]; then
                printf 'case %d (%s): stderr [%s], expected none\n' "${index}" "${name}" "$(cat "${DISCORD_PARITY_STDERR}")"
                failures=$((failures + 1))
            fi
        fi
        index=$((index + 1))
    done < <(_discord_parity_cases "${fixture}")
    [ "${index}" -eq "${#expected[@]}" ] || return 1
    [ "${failures}" -eq 0 ]
}

# The locales the cases run in: C.UTF-8, and en_GB.UTF-8 as well where the host has it
_discord_parity_locales() {
    printf 'C.UTF-8\n'
    if locale -a 2> /dev/null | grep -qix 'en_GB.utf-\?8'; then
        printf 'en_GB.UTF-8\n'
    fi
}

# Runs every case of every fixture in every locale, as the caller has set ORCHESTRATOR_DOTNET_DISCORD
_check_every_discord_parity_case() {
    local fixture locale
    for fixture in "${DISCORD_FIXTURES[@]}"; do
        while IFS= read -r locale; do
            LC_ALL="${locale}" run _check_discord_parity_cases "${BATS_TEST_TMPDIR}" "${fixture}"
            if [ "${status}" -ne 0 ]; then
                printf '%s, %s: %s\n' "${fixture##*/}" "${locale}" "${output}"
            fi
            [ "${status}" -eq 0 ]
        done < <(_discord_parity_locales)
    done
}

@test "the lib/discord payload builders print and return what the fixture records for every discord parity case (#252)" {
    ORCHESTRATOR_DOTNET_DISCORD=0
    _check_every_discord_parity_case
}

# The end-to-end check the plan asks for before each phase's PR: the same cases through the freshly built tool, given
# as ORCHESTRATOR_PARITY_CMD (for example a wrapper running the Release build of src/Credfeto.Orchestrator.Cmd).
# Skipped when it is not set, as in CI, which has no tool on PATH.
@test "every discord parity case prints and returns the same through ORCHESTRATOR_CMD when switched on (#252)" {
    [ -n "${ORCHESTRATOR_PARITY_CMD:-}" ] || skip "ORCHESTRATOR_PARITY_CMD is not set"
    ORCHESTRATOR_DOTNET_DISCORD=1
    ORCHESTRATOR_CMD="${ORCHESTRATOR_PARITY_CMD}"
    _check_every_discord_parity_case
}

@test "the discord parity fixtures cover every lib/discord payload builder once, each answered and refused (#252)" {
    local fixture function builders
    builders=$(grep -o '^build_discord_[a-z_]*_payload()' "${REPO_ROOT}/lib/discord" | tr -d '()' | sort)
    [ -n "${builders}" ]
    [ "$(jq -r '.functions | keys[]' "${DISCORD_FIXTURES[@]}" | sort)" = "${builders}" ]
    for fixture in "${DISCORD_FIXTURES[@]}"; do
        for function in $(jq -r '.functions | keys[]' "${fixture}"); do
            [ "$(jq --arg f "${function}" '[.cases[] | select(.function == $f and .tool == "answers")] | length' "${fixture}")" -gt 0 ]
            [ "$(jq --arg f "${function}" '[.cases[] | select(.function == $f and .tool == "refuses")] | length' "${fixture}")" -gt 0 ]
        done
        [ "$(jq '[.cases[] | select(.stdout == null or .status == null)] | length' "${fixture}")" -eq 0 ]
        [ "$(jq '[.cases[] | select((.args | length) != ($fixture[0].functions[.function].options | length))] | length' \
            --slurpfile fixture "${fixture}" "${fixture}")" -eq 0 ]
    done
}

# Rewrites the fixtures' recorded results from the shell functions: DISCORD_PARITY_REGENERATE names the directory to
# write them to, under their own names. The fixtures are written with --ascii-output, so they hold no raw U+2028, NBSP
# or other character a JSON linter flags.
@test "regenerate the discord parity fixtures when DISCORD_PARITY_REGENERATE is set (#252)" {
    [ -n "${DISCORD_PARITY_REGENERATE:-}" ] || skip "DISCORD_PARITY_REGENERATE is not set"
    local fixture fields result results="${BATS_TEST_TMPDIR}/results"
    ORCHESTRATOR_DOTNET_DISCORD=0
    DISCORD_PARITY_STDERR=/dev/null
    for fixture in "${DISCORD_FIXTURES[@]}"; do
        : > "${results}"
        while IFS=$'\x1f' read -r -a fields; do
            result=$(LC_ALL=C.UTF-8 _discord_parity_call "${fields[1]}" "${fields[@]:4}")
            jq -n -c --arg stdout "${result%.*}" --argjson status "${result##*.}" \
                '{stdout: $stdout, status: $status}' >> "${results}"
        done < <(_discord_parity_cases "${fixture}")
        jq -a --slurpfile r "${results}" '.cases |= [to_entries[] | .value + $r[.key]]' "${fixture}" \
            > "${DISCORD_PARITY_REGENERATE}/${fixture##*/}"
    done
}
