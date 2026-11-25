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
