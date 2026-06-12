#!/usr/bin/env bash

# Shared helpers for the bats suites covering the oneshot and loop scripts.
#
# These helpers keep every test isolated and offline:
#   * a per-test temporary directory is created under BATS_TEST_TMPDIR
#   * HOME / XDG_CONFIG_HOME / XDG_PROJECTS_DIR / SESSION_BASE_DIR are redirected there
#   * external commands are replaced with deterministic PATH stubs
# Nothing here touches the real filesystem outside TEST_TMP or makes network calls.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Tracks repo-tree fixture directories so teardown can remove them.
REPO_FIXTURE_DIRS=()

# Tracks stub-bin directories created in the repo tree so teardown can remove them.
STUB_BIN_DIRS=()

# Creates an isolated environment and exports the variables the scripts read.
# Call this from setup() before sourcing a script under test.
setup_isolated_env() {
    TEST_TMP="$(mktemp -d "${BATS_TEST_TMPDIR}/oneshot.XXXXXX")"
    export TEST_TMP

    export HOME="${TEST_TMP}/home"
    export XDG_CONFIG_HOME="${TEST_TMP}/config"
    export XDG_PROJECTS_DIR="${TEST_TMP}/projects"
    export SESSION_BASE_DIR="${TEST_TMP}/sessions"

    # Stub bin must live inside the repo tree so that stub scripts are executable;
    # the system temp directory (/tmp) may be mounted noexec in sandboxed environments.
    STUB_BIN="$(mktemp -d "${REPO_ROOT}/test/.stub.XXXXXX")"
    export STUB_BIN
    STUB_BIN_DIRS+=("${STUB_BIN}")
    mkdir -p "${HOME}" "${XDG_CONFIG_HOME}" "${XDG_PROJECTS_DIR}" "${SESSION_BASE_DIR}"

    # Provide a minimal git global config so that build_minimal_gitconfig can read
    # identity values without touching the real host config.  Tests that need different
    # values overwrite this file directly.
    printf '[user]\n\tname = Test User\n\temail = test@example.com\n\tsigningkey = TESTKEY1234\n[commit]\n\tgpgsign = true\n' \
        > "${HOME}/.gitconfig"

    # Put the stub directory first so any stubs we create take precedence.
    export PATH="${STUB_BIN}:${PATH}"
}

# Sources the oneshot script so its functions are defined without running main.
# Calls set_repo_context with the canonical test repo so tests that reference
# REPO_FULL / REPO_WORK_DIR / RULES_DIR get consistent values, then overrides
# SESSION_BASE_DIR to point into the isolated test directory.
source_oneshot() {
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/oneshot"
    set_repo_context "credfeto/credfeto-orchestrator"
    SESSION_BASE_DIR="${TEST_TMP}/sessions"
}

# Sources the loop script so its functions are defined without running main.
source_loop() {
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/loop"
}

# Sources the install-timer script so its functions are defined without running main.
source_install_timer() {
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/install-timer"
}

# Sources the uninstall-timer script so its functions are defined without running main.
source_uninstall_timer() {
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/uninstall-timer"
}

# Creates a unique fixture directory inside the repository tree and assigns its path
# to the variable named REPO_FIXTURE_DIR. The loop script checks `[ -x oneshot ]`;
# some sandboxes do not honour the execute bit for files created under the system temp
# directory, so loop subprocess fixtures must live inside the repo tree. The directory
# is registered for teardown removal. It assigns rather than prints so the registration
# is not lost to a command-substitution subshell.
make_repo_fixture_dir() {
    REPO_FIXTURE_DIR="$(mktemp -d "${REPO_ROOT}/test/.fixture.XXXXXX")"
    REPO_FIXTURE_DIRS+=("${REPO_FIXTURE_DIR}")
}

# Removes any repo-tree fixture directories created during the test.
cleanup_repo_fixtures() {
    local dir
    for dir in "${REPO_FIXTURE_DIRS[@]}"; do
        [ -n "${dir}" ] && rm -rf "${dir}"
    done
    REPO_FIXTURE_DIRS=()
}

# Removes stub-bin directories created in the repo tree during the test.
cleanup_stubs() {
    local dir
    for dir in "${STUB_BIN_DIRS[@]}"; do
        [ -n "${dir}" ] && rm -rf "${dir}"
    done
    STUB_BIN_DIRS=()
}

# Writes an executable PATH stub named "$1" whose body is the remaining arguments,
# in the per-test stub directory that is first on PATH. Use this for commands invoked
# as subprocesses. For commands that the test must inspect or vary per call — or that
# the host environment resolves regardless of PATH — override the matching shell
# function directly in the test instead.
# Example: make_stub gh 'echo "{}"'
make_stub() {
    local name="$1"
    shift
    local script="${STUB_BIN}/${name}"
    {
        printf '#!/usr/bin/env bash\n'
        printf '%s\n' "$*"
    } > "${script}"
    chmod +x "${script}"
}

# Writes an executable PATH stub named "$1" whose body consists of each subsequent
# argument as a separate line. Use when the stub body requires multiple statements
# that make_stub cannot express as a single joined string.
# Example: make_stub_multiline claude 'line_one' 'line_two'
make_stub_multiline() {
    local name="$1"
    shift
    local script="${STUB_BIN}/${name}"
    {
        printf '#!/usr/bin/env bash\n'
        local line
        for line; do
            printf '%s\n' "${line}"
        done
    } > "${script}"
    chmod +x "${script}"
}
