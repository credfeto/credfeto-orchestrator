#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are read by the sourced oneshot functions, where shellcheck cannot trace them
# shellcheck disable=SC2016  # stub bodies are expanded by the stub, not here

# ORCHESTRATOR_DOTNET_PODMAN (#252): off by default; when on, the read-only lib/podman queries ask ORCHESTRATOR_CMD
# podman, take its answer when it gives one (exit 0 or 1) and run their bash version, with a warning, when it does not.
# test/oneshot-podman-parity.bats checks what both sides print and return.

bats_require_minimum_version 1.5.0

load test_helper
load oneshot_helper

# A stand-in for the tool: appends its arguments to ${TEST_TMP}/cmd_args (one a line, then ---), writes "tool stderr"
# to stderr, prints ${TEST_TMP}/answer and exits with ${TEST_TMP}/status (0 when absent)
make_podman_cmd_stub() {
    make_stub_multiline fake-orchestrator \
        '{ printf "%s\n" "$@"; printf -- "---\n"; } >> "${TEST_TMP}/cmd_args"' \
        'printf "tool stderr\n" >&2' \
        'if [ -f "${TEST_TMP}/answer" ]; then cat "${TEST_TMP}/answer"; fi' \
        'if [ -f "${TEST_TMP}/status" ]; then exit "$(cat "${TEST_TMP}/status")"; fi' \
        'exit 0'
    export ORCHESTRATOR_CMD=fake-orchestrator
}

_tool_answers() {
    printf '%s' "$1" > "${TEST_TMP}/answer"
    printf '%s' "$2" > "${TEST_TMP}/status"
}

# A podman whose image has IMAGE_SHA_DEVELOPMENT_AGENT=bash-sha, whose container orchestrator-org exists and is stopped,
# and whose image exists locally; every call is logged to ${TEST_TMP}/podman_args and writes "podman stderr"
make_bash_podman_stub() {
    make_stub podman 'printf "%s\n" "$*" >> "${TEST_TMP}/podman_args"
        printf "podman stderr\n" >&2
        case "$*" in
            "inspect --format {{range .Config.Env}}{{println .}}{{end}} img:latest") printf "PATH=/bin\nIMAGE_SHA_DEVELOPMENT_AGENT=bash-sha\n" ;;
            "inspect orchestrator-org") printf "[{}]\n" ;;
            "inspect --format {{.State.Running}} orchestrator-org") printf "false\n" ;;
            "image exists img:latest") exit 0 ;;
            *) exit 125 ;;
        esac'
}

@test "ORCHESTRATOR_DOTNET_PODMAN defaults to off (#252)" {
    run env -u ORCHESTRATOR_DOTNET_PODMAN bash -c 'source "'"${REPO_ROOT}"'/oneshot"; printf "%s" "${ORCHESTRATOR_DOTNET_PODMAN}"'
    [ "${status}" -eq 0 ]
    [ "${output}" = "0" ]
}

