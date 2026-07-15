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

    # Make fuse-overlayfs unavailable so the storage driver falls back to vfs.
    # shellcheck disable=SC2329
    command() {
        case "$*" in
            "-v fuse-overlayfs") return 1 ;;
            *) builtin command "$@" ;;
        esac
    }
    export -f command

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

    # Make fuse-overlayfs unavailable so the storage driver falls back to vfs.
    # shellcheck disable=SC2329
    command() {
        case "$*" in
            "-v fuse-overlayfs") return 1 ;;
            *) builtin command "$@" ;;
        esac
    }
    export -f command

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

    # Make fuse-overlayfs unavailable so the storage driver falls back to vfs.
    # shellcheck disable=SC2329
    command() {
        case "$*" in
            "-v fuse-overlayfs") return 1 ;;
            *) builtin command "$@" ;;
        esac
    }
    export -f command

    run configure_podman_storage "testowner"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"vfs"* ]]

    local storage_conf="${test_home}/.config/containers/storage.conf"
    [ -f "${storage_conf}" ]
    grep -q 'driver = "vfs"' "${storage_conf}"
}

@test "configure_git writes user identity to .gitconfig" {
    local test_home="${TEST_TMP}/owner_home"
    mkdir -p "${test_home}"

    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf 'GIT_USER_NAME="Test User"\nGIT_USER_EMAIL="test@example.com"\n' \
        > "${XDG_CONFIG_HOME}/orchestrator/.env"

    # shellcheck disable=SC2329
    getent() { echo "testowner:x:1001:1001:Test Owner:${test_home}:/bin/bash"; }
    export -f getent

    # shellcheck disable=SC2329
    sudo() {
        printf '%s\n' "$*" >> "${TEST_TMP}/sudo.log"
        case "$1" in
            tee)   shift; tee "$1" ;;
            chown|chmod) true ;;
        esac
    }
    export -f sudo

    run configure_git "testowner" "${test_home}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Git configured for testowner"* ]]

    local gitconfig="${test_home}/.gitconfig"
    [ -f "${gitconfig}" ]
    grep -q 'name = Test User' "${gitconfig}"
    grep -q 'email = test@example.com' "${gitconfig}"
}

@test "configure_git writes GPG signing config when GIT_SIGNING_KEY is set" {
    local test_home="${TEST_TMP}/owner_home"
    mkdir -p "${test_home}"

    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf 'GIT_USER_NAME="Test User"\nGIT_USER_EMAIL="test@example.com"\nGIT_SIGNING_KEY=ABCD1234\n' \
        > "${XDG_CONFIG_HOME}/orchestrator/.env"

    # shellcheck disable=SC2329
    getent() { echo "testowner:x:1001:1001:Test Owner:${test_home}:/bin/bash"; }
    export -f getent

    # shellcheck disable=SC2329
    sudo() {
        printf '%s\n' "$*" >> "${TEST_TMP}/sudo.log"
        case "$1" in
            tee)   shift; tee "$1" ;;
            chown|chmod) true ;;
        esac
    }
    export -f sudo

    run configure_git "testowner" "${test_home}"
    [ "${status}" -eq 0 ]

    local gitconfig="${test_home}/.gitconfig"
    [ -f "${gitconfig}" ]
    grep -q 'signingkey = ABCD1234' "${gitconfig}"
    grep -q 'gpgsign = true' "${gitconfig}"
    grep -q 'gpgSign = true' "${gitconfig}"
}

@test "configure_git writes standard git settings to .gitconfig" {
    local test_home="${TEST_TMP}/owner_home"
    mkdir -p "${test_home}"

    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf 'GIT_USER_NAME="Test User"\nGIT_USER_EMAIL="test@example.com"\n' \
        > "${XDG_CONFIG_HOME}/orchestrator/.env"

    # shellcheck disable=SC2329
    getent() { echo "testowner:x:1001:1001:Test Owner:${test_home}:/bin/bash"; }
    export -f getent

    # shellcheck disable=SC2329
    sudo() {
        printf '%s\n' "$*" >> "${TEST_TMP}/sudo.log"
        case "$1" in
            tee)   shift; tee "$1" ;;
            chown|chmod) true ;;
        esac
    }
    export -f sudo

    run configure_git "testowner" "${test_home}"
    [ "${status}" -eq 0 ]

    local gitconfig="${test_home}/.gitconfig"
    [ -f "${gitconfig}" ]
    grep -q 'autocrlf = false' "${gitconfig}"
    grep -q 'fscache = true' "${gitconfig}"
    grep -q 'ignorecase = false' "${gitconfig}"
    grep -q 'preloadIndex = true' "${gitconfig}"
    grep -q 'packedGitLimit = 512m' "${gitconfig}"
    grep -q 'packedGitWindowSize = 512m' "${gitconfig}"
    grep -q 'manyFiles = true' "${gitconfig}"
    grep -q 'parallel = 16' "${gitconfig}"
    grep -q 'prune = true' "${gitconfig}"
    grep -q 'defaultBranch = main' "${gitconfig}"
    grep -q 'ff = false' "${gitconfig}"
    grep -q 'rebase = true' "${gitconfig}"
    grep -q 'autoSetupRemote = true' "${gitconfig}"
    grep -q 'autosquash = true' "${gitconfig}"
}

