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
    # Each stub server prints where it ran, the root it was given and its arguments, one a line,
    # so the tests can tell which one the wrapper started and how.
    # shellcheck disable=SC2016  # expanded by the stub, not here
    make_stub dotnet 'printf "%s\n" "dotnet" "cwd=$(pwd -P)" "root=${BUILD_MCP_REPO_ROOT}" "argc=$#" "$@"'

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

# Writes a tool manifest at the given path listing the given commands.
write_manifest() {
    local path="$1"
    shift
    mkdir -p "${path%/*}"
    jq -n '{version: 1, isRoot: true, tools: {"credfeto.build.dotnet.server": {version: "1.0.0", commands: $ARGS.positional}}}' \
        --args "$@" > "${path}"
}

# Installs a global tool stub whose body is the given line, or by default one that prints the same
# report as the dotnet stub. It is written beside the target and renamed onto it, as make_stub does,
# so a parallel bats job never sees a half-written or not yet executable file.
make_global_tool() {
    # shellcheck disable=SC2016  # expanded by the stub, not here
    local body='printf "%s\n" "global" "cwd=$(pwd -P)" "root=${BUILD_MCP_REPO_ROOT}" "argc=$#" "$@"'
    [ "$#" -eq 0 ] || body="$1"
    local tmp="${GLOBAL_TOOL}.$$_${RANDOM}${RANDOM}"
    mkdir -p "${GLOBAL_TOOL%/*}"
    printf '%s\n' '#!/usr/bin/env bash' "${body}" > "${tmp}"
    chmod 0755 "${tmp}"
    "${REAL_MV}" "${tmp}" "${GLOBAL_TOOL}"
}

# Makes a git repository with a nested subfolder.
make_git_repo() {
    git init -q "$1"
    mkdir -p "$1/src/deep"
}

@test "the local tool from ~/dotnet-tools.json runs through dotnet tool run, from HOME, with the start directory as the root" {
    write_manifest "${USER_HOME}/dotnet-tools.json" credfeto-build-dotnet
    make_global_tool
    run_wrapper "${WORK}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' dotnet "cwd=${USER_HOME}" "root=${WORK}" argc=3 tool run credfeto-build-dotnet)" ]
    [ -z "${stderr}" ]
}

@test "the local tool runs from HOME even when the start directory has its own root manifest" {
    write_manifest "${USER_HOME}/dotnet-tools.json" credfeto-build-dotnet
    make_git_repo "${WORK}/repo"
    write_manifest "${WORK}/repo/dotnet-tools.json" some-other-tool
    run_wrapper "${WORK}/repo"
    [ "${status}" -eq 0 ]
    [ "${lines[0]}" = "dotnet" ]
    [ "${lines[1]}" = "cwd=${USER_HOME}" ]
    [ "${lines[2]}" = "root=${WORK}/repo" ]
}

@test "the global tool runs when there is no ~/dotnet-tools.json" {
    make_global_tool
    run_wrapper "${WORK}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' global "cwd=${WORK}" "root=${WORK}" argc=0)" ]
    [ -z "${stderr}" ]
}

@test "the global tool runs when ~/dotnet-tools.json does not list credfeto-build-dotnet" {
    write_manifest "${USER_HOME}/dotnet-tools.json" some-other-tool
    make_global_tool
    run_wrapper "${WORK}"
    [ "${status}" -eq 0 ]
    [ "${lines[0]}" = "global" ]
}

@test "a ~/dotnet-tools.json that is not valid JSON, or not a manifest, fails instead of falling back" {
    mkdir -p "${USER_HOME}"
    make_global_tool
    # Each is one file's whole content: invalid JSON, JSON that is not one object whose tools is an
    # object, several documents, and an empty file.
    local content
    for content in '{ not json' '[1, 2]' '{}' 'null' '{"tools": 5}' '{"tools": "x"}' \
        '{"tools": {}} {"tools": {}}' '{"tools": {}}
{"tools": {}}' ''; do
        printf '%s' "${content}" > "${USER_HOME}/dotnet-tools.json"
        run_wrapper "${WORK}"
        [ "${status}" -ne 0 ]
        [ -z "${output}" ]
        [[ "${stderr}" == *"build-dotnet-mcp: cannot read ${USER_HOME}/dotnet-tools.json as a dotnet tool manifest" ]]
    done
}