@test "the lib/podman queries never run ORCHESTRATOR_CMD while ORCHESTRATOR_DOTNET_PODMAN is off (#252)" {
    make_podman_cmd_stub
    make_bash_podman_stub
    ORCHESTRATOR_DOTNET_PODMAN=0
    ORCHESTRATOR_IMAGE=img:latest
    [ "$(current_agent_image_sha)" = bash-sha ]
    agent_container_exists orchestrator-org
    run agent_container_running orchestrator-org
    [ "${status}" -eq 1 ]
    agent_image_cached img:latest 2> /dev/null
    [ ! -f "${TEST_TMP}/cmd_args" ]
    [ "$(cat "${TEST_TMP}/podman_args")" = "inspect --format {{range .Config.Env}}{{println .}}{{end}} img:latest
inspect orchestrator-org
inspect --format {{.State.Running}} orchestrator-org
image exists img:latest" ]
}

@test "each lib/podman query hands its query and option to ORCHESTRATOR_CMD podman when switched on (#252)" {
    make_podman_cmd_stub
    make_bash_podman_stub
    _tool_answers "" 1
    ORCHESTRATOR_DOTNET_PODMAN=1
    ORCHESTRATOR_IMAGE="img:latest"
    current_agent_image_sha 2> /dev/null || true
    agent_container_exists "orchestrator-org" 2> /dev/null || true
    agent_container_running "a name" 2> /dev/null || true
    agent_image_cached "--image" 2> /dev/null || true
    [ "$(cat "${TEST_TMP}/cmd_args")" = "podman
image-sha
--image
img:latest
---
podman
container-exists
--name
orchestrator-org
---
podman
container-running
--name
a name
---
podman
image-exists
--image
--image
---" ]
    [ ! -f "${TEST_TMP}/podman_args" ]
}

@test "a query prints the tool's answer byte for byte, trailing newlines kept, and returns its status (#252)" {
    make_podman_cmd_stub
    ORCHESTRATOR_DOTNET_PODMAN=1
    local text
    _tool_answers $'tool-sha\n\n' 0
    text=$(
        current_agent_image_sha 2> /dev/null
        printf x
    )
    [ "${text}" = $'tool-sha\n\nx' ]
    _tool_answers $'note\n' 0
    text=$(
        agent_image_cached img 2> /dev/null
        printf x
    )
    [ "${text}" = $'note\nx' ]
    _tool_answers "" 1
    run --separate-stderr current_agent_image_sha
    [ "${status}" -eq 1 ]
    [ "${output}" = "" ]
    run --separate-stderr agent_container_exists c
    [ "${status}" -eq 1 ]
    run --separate-stderr agent_image_cached img
    [ "${status}" -eq 1 ]
    _tool_answers "" 0
    run --separate-stderr agent_container_running c
    [ "${status}" -eq 0 ]
    run --separate-stderr agent_container_exists c
    [ "${status}" -eq 0 ]
}

@test "the quiet queries hide the tool's stderr, as their podman stderr is hidden, and image-exists passes it through (#252)" {
    make_podman_cmd_stub
    ORCHESTRATOR_DOTNET_PODMAN=1
    _tool_answers "x" 0
    run --separate-stderr current_agent_image_sha
    [ "${stderr}" = "" ]
    run --separate-stderr agent_container_exists c
    [ "${stderr}" = "" ]
    run --separate-stderr agent_container_running c
    [ "${stderr}" = "" ]
    run --separate-stderr agent_image_cached img
    [ "${stderr}" = "tool stderr" ]
}

@test "a query answers in bash, with a warning, when ORCHESTRATOR_CMD refuses, fails or is missing (#252)" {
    make_podman_cmd_stub
    make_bash_podman_stub
    ORCHESTRATOR_DOTNET_PODMAN=1
    ORCHESTRATOR_IMAGE=img:latest
    local exit_code
    for exit_code in 2 3 125 128 130 143; do
        _tool_answers "wrong" "${exit_code}"
        run --separate-stderr current_agent_image_sha
        [ "${status}" -eq 0 ]
        [ "${output}" = bash-sha ]
        [[ "${stderr}" == *"fake-orchestrator podman image-sha failed (exit ${exit_code}); running podman in bash instead"* ]]
        run --separate-stderr agent_container_exists orchestrator-org
        [ "${status}" -eq 0 ]
        [[ "${stderr}" == *"podman container-exists failed (exit ${exit_code})"* ]]
        run --separate-stderr agent_container_running orchestrator-org
        [ "${status}" -eq 1 ]
        run --separate-stderr agent_image_cached img:latest
        [ "${status}" -eq 0 ]
        [ "${output}" = "" ]
        [[ "${stderr}" == *"podman image-exists failed (exit ${exit_code}); running podman in bash instead"*"podman stderr"* ]]
    done
    ORCHESTRATOR_CMD="${TEST_TMP}/no-such-tool"
    run --separate-stderr agent_container_running orchestrator-org
    [ "${status}" -eq 1 ]
    [[ "${stderr}" == *"no-such-tool podman container-running failed (exit 127); running podman in bash instead"* ]]
}

@test "ensure_agent_container_ready takes the tool's container answers when switched on (#252)" {
    make_podman_cmd_stub
    make_stub podman 'printf "%s\n" "$*" >> "${TEST_TMP}/podman_args"; exit 0'
    cleanup_dangling_images() { return 0; }
    prune_transcripts() { return 0; }
    prune_codegraph_indexes() { return 0; }
    pull_agent_image_once() { return 0; }
    notify_discord_claude_error() { return 0; }
    ORCHESTRATOR_DOTNET_PODMAN=1
    # The tool says there is no such container, so nothing is removed
    _tool_answers "" 1
    ensure_agent_container_ready orchestrator-org Issue 7 2> /dev/null
    [ ! -f "${TEST_TMP}/podman_args" ]
    # The tool says it exists and runs, so the launch dies
    _tool_answers "" 0
    run ensure_agent_container_ready orchestrator-org Issue 7
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Container orchestrator-org already exists and is running"* ]]
    [ ! -f "${TEST_TMP}/podman_args" ]
    [ "$(grep -c '^container-exists$' "${TEST_TMP}/cmd_args")" -eq 2 ]
    [ "$(grep -c '^container-running$' "${TEST_TMP}/cmd_args")" -eq 1 ]
}

@test "pull_agent_image_once asks the tool whether the image is cached when a pull fails and switched on (#252)" {
    make_podman_cmd_stub
    make_stub podman 'printf "%s\n" "$*" >> "${TEST_TMP}/podman_args"; exit 1'
    notify_discord_pull_failed() { return 0; }
    ORCHESTRATOR_DOTNET_PODMAN=1
    ORCHESTRATOR_IMAGE=img:latest
    ORCHESTRATOR_IMAGE_PULLED_THIS_RUN=0
    _tool_answers "" 0
    run --separate-stderr pull_agent_image_once Issue 7
    [ "${status}" -eq 0 ]
    [[ "${stderr}" == *"falling back to the cached local image"* ]]
    [ "$(cat "${TEST_TMP}/podman_args")" = "pull img:latest" ]
    _tool_answers "" 1
    run --separate-stderr pull_agent_image_once Issue 7
    [ "${status}" -ne 0 ]
    [[ "${stderr}" == *"no cached local image is available"* ]]
}

# A Claude JSON result with one Bash denial, which the bash jq summarises as "- Bash: git status" and names as "git"
_write_denials_result() {
    printf '%s' '{"result":"done","permission_denials":[{"tool_name":"Bash","tool_input":{"command":"git status"}}]}' \
        > "${TEST_TMP}/result.json"
}

@test "the Claude result reads never run ORCHESTRATOR_CMD while ORCHESTRATOR_DOTNET_PODMAN is off (#252)" {
    make_podman_cmd_stub
    _write_denials_result
    ORCHESTRATOR_DOTNET_PODMAN=0
    [ "$(claude_result_permission_denials_summary "${TEST_TMP}/result.json")" = "- Bash: git status" ]
    [ "$(claude_result_denied_command_names "${TEST_TMP}/result.json")" = git ]
    [ ! -f "${TEST_TMP}/cmd_args" ]
}

@test "each Claude result read hands its query and the result file to ORCHESTRATOR_CMD podman when switched on (#252)" {
    make_podman_cmd_stub
    _write_denials_result
    ORCHESTRATOR_DOTNET_PODMAN=1
    _tool_answers "" 0
    claude_result_permission_denials_summary "${TEST_TMP}/result.json" > /dev/null
    claude_result_denied_command_names "a file" > /dev/null
    [ "$(cat "${TEST_TMP}/cmd_args")" = "podman
denials-summary
--result
${TEST_TMP}/result.json
---
podman
denied-command-names
--result
a file
---" ]
}

@test "a Claude result read prints the tool's answer byte for byte, trailing newlines kept, and hides its stderr (#252)" {
    make_podman_cmd_stub
    _write_denials_result
    ORCHESTRATOR_DOTNET_PODMAN=1
    local text
    _tool_answers $'- Tool: answer\n\n' 0
    text=$(
        claude_result_permission_denials_summary "${TEST_TMP}/result.json"
        printf '.%s' "$?"
    )
    [ "${text}" = $'- Tool: answer\n\n.0' ]
    _tool_answers $'tool-name\n' 0
    run --separate-stderr claude_result_denied_command_names "${TEST_TMP}/result.json"
    [ "${status}" -eq 0 ]
    [ "${output}" = tool-name ]
    [ "${stderr}" = "" ]
}

@test "a Claude result read runs its jq, with a warning, when ORCHESTRATOR_CMD refuses, fails or is missing (#252)" {
    make_podman_cmd_stub
    _write_denials_result
    ORCHESTRATOR_DOTNET_PODMAN=1
    local exit_code
    for exit_code in 1 2 3 125 130 143; do
        _tool_answers "wrong" "${exit_code}"
        run --separate-stderr claude_result_permission_denials_summary "${TEST_TMP}/result.json"
        [ "${status}" -eq 0 ]
        [ "${output}" = "- Bash: git status" ]
        [[ "${stderr}" == *"fake-orchestrator podman denials-summary failed (exit ${exit_code}); running jq in bash instead"* ]]
        run --separate-stderr claude_result_denied_command_names "${TEST_TMP}/result.json"
        [ "${status}" -eq 0 ]
        [ "${output}" = git ]
        [[ "${stderr}" == *"fake-orchestrator podman denied-command-names failed (exit ${exit_code}); running jq in bash instead"* ]]
    done
    ORCHESTRATOR_CMD="${TEST_TMP}/no-such-tool"
    run --separate-stderr claude_result_denied_command_names "${TEST_TMP}/result.json"
    [ "${output}" = git ]
    [[ "${stderr}" == *"no-such-tool podman denied-command-names failed (exit 127); running jq in bash instead"* ]]
}

@test "handle_claude_permission_denials logs, counts and notifies the tool's summary when switched on (#252)" {
    make_podman_cmd_stub
    _write_denials_result
    local notify_log="${TEST_TMP}/notify.log"
    notify_discord_permission_denials() { printf '%s\n' "$*" >> "${notify_log}"; }
    ORCHESTRATOR_DOTNET_PODMAN=1
    _tool_answers $'- Tool: one\n- Tool: two\n' 0
    run --separate-stderr handle_claude_permission_denials "${TEST_TMP}/result.json" Issue 42
    [ "${status}" -eq 0 ]
    [ "${output}" = $'- Tool: one\n- Tool: two' ]
    [[ "${stderr}" == *"Claude reported 2 permission denial(s)"* ]]
    [ "$(cat "${notify_log}")" = $'Issue 42 - Tool: one\n- Tool: two 2' ]
}

# A stand-in for the tool's text queries: writes its arguments NUL-ended to ${TEST_TMP}/text_args_<n> and its stdin to
# ${TEST_TMP}/text_stdin_<n> (n counts the calls from 1), prints ${TEST_TMP}/answer and exits with ${TEST_TMP}/status
make_text_cmd_stub() {
    make_stub_multiline fake-orchestrator \
        'n=$(($(cat "${TEST_TMP}/text_calls" 2> /dev/null || printf 0) + 1)); printf "%s" "${n}" > "${TEST_TMP}/text_calls"' \
        'for a in "$@"; do printf "%s\0" "${a}"; done > "${TEST_TMP}/text_args_${n}"' \
        'cat > "${TEST_TMP}/text_stdin_${n}"' \
        'printf "tool stderr\n" >&2' \
        'if [ -f "${TEST_TMP}/answer" ]; then cat "${TEST_TMP}/answer"; fi' \
        'if [ -f "${TEST_TMP}/status" ]; then exit "$(cat "${TEST_TMP}/status")"; fi' \
        'exit 0'
    export ORCHESTRATOR_CMD=fake-orchestrator
}

# Prints argument $2 (from 0) of text query call $1
_text_call_arg() {
    local -a args
    mapfile -d '' -t args < "${TEST_TMP}/text_args_$1"
    printf '%s' "${args[$2]}"
}

# Prints the pattern array named $1 joined with "|", as lib/podman joins it
_joined_patterns() {
    local IFS='|'
    local -n patterns="$1"
    printf '%s' "${patterns[*]}"
}

# Prints text query call $1's arguments, one a line
_text_call_args() {
    tr '\0' '\n' < "${TEST_TMP}/text_args_$1"
}

@test "the text heuristics never run ORCHESTRATOR_CMD while ORCHESTRATOR_DOTNET_PODMAN is off (#252)" {
    make_text_cmd_stub
    ORCHESTRATOR_DOTNET_PODMAN=0
    claude_result_indicates_background_stall "I'll continue automatically"
    claude_result_indicates_diagnostic_refusal "git push is denied"
    claude_result_indicates_tool_denied_quit "Bash is denied, so I cannot continue."
    [ "$(review_result_marker "REVIEW RESULT: CLEAN")" = CLEAN ]
    claude_result_indicates_clean_review "Code review: no findings."
    [ ! -f "${TEST_TMP}/text_calls" ]
}

@test "each text heuristic hands its query, the locale, its patterns and the message to ORCHESTRATOR_CMD podman (#252)" {
    make_text_cmd_stub
    ORCHESTRATOR_DOTNET_PODMAN=1
    _tool_answers "" 1
    local stall_args
    LC_ALL=C.UTF-8
    claude_result_indicates_background_stall $'a message\n' || true
    claude_result_indicates_diagnostic_refusal "short" || true
    claude_result_indicates_tool_denied_quit "quit?" || true
    review_result_marker "marker?" > /dev/null
    claude_result_indicates_clean_review "clean?" || true
    [ "$(cat "${TEST_TMP}/text_calls")" = 5 ]
    stall_args=$(_text_call_args 1)
    [ "$(printf '%s\n' "${stall_args}" | head -6)" = "podman
background-stall
--ctype
C.UTF-8
--collate
C.UTF-8" ]
    [ "$(_text_call_arg 1 6)" = --pattern ]
    [[ "$(_text_call_arg 1 7)" == "background.*(wait|still running|pause here)|"* ]]
    [ "$(od -An -c "${TEST_TMP}/text_stdin_1" | tr -s ' ')" = " a m e s s a g e \n \n" ]
    [ "$(_text_call_arg 2 1)" = diagnostic-refusal ]
    [ "$(cat "${TEST_TMP}/text_stdin_2")" = short ]
    [ "$(_text_call_arg 3 1)" = tool-denied-quit ]
    [ "$(_text_call_args 3 | sed -n '7p;9p;11p;13p' | tr '\n' ' ')" = "--mention --give-up --workaround --negated " ]
    [ "$(_text_call_arg 3 7)" = "$(_joined_patterns TOOL_DENIAL_MENTION_PATTERNS)" ]
    [ "$(_text_call_arg 3 13)" = "$(_joined_patterns TOOL_DENIED_NEGATED_WORKAROUND_PATTERNS)" ]
    [ "$(_text_call_args 4 | tail -n +2 | sed -n '1p;6,9p' | tr '\n' '|')" = "review-result-marker|--clean-marker|${REVIEW_RESULT_CLEAN_MARKER}|--findings-marker|${REVIEW_RESULT_FINDINGS_MARKER}|" ]
    [ "$(_text_call_arg 5 1)" = clean-review ]
    [ "$(_text_call_args 5 | sed -n '7p;9p;11p;13p;15p' | tr '\n' ' ')" = "--clean-marker --findings-marker --clean --findings --negated " ]
    [ "$(_text_call_arg 5 13)" = "$(_joined_patterns REVIEW_FINDINGS_PATTERNS)" ]
}

@test "the text heuristics pass the shell's effective LC_CTYPE and LC_COLLATE, exported or not (#252)" {
    make_text_cmd_stub
    ORCHESTRATOR_DOTNET_PODMAN=1
    _tool_answers "" 1
    (
        unset LC_ALL LC_CTYPE LC_COLLATE
        LANG=C.UTF-8
        claude_result_indicates_background_stall "x" || true
        LC_CTYPE=C
        LC_COLLATE=POSIX
        claude_result_indicates_background_stall "x" || true
        LC_ALL=C.UTF-8
        claude_result_indicates_background_stall "x" || true
        unset LANG LC_ALL LC_CTYPE LC_COLLATE
        claude_result_indicates_background_stall "x" || true
    ) 2> /dev/null
    [ "$(_text_call_args 1 | sed -n '4p;6p' | tr '\n' ' ')" = "C.UTF-8 C.UTF-8 " ]
    [ "$(_text_call_args 2 | sed -n '4p;6p' | tr '\n' ' ')" = "C POSIX " ]
    [ "$(_text_call_args 3 | sed -n '4p;6p' | tr '\n' ' ')" = "C.UTF-8 C.UTF-8 " ]
    [ "$(_text_call_args 4 | sed -n '4p;6p' | tr '\n' '|')" = "||" ]
}

@test "a text heuristic takes the tool's answer, exit 0 or 1, and hides its stderr (#252)" {
    make_text_cmd_stub
    ORCHESTRATOR_DOTNET_PODMAN=1
    _tool_answers "" 0
    run --separate-stderr claude_result_indicates_background_stall "no stall here"
    [ "${status}" -eq 0 ]
    [ "${stderr}" = "" ]
    _tool_answers "" 1
    run --separate-stderr claude_result_indicates_tool_denied_quit "Bash is denied, so I cannot continue."
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "" ]
    _tool_answers "" 0
    run claude_result_indicates_clean_review "I fixed two findings."
    [ "${status}" -eq 0 ]
    _tool_answers "FINDINGS" 0
    run --separate-stderr review_result_marker "REVIEW RESULT: CLEAN"
    [ "${status}" -eq 0 ]
    [ "${output}" = FINDINGS ]
    [ "${stderr}" = "" ]
}

@test "a text heuristic matches in bash, with a warning, when ORCHESTRATOR_CMD refuses, fails or is missing (#252)" {
    make_text_cmd_stub
    ORCHESTRATOR_DOTNET_PODMAN=1
    local exit_code
    for exit_code in 2 3 125 130 143; do
        _tool_answers "wrong" "${exit_code}"
        run --separate-stderr claude_result_indicates_background_stall "I'll continue automatically once it completes"
        [ "${status}" -eq 0 ]
        [[ "${stderr}" == *"fake-orchestrator podman background-stall failed (exit ${exit_code}); matching it in bash instead"* ]]
        run --separate-stderr claude_result_indicates_diagnostic_refusal "done"
        [ "${status}" -eq 1 ]
        [[ "${stderr}" == *"podman diagnostic-refusal failed (exit ${exit_code}); matching it in bash instead"* ]]
        run --separate-stderr claude_result_indicates_tool_denied_quit "Bash is denied, so I cannot continue."
        [ "${status}" -eq 0 ]
        [[ "${stderr}" == *"podman tool-denied-quit failed (exit ${exit_code}); matching it in bash instead"* ]]
        run --separate-stderr review_result_marker $'done\nREVIEW RESULT: CLEAN'
        [ "${output}" = CLEAN ]
        [[ "${stderr}" == *"podman review-result-marker failed (exit ${exit_code}); matching it in bash instead"* ]]
        run --separate-stderr claude_result_indicates_clean_review "Code review: no findings."
        [ "${status}" -eq 0 ]
        [[ "${stderr}" == *"podman clean-review failed (exit ${exit_code}); matching it in bash instead"* ]]
    done
    ORCHESTRATOR_CMD="${TEST_TMP}/no-such-tool"
    run --separate-stderr claude_result_indicates_tool_denied_quit "Bash is denied, so I cannot continue."
    [ "${status}" -eq 0 ]
    [[ "${stderr}" == *"no-such-tool podman tool-denied-quit failed (exit 127); matching it in bash instead"* ]]
}

@test "review_result_marker reads the line in bash when the tool exits 1, which it never answers with (#252)" {
    make_text_cmd_stub
    ORCHESTRATOR_DOTNET_PODMAN=1
    _tool_answers "FINDINGS" 1
    run --separate-stderr review_result_marker "REVIEW RESULT: CLEAN"
    [ "${status}" -eq 0 ]
    [ "${output}" = CLEAN ]
}

@test "the diagnostic refusal's length cap and the clean review's empty test are decided before the tool is asked (#252)" {
    make_text_cmd_stub
    ORCHESTRATOR_DOTNET_PODMAN=1
    _tool_answers "" 0
    local long
    printf -v long '%501s' "is denied"
    run claude_result_indicates_diagnostic_refusal "${long}"
    [ "${status}" -eq 1 ]
    run claude_result_indicates_clean_review ""
    [ "${status}" -eq 1 ]
    [ ! -f "${TEST_TMP}/text_calls" ]
}

@test "a clean review the tool refuses reads its result line in bash, without asking the tool again (#252)" {
    make_text_cmd_stub
    ORCHESTRATOR_DOTNET_PODMAN=1
    _tool_answers "" 3
    run --separate-stderr claude_result_indicates_clean_review $'I fixed it.\nREVIEW RESULT: CLEAN'
    [ "${status}" -eq 0 ]
    [ "$(cat "${TEST_TMP}/text_calls")" = 1 ]
    [ "$(grep -c 'matching it in bash instead' <<< "${stderr}")" -eq 1 ]
}