@test "configure_git writes SSH URL rewrites to .gitconfig" {
    local test_home="${TEST_TMP}/owner_home"
    mkdir -p "${test_home}"

    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf 'GIT_USER_NAME="Test User"\nGIT_USER_EMAIL="test@example.com"\n' \
        > "${XDG_CONFIG_HOME}/orchestrator/.env"

    # shellcheck disable=SC2329
    getent() { echo "testowner:x:1001:1001:Test Owner:${test_home}:/bin/bash"; }
    export -f getent

    # shellcheck disable=SC2329
    sudo() {
        printf '%s\n' "$*" >> "${TEST_TMP}/sudo.log"
        case "$1" in
            tee)   shift; tee "$1" ;;
            chown|chmod) true ;;
        esac
    }
    export -f sudo

    run configure_git "testowner" "${test_home}"
    [ "${status}" -eq 0 ]

    local gitconfig="${test_home}/.gitconfig"
    [ -f "${gitconfig}" ]
    grep -q 'insteadOf = https://github.com/' "${gitconfig}"
    grep -q 'pushInsteadOf = https://github.com/' "${gitconfig}"
    grep -q 'insteadOf = git@github-api.markridgwell.com:' "${gitconfig}"
    grep -q 'pushInsteadOf = git@github-api.markridgwell.com:' "${gitconfig}"
    grep -q 'insteadOf = https://gitlab.com/' "${gitconfig}"
    grep -q 'pushInsteadOf = https://gitlab.com/' "${gitconfig}"
    grep -q 'insteadOf = https://bitbucket.org/' "${gitconfig}"
    grep -q 'pushInsteadOf = https://bitbucket.org/' "${gitconfig}"
}

@test "configure_git skips when GIT_USER_NAME is not set" {
    local test_home="${TEST_TMP}/owner_home"
    mkdir -p "${test_home}"

    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf 'GIT_USER_EMAIL="test@example.com"\n' \
        > "${XDG_CONFIG_HOME}/orchestrator/.env"

    # shellcheck disable=SC2329
    getent() { echo "testowner:x:1001:1001:Test Owner:${test_home}:/bin/bash"; }
    export -f getent

    run configure_git "testowner" "${test_home}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"skipping git config"* ]]

    local gitconfig="${test_home}/.gitconfig"
    [ ! -f "${gitconfig}" ]
}

# shellcheck disable=SC2329
stub_sudo_for_copy_dotdir() {
    sudo() {
        printf '%s\n' "$*" >> "${TEST_TMP}/sudo.log"
        case "$1" in
            rm)   shift; /bin/rm "$@" ;;
            cp)   shift; /bin/cp "$@" ;;
            mv)   shift; /bin/mv "$@" ;;
            cat)  shift; /bin/cat "$@" ;;
            tee)  shift; tee "$@" ;;
            find) shift; /usr/bin/find "$@" ;;
            chown|chmod) true ;;
        esac
    }
    export -f sudo
}

@test "copy_dotdir refreshes an existing .ssh directory instead of skipping it" {
    local src_ssh="${HOME}/.ssh"
    local dst_home="${TEST_TMP}/owner_home"
    local dst_ssh="${dst_home}/.ssh"
    mkdir -p "${src_ssh}" "${dst_ssh}"
    printf 'new-key-material\n' > "${src_ssh}/id_ed25519"
    printf 'old-key-material\n' > "${dst_ssh}/id_ed25519"

    stub_sudo_for_copy_dotdir

    run copy_dotdir "testowner" "${dst_home}" ".ssh"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Refreshed .ssh"* ]]

    run cat "${dst_ssh}/id_ed25519"
    [[ "${output}" == "new-key-material" ]]
}

@test "copy_dotdir preserves a destination-only known_hosts across the refresh" {
    local src_ssh="${HOME}/.ssh"
    local dst_home="${TEST_TMP}/owner_home"
    local dst_ssh="${dst_home}/.ssh"
    mkdir -p "${src_ssh}" "${dst_ssh}"
    printf 'new-key-material\n' > "${src_ssh}/id_ed25519"
    printf 'old-key-material\n' > "${dst_ssh}/id_ed25519"
    printf 'accumulated-host-key\n' > "${dst_ssh}/known_hosts"
    # Source does not ship its own known_hosts.

    stub_sudo_for_copy_dotdir

    run copy_dotdir "testowner" "${dst_home}" ".ssh"
    [ "${status}" -eq 0 ]

    run cat "${dst_ssh}/known_hosts"
    [[ "${output}" == "accumulated-host-key" ]]
    run cat "${dst_ssh}/id_ed25519"
    [[ "${output}" == "new-key-material" ]]
}

