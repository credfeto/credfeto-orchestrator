#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2154  # stderr is set by run --separate-stderr

bats_require_minimum_version 1.5.0

load test_helper

WRAPPER="${REPO_ROOT}/containers/base/development-full/claude-mcp/build-dotnet-mcp"

setup() {
    setup_isolated_env
    # The wrapper runs with PATH set to the stub directory alone, so no real dotnet on this host
    # can answer; git and jq, plus env and bash for the stubs' shebang, are linked in beside it.
    local tool
    for tool in git jq env bash; do
        ln -s "$(which "${tool}")" "${STUB_BIN}/${tool}"
    done

    # The user's home must allow execution for the global tool stub, which the system temp
    # directory may not, so it lives in the repository tree like the stub directory. git is only
    # ever run from the start directories under WORK, never from it, so it cannot find this repo.
    make_repo_fixture_dir
    USER_HOME="$(cd "${REPO_FIXTURE_DIR}" && pwd -P)"
    GLOBAL_TOOL="${USER_HOME}/.dotnet/tools/credfeto-build-dotnet"

    WORK="$(cd "${TEST_TMP}" && pwd -P)/work"
    mkdir -p "${WORK}"
    # Every wrapper run gets these, so git never finds a repository above the test's own
    # directory (GIT_CEILING_DIRECTORIES) or reads the host's system config.
    GIT_ISOLATION_ENV=("GIT_CEILING_DIRECTORIES=${WORK}" GIT_CONFIG_NOSYSTEM=1)

    # dotnet tool list's canned answer and what the stub saw, outside the wrapper's environment.
    DOTNET_STUB_STATE="${TEST_TMP}/dotnet-stub"
    mkdir -p "${DOTNET_STUB_STATE}"
    make_dotnet_stub
    # What dotnet prints when no manifest is found from HOME upwards.
    set_dotnet_list '{"version":1,"data":[]}'
}

teardown() {
    cleanup_repo_fixtures
    cleanup_stubs
}

# Runs the wrapper from the given start directory with only the variables Claude Code would pass
# (env -i drops every BUILD_MCP_REPO_ROOT the host exported) plus any NAME=value in WRAPPER_ENV,
# passing the remaining arguments through, stdout in output and stderr in stderr.
WRAPPER_ENV=()
run_wrapper() {
    local start_dir="$1"
    shift
    cd "${start_dir}" || return 1
    run --separate-stderr env -i "PATH=${STUB_BIN}" "HOME=${USER_HOME}" \
        "${GIT_ISOLATION_ENV[@]}" "${WRAPPER_ENV[@]}" "${WRAPPER}" "$@"
}

# Installs the dotnet stub. It answers "tool list" with the canned stdout, stderr and exit status
# set_dotnet_list wrote, recording where it ran and its arguments; anything else runs the given
# report line, or by default one that prints where it ran, the root it was given and its arguments,
# one a line, so the tests can tell which server the wrapper started and how. Only bash builtins
# are used, because the wrapper's PATH holds the stub directory alone, except that with a
# lock-home-after-list file in the state directory "tool list" makes HOME unenterable once it has
# answered (a test that wants that links chmod in), and with a read-stdin-in-list file it first
# reads all of its stdin, as a child that took the MCP stream would.
make_dotnet_stub() {
    # shellcheck disable=SC2016  # expanded by the stub, not here
    local report='printf "%s\n" "dotnet" "cwd=$(pwd -P)" "root=${BUILD_MCP_REPO_ROOT}" "argc=$#" "$@"'
    [ "$#" -eq 0 ] || report="$1"
    local state
    state="$(printf '%q' "${DOTNET_STUB_STATE}")"
    # shellcheck disable=SC2016  # expanded by the stub, not here
    make_stub_multiline dotnet \
        'if [ "${1-}" = tool ] && [ "${2-}" = list ]; then' \
        "    state=${state}" \
        '    printf "%s\n" "$(pwd -P)" > "${state}/list-cwd"' \
        '    printf "%s\n" "$*" > "${state}/list-args"' \
        '    [ ! -s "${state}/list-stderr" ] || printf "%s\n" "$(<"${state}/list-stderr")" >&2' \
        '    printf "%s" "$(<"${state}/list-stdout")"' \
        '    [ ! -e "${state}/lock-home-after-list" ] || chmod 000 "$(pwd -P)"' \
        '    [ ! -e "${state}/read-stdin-in-list" ] || IFS= read -r -d "" _ || true' \
        '    exit "$(<"${state}/list-status")"' \
        'fi' \
        "${report}"
}

