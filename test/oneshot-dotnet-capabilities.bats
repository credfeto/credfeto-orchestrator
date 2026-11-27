#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are read by the sourced oneshot functions, where shellcheck cannot trace them
# shellcheck disable=SC2016  # stand-in binary bodies are expanded when they run, not here

# The self-installed tool older than the bash checkout (#2095): check_orchestrator_cmd_capabilities (lib/self-install)
# asks the installed binary for --capabilities once a run, and orchestrator_cmd_supports sends a call to it only when
# it lists the command; any other call runs in bash, as with its area off, and the run logs one line at most. The
# stand-in binaries here print a full usage text to stderr for any command they lack, as the real tool does, so a
# test sees it if one is ever asked.

bats_require_minimum_version 1.5.0

load test_helper
load oneshot_helper

CAPABILITIES_FILE="${BATS_TEST_DIRNAME}/../src/Credfeto.Orchestrator.Install/capabilities.txt"

# Installs a stand-in binary as the self-installed current version and points ORCHESTRATOR_CMD at it, as lib/globals
# does. The stand-in logs each call's arguments as one line to ${TEST_TMP}/calls. With "old" it predates
# --capabilities and answers it with a usage error; otherwise it lists this checkout's commands except those in
# ${TEST_TMP}/lacks, one a line. Any command it lists prints ${TEST_TMP}/answer; any other gets the usage error.
_install_stand_in() {
    local kind="${1:-listed}" dir="${STUB_BIN}/install"
    mkdir -p "${dir}/9.9.9-main"
    touch "${TEST_TMP}/lacks"
    grep -vxF -f "${TEST_TMP}/lacks" "${CAPABILITIES_FILE}" > "${TEST_TMP}/listed" || true
    {
        printf '#!/usr/bin/env bash\n'
        printf 'printf "%%s\\n" "$*" >> "%s/calls"\n' "${TEST_TMP}"
        printf 'usage() { printf "credfeto-orchestrator: expected: %%s\\nUsage: credfeto-orchestrator <command>\\n  every command\\n" "$*" >&2; exit 2; }\n'
        if [ "${kind}" = old ]; then
            printf '[ "$1" != --capabilities ] || usage "$@"\n'
        else
            printf '[ "$1" != --capabilities ] || { cat "%s/listed"; exit 0; }\n' "${TEST_TMP}"
        fi
        printf 'if [ "$1 $2" = "discord payload" ]; then command="$1 $2 $3"; else command="$1 $2"; fi\n'
        printf 'grep -qxF -- "${command}" "%s/listed" || usage "$@"\n' "${TEST_TMP}"
        printf 'cat "%s/answer"\n' "${TEST_TMP}"
    } > "${dir}/9.9.9-main/Credfeto.Orchestrator.Cmd"
    chmod +x "${dir}/9.9.9-main/Credfeto.Orchestrator.Cmd"
    ln -sfn 9.9.9-main "${dir}/current"
    printf '{"from":"tool"}' > "${TEST_TMP}/answer"
    ORCHESTRATOR_CMD_INSTALL_DIR="${dir}"
    ORCHESTRATOR_CMD_FROM_ENVIRONMENT=0
    ORCHESTRATOR_CMD="${dir}/current/Credfeto.Orchestrator.Cmd"
}

# One run's worth of tool use: the once-a-run check, then three work-item payloads, each built in a subshell as the
# notifiers do, and one no-work payload, printing each payload as one line of JSON
_run_cycle() {
    local payload i
    check_orchestrator_cmd_capabilities
    for i in 1 2 3; do
        payload=$(build_discord_work_item_payload 3066993 "Title ${i}" https://example.invalid/1 owner/repo Issue \
            "In Progress" "" Medium 1 2)
        jq -c . <<< "${payload}"
    done
    payload=$(build_discord_no_work_payload "No work" "Nothing queued")
    jq -c . <<< "${payload}"
}

# The lines warn printed to stderr
_warnings() {
    printf '%s\n' "${stderr}" | grep '^! ' || true
}

@test "a self-installed binary lacking a payload kind is never asked for it, and the run logs it in one line (#2095)" {
    local expected
    ORCHESTRATOR_DOTNET_DISCORD=1
    printf 'discord payload work-item\n' > "${TEST_TMP}/lacks"
    _install_stand_in
    expected=$(ORCHESTRATOR_DOTNET_DISCORD=0 _run_cycle | head -n 3)
    [ "$(printf '%s\n' "${expected}" | jq -r '.embeds[0].title' | paste -sd '|')" = "Title 1|Title 2|Title 3" ]

    run --separate-stderr _run_cycle

    [ "${status}" -eq 0 ]
    [ "${output}" = "${expected}"$'\n''{"from":"tool"}' ]
    [ "$(_warnings | wc -l)" -eq 1 ]
    [[ "$(_warnings)" == *"Credfeto.Orchestrator.Cmd 9.9.9-main is older than this checkout and lacks discord payload work-item, so those run in bash this run" ]]
    [[ "${stderr}" != *Usage* ]]
    [[ "${stderr}" != *expected:* ]]
    [ "$(cat "${TEST_TMP}/calls")" = "--capabilities"$'\n'"discord payload no-work --title No work --description Nothing queued" ]
}

