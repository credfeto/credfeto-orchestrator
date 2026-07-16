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

    # Put the stub directory first so any stubs we create take precedence.
    export PATH="${STUB_BIN}:${PATH}"

    # Fail-closed network guard: several tests exercise real git plumbing (clone/fetch/
    # push/rebase) against a local bare "remote" fixture under TEST_TMP, using the real
    # git binary rather than a stub, because the behaviour under test is git's own
    # plumbing rather than oneshot's use of it. If a test's isolation of REPO_WORK_DIR
    # or a remote URL is ever wrong for any reason (a bug in the test itself, environment
    # leakage between tests, etc.), the only thing that should happen is the git command
    # failing fast - never a real network call reaching a real remote. Restricting the
    # allowed transport to "file" makes every ssh://, https://, or git:// operation fail
    # immediately at the transport layer, regardless of what host or URL was requested.
    export GIT_ALLOW_PROTOCOL=file

    # Fail-closed local-escape guard: make_repo_fixture_dir creates fixtures nested INSIDE
    # this real repo's working tree (under test/.fixture.XXXXXX), with no .git of their own.
    # Without this, a git command run with -C pointed at such a fixture (or with cwd inside
    # one) doesn't fail — git's normal repository-discovery walks up parent directories until
    # it finds a .git, silently escapes the fixture, and finds THIS repo's real .git, so the
    # command operates on the real repo instead of erroring "not a git repository" as intended
    # (confirmed incident, #1185 review: a test-only script bug left a loop iteration running
    # `git switch main` against this exact fixture pattern, which silently checked out this
    # real repo's main branch every 5 minutes for hours). GIT_CEILING_DIRECTORIES stops git's
    # upward search AT (and excluding) REPO_ROOT, so any git command inside a fixture that
    # lacks its own .git fails fast instead of discovering the enclosing real repo. Does not
    # affect fixtures that `git init`/`git clone` their own nested repo (e.g.
    # setup_local_git_remote) — git finds their own .git before ever reaching the ceiling.
    export GIT_CEILING_DIRECTORIES="${REPO_ROOT}"

    # Unset host-level env vars that leak from the container/agent environment
    # and change script behaviour in ways the tests do not expect.
    unset GIT_USER_NAME GIT_USER_EMAIL GIT_SIGNING_KEY
    unset GH_HOST GH_ENTERPRISE_TOKEN GH_TOKEN
    unset CLAUDECODE CLAUDE_CODE_OAUTH_TOKEN ORCHESTRATOR_IMAGE
    unset DISCORD_WEBHOOK_URL
    unset SSH_AUTH_SOCK
    # Prevent the host gpg-agent's runtime socket from leaking into tests that
    # exercise add_gpg_podman_args — a live socket at $XDG_RUNTIME_DIR/gnupg/
    # S.gpg-agent.extra would bypass the "socket absent" code path and fail the
    # isolation test.  Tests that need this path set it explicitly.
    unset XDG_RUNTIME_DIR
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
    export CLAUDE_STATE_DIR="${SESSION_BASE_DIR}/claude"
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

# Sources the install-claude-hooks script so its functions are defined without running main.
source_install_claude_hooks() {
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/install-claude-hooks"
}

# Sources the setup-owner script so its functions are defined without running main.
source_setup_owner() {
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/setup-owner"
}

# Sources the create-project script so its functions are defined without running main.
source_create_project() {
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/create-project"
}

# Creates a unique fixture directory inside the repository tree and assigns its path
# to the variable named REPO_FIXTURE_DIR. The loop script checks `[ -x oneshot ]`;
# some sandboxes do not honour the execute bit for files created under the system temp
# directory, so loop subprocess fixtures must live inside the repo tree. The directory
# is registered for teardown removal. It assigns rather than prints so the registration
# is not lost to a command-substitution subshell.
# Also copies lib/ alongside, since any top-level script staged into the fixture (loop,
# create-project, setup-owner) sources it and must find it at the same relative path it
# uses in the real repo (resolved via BASH_SOURCE/$0, not a fixed path).
make_repo_fixture_dir() {
    REPO_FIXTURE_DIR="$(mktemp -d "${REPO_ROOT}/test/.fixture.XXXXXX")"
    REPO_FIXTURE_DIRS+=("${REPO_FIXTURE_DIR}")
    cp -r "${REPO_ROOT}/lib" "${REPO_FIXTURE_DIR}/lib"
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
