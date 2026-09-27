#!/usr/bin/env bats

# The ten workflow states that the Workflow board's built-in Status field carries (#1519) are
# written in three places: lib/project-status (the one definition the orchestrator and
# create-project use), _WF_STATUS_ORDER in lib/globals (the ordinal the forward-only PR mirror
# compares), and WORKFLOW_STATES in cfwf, which is copied alone into a container image and cannot
# source lib/. These tests are the only thing stopping the three drifting apart.

bats_require_minimum_version 1.5.0

load test_helper

CFWF="${REPO_ROOT}/containers/base/development-full/scripts/cfwf"

setup() {
    setup_isolated_env
    source_oneshot
}

teardown() {
    cleanup_stubs
}

# cfwf's list, one per line, run in a subshell so sourcing cfwf cannot replace this shell's own
# functions.
cfwf_states() {
    (
        # shellcheck source=/dev/null
        source "${CFWF}"
        printf '%s\n' "${WORKFLOW_STATES[@]}"
    )
}

@test "there are ten workflow states" {
    [ "$(project_status_names | wc -l)" -eq 10 ]
}

@test "cfwf lists the same workflow states as lib/project-status, in the same order (#1519)" {
    [ "$(cfwf_states)" = "$(project_status_names)" ]
}

@test "_WF_STATUS_ORDER lists the same workflow states as lib/project-status, in the same order (#1519)" {
    [ "$(printf '%s\n' "${_WF_STATUS_ORDER[@]}")" = "$(project_status_names)" ]
}