@test "a self-installed binary that predates --capabilities is asked for nothing else, and its usage text is not shown (#2095)" {
    ORCHESTRATOR_DOTNET_DISCORD=1
    ORCHESTRATOR_DOTNET_GIT=1
    _install_stand_in old

    run --separate-stderr _run_cycle

    [ "${status}" -eq 0 ]
    [ "$(printf '%s\n' "${output}" | jq -r '.embeds[0].title' | paste -sd '|')" = "Title 1|Title 2|Title 3|No work" ]
    [ "$(_warnings | wc -l)" -eq 1 ]
    [[ "$(_warnings)" == *"Credfeto.Orchestrator.Cmd 9.9.9-main does not list its capabilities (it is older than this checkout), so discord, git run in bash this run" ]]
    [[ "${stderr}" != *Usage* ]]
    [ "$(cat "${TEST_TMP}/calls")" = "--capabilities" ]
}

@test "a self-installed binary that lists every command is asked as before, and nothing is logged (#2095)" {
    ORCHESTRATOR_DOTNET_DISCORD=1
    _install_stand_in

    run --separate-stderr _run_cycle

    [ "${status}" -eq 0 ]
    [ "$(printf '%s\n' "${output}" | paste -sd '|')" = '{"from":"tool"}|{"from":"tool"}|{"from":"tool"}|{"from":"tool"}' ]
    [ -z "${stderr}" ]
    [ "$(grep -c 'discord payload work-item' "${TEST_TMP}/calls")" -eq 3 ]
}

@test "the missing-commands line names only the commands of areas that are on (#2095)" {
    ORCHESTRATOR_DOTNET_DISCORD=1
    printf 'discord payload work-item\ngit head-sha\nstate marker\n' > "${TEST_TMP}/lacks"
    _install_stand_in

    run --separate-stderr check_orchestrator_cmd_capabilities

    [ "${status}" -eq 0 ]
    [ "$(_warnings | wc -l)" -eq 1 ]
    [[ "$(_warnings)" == *"lacks discord payload work-item, so those run in bash this run" ]]
}

@test "a git query the self-installed binary lacks runs git in bash, with no warning per call (#2095)" {
    local repo="${TEST_TMP}/repo"
    git init -q -b main "${repo}"
    git -C "${repo}" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m one
    ORCHESTRATOR_DOTNET_GIT=1
    REPO_WORK_DIR="${repo}"
    printf 'git head-sha\n' > "${TEST_TMP}/lacks"
    _install_stand_in
    check_orchestrator_cmd_capabilities 2> "${TEST_TMP}/check-stderr"

    run --separate-stderr checkout_head_sha

    [ "${status}" -eq 0 ]
    [ "${output}" = "$(git -C "${repo}" rev-parse HEAD)" ]
    [ -z "${stderr}" ]
    [ "$(cat "${TEST_TMP}/calls")" = "--capabilities" ]
}

@test "a predicate the self-installed binary lacks is answered by jq, not reported as a tool failure (#2095)" {
    ORCHESTRATOR_DOTNET_PREDICATES=1
    printf 'predicate pr-has-placeholder-file\n' > "${TEST_TMP}/lacks"
    _install_stand_in
    check_orchestrator_cmd_capabilities 2> "${TEST_TMP}/check-stderr"

    run --separate-stderr pr_json_has_placeholder_file '{"files":[{"path":".deleteme.now"}]}'

    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    run --separate-stderr pr_json_has_placeholder_file '{"files":[{"path":"README.md"}]}'
    [ "${status}" -eq 1 ]
    [ "$(cat "${TEST_TMP}/calls")" = "--capabilities" ]
}

@test "an ORCHESTRATOR_CMD the environment set is never probed and is asked as before (#2095)" {
    ORCHESTRATOR_DOTNET_DISCORD=1
    printf 'discord payload work-item\n' > "${TEST_TMP}/lacks"
    _install_stand_in
    ORCHESTRATOR_CMD_FROM_ENVIRONMENT=1

    run --separate-stderr _run_cycle

    [ "${status}" -eq 0 ]
    [ "$(grep -c -- '--capabilities' "${TEST_TMP}/calls")" -eq 0 ]
    [ "$(grep -c 'discord payload work-item' "${TEST_TMP}/calls")" -eq 3 ]
}

@test "with every ORCHESTRATOR_DOTNET area off the installed binary is never run (#2095)" {
    _install_stand_in

    run --separate-stderr _run_cycle

    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ ! -e "${TEST_TMP}/calls" ]
    [ "${ORCHESTRATOR_CMD_CHECKED}" = 0 ]
}

@test "orchestrator_cmd_supports lets every command through until a binary was checked (#2095)" {
    ORCHESTRATOR_CMD_CHECKED=0
    ORCHESTRATOR_CMD_CAPABILITIES=""

    run orchestrator_cmd_supports discord payload no-such-kind

    [ "${status}" -eq 0 ]
}

