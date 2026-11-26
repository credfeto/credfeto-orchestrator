#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are read by the sourced oneshot functions, where shellcheck cannot trace them
# shellcheck disable=SC2016  # stand-in binary bodies are expanded when they run, not here

# ORCHESTRATOR_DOTNET_SELF_INSTALL (#252 phase 10): lib/self-install against a fake local NuGet feed (file:// URLs,
# no network). Each test builds the feed it needs: the flat container's version index, real small zip packages
# (made with python3's zipfile) holding a stand-in binary, the registration leaf and the catalog entry with the
# package's SHA-512. The stand-in prints the version baked into it for --version and passes --self-test, unless
# the test asks it to misbehave.

bats_require_minimum_version 1.5.0

load test_helper
load oneshot_helper

SELF_INSTALL_ID="credfeto.orchestrator.cmd.linux-x64"

# Points lib/self-install at a fresh feed and installs into the repo tree (the test temp dir may be noexec)
_self_install_setup() {
    FEED="${TEST_TMP}/feed"
    mkdir -p "${FEED}/flat/${SELF_INSTALL_ID}" "${FEED}/registration/${SELF_INSTALL_ID}" "${FEED}/catalog"
    ORCHESTRATOR_DOTNET_SELF_INSTALL=1
    ORCHESTRATOR_CMD_FEED_URL="file://${FEED}/flat/"
    ORCHESTRATOR_CMD_REGISTRATION_URL="file://${FEED}/registration"
    ORCHESTRATOR_CMD_CHANNEL=prerelease
    ORCHESTRATOR_CMD_VERSION=""
    ORCHESTRATOR_CMD_VERSION_CACHE_MINUTES=60
    ORCHESTRATOR_CMD_FROM_ENVIRONMENT=0
    ORCHESTRATOR_CMD=credfeto-orchestrator
    INSTALL_DIR="${STUB_BIN}/install"
    ORCHESTRATOR_CMD_INSTALL_DIR="${INSTALL_DIR}"
}

# Writes the flat container's version index listing the arguments
_feed_versions() {
    jq -n '{versions: $ARGS.positional}' --args "$@" > "${FEED}/flat/${SELF_INSTALL_ID}/index.json"
}

# Writes a stand-in binary for the version to the file in $2. Kinds: good; wrong-version (prints 9.9.9);
# version-fails (--version exits 3); self-test-fails (--self-test exits 1 with a message); metadata (prints the
# version upper-cased with +build metadata)
_stand_in_binary() {
    local version="$1" file="$2" kind="${3:-good}" printed="$1" version_status=0 self_test_status=0
    case "${kind}" in
        wrong-version) printed="9.9.9" ;;
        version-fails) version_status=3 ;;
        self-test-fails) self_test_status=1 ;;
        metadata) printed="${version^^}+0123abc" ;;
    esac
    {
        printf '#!/usr/bin/env bash\n'
        printf 'case "$1" in\n'
        printf '    --version) printf "%%s\\n" "%s"; exit %d ;;\n' "${printed}" "${version_status}"
        printf '    --self-test) [ %d -eq 0 ] || { echo "self-test: json failed: expected a, got b" >&2; exit 1; }; echo "self-test: passed" ;;\n' "${self_test_status}"
        printf '    *) printf "%%s\\n" "$*" >> "%s/ran" ;;\n' "${TEST_TMP}"
        printf 'esac\n'
    } > "${file}"
}

# Zips name=path pairs into the file in $1
_make_zip() {
    python3 -c '
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED) as package:
    for spec in sys.argv[2:]:
        name, path = spec.split("=", 1)
        package.write(path, name)
' "$@"
}

