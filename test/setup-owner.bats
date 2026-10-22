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

    # Privileged tools are stubbed to record their invocation in calls.log, so no test
    # touches real accounts, ownership or systemd state. File tools (cp, rm, mkdir, tee,
    # chmod, find) stay real and operate inside TEST_TMP.
    local tool
    for tool in chown useradd passwd usermod loginctl systemctl pkill; do
        # shellcheck disable=SC2016  # stub body: $0/$* must stay literal and expand at stub runtime
        make_stub "${tool}" 'printf "%s\n" "$(basename "$0") $*" >> "${TEST_TMP}/calls.log"'
    done
    make_stub getent 'exit 1'
    make_stub git 'exit 0'

    # runuser must always be handed an explicit HOME, because runuser -u keeps root's
    # environment and the owner's git/gpg would otherwise read root's configuration.
    # shellcheck disable=SC2016  # stub body: $*/$#/$1/$@ must stay literal and expand at stub runtime
    make_stub_multiline runuser \
        'printf "%s\n" "runuser $*" >> "${TEST_TMP}/calls.log"' \
        'case "$*" in' \
        '    "-u "*" -- env HOME="*) ;;' \
        '    *) echo "runuser called without an explicit HOME: $*" >&2; exit 97 ;;' \
        'esac' \
        'while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done' \
        'shift' \
        'exec "$@"'

    # Redirect unit and polkit writes to the test tree; setup-owner reads both at source time.
    export UNIT_DIR="${TEST_TMP}/units"
    export POLKIT_RULES_DIR="${TEST_TMP}/polkit"
    mkdir -p "${UNIT_DIR}" "${POLKIT_RULES_DIR}"

    unset CLAUDECODE
    unset SUDO_USER

    source_setup_owner
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

@test "check_required_tools requires neither visudo nor sudo" {
    # visudo was previously required for ensure_sudoers, and sudo for every privileged
    # step; setup-owner now runs as root and must need neither.
    # shellcheck disable=SC2329
    command() {
        if [ "$1" = "-v" ] && { [ "$2" = "visudo" ] || [ "$2" = "sudo" ]; }; then
            return 1
        fi
        builtin command "$@"
    }
    run check_required_tools
    [ "${status}" -eq 0 ]
}

@test "check_required_tools dies when runuser is missing" {
    # shellcheck disable=SC2329
    command() {
        if [ "$1" = "-v" ] && [ "$2" = "runuser" ]; then
            return 1
        fi
        builtin command "$@"
    }
    run check_required_tools
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"runuser"* ]]
}

@test "no provisioning script invokes sudo outside comments" {
    local script
    for script in setup-owner teardown-owner lib/systemd-units; do
        run bash -c 'sed "s/#.*//" "$1" | grep -qw sudo' _ "${REPO_ROOT}/${script}"
        [ "${status}" -ne 0 ] || { echo "${script} invokes sudo" >&2; return 1; }
    done
}

@test "main dies when not run as root" {
    run main --owner testowner
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"must be run as root"* ]]
    [ ! -f "${TEST_TMP}/calls.log" ]
}

@test "main dies with usage when no owner is given" {
    run main
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Usage:"* ]]
}

@test "enable_linger invokes loginctl enable-linger for the owner" {
    run enable_linger "testowner"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Linger enabled for testowner"* ]]
    grep -qxF "loginctl enable-linger testowner" "${TEST_TMP}/calls.log"
}

@test "ensure_user_exists creates and locks a new user" {
    # shellcheck disable=SC2329
    id() { return 1; }
    run ensure_user_exists "testowner"
    [ "${status}" -eq 0 ]
    grep -qxF "useradd -m -s /bin/bash testowner" "${TEST_TMP}/calls.log"
    grep -qxF "passwd -l testowner" "${TEST_TMP}/calls.log"
}

@test "ensure_journal_group adds a newly created user to systemd-journal" {
    # shellcheck disable=SC2329
    id() { return 1; }
    # shellcheck disable=SC2329
    getent() { [ "$1" = "group" ] && [ "$2" = "systemd-journal" ]; }
    run ensure_user_exists "testowner"
    [ "${status}" -eq 0 ]
    run ensure_journal_group "testowner"
    [ "${status}" -eq 0 ]
    grep -qxF "usermod -aG systemd-journal testowner" "${TEST_TMP}/calls.log"

    local useradd_line usermod_line
    useradd_line=$(grep -nF "useradd " "${TEST_TMP}/calls.log" | head -1 | cut -d: -f1)
    usermod_line=$(grep -nF "usermod " "${TEST_TMP}/calls.log" | head -1 | cut -d: -f1)
    [ "${useradd_line}" -lt "${usermod_line}" ]
}