@test "main checks the binary's capabilities right after the self-install, before any tool call (#2095)" {
    declare -f main | grep -A1 '^ *self_install_orchestrator_cmd;$' | grep -q '^ *check_orchestrator_cmd_capabilities;$'
}

@test "every command lib/ checks with orchestrator_cmd_supports by name is in the committed capability list (#2095)" {
    local line count=0
    [ "$(head -n 1 "${CAPABILITIES_FILE}")" = "credfeto-orchestrator capabilities 1" ]
    while IFS= read -r line; do
        if ! grep -qxF -- "${line}" "${CAPABILITIES_FILE}"; then
            printf 'not in the capability list: %s\n' "${line}" >&2
            return 1
        fi
        count=$((count + 1))
    done < <(grep -ohE 'orchestrator_cmd_supports [a-z]+ [a-z-]+( [a-z-]+)?(;| \|\|)' "${REPO_ROOT}"/lib/* \
        | sed -E 's/^orchestrator_cmd_supports //; s/(;| \|\|)$//' | sort -u)
    [ "${count}" -ge 30 ]
}

# Messages for the session-outcome text heuristics: a background stall, a refusal, a clean review and one with findings
_TEXT_MESSAGES=(
    "The build is running in the background. I'll continue automatically once it completes."
    "Running git push is denied."
    $'No issues found.\nREVIEW RESULT: CLEAN'
    $'REVIEW RESULT: FINDINGS\nThe loop never ends.'
)

# Prints 1 when the command in its arguments succeeds, 0 when it fails
_answer() {
    if "$@"; then printf '1'; else printf '0'; fi
}

# One run's worth of the session-outcome text heuristics (lib/podman): the once-a-run check, then every heuristic on
# each message, each in a subshell as the callers do, printing one line of answers per message
_run_text_cycle() {
    local message answers
    check_orchestrator_cmd_capabilities
    for message in "${_TEXT_MESSAGES[@]}"; do
        answers=$(
            _answer claude_result_indicates_background_stall "${message}"
            _answer claude_result_indicates_diagnostic_refusal "${message}"
            _answer claude_result_indicates_tool_denied_quit "${message}"
            _answer claude_result_indicates_clean_review "${message}"
            printf ' %s' "$(review_result_marker "${message}")"
        )
        printf '%s\n' "${answers}"
    done
}

@test "a self-installed binary lacking the podman text queries is never asked them, and the run logs it in one line (#2095)" {
    local expected lines
    ORCHESTRATOR_DOTNET_PODMAN=1
    printf 'podman %s\n' background-stall clean-review diagnostic-refusal review-result-marker tool-denied-quit \
        > "${TEST_TMP}/lacks"
    _install_stand_in
    expected=$(ORCHESTRATOR_DOTNET_PODMAN=0 _run_text_cycle)
    mapfile -t lines <<< "${expected}"
    [ "${#lines[@]}" -eq 4 ]
    [[ "${lines[0]}" == 1* ]]
    [[ "${lines[1]}" == ?1* ]]
    [[ "${lines[2]}" == *" CLEAN" ]]
    [[ "${lines[3]}" == *" FINDINGS" ]]

    run --separate-stderr _run_text_cycle

    [ "${status}" -eq 0 ]
    [ "${output}" = "${expected}" ]
    [ "$(_warnings | wc -l)" -eq 1 ]
    [[ "$(_warnings)" == *"Credfeto.Orchestrator.Cmd 9.9.9-main is older than this checkout and lacks podman background-stall, podman clean-review, podman diagnostic-refusal, podman review-result-marker, podman tool-denied-quit, so those run in bash this run" ]]
    [[ "${stderr}" != *Usage* ]]
    [[ "${stderr}" != *expected:* ]]
    [ "$(cat "${TEST_TMP}/calls")" = "--capabilities" ]
}

@test "a self-installed binary that predates --capabilities is never asked a podman text query (#2095)" {
    local expected
    ORCHESTRATOR_DOTNET_PODMAN=1
    _install_stand_in old
    expected=$(ORCHESTRATOR_DOTNET_PODMAN=0 _run_text_cycle)

    run --separate-stderr _run_text_cycle

    [ "${status}" -eq 0 ]
    [ "${output}" = "${expected}" ]
    [ "$(_warnings | wc -l)" -eq 1 ]
    [[ "$(_warnings)" == *"Credfeto.Orchestrator.Cmd 9.9.9-main does not list its capabilities (it is older than this checkout), so podman run in bash this run" ]]
    [[ "${stderr}" != *Usage* ]]
    [ "$(cat "${TEST_TMP}/calls")" = "--capabilities" ]
}

@test "a self-installed binary that lists the podman text queries is asked them, and nothing is logged (#2095)" {
    local query
    ORCHESTRATOR_DOTNET_PODMAN=1
    _install_stand_in

    run --separate-stderr _run_text_cycle

    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    for query in background-stall diagnostic-refusal tool-denied-quit clean-review review-result-marker; do
        [ "$(grep -c "^podman ${query} " "${TEST_TMP}/calls")" -eq "${#_TEXT_MESSAGES[@]}" ]
    done
}
