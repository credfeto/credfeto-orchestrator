#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2154  # stderr is set by run --separate-stderr

# The dotnet tool MCP server launchers: the thin build-dotnet-mcp, build-node-mcp and
# changelog-mcp entries and the shared dotnet-tool-mcp-launcher they source. Every case runs
# against every entry (for_each_entry), so the entries cannot drift apart again.

bats_require_minimum_version 1.5.0

load test_helper

MCP_DIR="${REPO_ROOT}/containers/base/development-full/claude-mcp"
ENTRIES=(build-dotnet-mcp build-node-mcp changelog-mcp)
# The runtime the dotnet stub's --info reports, and one it does not.
HOST_RID="test-x64"
OTHER_RID="other-arm64"

setup() {
    setup_isolated_env
    make_repo_fixture_dir
    FIXTURE_ROOT="$(cd "${REPO_FIXTURE_DIR}" && pwd -P)"
    TMP_ROOT="$(cd "${TEST_TMP}" && pwd -P)"
    # The launchers are #!/bin/sh, so they run under dash where it is installed, the strictest
    # POSIX shell to hand (and /bin/sh on Debian and Ubuntu), and under sh otherwise.
    LAUNCHER_SHELL="$(command -v dash || command -v sh)"
    # The real tools the stub directory links to, looked up once while it is still empty: the
    # shell's command hash would otherwise hand back a link use_entry has just removed.
    declare -gA REAL_TOOL=()
    local tool
    for tool in git jq env bash mv; do
        REAL_TOOL[${tool}]="$(command -v "${tool}")"
    done
}

teardown() {
    cleanup_repo_fixtures
    cleanup_stubs
}

# Runs "$@" once for each entry, after use_entry has set up a fresh fixture for it.
for_each_entry() {
    local entry
    for entry in "${ENTRIES[@]}"; do
        use_entry "${entry}"
        "$@"
    done
}

# Sets the values entry "$1" hands the shared launcher, and gives it its own HOME, work tree and
# stubs, so nothing one entry's run leaves behind is seen by the next.
use_entry() {
    ENTRY="$1"
    printf 'entry %s\n' "${ENTRY}"
    case "${ENTRY}" in
        build-dotnet-mcp)
            TOOL_COMMAND=credfeto-build-dotnet PACKAGE_ID=Credfeto.Build.Dotnet.Server PREFIX=BUILD_MCP
            LOG_DIR_NAME=credfeto-build-mcp QUIET_SDK_PREVIEW=yes
            ;;
        build-node-mcp)
            TOOL_COMMAND=credfeto-build-node PACKAGE_ID=Credfeto.Build.Node.Server PREFIX=BUILD_MCP
            LOG_DIR_NAME=credfeto-build-mcp QUIET_SDK_PREVIEW=no
            ;;
        changelog-mcp)
            TOOL_COMMAND=changelog-mcp PACKAGE_ID=Credfeto.ChangeLog.Mcp PREFIX=CHANGELOG_MCP
            LOG_DIR_NAME='' QUIET_SDK_PREVIEW=no
            ;;
        *) return 1 ;;
    esac
    WRAPPER="${MCP_DIR}/${ENTRY}"
    ROOT_VAR="${PREFIX}_REPO_ROOT"
    TOOL_VAR="${PREFIX}_TOOL"
    LOG_VAR="${PREFIX}_LOG_DIR"
    PACKAGE_DIR_NAME="${PACKAGE_ID,,}"
    LIST_VERSION="1.0.0"

    # The user's home must allow execution for the tool stubs, which the system temp directory may
    # not, so it lives in the repository tree like the stub directory. git is only ever run from the
    # start directories under WORK, never from it, so it cannot find this repo.
    USER_HOME="${FIXTURE_ROOT}/${ENTRY}/home"
    PACKAGES="${USER_HOME}/.nuget/packages"
    GLOBAL_TOOL="${USER_HOME}/.dotnet/tools/${TOOL_COMMAND}"
    WORK="${TMP_ROOT}/${ENTRY}/work"
    # A preset root that exists, as the image's mount does.
    PRESET_ROOT="${WORK}/preset/repo"
    mkdir -p "${USER_HOME}" "${WORK}" "${PRESET_ROOT}"
    # Every launcher run gets these, so git never finds a repository above the test's own
    # directory (GIT_CEILING_DIRECTORIES) or reads the host's system config.
    GIT_ISOLATION_ENV=("GIT_CEILING_DIRECTORIES=${WORK}" GIT_CONFIG_NOSYSTEM=1)
    WRAPPER_ENV=()
    PROBE_CALLS="${TMP_ROOT}/${ENTRY}/probe-calls"

    # The launcher runs with PATH set to the stub directory alone, so no real dotnet on this host
    # can answer; git and jq, plus env and bash for the stubs' shebang, are linked in beside it.
    local tool
    for tool in git jq env bash; do
        rm -f "${STUB_BIN:?}/${tool}"
        ln -s "${REAL_TOOL[${tool}]}" "${STUB_BIN}/${tool}"
    done

    # The dotnet stub's canned answers and what it saw, outside the launcher's environment.
    DOTNET_STUB_STATE="${TMP_ROOT}/${ENTRY}/dotnet-stub"
    mkdir -p "${DOTNET_STUB_STATE}"
    make_dotnet_stub
    # What dotnet prints when no manifest is found from HOME upwards.
    set_dotnet_list '{"version":1,"data":[]}'
    set_dotnet_info "$(printf '%s\n' ' Version:   10.0.100' " Base Path:   /opt/dotnet-sdk/sdk/10.0.100/" \
        '' 'Runtime Environment:' ' OS Name:     test' " RID:         ${HOST_RID}")"
}

# The line every stub server prints: which one ran ($1), where, the root it was given and its
# arguments, one a line, so the tests can tell which server the launcher started and how.
server_report() {
    printf '%s' "printf \"%s\\n\" \"$1\" \"cwd=\$(pwd -P)\" \"root=\${${ROOT_VAR}}\" \"argc=\$#\" \"\$@\""
}

# Runs the entry from the given start directory with only the variables Claude Code would pass
# (env -i drops every variable the host exported) plus any NAME=value in WRAPPER_ENV, passing the
# remaining arguments through, stdout in output and stderr in stderr.
run_wrapper() {
    local start_dir="$1"
    shift
    cd "${start_dir}" || return 1
    run --separate-stderr env -i "PATH=${STUB_BIN}" "HOME=${USER_HOME}" \
        "${GIT_ISOLATION_ENV[@]}" "${WRAPPER_ENV[@]}" "${LAUNCHER_SHELL}" "${WRAPPER}" "$@"
}