# Publishes a package version: the .nupkg, its registration leaf and its catalog entry (with the real hash, unless
# a hash/algorithm is given). Kinds as _stand_in_binary, plus no-binary and two-binaries.
_feed_package() {
    local version="$1" kind="${2:-good}" hash="${3:-}" algorithm="${4:-SHA512}"
    local dir="${FEED}/flat/${SELF_INSTALL_ID}/${version}" work="${TEST_TMP}/pack-${version}"
    local package="${dir}/${SELF_INSTALL_ID}.${version}.nupkg"
    mkdir -p "${dir}" "${work}"
    _stand_in_binary "${version}" "${work}/binary" "${kind}"
    printf '<DotNetCliTool Version="2" />\n' > "${work}/settings.xml"
    printf '<package />\n' > "${work}/nuspec"
    case "${kind}" in
        no-binary)
            _make_zip "${package}" "${SELF_INSTALL_ID}.nuspec=${work}/nuspec" \
                "tools/any/linux-x64/DotnetToolSettings.xml=${work}/settings.xml" \
                "tools/any/linux-arm64/Credfeto.Orchestrator.Cmd=${work}/binary"
            ;;
        two-binaries)
            _make_zip "${package}" "${SELF_INSTALL_ID}.nuspec=${work}/nuspec" \
                "tools/any/linux-x64/Credfeto.Orchestrator.Cmd=${work}/binary" \
                "tools/net11.0/linux-x64/Credfeto.Orchestrator.Cmd=${work}/binary"
            ;;
        *)
            _make_zip "${package}" "${SELF_INSTALL_ID}.nuspec=${work}/nuspec" \
                "tools/any/linux-x64/DotnetToolSettings.xml=${work}/settings.xml" \
                "tools/any/linux-x64/Credfeto.Orchestrator.Cmd=${work}/binary"
            ;;
    esac
    if [ -z "${hash}" ]; then
        hash=$(python3 -c 'import base64, hashlib, sys; print(base64.b64encode(hashlib.sha512(open(sys.argv[1], "rb").read()).digest()).decode())' "${package}")
    fi
    jq -n --arg catalog "file://${FEED}/catalog/${version}.json" '{catalogEntry: $catalog, listed: true}' \
        > "${FEED}/registration/${SELF_INSTALL_ID}/${version}.json"
    jq -n --arg hash "${hash}" --arg algorithm "${algorithm}" '{packageHash: $hash, packageHashAlgorithm: $algorithm}' \
        > "${FEED}/catalog/${version}.json"
}

# Republishes the catalog hash of the .nupkg already in the feed
_feed_package_hash_only() {
    local package="${FEED}/flat/${SELF_INSTALL_ID}/$1/${SELF_INSTALL_ID}.$1.nupkg" hash
    hash=$(python3 -c 'import base64, hashlib, sys; print(base64.b64encode(hashlib.sha512(open(sys.argv[1], "rb").read()).digest()).decode())' "${package}")
    jq -n --arg hash "${hash}" '{packageHash: $hash, packageHashAlgorithm: "SHA512"}' > "${FEED}/catalog/$1.json"
}

# Runs the install and prints what ORCHESTRATOR_CMD then is
_install() {
    self_install_orchestrator_cmd
    local status=$?
    printf 'CMD=%s\n' "${ORCHESTRATOR_CMD}"
    return "${status}"
}

# Asserts the version current names
_assert_current() {
    [ "$(readlink "${INSTALL_DIR}/current")" = "$1" ]
    [ -x "${INSTALL_DIR}/$1/Credfeto.Orchestrator.Cmd" ]
}

# Installs 1.0.0.1-main as the last good version, for the failure tests
_install_good_first() {
    _feed_versions 1.0.0.1-main
    _feed_package 1.0.0.1-main
    run --separate-stderr _install
    [ "${status}" -eq 0 ]
    _assert_current 1.0.0.1-main
    # The next run must read the index again
    rm -f "${INSTALL_DIR}/resolved-version"
}

# A failure keeps 1.0.0.1-main, warns once and still returns 0 with ORCHESTRATOR_CMD on the kept binary
_assert_kept_with_warning() {
    [ "${status}" -eq 0 ]
    [ "${output}" = "CMD=${INSTALL_DIR}/current/Credfeto.Orchestrator.Cmd" ]
    [ "$(grep -c '^! Self-install: ' <<< "${stderr}")" -eq 1 ]
    [[ "${stderr}" == *"$1"* ]]
    [[ "${stderr}" == *"keeping the installed tool"* ]]
    _assert_current 1.0.0.1-main
    [ ! -e "${INSTALL_DIR}/previous" ]
    [ -z "$(find "${INSTALL_DIR}" -maxdepth 1 -name '.download.*')" ]
}