@test "copy_dotdir reports a recoverable known_hosts backup path when the refresh cp fails" {
    local src_ssh="${HOME}/.ssh"
    local dst_home="${TEST_TMP}/owner_home"
    local dst_ssh="${dst_home}/.ssh"
    mkdir -p "${src_ssh}" "${dst_ssh}"
    printf 'new-key-material\n' > "${src_ssh}/id_ed25519"
    printf 'accumulated-host-key\n' > "${dst_ssh}/known_hosts"
    # Source does not ship its own known_hosts.

    # shellcheck disable=SC2329
    sudo() {
        printf '%s\n' "$*" >> "${TEST_TMP}/sudo.log"
        case "$1" in
            rm)   shift; /bin/rm "$@" ;;
            cp)   return 1 ;;
            mv)   shift; /bin/mv "$@" ;;
            find) shift; /usr/bin/find "$@" ;;
            chown|chmod) true ;;
        esac
    }
    export -f sudo

    run copy_dotdir "testowner" "${dst_home}" ".ssh"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Failed to copy"* ]]
    [[ "${output}" == *"known_hosts backup preserved at"* ]]

    local backup_path
    backup_path=$(printf '%s\n' "${output}" | sed -n 's/.*preserved at \([^,]*\),.*/\1/p')
    [ -f "${backup_path}" ]
    run cat "${backup_path}"
    [[ "${output}" == "accumulated-host-key" ]]
}

@test "copy_dotdir reports a recoverable known_hosts backup path when the refresh rm fails" {
    local src_ssh="${HOME}/.ssh"
    local dst_home="${TEST_TMP}/owner_home"
    local dst_ssh="${dst_home}/.ssh"
    mkdir -p "${src_ssh}" "${dst_ssh}"
    printf 'new-key-material\n' > "${src_ssh}/id_ed25519"
    printf 'accumulated-host-key\n' > "${dst_ssh}/known_hosts"
    # Source does not ship its own known_hosts.

    # shellcheck disable=SC2329
    sudo() {
        printf '%s\n' "$*" >> "${TEST_TMP}/sudo.log"
        case "$1" in
            rm)   return 1 ;;
            cp)   shift; /bin/cp "$@" ;;
            mv)   shift; /bin/mv "$@" ;;
            find) shift; /usr/bin/find "$@" ;;
            chown|chmod) true ;;
        esac
    }
    export -f sudo

    run copy_dotdir "testowner" "${dst_home}" ".ssh"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Failed to remove existing"* ]]
    [[ "${output}" == *"known_hosts backup preserved at"* ]]

    local backup_path
    backup_path=$(printf '%s\n' "${output}" | sed -n 's/.*preserved at \([^,]*\),.*/\1/p')
    [ -f "${backup_path}" ]
    run cat "${backup_path}"
    [[ "${output}" == "accumulated-host-key" ]]
}

@test "copy_dotdir reports the known_hosts backup location when the final restore mv fails" {
    local src_ssh="${HOME}/.ssh"
    local dst_home="${TEST_TMP}/owner_home"
    local dst_ssh="${dst_home}/.ssh"
    mkdir -p "${src_ssh}" "${dst_ssh}"
    printf 'new-key-material\n' > "${src_ssh}/id_ed25519"
    printf 'accumulated-host-key\n' > "${dst_ssh}/known_hosts"
    # Source does not ship its own known_hosts.

    # shellcheck disable=SC2329
    sudo() {
        printf '%s\n' "$*" >> "${TEST_TMP}/sudo.log"
        case "$1" in
            rm)   shift; /bin/rm "$@" ;;
            cp)   shift; /bin/cp "$@" ;;
            mv)
                shift
                # Let the backup-out mv succeed; fail only the final restore-in mv.
                case "$*" in
                    *"${dst_ssh}/known_hosts") return 1 ;;
                    *) /bin/mv "$@" ;;
                esac
                ;;
            find) shift; /usr/bin/find "$@" ;;
            chown|chmod) true ;;
        esac
    }
    export -f sudo

    run copy_dotdir "testowner" "${dst_home}" ".ssh"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Failed to restore known_hosts"* ]]
    [[ "${output}" == *"backup still at"* ]]

    local backup_path
    backup_path=$(printf '%s\n' "${output}" | sed -n 's/.*backup still at \([^,]*\),.*/\1/p')
    [ -f "${backup_path}" ]
    run cat "${backup_path}"
    [[ "${output}" == "accumulated-host-key" ]]
}

@test "configure_podman_engine writes containers.conf with cgroupfs manager only" {
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
    run grep -q 'cgroup_parent' "${containers_conf}"
    [ "${status}" -ne 0 ]
}