# Installs the dotnet stub. "tool list" answers with the canned stdout, stderr and exit status
# set_dotnet_list wrote, recording where it ran and its arguments; "--info" prints what
# set_dotnet_info wrote; "tool restore" records where it ran and what it read on stdin, prints a
# line on stdout (which must never reach the MCP stream) and, with restore-from and restore-to
# files in the state directory, moves that package into place (a test that wants that links mv
# in). Anything else runs the given report line, by default server_report's. Only bash builtins
# are used otherwise, because the launcher's PATH holds the stub directory alone. With a
# read-stdin file in the state directory every probe first reads all of its stdin, as a child
# that took the MCP stream would.
make_dotnet_stub() {
    local report
    report="$(server_report dotnet)"
    [ "$#" -eq 0 ] || report="$1"
    local state
    state="$(printf '%q' "${DOTNET_STUB_STATE}")"
    # shellcheck disable=SC2016  # expanded by the stub, not here
    make_stub_multiline dotnet \
        "state=${state}" \
        'if [ "${1-}" = tool ] && [ "${2-}" = list ]; then' \
        '    [ ! -e "${state}/read-stdin" ] || IFS= read -r -d "" _ || true' \
        '    printf "%s\n" "$(pwd -P)" > "${state}/list-cwd"' \
        '    printf "%s\n" "$*" > "${state}/list-args"' \
        '    [ ! -s "${state}/list-stderr" ] || printf "%s\n" "$(< "${state}/list-stderr")" >&2' \
        '    printf "%s" "$(< "${state}/list-stdout")"' \
        '    exit "$(< "${state}/list-status")"' \
        'fi' \
        'if [ "${1-}" = --info ]; then' \
        '    [ ! -e "${state}/read-stdin" ] || IFS= read -r -d "" _ || true' \
        '    printf "%s\n" "$(< "${state}/info-stdout")"' \
        '    exit 0' \
        'fi' \
        'if [ "${1-}" = tool ] && [ "${2-}" = restore ]; then' \
        '    payload=""' \
        '    IFS= read -r -d "" payload || true' \
        '    printf "%s\n" "cwd=$(pwd -P) stdin=${payload}" >> "${state}/restore-calls"' \
        '    printf "%s\n" "Restore was successful."' \
        '    [ ! -e "${state}/restore-from" ] || mv "$(< "${state}/restore-from")" "$(< "${state}/restore-to")"' \
        '    exit 0' \
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

# Sets what the dotnet stub's "--info" prints.
set_dotnet_info() {
    printf '%s' "$1" > "${DOTNET_STUB_STATE}/info-stdout"
}

# Makes the dotnet stub's "tool list" report one local tool with the given commands, as the
# entry's package at LIST_VERSION, in the shape dotnet tool list --local --format json prints.
list_local_tool() {
    set_dotnet_list "$(jq -nc --arg manifest "${USER_HOME}/dotnet-tools.json" \
        --arg id "${PACKAGE_DIR_NAME}" --arg version "${LIST_VERSION}" \
        '{version: 1, data: [{manifest: $manifest, packageId: $id, version: $version, commands: $ARGS.positional}]}' \
        --args "$@")"
}

# Writes a DotnetToolSettings.xml ("$1") whose Command element carries the given attributes ("$2")
# and, when given, RuntimeIdentifierPackage elements ("$3"), as dotnet pack writes it: a byte
# order mark, one element a line.
write_tool_settings() {
    local version=1
    [ -z "${3-}" ] || version=2
    mkdir -p "${1%/*}"
    {
        printf '\xef\xbb\xbf<?xml version="1.0" encoding="utf-8"?>\n'
        printf '<DotNetCliTool Version="%s">\n  <Commands>\n    <Command %s />\n  </Commands>\n' "${version}" "$2"
        [ -z "${3-}" ] || printf '  <RuntimeIdentifierPackages>\n%s\n  </RuntimeIdentifierPackages>\n' "$3"
        printf '</DotNetCliTool>'
    } > "$1"
}

# Makes a framework-dependent tool package for the entry's command in the packages folder ("$3",
# PACKAGES by default) at version "$1" (LIST_VERSION by default) under tools/<"$2">/any/
# (net10.0 by default), with the server's dll as its entry point.
make_dependent_package() {
    local dir="${3:-${PACKAGES}}/${PACKAGE_DIR_NAME}/${1:-${LIST_VERSION}}/tools/${2:-net10.0}/any"
    write_tool_settings "${dir}/DotnetToolSettings.xml" \
        "Name=\"${TOOL_COMMAND}\" EntryPoint=\"Server.dll\" Runner=\"dotnet\""
    : > "${dir}/Server.dll"
    DEPENDENT_DLL="${dir}/Server.dll"
}

# Makes a Native AOT tool, as dotnet pack lays one out: a pointer package at tools/any/any/ that
# names a runtime-specific package for each runtime, and the runtime-specific package for HOST_RID
# holding the executable, a stub server reporting "local". "$1" is the packages folder (PACKAGES
# by default).
make_native_package() {
    local packages="${1:-${PACKAGES}}"
    write_tool_settings "${packages}/${PACKAGE_DIR_NAME}/${LIST_VERSION}/tools/any/any/DotnetToolSettings.xml" \
        "Name=\"${TOOL_COMMAND}\"" \
        "$(printf '    <RuntimeIdentifierPackage RuntimeIdentifier="%s" Id="%s" />\n' \
            "${OTHER_RID}" "${PACKAGE_ID}.${OTHER_RID}" "${HOST_RID}" "${PACKAGE_ID}.${HOST_RID}")"
    local dir="${packages}/${PACKAGE_DIR_NAME}.${HOST_RID}/${LIST_VERSION}/tools/any/${HOST_RID}"
    write_tool_settings "${dir}/DotnetToolSettings.xml" \
        "Name=\"${TOOL_COMMAND}\" EntryPoint=\"Server\" Runner=\"executable\""
    STUB_BIN="${dir}" make_stub Server "$(server_report local)"
    NATIVE_EXECUTABLE="${dir}/Server"
}

# Installs a global tool stub whose body is the given line, or by default server_report's.
# make_stub writes it, pointed at the global tool's directory, so it gets the same atomic write
# that stops a parallel bats job seeing a half-written file.
make_global_tool() {
    local body
    body="$(server_report global)"
    [ "$#" -eq 0 ] || body="$1"
    mkdir -p "${GLOBAL_TOOL%/*}"
    STUB_BIN="${GLOBAL_TOOL%/*}" make_stub "${GLOBAL_TOOL##*/}" "${body}"
}

# Makes a git repository with a nested subfolder.
make_git_repo() {
    git init -q "$1"
    mkdir -p "$1/src/deep"
}

# Replaces git and dotnet with stubs that only record that they ran, for the cases that prove the
# launcher never starts them.
make_recording_probes() {
    rm -f "${STUB_BIN}/git"
    local calls
    calls="$(printf '%q' "${PROBE_CALLS}")"
    make_stub git "printf '%s\\n' \"git \$*\" >> ${calls}; exit 1"
    make_stub dotnet "printf '%s\\n' \"dotnet \$*\" >> ${calls}; exit 1"
}

# --- the local tool from the home manifest -------------------------------------------------------

case_local_dependent_from_root() {
    list_local_tool "${TOOL_COMMAND}"
    make_dependent_package
    make_global_tool
    make_git_repo "${WORK}/repo"
    run_wrapper "${WORK}/repo/src/deep" --flag
    [ "${status}" -eq 0 ]
    # dotnet runs the listed package's dll itself, from the repository's top level, not HOME.
    [ "${output}" = "$(printf '%s\n' dotnet "cwd=${WORK}/repo" "root=${WORK}/repo" argc=2 "${DEPENDENT_DLL}" --flag)" ]
    [ -z "${stderr}" ]
    # The list ran from HOME, so it saw the user's manifest, not one in the repository.
    [ "$(< "${DOTNET_STUB_STATE}/list-cwd")" = "${USER_HOME}" ]
    [ "$(< "${DOTNET_STUB_STATE}/list-args")" = "tool list --local --format json" ]
    [ ! -e "${DOTNET_STUB_STATE}/restore-calls" ]
}

@test "a listed framework-dependent local tool runs as dotnet <dll> from the repository root, ahead of the global tool" {
    for_each_entry case_local_dependent_from_root
}

case_local_native_from_root() {
    list_local_tool "${TOOL_COMMAND}"
    make_native_package
    make_global_tool
    make_git_repo "${WORK}/repo"
    run_wrapper "${WORK}/repo/src" one 'two words' ''
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' local "cwd=${WORK}/repo" "root=${WORK}/repo" argc=3 one 'two words' '')" ]
    [ -z "${stderr}" ]
    [ ! -e "${DOTNET_STUB_STATE}/restore-calls" ]
}

@test "a listed Native AOT local tool runs its runtime-specific executable from the repository root" {
    for_each_entry case_local_native_from_root
}

case_local_preset_root() {
    list_local_tool "${TOOL_COMMAND}"
    make_native_package
    make_git_repo "${WORK}/repo"
    WRAPPER_ENV=("${ROOT_VAR}=${PRESET_ROOT}" "CLAUDE_PROJECT_DIR=${WORK}/repo")
    run_wrapper "${WORK}/repo/src"
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' local "cwd=${PRESET_ROOT}" "root=${PRESET_ROOT}" argc=0)" ]
}

@test "a listed local tool starts in a preset root, which is kept ahead of CLAUDE_PROJECT_DIR" {
    for_each_entry case_local_preset_root
}

case_local_picks_settings() {
    LIST_VERSION=2.0.0-beta.1
    list_local_tool "${TOOL_COMMAND}"
    # An older framework and another runtime's folder lose to the newest framework's any folder...
    make_dependent_package "" net8.0
    local older="${DEPENDENT_DLL}"
    make_dependent_package "" net10.0
    local newest="${DEPENDENT_DLL}"
    write_tool_settings "${PACKAGES}/${PACKAGE_DIR_NAME}/${LIST_VERSION}/tools/net11.0/${OTHER_RID}/DotnetToolSettings.xml" \
        "Name=\"${TOOL_COMMAND}\" EntryPoint=\"Other\" Runner=\"executable\""
    [ "${older}" != "${newest}" ]
    run_wrapper "${WORK}"
    [ "${status}" -eq 0 ]
    [ "${lines[0]}" = dotnet ]
    [ "${lines[4]}" = "${newest}" ]

    # ...and this runtime's own folder wins over any.
    local dir="${PACKAGES}/${PACKAGE_DIR_NAME}/${LIST_VERSION}/tools/net9.0/${HOST_RID}"
    write_tool_settings "${dir}/DotnetToolSettings.xml" \
        "Name=\"${TOOL_COMMAND}\" EntryPoint=\"bin/Server\" Runner=\"executable\""
    mkdir -p "${dir}/bin"
    STUB_BIN="${dir}/bin" make_stub Server "$(server_report local)"
    run_wrapper "${WORK}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' local "cwd=${WORK}" "root=${WORK}" argc=0)" ]
}