@test "ORCHESTRATOR_DOTNET_SELF_INSTALL is off by default, and the feed defaults are nuget.org's (#252)" {
    run env -u ORCHESTRATOR_DOTNET_SELF_INSTALL -u ORCHESTRATOR_CMD_FEED_URL -u ORCHESTRATOR_CMD_REGISTRATION_URL \
        -u ORCHESTRATOR_CMD_CHANNEL -u ORCHESTRATOR_CMD_VERSION -u ORCHESTRATOR_CMD_VERSION_CACHE_MINUTES bash -c \
        'source "'"${REPO_ROOT}"'/oneshot"; printf "%s|" "${ORCHESTRATOR_DOTNET_SELF_INSTALL}" "${ORCHESTRATOR_CMD_FEED_URL}" "${ORCHESTRATOR_CMD_REGISTRATION_URL}" "${ORCHESTRATOR_CMD_CHANNEL}" "${ORCHESTRATOR_CMD_VERSION}" "${ORCHESTRATOR_CMD_VERSION_CACHE_MINUTES}" "${ORCHESTRATOR_CMD_INSTALL_DIR}"'
    [ "${status}" -eq 0 ]
    [ "${output}" = "0|https://api.nuget.org/v3-flatcontainer|https://api.nuget.org/v3/registration5-semver1|prerelease||60|${XDG_STATE_HOME}/orchestrator/bin|" ]
}

@test "ORCHESTRATOR_CMD stays credfeto-orchestrator when no binary is installed (#252)" {
    mkdir -p "${XDG_STATE_HOME}/orchestrator/bin/1.0.0.1-main"
    printf '#!/bin/sh\n' > "${XDG_STATE_HOME}/orchestrator/bin/1.0.0.1-main/Credfeto.Orchestrator.Cmd"
    # Not executable, and no current link: neither counts
    ln -s missing "${XDG_STATE_HOME}/orchestrator/bin/current"
    run env -u ORCHESTRATOR_CMD bash -c 'source "'"${REPO_ROOT}"'/oneshot"; printf "%s|%s" "${ORCHESTRATOR_CMD}" "${ORCHESTRATOR_CMD_FROM_ENVIRONMENT}"'
    [ "${status}" -eq 0 ]
    [ "${output}" = "credfeto-orchestrator|0" ]
    rm "${XDG_STATE_HOME}/orchestrator/bin/current"
    ln -s 1.0.0.1-main "${XDG_STATE_HOME}/orchestrator/bin/current"
    run env -u ORCHESTRATOR_CMD bash -c 'source "'"${REPO_ROOT}"'/oneshot"; printf "%s" "${ORCHESTRATOR_CMD}"'
    [ "${output}" = "credfeto-orchestrator" ]
}

@test "ORCHESTRATOR_CMD is the installed current binary unless the environment sets it (#252)" {
    mkdir -p "${XDG_STATE_HOME}/orchestrator/bin/1.0.0.1-main"
    printf '#!/bin/sh\n' > "${XDG_STATE_HOME}/orchestrator/bin/1.0.0.1-main/Credfeto.Orchestrator.Cmd"
    chmod +x "${XDG_STATE_HOME}/orchestrator/bin/1.0.0.1-main/Credfeto.Orchestrator.Cmd"
    ln -s 1.0.0.1-main "${XDG_STATE_HOME}/orchestrator/bin/current"
    run env -u ORCHESTRATOR_CMD bash -c 'source "'"${REPO_ROOT}"'/oneshot"; printf "%s|%s" "${ORCHESTRATOR_CMD}" "${ORCHESTRATOR_CMD_FROM_ENVIRONMENT}"'
    [ "${status}" -eq 0 ]
    [ "${output}" = "${XDG_STATE_HOME}/orchestrator/bin/current/Credfeto.Orchestrator.Cmd|0" ]
    run env ORCHESTRATOR_CMD=/opt/tool bash -c 'source "'"${REPO_ROOT}"'/oneshot"; printf "%s|%s" "${ORCHESTRATOR_CMD}" "${ORCHESTRATOR_CMD_FROM_ENVIRONMENT}"'
    [ "${output}" = "/opt/tool|1" ]
}

@test "self_install_orchestrator_cmd reads and writes nothing while ORCHESTRATOR_DOTNET_SELF_INSTALL is off (#252)" {
    _self_install_setup
    make_stub curl 'printf "%s\n" "$*" >> "${TEST_TMP}/curl_args"; exit 7'
    local value
    for value in 0 "" true 01 yes; do
        ORCHESTRATOR_DOTNET_SELF_INSTALL="${value}"
        run --separate-stderr _install
        [ "${status}" -eq 0 ]
        [ "${output}" = "CMD=credfeto-orchestrator" ]
        [ -z "${stderr}" ]
    done
    [ ! -e "${TEST_TMP}/curl_args" ]
    [ ! -e "${INSTALL_DIR}" ]
}