@test "a tool whose commands is not an array never matches, and does not stop the others being read" {
    mkdir -p "${USER_HOME}"
    make_global_tool
    local content
    for content in '{"tools": {"a": {"commands": "credfeto-build-dotnet"}}}' \
        '{"tools": {"a": 5, "b": {}, "c": {"commands": ["some-other-tool"]}}}'; do
        printf '%s' "${content}" > "${USER_HOME}/dotnet-tools.json"
        run_wrapper "${WORK}"
        [ "${status}" -eq 0 ]
        [ "${lines[0]}" = "global" ]
        [ -z "${stderr}" ]
    done

    printf '%s' '{"tools": {"a": {"commands": "x"}, "b": 5, "c": {"commands": [1, "credfeto-build-dotnet"]}}}' \
        > "${USER_HOME}/dotnet-tools.json"
    run_wrapper "${WORK}"
    [ "${status}" -eq 0 ]
    [ "${lines[0]}" = "dotnet" ]
    [ -z "${stderr}" ]
}

@test "with jq missing from PATH a ~/dotnet-tools.json fails instead of falling back" {
    write_manifest "${USER_HOME}/dotnet-tools.json" credfeto-build-dotnet
    make_global_tool
    rm -f "${STUB_BIN}/jq"
    run_wrapper "${WORK}"
    [ "${status}" -ne 0 ]
    [ -z "${output}" ]
    [ "${stderr}" = "build-dotnet-mcp: ${USER_HOME}/dotnet-tools.json exists, but jq is not on PATH to read it" ]
}

@test "with jq missing from PATH and no ~/dotnet-tools.json the global tool still runs" {
    make_global_tool
    rm -f "${STUB_BIN}/jq"
    run_wrapper "${WORK}"
    [ "${status}" -eq 0 ]
    [ "${lines[0]}" = "global" ]
    [ -z "${stderr}" ]
}

@test "the old ~/.config/dotnet-tools.json manifest name is not looked for" {
    write_manifest "${USER_HOME}/.config/dotnet-tools.json" credfeto-build-dotnet
    make_global_tool
    run_wrapper "${WORK}"
    [ "${status}" -eq 0 ]
    [ "${lines[0]}" = "global" ]

    rm -f "${GLOBAL_TOOL}"
    run_wrapper "${WORK}"
    [ "${status}" -ne 0 ]
    [ -z "${output}" ]
}

@test "a preset BUILD_MCP_REPO_ROOT is kept" {
    make_global_tool
    make_git_repo "${WORK}/repo"
    WRAPPER_ENV=(BUILD_MCP_REPO_ROOT=/workspace/repo)
    run_wrapper "${WORK}/repo/src"
    [ "${status}" -eq 0 ]
    [ "${lines[2]}" = "root=/workspace/repo" ]

    write_manifest "${USER_HOME}/dotnet-tools.json" credfeto-build-dotnet
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
    [ "${output}" = "$(printf '%s\n' global "cwd=${WORK}" "root=${WORK}" argc=3 --flag 'two words' '')" ]

    write_manifest "${USER_HOME}/dotnet-tools.json" credfeto-build-dotnet
    run_wrapper "${WORK}" --flag 'two words' ''
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' dotnet "cwd=${USER_HOME}" "root=${WORK}" argc=6 tool run credfeto-build-dotnet --flag 'two words' '')" ]
}

# Checks that the variable named "$1" reaches both tools as "$2": unset by the caller and over the
# caller's "$3" for the global tool, then unset and over the caller's "$4" for the local tool.
assert_forced_for_both_tools() {
    local name="$1" forced="$2" global_override="$3" local_override="$4"
    local report="printf \"%s\\n\" \"\${0##*/}\" \"value=\${${name}-unset}\""
    make_stub dotnet "${report}"
    make_global_tool "${report}"

    WRAPPER_ENV=()
    run_wrapper "${WORK}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' credfeto-build-dotnet "value=${forced}")" ]

    WRAPPER_ENV=("${name}=${global_override}")
    run_wrapper "${WORK}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' credfeto-build-dotnet "value=${forced}")" ]

    write_manifest "${USER_HOME}/dotnet-tools.json" credfeto-build-dotnet
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

@test "SuppressNETCoreSdkPreviewMessage is forced to true for either tool, over a value the caller set" {
    assert_forced_for_both_tools SuppressNETCoreSdkPreviewMessage true false ''
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

@test "a listed local tool with no dotnet on PATH fails with a message on stderr and nothing on stdout" {
    write_manifest "${USER_HOME}/dotnet-tools.json" credfeto-build-dotnet
    rm -f "${STUB_BIN}/dotnet"
    run_wrapper "${WORK}"
    [ "${status}" -ne 0 ]
    [ -z "${output}" ]
    [[ "${stderr}" == "build-dotnet-mcp: ${USER_HOME}/dotnet-tools.json lists credfeto-build-dotnet, but dotnet is not on PATH" ]]
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