@test "the package's settings come from this runtime's folder ahead of any, then the newest framework, at the listed version" {
    for_each_entry case_local_picks_settings
}

case_local_case_and_metadata() {
    # dotnet may report the id in its original case and a version with build metadata; the
    # packages folder holds both in lower case and without the metadata.
    LIST_VERSION=1.0.0-RC.1
    make_dependent_package 1.0.0-rc.1
    set_dotnet_list "$(jq -nc --arg id "${PACKAGE_ID}" --arg command "${TOOL_COMMAND}" \
        '{version: 1, data: [{packageId: $id, version: "1.0.0-RC.1+abc123", commands: [$command]}]}')"
    run_wrapper "${WORK}"
    [ "${status}" -eq 0 ]
    [ "${lines[0]}" = dotnet ]
    [ "${lines[4]}" = "${DEPENDENT_DLL}" ]
}

@test "the listed package id and version are found in lower case and without build metadata" {
    for_each_entry case_local_case_and_metadata
}

case_local_nuget_packages() {
    list_local_tool "${TOOL_COMMAND}"
    local folder="${FIXTURE_ROOT}/${ENTRY}/nuget-cache"
    make_native_package "${folder}"
    WRAPPER_ENV=("NUGET_PACKAGES=${folder}")
    run_wrapper "${WORK}"
    [ "${status}" -eq 0 ]
    [ "${lines[0]}" = local ]
    [ "${lines[1]}" = "cwd=${WORK}" ]

    WRAPPER_ENV=(NUGET_PACKAGES=nuget-cache)
    run_wrapper "${WORK}"
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "${ENTRY}: the NuGet global packages folder 'nuget-cache' from NUGET_PACKAGES is not an absolute path" ]
}

@test "NUGET_PACKAGES names the packages folder when set, and must be absolute" {
    for_each_entry case_local_nuget_packages
}

case_local_restore_then_runs() {
    list_local_tool "${TOOL_COMMAND}"
    make_global_tool
    ln -sf "${REAL_TOOL[mv]}" "${STUB_BIN}/mv"
    # The restore brings the package in: it is staged elsewhere and moved into the folder.
    local staged="${TMP_ROOT}/${ENTRY}/staged"
    make_dependent_package "" "" "${staged}"
    local expected_dll="${DEPENDENT_DLL/#${staged}/${PACKAGES}}"
    mkdir -p "${PACKAGES}"
    printf '%s' "${staged}/${PACKAGE_DIR_NAME}" > "${DOTNET_STUB_STATE}/restore-from"
    printf '%s' "${PACKAGES}/${PACKAGE_DIR_NAME}" > "${DOTNET_STUB_STATE}/restore-to"
    printf '%s' '{"jsonrpc":"2.0","id":1,"method":"initialize"}' > "${TMP_ROOT}/${ENTRY}/mcp-stream"
    run_wrapper "${WORK}" < "${TMP_ROOT}/${ENTRY}/mcp-stream"
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' dotnet "cwd=${WORK}" "root=${WORK}" argc=1 "${expected_dll}")" ]
    # Restored once, from HOME, reading /dev/null, with its stdout moved to stderr.
    [ "$(< "${DOTNET_STUB_STATE}/restore-calls")" = "cwd=${USER_HOME} stdin=" ]
    [ "${stderr}" = "Restore was successful." ]
}

@test "a listed local tool missing from the packages folder is restored once from HOME, off stdout, and then runs" {
    for_each_entry case_local_restore_then_runs
}

case_local_restore_runtime_package() {
    list_local_tool "${TOOL_COMMAND}"
    ln -sf "${REAL_TOOL[mv]}" "${STUB_BIN}/mv"
    # Only the pointer package is there; the restore brings the runtime-specific one.
    local staged="${TMP_ROOT}/${ENTRY}/staged"
    make_native_package "${staged}"
    mkdir -p "${PACKAGES}"
    mv "${staged}/${PACKAGE_DIR_NAME}" "${PACKAGES}/${PACKAGE_DIR_NAME}"
    printf '%s' "${staged}/${PACKAGE_DIR_NAME}.${HOST_RID}" > "${DOTNET_STUB_STATE}/restore-from"
    printf '%s' "${PACKAGES}/${PACKAGE_DIR_NAME}.${HOST_RID}" > "${DOTNET_STUB_STATE}/restore-to"
    run_wrapper "${WORK}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' local "cwd=${WORK}" "root=${WORK}" argc=0)" ]
    [ "$(wc -l < "${DOTNET_STUB_STATE}/restore-calls")" -eq 1 ]
}

@test "a Native AOT tool whose runtime-specific package is missing is restored, and then runs" {
    for_each_entry case_local_restore_runtime_package
}

case_local_still_missing() {
    list_local_tool "${TOOL_COMMAND}"
    # The global tool is there, but the user's listed local tool is never replaced by it.
    make_global_tool
    run_wrapper "${WORK}"
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "$(printf '%s\n' "Restore was successful." \
        "${ENTRY}: the local ${TOOL_COMMAND} (${PACKAGE_DIR_NAME} ${LIST_VERSION}) from the tool manifest in ${USER_HOME} is not in the NuGet global packages folder ${PACKAGES}, even after dotnet tool restore in ${USER_HOME}")" ]
    [ "$(wc -l < "${DOTNET_STUB_STATE}/restore-calls")" -eq 1 ]

    # The same when the pointer package is there but its runtime-specific package is not, or the
    # entry point is gone from a package that is.
    make_native_package
    rm -f "${NATIVE_EXECUTABLE}"
    run_wrapper "${WORK}"
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == *"${ENTRY}: the local ${TOOL_COMMAND} (${PACKAGE_DIR_NAME} ${LIST_VERSION}) from the tool manifest in ${USER_HOME} is not in the NuGet global packages folder ${PACKAGES}, even after dotnet tool restore in ${USER_HOME}" ]]
    rm -rf "${PACKAGES:?}/${PACKAGE_DIR_NAME}.${HOST_RID}"
    run_wrapper "${WORK}"
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == *"is not in the NuGet global packages folder ${PACKAGES}, even after dotnet tool restore in ${USER_HOME}" ]]
}