@test "main runs the self-install after the stale-checkout check and before anything else runs the tool (#252)" {
    local body
    body=$(declare -f main)
    [[ "${body}" == *"self_install_orchestrator_cmd"* ]]
    local before="${body%%self_install_orchestrator_cmd*}"
    [[ "${before}" == *"notify_discord_self_update_stale"* ]]
    [[ "${before}" != *"validate_config"* ]]
    [[ "${before}" != *"preload_ssh_keys"* ]]
    [[ "${before}" != *"fetch_all_priorities"* ]]
}

@test "the prerelease channel installs the newest -main version, never a branch or pull request build (#252)" {
    _self_install_setup
    _feed_versions 0.0.9.3641-pull-2085-merge 0.0.9.99-main 0.0.10.1-main 0.0.10.2-dotnet-orchestr \
        0.0.10.3-pull-12-merge 0.0.10.4 0.0.10.5-mainline 0.0.10.6-main-x 0.0.9.3642-main
    _feed_package 0.0.10.1-main
    run --separate-stderr _install
    [ "${status}" -eq 0 ]
    [ "${lines[-1]}" = "CMD=${INSTALL_DIR}/current/Credfeto.Orchestrator.Cmd" ]
    [[ "${output}" == *"Self-install: Credfeto.Orchestrator.Cmd 0.0.10.1-main installed"* ]]
    [ -z "${stderr}" ]
    _assert_current 0.0.10.1-main
    [ ! -e "${INSTALL_DIR}/previous" ]
    [ "$(cat "${INSTALL_DIR}/resolved-version")" = "prerelease 0.0.10.1-main" ]
    [ ! -e "${INSTALL_DIR}/failed-version" ]
    # Only the binary is unpacked
    [ "$(ls -A "${INSTALL_DIR}/0.0.10.1-main")" = "Credfeto.Orchestrator.Cmd" ]
    [ "$("${INSTALL_DIR}/current/Credfeto.Orchestrator.Cmd" --version)" = "0.0.10.1-main" ]
}

@test "a feed listing no -main version, only branch builds, installs nothing (#252)" {
    _self_install_setup
    _feed_versions 0.0.9.3640-dotnet-orchestr 0.0.9.3641-pull-2085-merge 0.0.9.3643-run-log-grep 1.0.0
    run --separate-stderr _install
    [ "${status}" -eq 0 ]
    [ "${output}" = "CMD=credfeto-orchestrator" ]
    [[ "${stderr}" == *"the feed lists no prerelease version of ${SELF_INSTALL_ID}"* ]]
    [ ! -e "${INSTALL_DIR}/current" ]
    [ ! -e "${INSTALL_DIR}/resolved-version" ]
    _feed_versions
    run --separate-stderr _install
    [[ "${stderr}" == *"the feed lists no prerelease version"* ]]
    printf 'not json' > "${FEED}/flat/${SELF_INSTALL_ID}/index.json"
    run --separate-stderr _install
    [ "${status}" -eq 0 ]
    [[ "${stderr}" == *"the feed lists no prerelease version"* ]]
}

@test "the stable channel installs the newest version with no pre-release tag (#252)" {
    _self_install_setup
    ORCHESTRATOR_CMD_CHANNEL=stable
    _feed_versions 1.0.9 1.0.10 1.0.11-main 2.0.0-beta 1.0.10.1
    _feed_package 1.0.10.1
    run --separate-stderr _install
    [ "${status}" -eq 0 ]
    _assert_current 1.0.10.1
    [ "$(cat "${INSTALL_DIR}/resolved-version")" = "stable 1.0.10.1" ]
}

@test "an unknown channel warns and installs nothing (#252)" {
    _self_install_setup
    ORCHESTRATOR_CMD_CHANNEL=nightly
    _feed_versions 1.0.0.1-main
    _feed_package 1.0.0.1-main
    run --separate-stderr _install
    [ "${status}" -eq 0 ]
    [ "${output}" = "CMD=credfeto-orchestrator" ]
    [[ "${stderr}" == *"unknown ORCHESTRATOR_CMD_CHANNEL 'nightly'"* ]]
    [ ! -e "${INSTALL_DIR}/current" ]
}