# Sets what the dotnet stub's "tool list" prints on stdout ("$1") and stderr ("$3") and its exit
# status ("$2", 0 when not given).
set_dotnet_list() {
    printf '%s' "$1" > "${DOTNET_STUB_STATE}/list-stdout"
    printf '%s' "${2:-0}" > "${DOTNET_STUB_STATE}/list-status"
    printf '%s' "${3-}" > "${DOTNET_STUB_STATE}/list-stderr"
}

# Makes the dotnet stub's "tool list" report one local tool with the given commands, in the shape
# dotnet tool list --local --format json prints.
list_local_tool() {
    set_dotnet_list "$(jq -nc --arg manifest "${USER_HOME}/dotnet-tools.json" \
        '{version: 1, data: [{manifest: $manifest, packageId: "credfeto.build.dotnet.server", version: "1.0.0", commands: $ARGS.positional}]}' \
        --args "$@")"
}

# Installs a global tool stub whose body is the given line, or by default one that prints the same
# report as the dotnet stub. make_stub writes it, pointed at the global tool's directory, so it gets
# the same atomic write that stops a parallel bats job seeing a half-written file.
make_global_tool() {
    # shellcheck disable=SC2016  # expanded by the stub, not here
    local body='printf "%s\n" "global" "cwd=$(pwd -P)" "root=${BUILD_MCP_REPO_ROOT}" "argc=$#" "$@"'
    [ "$#" -eq 0 ] || body="$1"
    mkdir -p "${GLOBAL_TOOL%/*}"
    STUB_BIN="${GLOBAL_TOOL%/*}" make_stub "${GLOBAL_TOOL##*/}" "${body}"
}

# Makes a git repository with a nested subfolder.
make_git_repo() {
    git init -q "$1"
    mkdir -p "$1/src/deep"
}

@test "a local tool dotnet tool list reports runs through dotnet tool run, from HOME, with the start directory as the root" {
    list_local_tool credfeto-build-dotnet
    make_global_tool
    run_wrapper "${WORK}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' dotnet "cwd=${USER_HOME}" "root=${WORK}" argc=3 tool run credfeto-build-dotnet)" ]
    [ -z "${stderr}" ]
    # The list ran from HOME too, so it saw the manifest dotnet tool run uses, not the start
    # directory's.
    [ "$(<"${DOTNET_STUB_STATE}/list-cwd")" = "${USER_HOME}" ]
    [ "$(<"${DOTNET_STUB_STATE}/list-args")" = "tool list --local --format json" ]
}

@test "the global tool runs when dotnet tool list finds no manifest, and the list's stdout never reaches stdout" {
    make_global_tool
    run_wrapper "${WORK}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' global "cwd=${USER_HOME}" "root=${WORK}" argc=0)" ]
    [ -z "${stderr}" ]
}

@test "the global tool runs when dotnet tool list reports only other tools" {
    list_local_tool some-other-tool
    make_global_tool
    run_wrapper "${WORK}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' global "cwd=${USER_HOME}" "root=${WORK}" argc=0)" ]
    [ -z "${stderr}" ]
}

@test "a failing dotnet tool list fails, with its message on stderr, instead of falling back" {
    make_global_tool
    set_dotnet_list '' 1 "Json parsing error in file ${USER_HOME}/dotnet-tools.json"
    run_wrapper "${WORK}"
    [ "${status}" -ne 0 ]
    [ -z "${output}" ]
    [ "${stderr}" = "$(printf '%s\n' "Json parsing error in file ${USER_HOME}/dotnet-tools.json" \
        "build-dotnet-mcp: dotnet tool list --local --format json failed in ${USER_HOME}")" ]
}

@test "dotnet tool list output that is not one object with a data array fails instead of falling back" {
    make_global_tool
    # Each is the list's whole stdout: invalid JSON, JSON of the wrong shape, several documents,
    # and nothing at all.
    local content
    for content in '{ not json' '[1, 2]' '{}' 'null' '{"data": 5}' '{"data": "x"}' '{"data": {}}' \
        '{"data": []} {"data": []}' '{"data": []}
{"data": []}' ''; do
        set_dotnet_list "${content}"
        run_wrapper "${WORK}"
        [ "${status}" -ne 0 ]
        [ -z "${output}" ]
        [[ "${stderr}" == *"build-dotnet-mcp: cannot read the output of dotnet tool list --local --format json in ${USER_HOME}" ]]
    done
}

@test "a listed tool whose commands is not an array never matches, and does not stop the others being read" {
    make_global_tool
    local content
    for content in '{"data": [{"commands": "credfeto-build-dotnet"}]}' \
        '{"data": [5, {}, {"commands": ["some-other-tool"]}]}'; do
        set_dotnet_list "${content}"
        run_wrapper "${WORK}"
        [ "${status}" -eq 0 ]
        [ "${lines[0]}" = "global" ]
        [ -z "${stderr}" ]
    done

    set_dotnet_list '{"data": [{"commands": "x"}, 5, {"commands": [1, "credfeto-build-dotnet"]}]}'
    run_wrapper "${WORK}"
    [ "${status}" -eq 0 ]
    [ "${lines[0]}" = "dotnet" ]
    [ -z "${stderr}" ]
}