@test "a listed local tool still missing after the restore fails, and neither server is started" {
    for_each_entry case_local_still_missing
}

case_local_bad_settings() {
    list_local_tool "${TOOL_COMMAND}"
    make_global_tool
    local settings="${PACKAGES}/${PACKAGE_DIR_NAME}/${LIST_VERSION}/tools/net10.0/any/DotnetToolSettings.xml"
    local attributes
    # Another command only, no entry point, an entry point leaving the package, and a runner this
    # launcher does not know.
    for attributes in 'Name="some-other-tool" EntryPoint="Server.dll" Runner="dotnet"' \
        "Name=\"${TOOL_COMMAND}\" Runner=\"dotnet\"" \
        "Name=\"${TOOL_COMMAND}\" EntryPoint=\"../../Server.dll\" Runner=\"dotnet\"" \
        "Name=\"${TOOL_COMMAND}\" EntryPoint=\"/bin/Server\" Runner=\"executable\"" \
        "Name=\"${TOOL_COMMAND}\" EntryPoint=\"Server.dll\" Runner=\"node\""; do
        write_tool_settings "${settings}" "${attributes}"
        : > "${settings%/*}/Server.dll"
        run_wrapper "${WORK}"
        [ "${status}" -eq 1 ]
        [ -z "${output}" ]
        [ "${stderr}" = "${ENTRY}: ${settings} does not name an entry point for ${TOOL_COMMAND} that this launcher can start" ]
    done
    [ ! -e "${DOTNET_STUB_STATE}/restore-calls" ]
}

@test "package settings without a usable entry point for the command fail without a restore" {
    for_each_entry case_local_bad_settings
}

case_local_no_runtime_package() {
    list_local_tool "${TOOL_COMMAND}"
    make_native_package
    local pointer="${PACKAGES}/${PACKAGE_DIR_NAME}/${LIST_VERSION}/tools/any/any/DotnetToolSettings.xml"
    set_dotnet_info " RID:         linux-riscv64"
    run_wrapper "${WORK}"
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "${ENTRY}: ${PACKAGE_DIR_NAME} ${LIST_VERSION} has no package for this machine's runtime linux-riscv64 (${pointer})" ]

    set_dotnet_info "no runtime line"
    run_wrapper "${WORK}"
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "${ENTRY}: cannot tell this machine's runtime from dotnet --info, to pick ${PACKAGE_DIR_NAME}'s package for it" ]
}

@test "a Native AOT tool with no package for this machine's runtime fails with a message" {
    for_each_entry case_local_no_runtime_package
}

case_local_not_executable() {
    list_local_tool "${TOOL_COMMAND}"
    make_native_package
    chmod 0644 "${NATIVE_EXECUTABLE}"
    run_wrapper "${WORK}"
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "${ENTRY}: the local ${TOOL_COMMAND}'s entry point ${NATIVE_EXECUTABLE} is not executable" ]
}

@test "a native entry point that is not executable fails instead of falling back" {
    for_each_entry case_local_not_executable
}

case_local_without_package() {
    make_global_tool
    local content
    for content in '{"data": [{"commands": ["%s"]}]}' '{"data": [{"packageId": "../x", "version": "1.0.0", "commands": ["%s"]}]}' \
        '{"data": [{"packageId": "x", "version": "1.0/../2", "commands": ["%s"]}]}'; do
        # shellcheck disable=SC2059  # the content is the format, with the command put in
        set_dotnet_list "$(printf "${content}" "${TOOL_COMMAND}")"
        run_wrapper "${WORK}"
        [ "${status}" -eq 1 ]
        [ -z "${output}" ]
        [ "${stderr}" = "${ENTRY}: dotnet tool list --local in ${USER_HOME} reports ${TOOL_COMMAND} without a package id and version to find it by" ]
    done
}

@test "a listed tool without a plain package id and version fails instead of falling back" {
    for_each_entry case_local_without_package
}

case_local_dotnet_root() {
    list_local_tool "${TOOL_COMMAND}"
    make_native_package
    # shellcheck disable=SC2016  # expanded by the stub, not here
    local report='printf "%s\n" "${0##*/}" "dotnet_root=${DOTNET_ROOT-unset}"'
    STUB_BIN="${NATIVE_EXECUTABLE%/*}" make_stub Server "${report}"
    run_wrapper "${WORK}"
    [ "${status}" -eq 0 ]
    # The install holding the SDK dotnet --info reports, as dotnet tool run would have used.
    [ "${output}" = "$(printf '%s\n' Server dotnet_root=/opt/dotnet-sdk)" ]

    WRAPPER_ENV=(DOTNET_ROOT=/srv/dotnet)
    run_wrapper "${WORK}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' Server dotnet_root=/srv/dotnet)" ]

    # dotnet runs a framework-dependent dll itself, so DOTNET_ROOT is left alone for it.
    rm -rf "${PACKAGES:?}/${PACKAGE_DIR_NAME}"
    make_dependent_package
    make_dotnet_stub "${report}"
    WRAPPER_ENV=()
    run_wrapper "${WORK}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' dotnet dotnet_root=unset)" ]
}

@test "a native local tool gets DOTNET_ROOT from dotnet --info when the caller set none" {
    for_each_entry case_local_dotnet_root
}

case_local_root_unenterable() {
    list_local_tool "${TOOL_COMMAND}"
    make_native_package
    make_global_tool
    WRAPPER_ENV=("${ROOT_VAR}=${WORK}/missing")
    run_wrapper "${WORK}"
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    # The shell names the failed cd on stderr first.
    [[ "${stderr}" == *"${ENTRY}: cannot change to the repository root ${WORK}/missing to run the local ${TOOL_COMMAND}" ]]
}

@test "a listed local tool fails without falling back to the global tool when the root cannot be entered" {
    for_each_entry case_local_root_unenterable
}

# --- choosing the tool ----------------------------------------------------------------------------

case_global_no_manifest() {
    make_global_tool
    run_wrapper "${WORK}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' global "cwd=${WORK}" "root=${WORK}" argc=0)" ]
    [ -z "${stderr}" ]

    list_local_tool some-other-tool
    run_wrapper "${WORK}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' global "cwd=${WORK}" "root=${WORK}" argc=0)" ]
    [ -z "${stderr}" ]
}

@test "the global tool runs from the root when dotnet tool list finds no manifest or only other tools" {
    for_each_entry case_global_no_manifest
}

case_shebang() {
    # Started by its own #!/bin/sh line, as Claude Code does, rather than by LAUNCHER_SHELL.
    make_global_tool
    cd "${WORK}" || return 1
    run --separate-stderr env -i "PATH=${STUB_BIN}" "HOME=${USER_HOME}" "${GIT_ISOLATION_ENV[@]}" "${WRAPPER}" --flag
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' global "cwd=${WORK}" "root=${WORK}" argc=1 --flag)" ]
    [ -z "${stderr}" ]
}

@test "each entry runs by its own #! line" {
    for_each_entry case_shebang
}