@test "ORCHESTRATOR_CMD_VERSION pins the version without reading the version index (#252)" {
    _self_install_setup
    ORCHESTRATOR_CMD_VERSION=0.0.9.3640-Dotnet-Orchestr
    _feed_package 0.0.9.3640-dotnet-orchestr
    run --separate-stderr _install
    [ "${status}" -eq 0 ]
    _assert_current 0.0.9.3640-dotnet-orchestr
    [ ! -e "${INSTALL_DIR}/resolved-version" ]
    ORCHESTRATOR_CMD_VERSION="../1.0"
    run --separate-stderr _install
    [ "${status}" -eq 0 ]
    [[ "${stderr}" == *"ORCHESTRATOR_CMD_VERSION '../1.0' is not a package version"* ]]
    _assert_current 0.0.9.3640-dotnet-orchestr
}

@test "an installed current version is not downloaded again, and the resolved version is cached (#252)" {
    _self_install_setup
    _feed_versions 1.0.0.1-main
    _feed_package 1.0.0.1-main
    run --separate-stderr _install
    _assert_current 1.0.0.1-main
    rm "${FEED}/flat/${SELF_INSTALL_ID}/1.0.0.1-main/${SELF_INSTALL_ID}.1.0.0.1-main.nupkg"
    run --separate-stderr _install
    [ "${status}" -eq 0 ]
    [ "${output}" = "CMD=${INSTALL_DIR}/current/Credfeto.Orchestrator.Cmd" ]
    [ -z "${stderr}" ]
    # A newer version is not seen while the cache is fresh
    _feed_versions 1.0.0.1-main 1.0.0.2-main
    _feed_package 1.0.0.2-main
    run --separate-stderr _install
    [ -z "${stderr}" ]
    _assert_current 1.0.0.1-main
    # ... and is installed once it has expired, keeping the old one as previous
    touch -t 202001010000 "${INSTALL_DIR}/resolved-version"
    run --separate-stderr _install
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"1.0.0.2-main installed (was 1.0.0.1-main)"* ]]
    _assert_current 1.0.0.2-main
    [ "$(readlink "${INSTALL_DIR}/previous")" = "1.0.0.1-main" ]
    [ -x "${INSTALL_DIR}/1.0.0.1-main/Credfeto.Orchestrator.Cmd" ]
    # A cache for another channel is not used
    printf 'stable 1.0.0.1-main\n' > "${INSTALL_DIR}/resolved-version"
    run --separate-stderr _install
    [ -z "${stderr}" ]
    [ "$(cat "${INSTALL_DIR}/resolved-version")" = "prerelease 1.0.0.2-main" ]
}

@test "each new version keeps the one it replaced and prunes the older ones (#252)" {
    _self_install_setup
    local version
    for version in 1.0.0.1-main 1.0.0.2-main 1.0.0.3-main; do
        _feed_versions "${version}"
        _feed_package "${version}"
        rm -f "${INSTALL_DIR}/resolved-version"
        run --separate-stderr _install
        [ "${status}" -eq 0 ]
        _assert_current "${version}"
    done
    [ "$(readlink "${INSTALL_DIR}/previous")" = "1.0.0.2-main" ]
    [ ! -e "${INSTALL_DIR}/1.0.0.1-main" ]
    [ -x "${INSTALL_DIR}/1.0.0.2-main/Credfeto.Orchestrator.Cmd" ]
    # Pinning the previous version back rolls back to it
    ORCHESTRATOR_CMD_VERSION=1.0.0.2-main
    run --separate-stderr _install
    [ "${status}" -eq 0 ]
    _assert_current 1.0.0.2-main
    [ "$(readlink "${INSTALL_DIR}/previous")" = "1.0.0.3-main" ]
}

@test "a package that does not match the published SHA-512 is not installed (#252)" {
    _self_install_setup
    _install_good_first
    _feed_versions 1.0.0.1-main 1.0.0.2-main
    _feed_package 1.0.0.2-main good "$(printf 'x%.0s' {1..86})=="
    run --separate-stderr _install
    _assert_kept_with_warning "1.0.0.2-main does not match the SHA-512 the feed publishes"
    [ ! -e "${INSTALL_DIR}/1.0.0.2-main" ]
    [ "$(cat "${INSTALL_DIR}/failed-version")" = "1.0.0.2-main" ]
    # It is not downloaded again until the cache period has passed
    rm "${FEED}/flat/${SELF_INSTALL_ID}/1.0.0.2-main/${SELF_INSTALL_ID}.1.0.0.2-main.nupkg"
    run --separate-stderr _install
    _assert_kept_with_warning "1.0.0.2-main failed to install less than 60 minutes ago"
    # ... and after it, a fixed package installs
    _feed_package 1.0.0.2-main
    touch -t 202001010000 "${INSTALL_DIR}/failed-version"
    run --separate-stderr _install
    [ "${status}" -eq 0 ]
    _assert_current 1.0.0.2-main
    [ ! -e "${INSTALL_DIR}/failed-version" ]
}