@test "the git and dotnet tool list probes never read stdin, so either server gets the whole MCP stream" {
    # git and dotnet tool list both read all of their stdin before doing their work, so if the
    # wrapper let them inherit it they would take the stream; each server reports what it reads.
    local real_git
    real_git="$(printf '%q' "$(readlink -f "$(which git)")")"
    rm -f "${STUB_BIN}/git"
    # shellcheck disable=SC2016  # expanded by the stub, not here
    make_stub_multiline git 'IFS= read -r -d "" _ || true' "exec ${real_git} \"\$@\""
    touch "${DOTNET_STUB_STATE}/read-stdin-in-list"
    # shellcheck disable=SC2016  # expanded by the stub, not here
    local report='IFS= read -r -d "" payload || true; printf "%s\n" "${0##*/}" "stdin=${payload}"'
    make_dotnet_stub "${report}"
    make_global_tool "${report}"
    local payload='{"jsonrpc":"2.0","id":1,"method":"initialize"}
{"jsonrpc":"2.0","method":"notifications/initialized"}'
    printf '%s' "${payload}" > "${TEST_TMP}/mcp-stream"

    run_wrapper "${WORK}" < "${TEST_TMP}/mcp-stream"
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' credfeto-build-dotnet "stdin=${payload}")" ]

    list_local_tool credfeto-build-dotnet
    run_wrapper "${WORK}" < "${TEST_TMP}/mcp-stream"
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' dotnet "stdin=${payload}")" ]
}

@test "a listed local tool fails without falling back to the global tool when HOME cannot be entered to run it" {
    [ "$(id -u)" -ne 0 ] || skip "root can enter a directory with mode 000"
    list_local_tool credfeto-build-dotnet
    make_global_tool
    ln -s "$(which chmod)" "${STUB_BIN}/chmod"
    # HOME changes between the list and the run: the list answers, then HOME becomes unenterable.
    touch "${DOTNET_STUB_STATE}/lock-home-after-list"
    local home_mode
    home_mode="$(stat -c '%a' "${USER_HOME}")"
    run_wrapper "${WORK}"
    # Restored before any assertion, so teardown can always remove HOME.
    chmod "${home_mode}" "${USER_HOME}"
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == *"build-dotnet-mcp: cannot change to ${USER_HOME} to run the local credfeto-build-dotnet" ]]
}

@test "a listed local tool that dotnet tool run cannot start fails without falling back to the global tool" {
    list_local_tool credfeto-build-dotnet
    make_global_tool
    # shellcheck disable=SC2016  # expanded by the stub, not here
    make_dotnet_stub 'printf "%s\n" "Run dotnet tool restore to make the tool available." >&2; exit 1'
    run_wrapper "${WORK}"
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "Run dotnet tool restore to make the tool available." ]
}

@test "with dotnet missing from PATH the global tool runs, or the wrapper fails when there is none" {
    make_global_tool
    rm -f "${STUB_BIN}/dotnet"
    run_wrapper "${WORK}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' global "cwd=${USER_HOME}" "root=${WORK}" argc=0)" ]
    [ -z "${stderr}" ]

    rm -f "${GLOBAL_TOOL}"
    run_wrapper "${WORK}"
    [ "${status}" -ne 0 ]
    [ -z "${output}" ]
    [[ "${stderr}" == "build-dotnet-mcp: credfeto-build-dotnet not found"* ]]
}

@test "with jq missing from PATH and dotnet present it fails instead of falling back" {
    list_local_tool credfeto-build-dotnet
    make_global_tool
    rm -f "${STUB_BIN}/jq"
    run_wrapper "${WORK}"
    [ "${status}" -ne 0 ]
    [ -z "${output}" ]
    [ "${stderr}" = "build-dotnet-mcp: jq is not on PATH to read dotnet tool list's output" ]
}

@test "a preset BUILD_MCP_REPO_ROOT is kept" {
    make_global_tool
    make_git_repo "${WORK}/repo"
    WRAPPER_ENV=(BUILD_MCP_REPO_ROOT=/workspace/repo)
    run_wrapper "${WORK}/repo/src"
    [ "${status}" -eq 0 ]
    [ "${lines[2]}" = "root=/workspace/repo" ]

    list_local_tool credfeto-build-dotnet
    run_wrapper "${WORK}/repo/src"
    [ "${status}" -eq 0 ]
    [ "${lines[0]}" = "dotnet" ]
    [ "${lines[2]}" = "root=/workspace/repo" ]
}