case_list_fails() {
    make_global_tool
    set_dotnet_list '' 1 "Json parsing error in file ${USER_HOME}/dotnet-tools.json"
    run_wrapper "${WORK}"
    [ "${status}" -ne 0 ]
    [ -z "${output}" ]
    [ "${stderr}" = "$(printf '%s\n' "Json parsing error in file ${USER_HOME}/dotnet-tools.json" \
        "${ENTRY}: dotnet tool list --local --format json failed in ${USER_HOME}")" ]
}

@test "a failing dotnet tool list fails, with its message on stderr, instead of falling back" {
    for_each_entry case_list_fails
}

case_list_unreadable() {
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
        [[ "${stderr}" == *"${ENTRY}: cannot read the output of dotnet tool list --local --format json in ${USER_HOME}" ]]
    done
}

@test "dotnet tool list output that is not one object with a data array fails instead of falling back" {
    for_each_entry case_list_unreadable
}

case_commands_not_array() {
    make_global_tool
    local content
    for content in '{"data": [{"commands": "%s"}]}' '{"data": [5, {}, {"commands": ["some-other-tool"]}]}'; do
        # shellcheck disable=SC2059  # the content is the format, with the command put in
        set_dotnet_list "$(printf "${content}" "${TOOL_COMMAND}")"
        run_wrapper "${WORK}"
        [ "${status}" -eq 0 ]
        [ "${lines[0]}" = "global" ]
        [ -z "${stderr}" ]
    done

    make_dependent_package
    set_dotnet_list "$(jq -nc --arg command "${TOOL_COMMAND}" --arg id "${PACKAGE_DIR_NAME}" \
        '{data: [{commands: "x"}, 5, {packageId: $id, version: "1.0.0", commands: [1, $command]}]}')"
    run_wrapper "${WORK}"
    [ "${status}" -eq 0 ]
    [ "${lines[0]}" = "dotnet" ]
    [ -z "${stderr}" ]
}

@test "a listed tool whose commands is not an array never matches, and does not stop the others being read" {
    for_each_entry case_commands_not_array
}

case_probes_never_read_stdin() {
    # git and every dotnet probe read all of their stdin before doing their work, so if the
    # launcher let them inherit it they would take the stream; each server reports what it reads.
    local real_git
    real_git="$(printf '%q' "$(readlink -f "${REAL_TOOL[git]}")")"
    rm -f "${STUB_BIN}/git"
    # shellcheck disable=SC2016  # expanded by the stub, not here
    make_stub_multiline git 'IFS= read -r -d "" _ || true' "exec ${real_git} \"\$@\""
    touch "${DOTNET_STUB_STATE}/read-stdin"
    # shellcheck disable=SC2016  # expanded by the stub, not here
    local report='IFS= read -r -d "" payload || true; printf "%s\n" "${0##*/}" "stdin=${payload}"'
    make_dotnet_stub "${report}"
    make_global_tool "${report}"
    local payload='{"jsonrpc":"2.0","id":1,"method":"initialize"}
{"jsonrpc":"2.0","method":"notifications/initialized"}'
    printf '%s' "${payload}" > "${TMP_ROOT}/${ENTRY}/mcp-stream"

    run_wrapper "${WORK}" < "${TMP_ROOT}/${ENTRY}/mcp-stream"
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' "${TOOL_COMMAND}" "stdin=${payload}")" ]

    # The local tool's list, dotnet --info and restore all run before it starts.
    list_local_tool "${TOOL_COMMAND}"
    make_native_package
    STUB_BIN="${NATIVE_EXECUTABLE%/*}" make_stub Server "${report}"
    rm -rf "${PACKAGES:?}/${PACKAGE_DIR_NAME}.${HOST_RID}" "${GLOBAL_TOOL}"
    run_wrapper "${WORK}" < "${TMP_ROOT}/${ENTRY}/mcp-stream"
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "$(< "${DOTNET_STUB_STATE}/restore-calls")" = "cwd=${USER_HOME} stdin=" ]

    make_native_package
    STUB_BIN="${NATIVE_EXECUTABLE%/*}" make_stub Server "${report}"
    run_wrapper "${WORK}" < "${TMP_ROOT}/${ENTRY}/mcp-stream"
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' Server "stdin=${payload}")" ]

    make_dependent_package 1.0.0 net11.0
    run_wrapper "${WORK}" < "${TMP_ROOT}/${ENTRY}/mcp-stream"
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' dotnet "stdin=${payload}")" ]
}

@test "no probe reads stdin, so whichever server starts gets the whole MCP stream" {
    for_each_entry case_probes_never_read_stdin
}

case_no_dotnet() {
    make_global_tool
    list_local_tool "${TOOL_COMMAND}"
    rm -f "${STUB_BIN}/dotnet"
    run_wrapper "${WORK}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' global "cwd=${WORK}" "root=${WORK}" argc=0)" ]
    [ -z "${stderr}" ]

    rm -f "${GLOBAL_TOOL}"
    run_wrapper "${WORK}"
    [ "${status}" -ne 0 ]
    [ -z "${output}" ]
    [[ "${stderr}" == "${ENTRY}: ${TOOL_COMMAND} not found"* ]]
}

@test "with dotnet missing from PATH the global tool runs, or the launcher fails when there is none" {
    for_each_entry case_no_dotnet
}

case_no_jq() {
    list_local_tool "${TOOL_COMMAND}"
    make_global_tool
    rm -f "${STUB_BIN}/jq"
    run_wrapper "${WORK}"
    [ "${status}" -ne 0 ]
    [ -z "${output}" ]
    [ "${stderr}" = "${ENTRY}: jq is not on PATH to read dotnet tool list's output" ]
}

@test "with jq missing from PATH and dotnet present it fails instead of falling back" {
    for_each_entry case_no_jq
}

case_neither_tool() {
    run_wrapper "${WORK}"
    [ "${status}" -ne 0 ]
    [ -z "${output}" ]
    [ "${stderr}" = "${ENTRY}: ${TOOL_COMMAND} not found: install it as a local tool in ${USER_HOME}'s tool manifest with dotnet tool install --local ${PACKAGE_ID}, run in ${USER_HOME}, or as a global tool with dotnet tool install -g ${PACKAGE_ID}, which puts it in ${USER_HOME}/.dotnet/tools" ]

    make_global_tool
    chmod 0644 "${GLOBAL_TOOL}"
    run_wrapper "${WORK}"
    [ "${status}" -ne 0 ]
    [ -z "${output}" ]
    [[ "${stderr}" == "${ENTRY}: ${TOOL_COMMAND} not found"* ]]
}

@test "with neither tool found, or a global tool that is not executable, it fails with a message on stderr only" {
    for_each_entry case_neither_tool
}

# --- the repository root --------------------------------------------------------------------------

case_preset_root() {
    make_global_tool
    make_git_repo "${WORK}/repo"
    WRAPPER_ENV=("${ROOT_VAR}=${PRESET_ROOT}")
    run_wrapper "${WORK}/repo/src"
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' global "cwd=${PRESET_ROOT}" "root=${PRESET_ROOT}" argc=0)" ]

    WRAPPER_ENV=("${ROOT_VAR}=${PRESET_ROOT}" "CLAUDE_PROJECT_DIR=${WORK}")
    run_wrapper "${WORK}"
    [ "${status}" -eq 0 ]
    [ "${lines[1]}" = "cwd=${PRESET_ROOT}" ]
    [ "${lines[2]}" = "root=${PRESET_ROOT}" ]

    WRAPPER_ENV=("${ROOT_VAR}=")
    run_wrapper "${WORK}"
    [ "${status}" -eq 0 ]
    [ "${lines[2]}" = "root=${WORK}" ]
}

@test "a preset root is kept, ahead of CLAUDE_PROJECT_DIR, and an empty one is resolved like an unset one" {
    for_each_entry case_preset_root
}

