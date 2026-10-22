#!/usr/bin/env bats

load test_helper

setup() {
    setup_isolated_env

    make_stub systemctl "printf 'systemctl %s\\n' \"\$*\" >> '${TEST_TMP}/systemctl.log'"

    # Run as root by default; individual tests override this to exercise the root check.
    # shellcheck disable=SC2329
    id() { echo "0"; }
    export -f id

    mkdir -p "${TEST_TMP}/units" "${TEST_TMP}/polkit"
    export UNIT_DIR="${TEST_TMP}/units"
    export POLKIT_RULES_DIR="${TEST_TMP}/polkit"

    unset CLAUDECODE
}

teardown() {
    cleanup_stubs
}

create_owner_units() {
    local name
    for name in credfeto-orchestrator-myorg-myorg.service \
        credfeto-orchestrator-myorg-myorg-failure.service \
        credfeto-orchestrator-myorg-myorg.timer; do
        printf '[Unit]\n' > "${TEST_TMP}/units/${name}"
    done
    printf 'polkit.addRule(function () {});\n' > "${POLKIT_RULES_DIR}/50-credfeto-orchestrator-myorg.rules"
}

@test "sourcing teardown-owner defines main without executing it" {
    source_teardown_owner
    run declare -F main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/systemctl.log" ]
}

@test "teardown-owner removes the owner's units and polkit rule" {
    create_owner_units

    run "${REPO_ROOT}/teardown-owner" --owner myorg
    [ "${status}" -eq 0 ]

    [ ! -e "${TEST_TMP}/units/credfeto-orchestrator-myorg-myorg.service" ]
    [ ! -e "${TEST_TMP}/units/credfeto-orchestrator-myorg-myorg-failure.service" ]
    [ ! -e "${TEST_TMP}/units/credfeto-orchestrator-myorg-myorg.timer" ]
    [ ! -e "${POLKIT_RULES_DIR}/50-credfeto-orchestrator-myorg.rules" ]
}

@test "teardown-owner stops and disables the timer, then reloads systemd" {
    create_owner_units

    run "${REPO_ROOT}/teardown-owner" --owner myorg
    [ "${status}" -eq 0 ]

    run cat "${TEST_TMP}/systemctl.log"
    [ "${lines[0]}" = "systemctl stop credfeto-orchestrator-myorg-myorg.timer" ]
    [ "${lines[1]}" = "systemctl disable credfeto-orchestrator-myorg-myorg.timer" ]
    [ "${lines[2]}" = "systemctl daemon-reload" ]
    [ "${#lines[@]}" -eq 3 ]
}

@test "teardown-owner leaves other owners' units, polkit rules, home and checkout in place" {
    create_owner_units
    printf '[Unit]\n' > "${TEST_TMP}/units/credfeto-orchestrator-other-other.service"
    printf 'rule\n' > "${POLKIT_RULES_DIR}/50-credfeto-orchestrator-other.rules"
    mkdir -p "${TEST_TMP}/home/myorg/credfeto-orchestrator"
    printf 'keep\n' > "${TEST_TMP}/home/myorg/credfeto-orchestrator/oneshot"

    run "${REPO_ROOT}/teardown-owner" --owner myorg
    [ "${status}" -eq 0 ]

    [ -f "${TEST_TMP}/units/credfeto-orchestrator-other-other.service" ]
    [ -f "${POLKIT_RULES_DIR}/50-credfeto-orchestrator-other.rules" ]
    [ -f "${TEST_TMP}/home/myorg/credfeto-orchestrator/oneshot" ]
}

@test "teardown-owner succeeds when the units were already removed" {
    run "${REPO_ROOT}/teardown-owner" --owner myorg
    [ "${status}" -eq 0 ]
    grep -q "systemctl daemon-reload" "${TEST_TMP}/systemctl.log"
}

@test "teardown-owner tolerates systemctl stop and disable failing" {
    create_owner_units
    make_stub systemctl "printf 'systemctl %s\\n' \"\$*\" >> '${TEST_TMP}/systemctl.log'; [ \"\$1\" = daemon-reload ]"

    run "${REPO_ROOT}/teardown-owner" --owner myorg
    [ "${status}" -eq 0 ]
    [ ! -e "${TEST_TMP}/units/credfeto-orchestrator-myorg-myorg.timer" ]
    grep -q "systemctl daemon-reload" "${TEST_TMP}/systemctl.log"
}

@test "teardown-owner dies when daemon-reload fails" {
    create_owner_units
    make_stub systemctl "printf 'systemctl %s\\n' \"\$*\" >> '${TEST_TMP}/systemctl.log'; [ \"\$1\" != daemon-reload ]"

    run "${REPO_ROOT}/teardown-owner" --owner myorg
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Failed to reload systemd daemon"* ]]
}

@test "teardown-owner dies when not run as root" {
    create_owner_units
    # shellcheck disable=SC2329
    id() { echo "1001"; }
    export -f id

    run "${REPO_ROOT}/teardown-owner" --owner myorg
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"must be run as root"* ]]
    [ -f "${TEST_TMP}/units/credfeto-orchestrator-myorg-myorg.service" ]
    [ ! -f "${TEST_TMP}/systemctl.log" ]
}

@test "teardown-owner dies inside a Claude Code session" {
    create_owner_units

    CLAUDECODE=1 run "${REPO_ROOT}/teardown-owner" --owner myorg
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"must not be run inside a Claude Code session"* ]]
    [ -f "${TEST_TMP}/units/credfeto-orchestrator-myorg-myorg.service" ]
    [ ! -f "${TEST_TMP}/systemctl.log" ]
}

@test "teardown-owner without --owner dies" {
    run "${REPO_ROOT}/teardown-owner"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"--owner is required"* ]]
}

@test "teardown-owner --owner with no value dies" {
    run "${REPO_ROOT}/teardown-owner" --owner
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"--owner requires a value"* ]]
}

@test "teardown-owner --owner with invalid characters dies" {
    create_owner_units

    run "${REPO_ROOT}/teardown-owner" --owner "../evil;cmd"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"invalid characters"* ]]
    [ ! -f "${TEST_TMP}/systemctl.log" ]
}

@test "teardown-owner with an unknown argument dies" {
    run "${REPO_ROOT}/teardown-owner" --owner myorg --unknown-flag
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Unknown argument"* ]]
}

@test "teardown-owner does not invoke sudo" {
    run bash -c "grep -v '^[[:space:]]*#' '${REPO_ROOT}/teardown-owner' | grep -n 'sudo'"
    [ "${status}" -ne 0 ]
}