@test "a missing, malformed or non-SHA512 published hash fails the install (#252)" {
    _self_install_setup
    _install_good_first
    _feed_versions 1.0.0.1-main 1.0.0.2-main
    local hash
    for hash in "short==" "$(printf 'x%.0s' {1..88})"; do
        rm -f "${INSTALL_DIR}/failed-version"
        _feed_package 1.0.0.2-main good "${hash}"
        run --separate-stderr _install
        _assert_kept_with_warning "the feed publishes no SHA-512 hash for ${SELF_INSTALL_ID} 1.0.0.2-main"
    done
    rm -f "${INSTALL_DIR}/failed-version"
    _feed_package 1.0.0.2-main good "" SHA256
    run --separate-stderr _install
    _assert_kept_with_warning "the feed publishes no SHA-512 hash"
    rm -f "${INSTALL_DIR}/failed-version"
    printf '{}' > "${FEED}/catalog/1.0.0.2-main.json"
    run --separate-stderr _install
    _assert_kept_with_warning "the feed publishes no SHA-512 hash"
    rm -f "${INSTALL_DIR}/failed-version" "${FEED}/catalog/1.0.0.2-main.json"
    run --separate-stderr _install
    _assert_kept_with_warning "could not read the published hash of ${SELF_INSTALL_ID} 1.0.0.2-main"
    rm -f "${INSTALL_DIR}/failed-version"
    printf '{"listed":true}' > "${FEED}/registration/${SELF_INSTALL_ID}/1.0.0.2-main.json"
    run --separate-stderr _install
    _assert_kept_with_warning "could not read the published hash"
}

@test "a package without exactly one linux-x64 binary is not installed (#252)" {
    _self_install_setup
    _install_good_first
    _feed_versions 1.0.0.1-main 1.0.0.2-main
    _feed_package 1.0.0.2-main no-binary
    run --separate-stderr _install
    _assert_kept_with_warning "the package holds 0 linux-x64 Credfeto.Orchestrator.Cmd binaries, not one"
    rm -f "${INSTALL_DIR}/failed-version"
    _feed_package 1.0.0.2-main two-binaries
    run --separate-stderr _install
    _assert_kept_with_warning "the package holds 2 linux-x64 Credfeto.Orchestrator.Cmd binaries, not one"
    rm -f "${INSTALL_DIR}/failed-version"
    printf 'not a zip' > "${FEED}/flat/${SELF_INSTALL_ID}/1.0.0.2-main/${SELF_INSTALL_ID}.1.0.0.2-main.nupkg"
    _feed_package_hash_only 1.0.0.2-main
    run --separate-stderr _install
    _assert_kept_with_warning "the package holds 0 linux-x64"
}

@test "a binary whose --version is wrong or fails is not installed (#252)" {
    _self_install_setup
    _install_good_first
    _feed_versions 1.0.0.1-main 1.0.0.2-main
    _feed_package 1.0.0.2-main wrong-version
    run --separate-stderr _install
    _assert_kept_with_warning "Credfeto.Orchestrator.Cmd 1.0.0.2-main --version printed '9.9.9', not 1.0.0.2-main"
    [ ! -e "${INSTALL_DIR}/1.0.0.2-main" ]
    rm -f "${INSTALL_DIR}/failed-version"
    _feed_package 1.0.0.2-main version-fails
    run --separate-stderr _install
    _assert_kept_with_warning "Credfeto.Orchestrator.Cmd 1.0.0.2-main --version failed (exit 3)"
}

@test "--version may add +build metadata and differ in case (#252)" {
    _self_install_setup
    _feed_versions 1.0.0.1-main
    _feed_package 1.0.0.1-main metadata
    run --separate-stderr _install
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    _assert_current 1.0.0.1-main
}