case_global_root_unenterable() {
    make_global_tool
    local preset
    for preset in "${TOOL_VAR}=" "${TOOL_VAR}=global"; do
        WRAPPER_ENV=("${preset}" "${ROOT_VAR}=${WORK}/missing")
        run_wrapper "${WORK}"
        [ "${status}" -ne 0 ]
        [ -z "${output}" ]
        # The shell names the failed cd on stderr first.
        [[ "${stderr}" == *"${ENTRY}: cannot change to the repository root ${WORK}/missing to run the global ${TOOL_COMMAND}" ]]
    done
}

@test "a root that cannot be entered fails for the global tool, with a message on stderr and nothing on stdout" {
    for_each_entry case_global_root_unenterable
}

case_root_from_git() {
    make_global_tool
    make_git_repo "${WORK}/repo"
    run_wrapper "${WORK}/repo"
    [ "${status}" -eq 0 ]
    [ "${lines[2]}" = "root=${WORK}/repo" ]

    run_wrapper "${WORK}/repo/src/deep"
    [ "${status}" -eq 0 ]
    # The server starts in the top level, not the subfolder, so a server that walks up from its
    # working directory finds the same repository.
    [ "${lines[1]}" = "cwd=${WORK}/repo" ]
    [ "${lines[2]}" = "root=${WORK}/repo" ]

    mkdir -p "${WORK}/plain/sub"
    run_wrapper "${WORK}/plain/sub"
    [ "${status}" -eq 0 ]
    [ "${lines[1]}" = "cwd=${WORK}/plain/sub" ]
    [ "${lines[2]}" = "root=${WORK}/plain/sub" ]
}

@test "the root is the repository's top level, from its root or a subfolder, or the start directory outside one" {
    for_each_entry case_root_from_git
}

case_claude_project_dir() {
    make_global_tool
    make_git_repo "${WORK}/repo"
    mkdir -p "${WORK}/elsewhere" "${WORK}/plain"
    WRAPPER_ENV=("CLAUDE_PROJECT_DIR=${WORK}/repo/src")
    run_wrapper "${WORK}/elsewhere"
    [ "${status}" -eq 0 ]
    [ "${lines[2]}" = "root=${WORK}/repo" ]

    WRAPPER_ENV=("CLAUDE_PROJECT_DIR=${WORK}/plain")
    run_wrapper "${WORK}/repo"
    [ "${status}" -eq 0 ]
    [ "${lines[2]}" = "root=${WORK}/plain" ]

    # Empty or not a directory, it is ignored for the working directory.
    local value
    for value in "" "${WORK}/missing"; do
        WRAPPER_ENV=("CLAUDE_PROJECT_DIR=${value}")
        run_wrapper "${WORK}/repo/src"
        [ "${status}" -eq 0 ]
        [ "${lines[2]}" = "root=${WORK}/repo" ]
    done
}

@test "CLAUDE_PROJECT_DIR is used ahead of the working directory, at its repository's top level" {
    for_each_entry case_claude_project_dir
}

case_relative_roots() {
    make_global_tool
    local value
    for value in repo ' '; do
        WRAPPER_ENV=("${ROOT_VAR}=${value}")
        run_wrapper "${WORK}"
        [ "${status}" -ne 0 ]
        [ -z "${output}" ]
        [ "${stderr}" = "${ENTRY}: the repository root '${value}' from ${ROOT_VAR} is not an absolute path" ]
    done

    mkdir -p "${WORK}/plain"
    WRAPPER_ENV=(CLAUDE_PROJECT_DIR=plain)
    run_wrapper "${WORK}"
    [ "${status}" -ne 0 ]
    [ -z "${output}" ]
    [ "${stderr}" = "${ENTRY}: the repository root 'plain' from CLAUDE_PROJECT_DIR is not an absolute path" ]

    make_git_repo "${WORK}/repo"
    WRAPPER_ENV=(CLAUDE_PROJECT_DIR=repo/src)
    run_wrapper "${WORK}"
    [ "${status}" -eq 0 ]
    [ "${lines[2]}" = "root=${WORK}/repo" ]
}

@test "a relative or blank preset root, or a relative CLAUDE_PROJECT_DIR outside a repository, fails" {
    for_each_entry case_relative_roots
}

case_start_dir_gone() {
    make_global_tool
    mkdir -p "${WORK}/gone" "${WORK}/project"
    cd "${WORK}/gone" || return 1
    rm -rf "${WORK}/gone"
    run --separate-stderr env -i "PATH=${STUB_BIN}" "HOME=${USER_HOME}" "${GIT_ISOLATION_ENV[@]}" \
        "${LAUNCHER_SHELL}" "${WRAPPER}"
    [ "${status}" -ne 0 ]
    [ -z "${output}" ]
    [[ "${stderr}" == *"${ENTRY}: cannot read the directory Claude Code was started in" ]]

    # It is not needed when CLAUDE_PROJECT_DIR is set.
    run --separate-stderr env -i "PATH=${STUB_BIN}" "HOME=${USER_HOME}" "${GIT_ISOLATION_ENV[@]}" \
        "CLAUDE_PROJECT_DIR=${WORK}/project" "${LAUNCHER_SHELL}" "${WRAPPER}"
    [ "${status}" -eq 0 ]
    [ "${lines[0]}" = "global" ]
    [ "${lines[2]}" = "root=${WORK}/project" ]
}

@test "a start directory that no longer exists fails, unless CLAUDE_PROJECT_DIR is set" {
    for_each_entry case_start_dir_gone
}

case_no_git() {
    make_global_tool
    make_git_repo "${WORK}/repo"
    rm -f "${STUB_BIN}/git"
    run_wrapper "${WORK}/repo/src"
    [ "${status}" -eq 0 ]
    [ "${lines[2]}" = "root=${WORK}/repo/src" ]
    [ -z "${stderr}" ]
}

@test "git missing from PATH falls back to the start directory as the root" {
    for_each_entry case_no_git
}

# --- the environment the server gets --------------------------------------------------------------

# Prints the value variable "$1" reaches each server with, one "<server> <value>" line per run:
# the global tool, the native and the framework-dependent local tool, without and then with the
# caller setting it to "$2".
values_for_every_tool() {
    local name="$1" caller="$2"
    local report="printf \"%s\\n\" \"\${0##*/} \${${name}-unset}\""
    make_dotnet_stub "${report}"
    make_global_tool "${report}"
    local env_case
    for env_case in "" "${name}=${caller}"; do
        WRAPPER_ENV=()
        [ -z "${env_case}" ] || WRAPPER_ENV=("${env_case}")
        set_dotnet_list '{"version":1,"data":[]}'
        run_wrapper "${WORK}"
        printf '%s\n' "${output}"

        list_local_tool "${TOOL_COMMAND}"
        rm -rf "${PACKAGES:?}"
        make_native_package
        STUB_BIN="${NATIVE_EXECUTABLE%/*}" make_stub Server "${report}"
        run_wrapper "${WORK}"
        printf '%s\n' "${output}"

        rm -rf "${PACKAGES:?}"
        make_dependent_package
        run_wrapper "${WORK}"
        printf '%s\n' "${output}"
    done
}

# Checks that variable "$1" reaches every server as "$2", whatever the caller set.
assert_forced_for_every_tool() {
    local values
    values="$(values_for_every_tool "$1" "$3")"
    [ "${values}" = "$(printf '%s\n' "${TOOL_COMMAND} $2" "Server $2" "dotnet $2" "${TOOL_COMMAND} $2" "Server $2" "dotnet $2")" ]
}