@test "ensure_journal_group adds an already existing user to systemd-journal" {
    # shellcheck disable=SC2329
    getent() { [ "$1" = "group" ] && [ "$2" = "systemd-journal" ]; }
    run ensure_user_exists "testowner"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"already exists"* ]]
    run ensure_journal_group "testowner"
    [ "${status}" -eq 0 ]
    run grep -qF "useradd" "${TEST_TMP}/calls.log"
    [ "${status}" -ne 0 ]
    grep -qxF "usermod -aG systemd-journal testowner" "${TEST_TMP}/calls.log"
}

@test "ensure_journal_group dies when the systemd-journal group does not exist" {
    run ensure_journal_group "testowner"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Group systemd-journal does not exist"* ]]
    [ ! -f "${TEST_TMP}/calls.log" ]
}

@test "ensure_journal_group dies when usermod fails" {
    # shellcheck disable=SC2329
    getent() { [ "$1" = "group" ] && [ "$2" = "systemd-journal" ]; }
    make_stub usermod 'exit 1'
    run ensure_journal_group "testowner"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Failed to add testowner to the systemd-journal group"* ]]
}

@test "write_polkit_rule allows only start, stop and restart of the owner's own service" {
    run write_polkit_rule "testowner"
    [ "${status}" -eq 0 ]

    local service_name rule_file
    service_name=$(systemd_service_name "testowner" "testowner")
    rule_file="${POLKIT_RULES_DIR}/50-credfeto-orchestrator-testowner.rules"
    [ -f "${rule_file}" ]
    grep -qF 'subject.user == "testowner"' "${rule_file}"
    grep -qF "action.lookup(\"unit\") == \"${service_name}.service\"" "${rule_file}"
    grep -qF 'org.freedesktop.systemd1.manage-units' "${rule_file}"
    grep -qF '"start"' "${rule_file}"
    grep -qF '"stop"' "${rule_file}"
    grep -qF '"restart"' "${rule_file}"
    grep -qF 'polkit.Result.YES' "${rule_file}"
    run grep -qE '"(reload|enable|disable|kill|mask)"' "${rule_file}"
    [ "${status}" -ne 0 ]
    run grep -c 'lookup("unit")' "${rule_file}"
    [ "${output}" -eq 1 ]
}

@test "write_polkit_rule sets root ownership and mode 0644" {
    run write_polkit_rule "testowner"
    [ "${status}" -eq 0 ]

    local rule_file="${POLKIT_RULES_DIR}/50-credfeto-orchestrator-testowner.rules"
    grep -qxF "chown root:root ${rule_file}" "${TEST_TMP}/calls.log"
    [ "$(stat -c '%a' "${rule_file}")" = "644" ]
}

@test "write_polkit_rule rewrites a stale rule on every run" {
    local rule_file="${POLKIT_RULES_DIR}/50-credfeto-orchestrator-testowner.rules"
    printf 'stale-rule-content\n' > "${rule_file}"
    chmod 0600 "${rule_file}"

    run write_polkit_rule "testowner"
    [ "${status}" -eq 0 ]

    run grep -qF 'stale-rule-content' "${rule_file}"
    [ "${status}" -ne 0 ]
    grep -qF 'subject.user == "testowner"' "${rule_file}"
    [ "$(stat -c '%a' "${rule_file}")" = "644" ]
}

@test "write_polkit_rule dies when the polkit rules directory is missing" {
    rm -rf "${POLKIT_RULES_DIR}"
    run write_polkit_rule "testowner"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"${POLKIT_RULES_DIR} does not exist"* ]]
    [ ! -d "${POLKIT_RULES_DIR}" ]
}

@test "install_owner_units installs the owner's units against its own clone" {
    local test_home="${TEST_TMP}/owner_home"
    # shellcheck disable=SC2329
    getent() { echo "testowner:x:1001:1001:Test Owner:${test_home}:/bin/bash"; }
    # shellcheck disable=SC2329
    install_systemd_units() { printf '%s\n' "install_systemd_units $*" >> "${TEST_TMP}/calls.log"; }

    run install_owner_units "testowner"
    [ "${status}" -eq 0 ]
    grep -qxF "install_systemd_units testowner ${test_home}/credfeto-orchestrator testowner" "${TEST_TMP}/calls.log"
}