@test "an empty BUILD_MCP_REPO_ROOT is resolved like an unset one" {
    make_global_tool
    WRAPPER_ENV=(BUILD_MCP_REPO_ROOT=)
    run_wrapper "${WORK}"
    [ "${status}" -eq 0 ]
    [ "${lines[2]}" = "root=${WORK}" ]
}

@test "the root is the repository's top level when started at its root or in a subfolder" {
    make_global_tool
    make_git_repo "${WORK}/repo"
    run_wrapper "${WORK}/repo"
    [ "${status}" -eq 0 ]
    [ "${lines[2]}" = "root=${WORK}/repo" ]

    run_wrapper "${WORK}/repo/src/deep"
    [ "${status}" -eq 0 ]
    [ "${lines[2]}" = "root=${WORK}/repo" ]
}

@test "the root is the start directory itself outside a repository" {
    make_global_tool
    mkdir -p "${WORK}/plain/sub"
    run_wrapper "${WORK}/plain/sub"
    [ "${status}" -eq 0 ]
    [ "${lines[2]}" = "root=${WORK}/plain/sub" ]
}

@test "CLAUDE_PROJECT_DIR is used ahead of the working directory, at its repository's top level" {
    make_global_tool
    make_git_repo "${WORK}/repo"
    mkdir -p "${WORK}/elsewhere"
    WRAPPER_ENV=("CLAUDE_PROJECT_DIR=${WORK}/repo/src")
    run_wrapper "${WORK}/elsewhere"
    [ "${status}" -eq 0 ]
    [ "${lines[2]}" = "root=${WORK}/repo" ]

    mkdir -p "${WORK}/plain"
    WRAPPER_ENV=("CLAUDE_PROJECT_DIR=${WORK}/plain")
    run_wrapper "${WORK}/repo"
    [ "${status}" -eq 0 ]
    [ "${lines[2]}" = "root=${WORK}/plain" ]
}

@test "a CLAUDE_PROJECT_DIR that is empty or not a directory is ignored for the working directory" {
    make_global_tool
    make_git_repo "${WORK}/repo"
    WRAPPER_ENV=(CLAUDE_PROJECT_DIR=)
    run_wrapper "${WORK}/repo/src"
    [ "${status}" -eq 0 ]
    [ "${lines[2]}" = "root=${WORK}/repo" ]

    WRAPPER_ENV=("CLAUDE_PROJECT_DIR=${WORK}/missing")
    run_wrapper "${WORK}/repo/src"
    [ "${status}" -eq 0 ]
    [ "${lines[2]}" = "root=${WORK}/repo" ]
}

@test "a preset BUILD_MCP_REPO_ROOT that is relative or blank fails instead of reaching the server" {
    make_global_tool
    WRAPPER_ENV=(BUILD_MCP_REPO_ROOT=repo)
    run_wrapper "${WORK}"
    [ "${status}" -ne 0 ]
    [ -z "${output}" ]
    [ "${stderr}" = "build-dotnet-mcp: the repository root 'repo' from BUILD_MCP_REPO_ROOT is not an absolute path" ]

    WRAPPER_ENV=("BUILD_MCP_REPO_ROOT= ")
    run_wrapper "${WORK}"
    [ "${status}" -ne 0 ]
    [ -z "${output}" ]
    [ "${stderr}" = "build-dotnet-mcp: the repository root ' ' from BUILD_MCP_REPO_ROOT is not an absolute path" ]
}

@test "a relative CLAUDE_PROJECT_DIR outside a repository fails, and inside one resolves to its absolute top level" {
    make_global_tool
    mkdir -p "${WORK}/plain"
    WRAPPER_ENV=(CLAUDE_PROJECT_DIR=plain)
    run_wrapper "${WORK}"
    [ "${status}" -ne 0 ]
    [ -z "${output}" ]
    [ "${stderr}" = "build-dotnet-mcp: the repository root 'plain' from CLAUDE_PROJECT_DIR is not an absolute path" ]

    make_git_repo "${WORK}/repo"
    WRAPPER_ENV=(CLAUDE_PROJECT_DIR=repo/src)
    run_wrapper "${WORK}"
    [ "${status}" -eq 0 ]
    [ "${lines[2]}" = "root=${WORK}/repo" ]
}

@test "a preset BUILD_MCP_REPO_ROOT is kept ahead of CLAUDE_PROJECT_DIR" {
    make_global_tool
    WRAPPER_ENV=(BUILD_MCP_REPO_ROOT=/workspace/repo "CLAUDE_PROJECT_DIR=${WORK}")
    run_wrapper "${WORK}"
    [ "${status}" -eq 0 ]
    [ "${lines[2]}" = "root=/workspace/repo" ]
}