@test "a binary whose --self-test fails is not installed (#252)" {
    _self_install_setup
    _install_good_first
    _feed_versions 1.0.0.1-main 1.0.0.2-main
    _feed_package 1.0.0.2-main self-test-fails
    run --separate-stderr _install
    _assert_kept_with_warning "Credfeto.Orchestrator.Cmd 1.0.0.2-main --self-test failed (exit 1): self-test: json failed: expected a, got b"
    [ ! -e "${INSTALL_DIR}/1.0.0.2-main" ]
}

@test "a feed that is down keeps the installed tool (#252)" {
    _self_install_setup
    _install_good_first
    rm "${FEED}/flat/${SELF_INSTALL_ID}/index.json"
    run --separate-stderr _install
    _assert_kept_with_warning "could not read the version index from file://${FEED}/flat/"
    [ ! -e "${INSTALL_DIR}/failed-version" ]
    _feed_versions 1.0.0.1-main 1.0.0.2-main
    _feed_package 1.0.0.2-main
    rm "${FEED}/flat/${SELF_INSTALL_ID}/1.0.0.2-main/${SELF_INSTALL_ID}.1.0.0.2-main.nupkg"
    run --separate-stderr _install
    _assert_kept_with_warning "could not download ${SELF_INSTALL_ID} 1.0.0.2-main"
}

@test "a feed that is down with nothing installed leaves ORCHESTRATOR_CMD as it was (#252)" {
    _self_install_setup
    run --separate-stderr _install
    [ "${status}" -eq 0 ]
    [ "${output}" = "CMD=credfeto-orchestrator" ]
    [[ "${stderr}" == *"could not read the version index"* ]]
    ORCHESTRATOR_CMD_FROM_ENVIRONMENT=1
    ORCHESTRATOR_CMD=/opt/tool
    _feed_versions 1.0.0.1-main
    _feed_package 1.0.0.1-main
    run --separate-stderr _install
    # Installed, but the environment's ORCHESTRATOR_CMD wins
    [ "${lines[-1]}" = "CMD=/opt/tool" ]
    _assert_current 1.0.0.1-main
}

@test "the package unpacks with unzip and with bsdtar, and neither installed warns (#252)" {
    _self_install_setup
    _feed_versions 1.0.0.1-main
    _feed_package 1.0.0.1-main
    local tool tried=0
    for tool in unzip bsdtar; do
        command -v "${tool}" > /dev/null 2>&1 || continue
        tried=$((tried + 1))
        eval "_self_install_zip_tool() { printf '%s' ${tool}; }"
        rm -rf "${INSTALL_DIR}"
        run --separate-stderr _install
        [ "${status}" -eq 0 ]
        [ -z "${stderr}" ]
        _assert_current 1.0.0.1-main
        cmp "${INSTALL_DIR}/current/Credfeto.Orchestrator.Cmd" "${TEST_TMP}/pack-1.0.0.1-main/binary"
    done
    [ "${tried}" -ge 1 ]
    _self_install_zip_tool() { return 1; }
    rm -rf "${INSTALL_DIR}"
    run --separate-stderr _install
    [ "${status}" -eq 0 ]
    [ "${output}" = "CMD=credfeto-orchestrator" ]
    [[ "${stderr}" == *"neither unzip nor bsdtar is installed"* ]]
    [ ! -e "${INSTALL_DIR}/current" ]
}

@test "a run that finds the install lock held leaves the install to the other run (#252)" {
    _self_install_setup
    _feed_versions 1.0.0.1-main
    _feed_package 1.0.0.1-main
    mkdir -p "${INSTALL_DIR}"
    exec 7> "${INSTALL_DIR}/install.lock"
    flock --exclusive 7
    run --separate-stderr _install
    exec 7>&-
    [ "${status}" -eq 0 ]
    [ "${lines[-1]}" = "CMD=credfeto-orchestrator" ]
    [[ "${output}" == *"Self-install: another run is installing the tool"* ]]
    [ -z "${stderr}" ]
    [ ! -e "${INSTALL_DIR}/current" ]
}

@test "an install directory that cannot be created warns and returns 0 (#252)" {
    _self_install_setup
    printf 'file' > "${TEST_TMP}/blocker"
    ORCHESTRATOR_CMD_INSTALL_DIR="${TEST_TMP}/blocker/bin"
    run --separate-stderr _install
    [ "${status}" -eq 0 ]
    [ "${output}" = "CMD=credfeto-orchestrator" ]
    [[ "${stderr}" == *"could not create ${TEST_TMP}/blocker/bin"* ]]
}