case_forced_variables() {
    assert_forced_for_every_tool DOTNET_NOLOGO 1 0
    assert_forced_for_every_tool DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE true false
    if [ "${QUIET_SDK_PREVIEW}" = yes ]; then
        assert_forced_for_every_tool SuppressNETCoreSdkPreviewMessage true false
    else
        # A server that starts no dotnet builds gets the caller's value, or none.
        local values
        values="$(values_for_every_tool SuppressNETCoreSdkPreviewMessage false)"
        [ "${values}" = "$(printf '%s\n' "${TOOL_COMMAND} unset" "Server unset" "dotnet unset" \
            "${TOOL_COMMAND} false" "Server false" "dotnet false")" ]
    fi
}

@test "DOTNET_NOLOGO, the workload notice and, for build-dotnet only, the SDK preview notice are forced for every tool" {
    for_each_entry case_forced_variables
}

case_log_dir_default() {
    [ -n "${LOG_DIR_NAME}" ] || return 0
    local values
    values="$(values_for_every_tool "${LOG_VAR}" /srv/build-logs)"
    local default="${USER_HOME}/.local/state/${LOG_DIR_NAME}"
    [ "${values}" = "$(printf '%s\n' "${TOOL_COMMAND} ${default}" "Server ${default}" "dotnet ${default}" \
        "${TOOL_COMMAND} /srv/build-logs" "Server /srv/build-logs" "dotnet /srv/build-logs")" ]
    # The launcher leaves creating it to the server.
    [ ! -e "${default}" ]

    # An empty value is resolved like an unset one, and an absolute XDG_STATE_HOME is used; a
    # relative one is invalid under the XDG spec, so HOME's default is used.
    local report="printf \"%s\\n\" \"\${${LOG_VAR}-unset}\""
    make_global_tool "${report}"
    set_dotnet_list '{"version":1,"data":[]}'
    WRAPPER_ENV=("${LOG_VAR}=" "XDG_STATE_HOME=${WORK}/state")
    run_wrapper "${WORK}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${WORK}/state/${LOG_DIR_NAME}" ]
    WRAPPER_ENV=(XDG_STATE_HOME=relative/state)
    run_wrapper "${WORK}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${default}" ]

    local value
    for value in logs ' '; do
        WRAPPER_ENV=("${LOG_VAR}=${value}")
        run_wrapper "${WORK}"
        [ "${status}" -ne 0 ]
        [ -z "${output}" ]
        [ "${stderr}" = "${ENTRY}: the log directory '${value}' from ${LOG_VAR} is not an absolute path" ]
    done
}

@test "a server with a log directory gets a per-user default for every tool, a preset one kept, and a relative one refused" {
    for_each_entry case_log_dir_default
}

case_log_dir_untouched() {
    [ -z "${LOG_DIR_NAME}" ] || return 0
    local values
    values="$(values_for_every_tool "${LOG_VAR}" logs)"
    [ "${values}" = "$(printf '%s\n' "${TOOL_COMMAND} unset" "Server unset" "dotnet unset" \
        "${TOOL_COMMAND} logs" "Server logs" "dotnet logs")" ]
}

@test "a server without a log directory gets no log variable from the launcher" {
    for_each_entry case_log_dir_untouched
}

# --- <PREFIX>_TOOL=global, the container -----------------------------------------------------------

case_tool_global() {
    make_global_tool
    make_recording_probes
    # A listed local tool would win without the setting; the stubs would also fail it.
    list_local_tool "${TOOL_COMMAND}"
    WRAPPER_ENV=("${TOOL_VAR}=global" "${ROOT_VAR}=${PRESET_ROOT}")
    run_wrapper "${WORK}" --flag
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' global "cwd=${PRESET_ROOT}" "root=${PRESET_ROOT}" argc=1 --flag)" ]
    [ -z "${stderr}" ]
    [ ! -e "${PROBE_CALLS}" ]

    # Without the setting the same run probes, so the stubs do record a call when there is one.
    WRAPPER_ENV=()
    run_wrapper "${WORK}"
    [ "$(< "${PROBE_CALLS}")" = "$(printf '%s\n' "git -C ${WORK} rev-parse --show-toplevel" 'dotnet tool list --local --format json')" ]
}

@test "<PREFIX>_TOOL=global runs the global tool directly from the preset root, starting neither git nor dotnet" {
    for_each_entry case_tool_global
}

case_tool_global_environment() {
    local preview=unset
    [ "${QUIET_SDK_PREVIEW}" = no ] || preview=true
    # The [ -v ] test tells a variable that is set but empty from one that is not in the environment.
    make_global_tool "printf \"%s\\n\" \"nologo=\${DOTNET_NOLOGO-unset}\" \"workload=\${DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE-unset}\" \"preview=\${SuppressNETCoreSdkPreviewMessage-unset}\"; if [ -v ${LOG_VAR} ]; then printf 'logs=%s\\n' \"\${${LOG_VAR}}\"; else printf '%s\\n' logs=unset; fi"
    make_recording_probes
    local preset
    # Unset, or empty, the server picks its own per-user default under HOME, so the launcher names
    # or creates no state directory, and never passes on an empty value, which the server refuses.
    for preset in "XDG_STATE_HOME=${WORK}/state" "${LOG_VAR}="; do
        WRAPPER_ENV=("${TOOL_VAR}=global" "${ROOT_VAR}=${PRESET_ROOT}" DOTNET_NOLOGO=0 "${preset}")
        run_wrapper "${WORK}"
        [ "${status}" -eq 0 ]
        # A server without a log directory gets the caller's variable as it was.
        local logs=logs=unset
        [ -n "${LOG_DIR_NAME}" ] || [ "${preset}" != "${LOG_VAR}=" ] || logs=logs=
        [ "${output}" = "$(printf '%s\n' nologo=1 workload=true "preview=${preview}" "${logs}")" ]
        [ -z "${stderr}" ]
    done
    [ ! -e "${USER_HOME}/.local/state" ]
    [ ! -e "${WORK}/state" ]

    [ -n "${LOG_DIR_NAME}" ] || return 0
    # A value the caller set is still kept, and still has to be absolute.
    WRAPPER_ENV=("${TOOL_VAR}=global" "${ROOT_VAR}=${PRESET_ROOT}" "${LOG_VAR}=/srv/build-logs")
    run_wrapper "${WORK}"
    [ "${status}" -eq 0 ]
    [ "${lines[3]}" = logs=/srv/build-logs ]

    WRAPPER_ENV=("${TOOL_VAR}=global" "${ROOT_VAR}=${PRESET_ROOT}" "${LOG_VAR}=logs")
    run_wrapper "${WORK}"
    [ "${status}" -ne 0 ]
    [ -z "${output}" ]
    [ "${stderr}" = "${ENTRY}: the log directory 'logs' from ${LOG_VAR} is not an absolute path" ]
    [ ! -e "${PROBE_CALLS}" ]
}

@test "<PREFIX>_TOOL=global still forces the dotnet variables and leaves an unset log directory to the server" {
    for_each_entry case_tool_global_environment
}

case_tool_global_failures() {
    make_global_tool
    make_recording_probes
    WRAPPER_ENV=("${TOOL_VAR}=global")
    run_wrapper "${WORK}"
    [ "${status}" -ne 0 ]
    [ -z "${output}" ]
    [ "${stderr}" = "${ENTRY}: ${TOOL_VAR}=global skips the git probe, so it needs ${ROOT_VAR} set" ]

    rm -f "${GLOBAL_TOOL}"
    WRAPPER_ENV=("${TOOL_VAR}=global" "${ROOT_VAR}=${PRESET_ROOT}")
    run_wrapper "${WORK}"
    [ "${status}" -ne 0 ]
    [ -z "${output}" ]
    [ "${stderr}" = "${ENTRY}: ${TOOL_VAR}=global, but ${GLOBAL_TOOL} is missing or not executable" ]

    local value
    for value in local Global auto ' '; do
        WRAPPER_ENV=("${TOOL_VAR}=${value}" "${ROOT_VAR}=${PRESET_ROOT}")
        run_wrapper "${WORK}"
        [ "${status}" -ne 0 ]
        [ -z "${output}" ]
        [ "${stderr}" = "${ENTRY}: ${TOOL_VAR} is '${value}', but it takes only global, or is left unset to choose the tool" ]
    done
    [ ! -e "${PROBE_CALLS}" ]
}

