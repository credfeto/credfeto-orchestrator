#!/usr/bin/env bats

load test_helper

setup() {
    setup_isolated_env

    # Redirect sudoers writes to the test-controlled directory so no real
    # root filesystem access is needed.
    SUDOERS_DIR="${TEST_TMP}/sudoers"
    export SUDOERS_DIR
    mkdir -p "${SUDOERS_DIR}"

    # Override id as a bash function so CURRENT_USER / current_uid resolve to
    # predictable test values. Must be exported so subshells in the script see it.
    # shellcheck disable=SC2329
    id() {
        case "$*" in
            -un)   echo "testuser" ;;
            -u)    echo "1001" ;;
            "-u "*)echo "1001" ;;
            *)     echo "testuser" ;;
        esac
    }
    export -f id

    make_stub useradd 'exit 0'
    make_stub getent 'exit 1'
    make_stub git 'exit 0'
    make_stub loginctl 'exit 0'

    unset CLAUDECODE

    source_setup_owner

    # Override sudo as a bash function to record calls and redirect writes into
    # the test tree. The rm case performs the actual deletion so file-existence
    # assertions in revoke_sudoers tests work correctly.
    # shellcheck disable=SC2329
    sudo() {
        printf '%s\n' "$*" >> "${TEST_TMP}/sudo.log"
        case "$1" in
            rm) shift; /bin/rm "$@" ;;
        esac
    }
    export -f sudo
}

teardown() {
    cleanup_stubs
}

@test "sourcing setup-owner defines main without executing it" {
    run declare -F main
    [ "${status}" -eq 0 ]
    run declare -F revoke_sudoers
    [ "${status}" -eq 0 ]
}

@test "check_required_tools dies when a required tool is missing" {
    # shellcheck disable=SC2329
    command() {
        if [ "$1" = "-v" ] && [ "$2" = "git" ]; then
            return 1
        fi
        builtin command "$@"
    }
    run check_required_tools
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Required tool not found"* ]]
}

@test "check_required_tools does not require visudo" {
    # visudo was previously required for ensure_sudoers; it must no longer be.
    # shellcheck disable=SC2329
    command() {
        if [ "$1" = "-v" ] && [ "$2" = "visudo" ]; then
            return 1
        fi
        builtin command "$@"
    }
    run check_required_tools
    [ "${status}" -eq 0 ]
}

@test "enable_linger invokes loginctl enable-linger for the owner" {
    run enable_linger "testowner"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Linger enabled for testowner"* ]]
    grep -q "loginctl enable-linger testowner" "${TEST_TMP}/sudo.log"
}

@test "revoke_sudoers is a no-op when the sudoers file does not exist" {
    run revoke_sudoers "testowner"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"nothing to revoke"* ]]
    [ ! -f "${TEST_TMP}/sudo.log" ]
}

@test "revoke_sudoers removes the sudoers file when it exists" {
    touch "${SUDOERS_DIR}/testowner"
    run revoke_sudoers "testowner"
    [ "${status}" -eq 0 ]
    [ ! -f "${SUDOERS_DIR}/testowner" ]
    [ -f "${TEST_TMP}/sudo.log" ]
    grep -q "rm -f ${SUDOERS_DIR}/testowner" "${TEST_TMP}/sudo.log"
}

@test "ensure_sudoers is not defined (regression: old grant removed)" {
    run declare -F ensure_sudoers
    [ "${status}" -ne 0 ]
}

@test "configure_podman_storage uses overlay driver with fuse-overlayfs mount_program when fuse-overlayfs is available" {
    local test_home="${TEST_TMP}/owner_home"
    mkdir -p "${test_home}"

    make_stub fuse-overlayfs 'exit 0'

    # shellcheck disable=SC2329
    getent() { echo "testowner:x:1001:1001:Test Owner:${test_home}:/bin/bash"; }
    export -f getent

    # shellcheck disable=SC2329
    sudo() {
        printf '%s\n' "$*" >> "${TEST_TMP}/sudo.log"
        case "$1" in
            mkdir) shift; mkdir "$@" ;;
            tee)   shift; tee "$1" ;;
            chown|chmod) true ;;
        esac
    }
    export -f sudo

    run configure_podman_storage "testowner"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"overlay"* ]]

    local storage_conf="${test_home}/.config/containers/storage.conf"
    [ -f "${storage_conf}" ]
    grep -q 'driver = "overlay"' "${storage_conf}"
    grep -q 'mount_program' "${storage_conf}"
    grep -qF "fuse-overlayfs" "${storage_conf}"
}