@test "revoke_sudoers is a no-op when the sudoers file does not exist" {
    run revoke_sudoers "testowner"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"nothing to revoke"* ]]
}

@test "revoke_sudoers removes the sudoers file when it exists" {
    touch "${SUDOERS_DIR}/testowner"
    run revoke_sudoers "testowner"
    [ "${status}" -eq 0 ]
    [ ! -f "${SUDOERS_DIR}/testowner" ]
    [[ "${output}" == *"Sudoers entry revoked for testowner"* ]]
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

@test "copy_dotdir refreshes an existing .ssh directory instead of skipping it" {
    local src_ssh="${HOME}/.ssh"
    local dst_home="${TEST_TMP}/owner_home"
    local dst_ssh="${dst_home}/.ssh"
    mkdir -p "${src_ssh}" "${dst_ssh}"
    printf 'new-key-material\n' > "${src_ssh}/id_ed25519"
    printf 'old-key-material\n' > "${dst_ssh}/id_ed25519"


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

    # Fail only the copy into the owner's .ssh; anything else (e.g. teardown) is untouched.
    # shellcheck disable=SC2329
    cp() { case "$*" in *"${dst_ssh}"*) return 1 ;; *) command cp "$@" ;; esac; }

    run copy_dotdir "testowner" "${dst_home}" ".ssh"
    # Drop the override at once: it reads a test-local variable, so left in place it would
    # match every call once that variable is out of scope and break bats' own cleanup.
    unset -f cp
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

    # Fail only the removal of the owner's .ssh; teardown's own rm calls must still work.
    # shellcheck disable=SC2329
    rm() { case "$*" in *"${dst_ssh}"*) return 1 ;; *) command rm "$@" ;; esac; }

    run copy_dotdir "testowner" "${dst_home}" ".ssh"
    # Drop the override at once: it reads a test-local variable, so left in place it would
    # match every call once that variable is out of scope and break bats' own cleanup.
    unset -f rm
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

    # Let the backup-out mv succeed; fail only the final restore-in mv.
    # shellcheck disable=SC2329
    mv() { case "$*" in *"${dst_ssh}/known_hosts") return 1 ;; *) command mv "$@" ;; esac; }

    run copy_dotdir "testowner" "${dst_home}" ".ssh"
    # Drop the override at once: it reads a test-local variable, so left in place it would
    # match every call once that variable is out of scope and break bats' own cleanup.
    unset -f mv
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Failed to restore known_hosts"* ]]
    [[ "${output}" == *"backup still at"* ]]

    local backup_path
    backup_path=$(printf '%s\n' "${output}" | sed -n 's/.*backup still at \([^,]*\),.*/\1/p')
    [ -f "${backup_path}" ]
    run cat "${backup_path}"
    [[ "${output}" == "accumulated-host-key" ]]
}

@test "clone_or_pull_repo reasserts ownership before pulling an already-cloned checkout" {
    local test_home="${TEST_TMP}/owner_home"
    local clone_dir="${test_home}/credfeto-orchestrator"
    mkdir -p "${clone_dir}/.git"

    # shellcheck disable=SC2329
    getent() { echo "testowner:x:1001:1001:Test Owner:${test_home}:/bin/bash"; }
    export -f getent

    # shellcheck disable=SC2329
    find() { case "$1" in "${clone_dir}") echo "drift-detected" ;; *) command find "$@" ;; esac; }

    run clone_or_pull_repo "testowner"
    # Drop the override at once: it reads a test-local variable, so left in place it would
    # match every call once that variable is out of scope and break bats' own cleanup.
    unset -f find
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Repository ready at ${clone_dir}"* ]]

    local pull_call="runuser -u testowner -- env HOME=${test_home} git -C ${clone_dir} pull --ff-only"
    grep -qxF "chown -R testowner:testowner ${clone_dir}" "${TEST_TMP}/calls.log"
    grep -qxF "${pull_call}" "${TEST_TMP}/calls.log"

    # The chown must run before the pull, so a root-owned .git/index left by an
    # earlier diagnostic command (#1300) is fixed before git needs to open it.
    local chown_line pull_line
    chown_line=$(grep -nxF "chown -R testowner:testowner ${clone_dir}" "${TEST_TMP}/calls.log" | head -1 | cut -d: -f1)
    pull_line=$(grep -nxF "${pull_call}" "${TEST_TMP}/calls.log" | head -1 | cut -d: -f1)
    [ "${chown_line}" -lt "${pull_line}" ]
}