@test "arguments are passed through unchanged to either tool" {
    make_global_tool
    run_wrapper "${WORK}" --flag 'two words' ''
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' global "cwd=${USER_HOME}" "root=${WORK}" argc=3 --flag 'two words' '')" ]

    list_local_tool credfeto-build-dotnet
    run_wrapper "${WORK}" --flag 'two words' ''
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' dotnet "cwd=${USER_HOME}" "root=${WORK}" argc=6 tool run credfeto-build-dotnet --flag 'two words' '')" ]
}

# Checks that the variable named "$1" reaches both tools as "$2": unset by the caller and over the
# caller's "$3" for the global tool, then unset and over the caller's "$4" for the local tool.
assert_forced_for_both_tools() {
    local name="$1" forced="$2" global_override="$3" local_override="$4"
    local report="printf \"%s\\n\" \"\${0##*/}\" \"value=\${${name}-unset}\""
    make_dotnet_stub "${report}"
    make_global_tool "${report}"

    WRAPPER_ENV=()
    run_wrapper "${WORK}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' credfeto-build-dotnet "value=${forced}")" ]

    WRAPPER_ENV=("${name}=${global_override}")
    run_wrapper "${WORK}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' credfeto-build-dotnet "value=${forced}")" ]

    list_local_tool credfeto-build-dotnet
    WRAPPER_ENV=()
    run_wrapper "${WORK}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' dotnet "value=${forced}")" ]

    WRAPPER_ENV=("${name}=${local_override}")
    run_wrapper "${WORK}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' dotnet "value=${forced}")" ]
}

@test "DOTNET_NOLOGO is forced to 1 for either tool, over a value the caller set" {
    assert_forced_for_both_tools DOTNET_NOLOGO 1 0 false
}

@test "DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE is forced to true for either tool, over a value the caller set" {
    assert_forced_for_both_tools DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE true false 0
}

@test "SuppressNETCoreSdkPreviewMessage is forced to true for either tool, over a value the caller set" {
    assert_forced_for_both_tools SuppressNETCoreSdkPreviewMessage true false ''
}

@test "BUILD_MCP_LOG_DIR defaults to a per-user state directory for either tool" {
    # shellcheck disable=SC2016  # expanded by the stub, not here
    local report='printf "%s\n" "${0##*/}" "logs=${BUILD_MCP_LOG_DIR-unset}"'
    make_dotnet_stub "${report}"
    make_global_tool "${report}"

    WRAPPER_ENV=()
    run_wrapper "${WORK}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' credfeto-build-dotnet "logs=${USER_HOME}/.local/state/credfeto-build-mcp")" ]
    [ -z "${stderr}" ]

    # An empty value is resolved like an unset one, and an absolute XDG_STATE_HOME is used.
    WRAPPER_ENV=(BUILD_MCP_LOG_DIR= "XDG_STATE_HOME=${WORK}/state")
    run_wrapper "${WORK}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' credfeto-build-dotnet "logs=${WORK}/state/credfeto-build-mcp")" ]

    # A relative XDG_STATE_HOME is invalid under the XDG spec, so HOME's default is used.
    WRAPPER_ENV=(XDG_STATE_HOME=relative/state)
    run_wrapper "${WORK}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' credfeto-build-dotnet "logs=${USER_HOME}/.local/state/credfeto-build-mcp")" ]

    list_local_tool credfeto-build-dotnet
    WRAPPER_ENV=()
    run_wrapper "${WORK}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' dotnet "logs=${USER_HOME}/.local/state/credfeto-build-mcp")" ]
    # The wrapper leaves creating it to the server.
    [ ! -e "${USER_HOME}/.local/state/credfeto-build-mcp" ]
}

@test "a preset BUILD_MCP_LOG_DIR is kept for either tool" {
    # shellcheck disable=SC2016  # expanded by the stub, not here
    local report='printf "%s\n" "${0##*/}" "logs=${BUILD_MCP_LOG_DIR-unset}"'
    make_dotnet_stub "${report}"
    make_global_tool "${report}"

    WRAPPER_ENV=(BUILD_MCP_LOG_DIR=/srv/build-logs "XDG_STATE_HOME=${WORK}/state")
    run_wrapper "${WORK}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' credfeto-build-dotnet logs=/srv/build-logs)" ]

    list_local_tool credfeto-build-dotnet
    run_wrapper "${WORK}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' dotnet logs=/srv/build-logs)" ]
}