@test "<PREFIX>_TOOL=global fails without a preset root or the global tool, an unknown value fails, and neither probes" {
    for_each_entry case_tool_global_failures
}

case_tool_empty() {
    list_local_tool "${TOOL_COMMAND}"
    make_native_package
    make_global_tool
    WRAPPER_ENV=("${TOOL_VAR}=")
    run_wrapper "${WORK}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' local "cwd=${WORK}" "root=${WORK}" argc=0)" ]
}

@test "an empty <PREFIX>_TOOL chooses the tool as an unset one does" {
    for_each_entry case_tool_empty
}

# --- DOTNET_CLI_HOME and HOME ---------------------------------------------------------------------

case_dotnet_cli_home() {
    local cli_home="${USER_HOME}/cli-home"
    local home_tool="${GLOBAL_TOOL}"
    GLOBAL_TOOL="${cli_home}/.dotnet/tools/${TOOL_COMMAND}"
    make_global_tool
    WRAPPER_ENV=("DOTNET_CLI_HOME=${cli_home}")
    run_wrapper "${WORK}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' global "cwd=${WORK}" "root=${WORK}" argc=0)" ]
    [ -z "${stderr}" ]

    # The one under HOME is not used in its place.
    rm -f "${GLOBAL_TOOL}"
    GLOBAL_TOOL="${home_tool}"
    make_global_tool
    run_wrapper "${WORK}"
    [ "${status}" -ne 0 ]
    [ -z "${output}" ]
    [[ "${stderr}" == *"which puts it in ${cli_home}/.dotnet/tools" ]]

    # Empty, it finds the tool under HOME as an unset one does.
    WRAPPER_ENV=(DOTNET_CLI_HOME=)
    run_wrapper "${WORK}"
    [ "${status}" -eq 0 ]
    [ "${lines[0]}" = global ]

    # With <PREFIX>_TOOL=global it is ignored, whatever its value, and the tool under HOME runs.
    GLOBAL_TOOL="${cli_home}/.dotnet/tools/${TOOL_COMMAND}"
    make_global_tool 'printf "%s\n" cli-home-tool'
    GLOBAL_TOOL="${home_tool}"
    make_recording_probes
    local value
    for value in "${cli_home}" cli-home ' '; do
        WRAPPER_ENV=("${TOOL_VAR}=global" "${ROOT_VAR}=${PRESET_ROOT}" "DOTNET_CLI_HOME=${value}")
        run_wrapper "${WORK}"
        [ "${status}" -eq 0 ]
        [ "${output}" = "$(printf '%s\n' global "cwd=${PRESET_ROOT}" "root=${PRESET_ROOT}" argc=0)" ]
        [ -z "${stderr}" ]
    done

    # Otherwise one that is not absolute fails before anything runs.
    for value in cli-home ' '; do
        WRAPPER_ENV=("DOTNET_CLI_HOME=${value}")
        run_wrapper "${WORK}"
        [ "${status}" -ne 0 ]
        [ -z "${output}" ]
        [ "${stderr}" = "${ENTRY}: the dotnet CLI home '${value}' from DOTNET_CLI_HOME is not an absolute path" ]
    done
    [ ! -e "${PROBE_CALLS}" ]
}

@test "the global tool is found under DOTNET_CLI_HOME when it is set and absolute, except with <PREFIX>_TOOL=global" {
    for_each_entry case_dotnet_cli_home
}

case_home_invalid() {
    make_global_tool
    cd "${WORK}" || return 1
    local home
    for home in unset ''; do
        if [ "${home}" = unset ]; then
            run --separate-stderr env -i "PATH=${STUB_BIN}" "${GIT_ISOLATION_ENV[@]}" "${LAUNCHER_SHELL}" "${WRAPPER}"
        else
            run --separate-stderr env -i "PATH=${STUB_BIN}" HOME= "${GIT_ISOLATION_ENV[@]}" "${LAUNCHER_SHELL}" "${WRAPPER}"
        fi
        [ "${status}" -ne 0 ]
        [ -z "${output}" ]
        [ "${stderr}" = "${ENTRY}: HOME is not set" ]
    done

    make_recording_probes
    # A global tool where the relative HOME resolves from the start directory, which the launcher's
    # global tool check would find although HOME names no directory the launcher ever checked.
    mkdir -p "${WORK}/relative-home/.dotnet/tools"
    STUB_BIN="${WORK}/relative-home/.dotnet/tools" make_stub "${TOOL_COMMAND}" 'printf "%s\n" global'
    local preset
    for preset in "${TOOL_VAR}=" "${TOOL_VAR}=global"; do
        # CDPATH is set because a relative cd consults it and prints the directory it found to
        # stdout, the MCP stream.
        run --separate-stderr env -i "PATH=${STUB_BIN}" HOME=relative-home "CDPATH=${WORK}" \
            "${ROOT_VAR}=${PRESET_ROOT}" "${preset}" "${GIT_ISOLATION_ENV[@]}" "${LAUNCHER_SHELL}" "${WRAPPER}"
        [ "${status}" -ne 0 ]
        [ -z "${output}" ]
        [ "${stderr}" = "${ENTRY}: the home directory 'relative-home' from HOME is not an absolute path" ]
    done
    [ ! -e "${PROBE_CALLS}" ]
}

@test "an unset, empty or relative HOME fails before anything runs, on a host and with <PREFIX>_TOOL=global" {
    for_each_entry case_home_invalid
}

# --- the entries and the shared launcher ----------------------------------------------------------

case_entry_without_path() {
    make_global_tool
    cd "${MCP_DIR}" || return 1
    run --separate-stderr env -i "PATH=${STUB_BIN}" "HOME=${USER_HOME}" "${LAUNCHER_SHELL}" "${ENTRY}"
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "${ENTRY}: started without a path, so the shared launcher beside it cannot be found" ]

    # A copy with no shared launcher beside it says so, rather than failing in the shell.
    mkdir -p "${WORK}/lonely"
    cp "${WRAPPER}" "${WORK}/lonely/${ENTRY}"
    WRAPPER="${WORK}/lonely/${ENTRY}"
    run_wrapper "${WORK}"
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "${ENTRY}: the shared launcher ${WORK}/lonely/dotnet-tool-mcp-launcher is missing" ]
}

@test "an entry needs its own directory, to find the shared launcher beside it" {
    for_each_entry case_entry_without_path
}

@test "the shared launcher run on its own stops with a message, and starts nothing" {
    use_entry changelog-mcp
    make_global_tool
    make_recording_probes
    WRAPPER="${MCP_DIR}/dotnet-tool-mcp-launcher"
    run_wrapper "${WORK}"
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "dotnet-tool-mcp-launcher: run one of the MCP server launchers that source this file, such as changelog-mcp, not this file itself" ]
    [ ! -e "${PROBE_CALLS}" ]
}

@test "the entries differ only in the values they hand the shared launcher" {
    # Every line of an entry but its comments and the values block is the same in all of them.
    local entry first=""
    for entry in "${ENTRIES[@]}"; do
        local body
        body="$(sed -e '/^#/d' -e '/^    mcp_[a-z_]*=/d' "${MCP_DIR}/${entry}")"
        [ -n "${first}" ] || first="${body}"
        [ "${body}" = "${first}" ]
        [ -x "${MCP_DIR}/${entry}" ]
    done
    [ -x "${MCP_DIR}/dotnet-tool-mcp-launcher" ]
}
