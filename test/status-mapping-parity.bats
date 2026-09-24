#!/usr/bin/env bats

# cfwf is copied alone into a container image and cannot source lib/, so the mapping from a
# Workflow Status to the built-in Status (Todo / In Progress / Done) exists twice: builtin_status_for
# in cfwf and builtin_status_for_workflow_status in lib/workflow-board. These tests are the only
# thing stopping the two drifting apart.

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

# cfwf's mapping, run in a subshell so sourcing cfwf cannot replace this shell's own functions.
cfwf_mapping() {
    (
        # shellcheck source=/dev/null
        source "${CFWF}"
        builtin_status_for "$1"
    )
}

@test "the parity tests cover all ten Workflow Statuses" {
    [ "${#_WF_STATUS_ORDER[@]}" -eq 10 ]
}

@test "cfwf and the orchestrator choose the same built-in Status for every Workflow Status" {
    local name from_cfwf from_orchestrator
    for name in "${_WF_STATUS_ORDER[@]}"; do
        from_cfwf=$(cfwf_mapping "${name}")
        from_orchestrator=$(builtin_status_for_workflow_status "${name}")
        [ -n "${from_cfwf}" ]
        [ "${from_cfwf}" = "${from_orchestrator}" ]
    done
}

@test "cfwf and the orchestrator both give nothing for a status they do not know" {
    [ -z "$(cfwf_mapping "Custom Stage")" ]
    [ -z "$(builtin_status_for_workflow_status "Custom Stage")" ]
    [ -z "$(cfwf_mapping "")" ]
    [ -z "$(builtin_status_for_workflow_status "")" ]
}

@test "the mapping is Todo for Not Started and Planning, In Progress for Approved through Human Review, Done for Complete" {
    [ "$(cfwf_mapping "Not Started")" = "Todo" ]
    [ "$(cfwf_mapping "Planning")" = "Todo" ]
    [ "$(cfwf_mapping "Approved")" = "In Progress" ]
    [ "$(cfwf_mapping "Human Review")" = "In Progress" ]
    [ "$(cfwf_mapping "Complete")" = "Done" ]
}