@test "a BUILD_MCP_LOG_DIR that is not absolute fails instead of reaching the server" {
    make_global_tool
    WRAPPER_ENV=(BUILD_MCP_LOG_DIR=logs)
    run_wrapper "${WORK}"
    [ "${status}" -ne 0 ]
    [ -z "${output}" ]
    [ "${stderr}" = "build-dotnet-mcp: the log directory 'logs' from BUILD_MCP_LOG_DIR is not an absolute path" ]

    WRAPPER_ENV=("BUILD_MCP_LOG_DIR= ")
    run_wrapper "${WORK}"
    [ "${status}" -ne 0 ]
    [ -z "${output}" ]
    [ "${stderr}" = "build-dotnet-mcp: the log directory ' ' from BUILD_MCP_LOG_DIR is not an absolute path" ]

    cd "${WORK}" || return 1
    run --separate-stderr env -i "PATH=${STUB_BIN}" HOME=relative-home "${GIT_ISOLATION_ENV[@]}" "${WRAPPER}"
    [ "${status}" -ne 0 ]
    [ -z "${output}" ]
    [ "${stderr}" = "build-dotnet-mcp: the log directory 'relative-home/.local/state/credfeto-build-mcp' from HOME is not an absolute path" ]
}

# Replaces git and dotnet with stubs that only record that they ran, for the tests that prove the
# wrapper never starts them.
make_recording_probes() {
    rm -f "${STUB_BIN}/git"
    local calls
    calls="$(printf '%q' "${TEST_TMP}/probe-calls")"
    make_stub git "printf '%s\\n' \"git \$*\" >> ${calls}; exit 1"
    make_stub dotnet "printf '%s\\n' \"dotnet \$*\" >> ${calls}; exit 1"
}

@test "BUILD_MCP_TOOL=global runs the global tool directly, starting neither git nor dotnet" {
    make_global_tool
    make_recording_probes
    # A listed local tool would win without the setting; the stubs would also fail it.
    list_local_tool credfeto-build-dotnet
    WRAPPER_ENV=(BUILD_MCP_TOOL=global BUILD_MCP_REPO_ROOT=/workspace/repo)
    run_wrapper "${WORK}" --flag
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' global "cwd=${USER_HOME}" root=/workspace/repo argc=1 --flag)" ]
    [ -z "${stderr}" ]
    [ ! -e "${TEST_TMP}/probe-calls" ]

    # Without the setting the same run probes, so the stubs do record a call when there is one.
    WRAPPER_ENV=()
    run_wrapper "${WORK}"
    [ "$(<"${TEST_TMP}/probe-calls")" = "$(printf '%s\n' 'git -C '"${WORK}"' rev-parse --show-toplevel' 'dotnet tool list --local --format json')" ]
}

@test "BUILD_MCP_TOOL=global still sets the forced variables before the exec" {
    # shellcheck disable=SC2016  # expanded by the stub, not here
    make_global_tool 'printf "%s\n" "nologo=${DOTNET_NOLOGO-unset}" "workload=${DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE-unset}" "preview=${SuppressNETCoreSdkPreviewMessage-unset}" "logs=${BUILD_MCP_LOG_DIR-unset}"'
    make_recording_probes
    WRAPPER_ENV=(BUILD_MCP_TOOL=global BUILD_MCP_REPO_ROOT=/workspace/repo DOTNET_NOLOGO=0)
    run_wrapper "${WORK}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' nologo=1 workload=true preview=true logs=unset)" ]
    [ ! -e "${TEST_TMP}/probe-calls" ]
}

@test "BUILD_MCP_TOOL=global leaves BUILD_MCP_LOG_DIR out of the environment unless the caller set it" {
    # The [ -v ] test tells a variable that is set but empty from one that is not in the environment.
    # shellcheck disable=SC2016  # expanded by the stub, not here
    make_global_tool 'if [ -v BUILD_MCP_LOG_DIR ]; then printf "logs=%s\n" "${BUILD_MCP_LOG_DIR}"; else printf "%s\n" logs=unset; fi'
    make_recording_probes

    # Unset, or empty, the server keeps its own TMPDIR-based default, so no per-user state directory
    # is named or created.
    for preset in "XDG_STATE_HOME=${WORK}/state" BUILD_MCP_LOG_DIR=; do
        WRAPPER_ENV=(BUILD_MCP_TOOL=global BUILD_MCP_REPO_ROOT=/workspace/repo "${preset}")
        run_wrapper "${WORK}"
        [ "${status}" -eq 0 ]
        [ "${output}" = logs=unset ]
        [ -z "${stderr}" ]
    done
    [ ! -e "${USER_HOME}/.local/state/credfeto-build-mcp" ]
    [ ! -e "${WORK}/state" ]

    # A value the caller set is still kept, and still has to be absolute.
    WRAPPER_ENV=(BUILD_MCP_TOOL=global BUILD_MCP_REPO_ROOT=/workspace/repo BUILD_MCP_LOG_DIR=/srv/build-logs)
    run_wrapper "${WORK}"
    [ "${status}" -eq 0 ]
    [ "${output}" = logs=/srv/build-logs ]

    WRAPPER_ENV=(BUILD_MCP_TOOL=global BUILD_MCP_REPO_ROOT=/workspace/repo BUILD_MCP_LOG_DIR=logs)
    run_wrapper "${WORK}"
    [ "${status}" -ne 0 ]
    [ -z "${output}" ]
    [ "${stderr}" = "build-dotnet-mcp: the log directory 'logs' from BUILD_MCP_LOG_DIR is not an absolute path" ]
    [ ! -e "${TEST_TMP}/probe-calls" ]
}

