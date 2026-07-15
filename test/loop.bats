#!/usr/bin/env bats

load test_helper

setup() {
    setup_isolated_env
}

teardown() {
    cleanup_stubs
    cleanup_repo_fixtures
}

# Runs the loop script as a subprocess from the given SCRIPT_DIR using a controlled
# environment. The script is expected to die before reaching the infinite while loop.
run_loop_in() {
    local script_dir="$1"
    shift
    run env "$@" bash -c '
        cd "'"${script_dir}"'" || exit 99
        bash ./loop
    '
}

@test "loop dies when oneshot is not executable" {
    local dir
    make_repo_fixture_dir
    dir="${REPO_FIXTURE_DIR}"
    cp "${REPO_ROOT}/loop" "${dir}/loop"
    chmod +x "${dir}/loop"
    # No oneshot present at all → not executable.

    run_loop_in "${dir}" -u CLAUDECODE
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"oneshot script not found or not executable"* ]]
}

@test "loop refuses to run inside a Claude Code session (CLAUDECODE=1)" {
    local dir
    make_repo_fixture_dir
    dir="${REPO_FIXTURE_DIR}"
    cp "${REPO_ROOT}/loop" "${dir}/loop"
    chmod +x "${dir}/loop"
    # oneshot present and executable so the is_ai_agent check is the one that fires.
    printf '#!/usr/bin/env bash\nexit 0\n' > "${dir}/oneshot"
    chmod +x "${dir}/oneshot"

    run_loop_in "${dir}" CLAUDECODE=1
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"must not be run inside a Claude Code session"* ]]
}

@test "loop dies loudly when lib/core cannot be sourced" {
    local dir
    make_repo_fixture_dir
    dir="${REPO_FIXTURE_DIR}"
    cp "${REPO_ROOT}/loop" "${dir}/loop"
    chmod +x "${dir}/loop"
    # make_repo_fixture_dir copies lib/ alongside; remove it to simulate a partially-synced
    # checkout. Without the FATAL-and-exit guard on the source line, this used to leave
    # die/success/info/warn/is_ai_agent silently undefined and fall through into the real
    # while-loop body instead of stopping here (confirmed incident, #1185 review: that let a
    # test session run real `git switch main`/`git pull` against the enclosing repo on every
    # 300-second iteration for hours).
    rm -rf "${dir:?}/lib"

    run_loop_in "${dir}" -u CLAUDECODE
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"FATAL: failed to source"*"lib/core"* ]]
}

@test "sourcing loop defines main without executing it" {
    source_loop
    # main is defined as a function.
    run declare -F main
    [ "${status}" -eq 0 ]
    # Helpers are available too.
    run declare -F is_ai_agent
    [ "${status}" -eq 0 ]
}

@test "loop is_ai_agent reflects CLAUDECODE" {
    source_loop
    CLAUDECODE=1 run is_ai_agent
    [ "${status}" -eq 0 ]
    CLAUDECODE=0 run is_ai_agent
    [ "${status}" -ne 0 ]
}

@test "update_scripts dies loudly when git switch fails" {
    make_stub git '
        case "$*" in
            *switch*) exit 1 ;;
            *)        exit 0 ;;
        esac
    '
    source_loop
    run update_scripts
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Failed to switch to main branch"* ]]
}

@test "update_scripts warns and continues when git pull fails" {
    make_stub git '
        case "$*" in
            *switch*) exit 0 ;;
            *pull*)   exit 1 ;;
            *)        exit 0 ;;
        esac
    '
    source_loop
    run update_scripts
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"git pull failed or timed out"* ]]
}

@test "update_scripts warns and continues when the pull times out" {
    make_stub git 'exit 0'
    make_stub timeout 'exit 124'
    source_loop
    run update_scripts
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"git pull failed or timed out"* ]]
}