@test "configure_podman_storage sets graphroot on btrfs work dir even with vfs driver" {
    local test_home="${TEST_TMP}/owner_home"
    local work_dir="${test_home}/work"
    mkdir -p "${work_dir}"

    make_stub findmnt 'echo "btrfs"'

    # shellcheck disable=SC2329
    getent() { echo "testowner:x:1001:1001:Test Owner:${test_home}:/bin/bash"; }
    export -f getent

    # shellcheck disable=SC2329
    sudo() {
        printf '%s\n' "$*" >> "${TEST_TMP}/sudo.log"
        case "$1" in
            mkdir) shift; mkdir "$@" ;;
            tee)   shift; tee "$1" ;;
            chown|chmod) true ;;
        esac
    }
    export -f sudo

    run configure_podman_storage "testowner"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"vfs"* ]]

    local storage_conf="${test_home}/.config/containers/storage.conf"
    [ -f "${storage_conf}" ]
    grep -q 'driver = "vfs"' "${storage_conf}"
    grep -q "graphroot = \"${work_dir}/.containers/storage\"" "${storage_conf}"
}

@test "configure_podman_storage falls back to vfs without graphroot when fuse-overlayfs absent and work dir not btrfs" {
    local test_home="${TEST_TMP}/owner_home"
    mkdir -p "${test_home}"

    make_stub findmnt 'echo "ext4"'

    # shellcheck disable=SC2329
    getent() { echo "testowner:x:1001:1001:Test Owner:${test_home}:/bin/bash"; }
    export -f getent

    # shellcheck disable=SC2329
    sudo() {
        printf '%s\n' "$*" >> "${TEST_TMP}/sudo.log"
        case "$1" in
            mkdir) shift; mkdir "$@" ;;
            tee)   shift; tee "$1" ;;
            chown|chmod) true ;;
        esac
    }
    export -f sudo

    run configure_podman_storage "testowner"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"vfs"* ]]

    local storage_conf="${test_home}/.config/containers/storage.conf"
    [ -f "${storage_conf}" ]
    grep -q 'driver = "vfs"' "${storage_conf}"
    run grep -q 'mount_program' "${storage_conf}"
    [ "${status}" -ne 0 ]
}

@test "configure_podman_storage falls back to vfs when work dir does not exist" {
    local test_home="${TEST_TMP}/owner_home"
    mkdir -p "${test_home}"

    # shellcheck disable=SC2329
    getent() { echo "testowner:x:1001:1001:Test Owner:${test_home}:/bin/bash"; }
    export -f getent

    # shellcheck disable=SC2329
    sudo() {
        printf '%s\n' "$*" >> "${TEST_TMP}/sudo.log"
        case "$1" in
            mkdir) shift; mkdir "$@" ;;
            tee)   shift; tee "$1" ;;
            chown|chmod) true ;;
        esac
    }
    export -f sudo

    run configure_podman_storage "testowner"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"vfs"* ]]

    local storage_conf="${test_home}/.config/containers/storage.conf"
    [ -f "${storage_conf}" ]
    grep -q 'driver = "vfs"' "${storage_conf}"
}

@test "configure_podman_engine writes containers.conf with cgroupfs and user session cgroup_parent" {
    local test_home="${TEST_TMP}/owner_home"
    mkdir -p "${test_home}"

    # shellcheck disable=SC2329
    getent() { echo "testowner:x:1001:1001:Test Owner:${test_home}:/bin/bash"; }
    export -f getent

    # shellcheck disable=SC2329
    sudo() {
        printf '%s\n' "$*" >> "${TEST_TMP}/sudo.log"
        case "$1" in
            mkdir) shift; mkdir "$@" ;;
            tee)   shift; tee "$1" ;;
            chown|chmod) true ;;
        esac
    }
    export -f sudo

    run configure_podman_engine "testowner"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"cgroupfs"* ]]

    local containers_conf="${test_home}/.config/containers/containers.conf"
    [ -f "${containers_conf}" ]
    grep -q 'cgroup_manager = "cgroupfs"' "${containers_conf}"
    grep -q 'cgroup_parent = "user.slice/user-1001.slice/user@1001.service"' "${containers_conf}"
}