@test "BUILD_MCP_TOOL=global fails without a preset root, or without the global tool, and never probes" {
    make_global_tool
    make_recording_probes
    WRAPPER_ENV=(BUILD_MCP_TOOL=global)
    run_wrapper "${WORK}"
    [ "${status}" -ne 0 ]
    [ -z "${output}" ]
    [ "${stderr}" = "build-dotnet-mcp: BUILD_MCP_TOOL=global skips the git probe, so it needs BUILD_MCP_REPO_ROOT set" ]

    rm -f "${GLOBAL_TOOL}"
    WRAPPER_ENV=(BUILD_MCP_TOOL=global BUILD_MCP_REPO_ROOT=/workspace/repo)
    run_wrapper "${WORK}"
    [ "${status}" -ne 0 ]
    [ -z "${output}" ]
    [ "${stderr}" = "build-dotnet-mcp: BUILD_MCP_TOOL=global, but ${GLOBAL_TOOL} is missing or not executable" ]
    [ ! -e "${TEST_TMP}/probe-calls" ]
}

@test "an unknown BUILD_MCP_TOOL value fails before anything runs" {
    make_global_tool
    make_recording_probes
    local value
    for value in local Global auto ' '; do
        WRAPPER_ENV=("BUILD_MCP_TOOL=${value}" BUILD_MCP_REPO_ROOT=/workspace/repo)
        run_wrapper "${WORK}"
        [ "${status}" -ne 0 ]
        [ -z "${output}" ]
        [ "${stderr}" = "build-dotnet-mcp: BUILD_MCP_TOOL is '${value}', but it takes only global, or is left unset to choose the tool" ]
    done
    [ ! -e "${TEST_TMP}/probe-calls" ]
}

@test "an empty BUILD_MCP_TOOL chooses the tool as an unset one does" {
    list_local_tool credfeto-build-dotnet
    make_global_tool
    WRAPPER_ENV=(BUILD_MCP_TOOL=)
    run_wrapper "${WORK}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' dotnet "cwd=${USER_HOME}" "root=${WORK}" argc=3 tool run credfeto-build-dotnet)" ]
}

@test "with neither tool found it fails with a message on stderr and nothing on stdout" {
    run_wrapper "${WORK}"
    [ "${status}" -ne 0 ]
    [ -z "${output}" ]
    [[ "${stderr}" == "build-dotnet-mcp: credfeto-build-dotnet not found"* ]]
}

@test "a global tool that is not executable is not run" {
    make_global_tool
    chmod 0644 "${GLOBAL_TOOL}"
    run_wrapper "${WORK}"
    [ "${status}" -ne 0 ]
    [ -z "${output}" ]
    [[ "${stderr}" == "build-dotnet-mcp: credfeto-build-dotnet not found"* ]]
}

@test "the global tool is found under DOTNET_CLI_HOME when it is set, and still started from HOME" {
    local cli_home="${USER_HOME}/cli-home"
    GLOBAL_TOOL="${cli_home}/.dotnet/tools/credfeto-build-dotnet"
    make_global_tool
    WRAPPER_ENV=("DOTNET_CLI_HOME=${cli_home}")
    run_wrapper "${WORK}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' global "cwd=${USER_HOME}" "root=${WORK}" argc=0)" ]
    [ -z "${stderr}" ]

    # The one under HOME is not used in its place.
    rm -f "${GLOBAL_TOOL}"
    GLOBAL_TOOL="${USER_HOME}/.dotnet/tools/credfeto-build-dotnet"
    make_global_tool
    run_wrapper "${WORK}"
    [ "${status}" -ne 0 ]
    [ -z "${output}" ]
    [ "${stderr}" = "build-dotnet-mcp: credfeto-build-dotnet not found: install it as a local tool from ${USER_HOME} with dotnet tool install --local, or as a global tool in ${cli_home}/.dotnet/tools" ]
}