@test "clone_or_pull_repo skips the ownership reassert when no drift is detected" {
    local test_home="${TEST_TMP}/owner_home"
    local clone_dir="${test_home}/credfeto-orchestrator"
    mkdir -p "${clone_dir}/.git"

    # shellcheck disable=SC2329
    getent() { echo "testowner:x:1001:1001:Test Owner:${test_home}:/bin/bash"; }
    export -f getent

    # No output: nothing under the checkout is owned by anyone else.
    # shellcheck disable=SC2329
    find() { case "$1" in "${clone_dir}") : ;; *) command find "$@" ;; esac; }

    run clone_or_pull_repo "testowner"
    # Drop the override at once: it reads a test-local variable, so left in place it would
    # match every call once that variable is out of scope and break bats' own cleanup.
    unset -f find
    [ "${status}" -eq 0 ]

    run grep -qF "chown -R testowner:testowner ${clone_dir}" "${TEST_TMP}/calls.log"
    [ "${status}" -ne 0 ]
    grep -qxF "runuser -u testowner -- env HOME=${test_home} git -C ${clone_dir} pull --ff-only" "${TEST_TMP}/calls.log"
}

@test "clone_or_pull_repo still pulls when reasserting ownership fails" {
    local test_home="${TEST_TMP}/owner_home"
    local clone_dir="${test_home}/credfeto-orchestrator"
    mkdir -p "${clone_dir}/.git"

    # shellcheck disable=SC2329
    getent() { echo "testowner:x:1001:1001:Test Owner:${test_home}:/bin/bash"; }
    export -f getent

    # shellcheck disable=SC2329
    find() { case "$1" in "${clone_dir}") echo "drift-detected" ;; *) command find "$@" ;; esac; }
    # shellcheck disable=SC2016  # stub body: $* must stay literal and expand at stub runtime
    make_stub chown 'printf "%s\n" "chown $*" >> "${TEST_TMP}/calls.log"; exit 1'

    run clone_or_pull_repo "testowner"
    # Drop the override at once: it reads a test-local variable, so left in place it would
    # match every call once that variable is out of scope and break bats' own cleanup.
    unset -f find
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Failed to fully reassert ownership"* ]]
    [[ "${output}" == *"Repository ready at ${clone_dir}"* ]]

    grep -qxF "runuser -u testowner -- env HOME=${test_home} git -C ${clone_dir} pull --ff-only" "${TEST_TMP}/calls.log"
}

@test "clone_or_pull_repo clones as the owner with an explicit HOME when no checkout exists" {
    local test_home="${TEST_TMP}/owner_home"
    local clone_dir="${test_home}/credfeto-orchestrator"
    mkdir -p "${test_home}"

    # shellcheck disable=SC2329
    getent() { echo "testowner:x:1001:1001:Test Owner:${test_home}:/bin/bash"; }
    export -f getent

    run clone_or_pull_repo "testowner"
    [ "${status}" -eq 0 ]
    grep -qxF "runuser -u testowner -- env HOME=${test_home} git clone ${REPO_URL} ${clone_dir}" "${TEST_TMP}/calls.log"
}

@test "clone_or_pull_repo dies when the pull fails" {
    local test_home="${TEST_TMP}/owner_home"
    local clone_dir="${test_home}/credfeto-orchestrator"
    mkdir -p "${clone_dir}/.git"

    # shellcheck disable=SC2329
    getent() { echo "testowner:x:1001:1001:Test Owner:${test_home}:/bin/bash"; }
    export -f getent
    make_stub git 'exit 1'

    run clone_or_pull_repo "testowner"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Failed to pull repository in ${clone_dir}"* ]]
}

@test "the runuser stub rejects a call without an explicit HOME" {
    run runuser -u testowner -- git status
    [ "${status}" -eq 97 ]
    [[ "${output}" == *"without an explicit HOME"* ]]
}

@test "configure_podman_engine writes containers.conf with cgroupfs manager only" {
    local test_home="${TEST_TMP}/owner_home"
    mkdir -p "${test_home}"

    # shellcheck disable=SC2329
    getent() { echo "testowner:x:1001:1001:Test Owner:${test_home}:/bin/bash"; }
    export -f getent

    run configure_podman_engine "testowner"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"cgroupfs"* ]]

    local containers_conf="${test_home}/.config/containers/containers.conf"
    [ -f "${containers_conf}" ]
    grep -q 'cgroup_manager = "cgroupfs"' "${containers_conf}"
    run grep -q 'cgroup_parent' "${containers_conf}"
    [ "${status}" -ne 0 ]
}
