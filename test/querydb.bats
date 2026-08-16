#!/usr/bin/env bats

load test_helper

SCRIPT="${REPO_ROOT}/containers/base/development-full/scripts/querydb"

setup() {
    setup_isolated_env
    # querydb re-execs itself through `tee` into "$TMPBASE/testdb-last.log";
    # TMPBASE falls back to TMPDIR then /tmp, so this must be redirected into
    # the per-test temp dir - otherwise every run writes to the real /tmp.
    export TMPDIR="${TEST_TMP}/tmp"
    mkdir -p "${TMPDIR}"
    make_stub sqlcmd 'echo "sqlcmd called with: $*"'
}

teardown() {
    cleanup_stubs
}

write_database_file() {
    local path="$1"
    shift
    mkdir -p "$(dirname "${path}")"
    printf '%s\n' "$@" > "${path}"
}

@test "dies when no settings are available at all" {
    run bash -c 'cd "$1" && "$2"' _ "${TEST_TMP}" "${SCRIPT}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"--server not specified"* ]]
}

@test "dies when password is missing" {
    write_database_file "${HOME}/.database" 'SERVER=dbserver' 'DB=Treasury' 'USER=sa'
    run bash -c 'cd "$1" && "$2"' _ "${TEST_TMP}" "${SCRIPT}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"--password not specified"* ]]
}

@test "loads \$HOME/.database and connects via sqlcmd" {
    write_database_file "${HOME}/.database" 'SERVER=dbserver' 'DB=Treasury' 'USER=sa' 'PASSWORD=secret'
    run bash -c 'cd "$1" && "$2"' _ "${TEST_TMP}" "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Connecting to dbserver (DB: Treasury) as sa"* ]]
    [[ "${output}" == *"sqlcmd called with: -S dbserver -d Treasury -U sa -P secret"* ]]
}

@test "a repo-local .database file overrides individual fields from the global one" {
    write_database_file "${HOME}/.database" 'SERVER=dbserver' 'DB=GlobalDb' 'USER=sa' 'PASSWORD=secret'
    local work_dir="${TEST_TMP}/work"
    write_database_file "${work_dir}/.database" 'DB=LocalDb'
    mkdir -p "${work_dir}/sub/sub2"
    run bash -c 'cd "$1" && "$2"' _ "${work_dir}/sub/sub2" "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Connecting to dbserver (DB: LocalDb) as sa"* ]]
    [[ "${output}" == *"sqlcmd called with: -S dbserver -d LocalDb -U sa -P secret"* ]]
}

@test "extra arguments are passed through to sqlcmd" {
    write_database_file "${HOME}/.database" 'SERVER=dbserver' 'DB=Treasury' 'USER=sa' 'PASSWORD=secret'
    run bash -c 'cd "$1" && "$2" -Q "SELECT 1"' _ "${TEST_TMP}" "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"sqlcmd called with: -S dbserver -d Treasury -U sa -P secret -Q SELECT 1"* ]]
}

@test "writes a copy of its output to the log file" {
    write_database_file "${HOME}/.database" 'SERVER=dbserver' 'DB=Treasury' 'USER=sa' 'PASSWORD=secret'
    run bash -c 'cd "$1" && "$2"' _ "${TEST_TMP}" "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [ -f "${TMPDIR}/testdb-last.log" ]
    grep -q "Connecting to dbserver" "${TMPDIR}/testdb-last.log"
}