@test "with BUILD_MCP_TOOL=global, DOTNET_CLI_HOME is ignored and the tool under HOME runs" {
    local cli_home="${USER_HOME}/cli-home"
    make_global_tool
    # A tool under DOTNET_CLI_HOME, the one an unchecked runtime value would point at, is never run.
    local home_tool="${GLOBAL_TOOL}"
    GLOBAL_TOOL="${cli_home}/.dotnet/tools/credfeto-build-dotnet"
    make_global_tool 'printf "%s\n" cli-home-tool'
    GLOBAL_TOOL="${home_tool}"
    make_recording_probes
    local value
    for value in "${cli_home}" cli-home ' '; do
        WRAPPER_ENV=(BUILD_MCP_TOOL=global BUILD_MCP_REPO_ROOT=/workspace/repo "DOTNET_CLI_HOME=${value}")
        run_wrapper "${WORK}"
        [ "${status}" -eq 0 ]
        [ "${output}" = "$(printf '%s\n' global "cwd=${USER_HOME}" root=/workspace/repo argc=0)" ]
        [ -z "${stderr}" ]
    done
    [ ! -e "${TEST_TMP}/probe-calls" ]
}

@test "an empty DOTNET_CLI_HOME finds the global tool under HOME, as an unset one does" {
    make_global_tool
    WRAPPER_ENV=(DOTNET_CLI_HOME=)
    run_wrapper "${WORK}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' global "cwd=${USER_HOME}" "root=${WORK}" argc=0)" ]
    [ -z "${stderr}" ]
}

@test "a DOTNET_CLI_HOME that is not absolute fails before anything runs" {
    make_global_tool
    make_recording_probes
    local value
    for value in cli-home ' '; do
        WRAPPER_ENV=("DOTNET_CLI_HOME=${value}")
        run_wrapper "${WORK}"
        [ "${status}" -ne 0 ]
        [ -z "${output}" ]
        [ "${stderr}" = "build-dotnet-mcp: the dotnet CLI home '${value}' from DOTNET_CLI_HOME is not an absolute path" ]
    done
    [ ! -e "${TEST_TMP}/probe-calls" ]
}

@test "with HOME unset or empty it fails with a message on stderr and nothing on stdout" {
    make_global_tool
    cd "${WORK}" || return 1
    run --separate-stderr env -i "PATH=${STUB_BIN}" "${GIT_ISOLATION_ENV[@]}" "${WRAPPER}"
    [ "${status}" -ne 0 ]
    [ -z "${output}" ]
    [ "${stderr}" = "build-dotnet-mcp: HOME is not set" ]

    run --separate-stderr env -i "PATH=${STUB_BIN}" HOME= "${GIT_ISOLATION_ENV[@]}" "${WRAPPER}"
    [ "${status}" -ne 0 ]
    [ -z "${output}" ]
    [ "${stderr}" = "build-dotnet-mcp: HOME is not set" ]
}

@test "a start directory that no longer exists fails with a message on stderr and nothing on stdout" {
    make_global_tool
    mkdir -p "${WORK}/gone"
    cd "${WORK}/gone" || return 1
    rm -rf "${WORK}/gone"
    run --separate-stderr env -i "PATH=${STUB_BIN}" "HOME=${USER_HOME}" "${GIT_ISOLATION_ENV[@]}" "${WRAPPER}"
    [ "${status}" -ne 0 ]
    [ -z "${output}" ]
    [[ "${stderr}" == *"build-dotnet-mcp: cannot read the directory Claude Code was started in" ]]
}

@test "a start directory that no longer exists is not needed when CLAUDE_PROJECT_DIR is set" {
    make_global_tool
    mkdir -p "${WORK}/gone" "${WORK}/project"
    cd "${WORK}/gone" || return 1
    rm -rf "${WORK}/gone"
    run --separate-stderr env -i "PATH=${STUB_BIN}" "HOME=${USER_HOME}" \
        "${GIT_ISOLATION_ENV[@]}" "CLAUDE_PROJECT_DIR=${WORK}/project" "${WRAPPER}"
    [ "${status}" -eq 0 ]
    [ "${lines[0]}" = "global" ]
    [ "${lines[2]}" = "root=${WORK}/project" ]
}

@test "git missing from PATH falls back to the start directory as the root" {
    make_global_tool
    make_git_repo "${WORK}/repo"
    rm -f "${STUB_BIN}/git"
    run_wrapper "${WORK}/repo/src"
    [ "${status}" -eq 0 ]
    [ "${lines[2]}" = "root=${WORK}/repo/src" ]
    [ -z "${stderr}" ]
}
