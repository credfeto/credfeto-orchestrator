#!/usr/bin/env bats
# shellcheck disable=SC2329  # functions in @test bodies are invoked indirectly via 'run'
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped

# Tests lib/project-status: converting a board's built-in Status field to the ten workflow states
# (#1519). A gh stub answers each GraphQL request (sent as a JSON body on stdin) from fixture
# files, and logs every request, so each test can check which steps ran and in what order.

load test_helper

setup() {
    setup_isolated_env
    # shellcheck source=../lib/core disable=SC1091
    source "${REPO_ROOT}/lib/core"
    export PROJECT_STATUS_READBACK_DELAY_SECS=0
    # shellcheck source=../lib/project-status disable=SC1091
    source "${REPO_ROOT}/lib/project-status"
    FIX="${TEST_TMP}/fixtures"
    mkdir -p "${FIX}"
    export FIX
    : > "${FIX}/gh.log"
    # The two item reads (before copying, and the read-back) are served from items-1.json and
    # items-2.json in turn.
    # shellcheck disable=SC2016  # the stub body expands at stub run time
    make_stub_multiline gh \
        'body=$(cat)' \
        'printf "%s\n" "${body}" >> "${FIX}/gh.log"' \
        'op=other' \
        'case "${body}" in' \
        '    *deleteProjectV2Workflow*) op=delete-workflow ;;' \
        '    *deleteProjectV2Field*) op=delete-field ;;' \
        '    *updateProjectV2ItemFieldValue*) op=set-item ;;' \
        '    *updateProjectV2Field*) op=update-field ;;' \
        '    *"items(first:100"*) op=items ;;' \
        '    *"fields(first:50)"*) op=project ;;' \
        'esac' \
        '[ ! -f "${FIX}/fail-${op}" ] || { printf "boom: %s\n" "${op}" >&2; exit 1; }' \
        '[ ! -f "${FIX}/gone-${op}" ] || { printf "{\"data\":null,\"errors\":[{\"type\":\"NOT_FOUND\",\"message\":\"Could not resolve to a node with the global id of '"'"'X'"'"'.\"}]}"; printf "gh: Could not resolve to a node with the global id of '"'"'X'"'"'.\n" >&2; exit 1; }' \
        'case "${op}" in' \
        '    project) cat "${FIX}/project.json" ;;' \
        '    update-field) cat "${FIX}/update-field.json" ;;' \
        '    items) n=$(( $(cat "${FIX}/items.count" 2>/dev/null || printf 0) + 1 )); printf "%s" "${n}" > "${FIX}/items.count"; f="${FIX}/items-${n}.json"; [ -f "${f}" ] || f=$(ls "${FIX}"/items-*.json | sort -V | tail -1); cat "${f}" ;;' \
        '    set-item) printf "{\"data\":{\"updateProjectV2ItemFieldValue\":{\"projectV2Item\":{\"id\":\"x\"}}}}" ;;' \
        '    delete-field) printf "{\"data\":{\"deleteProjectV2Field\":{\"projectV2Field\":{\"id\":\"x\"}}}}" ;;' \
        '    delete-workflow) printf "{\"data\":{\"deleteProjectV2Workflow\":{\"deletedWorkflowId\":\"x\"}}}" ;;' \
        '    *) exit 1 ;;' \
        'esac'
}

teardown() {
    cleanup_stubs
}

# The ten states as Status options with ids S0..S9, for a converted board.
all_states_json() {
    project_status_names | jq -R . | jq -sc 'to_entries | map({id: "S\(.key)", name: .value, color: "GRAY", description: ""})'
}

# Writes project.json: $1 the Status options, $2 the Workflow Status field or null, $3 the workflows.
write_project() {
    jq -cn --argjson s "$1" --argjson l "$2" --argjson w "$3" \
        '{data: {node: {fields: {nodes: ([{id: "F_STATUS", name: "Status", options: $s}] + (if $l == null then [] else [$l] end))}, workflows: {nodes: $w}}}}' \
        > "${FIX}/project.json"
}

# Writes items-N.json: $1 N, $2 a JSON array of [id, legacy, status] triples.
write_items() {
    jq -cn --argjson i "$2" '{data: {node: {items: {pageInfo: {hasNextPage: false, endCursor: null}, nodes: [$i[] | {id: .[0], legacy: (if .[1] == null then null else {name: .[1]} end), status: (if .[2] == null then null else {name: .[2]} end)}]}}}}' \
        > "${FIX}/items-$1.json"
}

# The response updateProjectV2Field returns: the ten states, keeping the old built-in ids.
write_update_result() {
    jq -cn --argjson s "$(all_states_json)" \
        '{data: {updateProjectV2Field: {projectV2Field: {id: "F_STATUS", name: "Status", options: ($s | map(if .name == "Not Started" then .id = "B_TODO" elif .name == "Development" then .id = "B_PROG" elif .name == "Complete" then .id = "B_DONE" else . end))}}}}' \
        > "${FIX}/update-field.json"
}

NEW_BOARD_STATUS='[{"id":"B_TODO","name":"Todo","color":"GREEN","description":"x"},{"id":"B_PROG","name":"In Progress","color":"YELLOW","description":"x"},{"id":"B_DONE","name":"Done","color":"PURPLE","description":"x"}]'
LEGACY_FIELD='{"id":"F_LEGACY","name":"Workflow Status","options":[{"id":"L1","name":"Approved"}]}'
PR_LINKED='[{"id":"W_ADD","name":"Item added to project","enabled":true},{"id":"W_LINK","name":"Pull request linked to issue","enabled":true}]'

@test "project_status_names lists the ten workflow states in board order" {
    run project_status_names
    [ "${status}" -eq 0 ]
    [ "${output}" = $'Not Started\nPlanning\nApproved\nDevelopment\nAI Simplify\nAI Review\nAI Security Review\nAI Coverage\nHuman Review\nComplete' ]
}

@test "project_status_is_converted is true only with all ten states, no Workflow Status field and no enabled PR-linked workflow" {
    local states
    states=$(all_states_json)
    project_status_is_converted "$(jq -cn --argjson s "${states}" '{status: {options: $s}, legacy: null, workflows: []}')"
    run project_status_is_converted "$(jq -cn --argjson s "${states}" --argjson l "${LEGACY_FIELD}" '{status: {options: $s}, legacy: $l, workflows: []}')"
    [ "${status}" -eq 1 ]
    run project_status_is_converted "$(jq -cn --argjson s "${states}" --argjson w "${PR_LINKED}" '{status: {options: $s}, legacy: null, workflows: $w}')"
    [ "${status}" -eq 1 ]
    run project_status_is_converted "$(jq -cn --argjson s "${NEW_BOARD_STATUS}" '{status: {options: $s}, legacy: null, workflows: []}')"
    [ "${status}" -eq 1 ]
}

@test "the options input renames Todo, In Progress and Done by id and adds the other seven, in board order (#1519)" {
    run _ps_options_input "$(jq -cn --argjson o "${NEW_BOARD_STATUS}" '{id: "F", options: $o}')"
    [ "${status}" -eq 0 ]
    [ "$(printf '%s' "${output}" | jq -r 'map(.name) | join(",")')" = "Not Started,Planning,Approved,Development,AI Simplify,AI Review,AI Security Review,AI Coverage,Human Review,Complete" ]
    [ "$(printf '%s' "${output}" | jq -r 'map(.id // "new") | join(",")')" = "B_TODO,new,new,B_PROG,new,new,new,new,new,B_DONE" ]
}

@test "the options input keeps an option that is not a workflow state, after the ten, and keeps an existing state's id and look (#1519)" {
    run _ps_options_input '{"id":"F","options":[{"id":"K1","name":"Planning","color":"RED","description":"mine"},{"id":"X1","name":"Banana","color":"YELLOW","description":"b"}]}'
    [ "${status}" -eq 0 ]
    [ "$(printf '%s' "${output}" | jq -c '.[1]')" = '{"id":"K1","name":"Planning","color":"RED","description":"mine"}' ]
    [ "$(printf '%s' "${output}" | jq -c '.[10]')" = '{"id":"X1","name":"Banana","color":"YELLOW","description":"b"}' ]
    [ "$(printf '%s' "${output}" | jq 'length')" -eq 11 ]
}

@test "project_status_convert converts a new project: renames and adds the options, deletes the PR-linked workflow, sets the field (#1519)" {
    write_project "${NEW_BOARD_STATUS}" null "${PR_LINKED}"
    write_update_result
    # Called directly, as the callers do, so the globals it sets are visible here.
    project_status_convert "P1" 2> /dev/null
    [ "$(printf '%s' "${PROJECT_STATUS_FIELD}" | jq -r '.id')" = "F_STATUS" ]
    [ "$(printf '%s' "${PROJECT_STATUS_FIELD}" | jq -r '[.options[] | select(.name == "Not Started") | .id] | first')" = "B_TODO" ]
    [ -z "${PROJECT_STATUS_FAILED_STEP}" ]
    grep -q 'updateProjectV2Field(' "${FIX}/gh.log"
    grep -q '"w":"W_LINK"' "${FIX}/gh.log"
    [ "$(grep -c 'W_ADD' "${FIX}/gh.log")" -eq 0 ]
    [ "$(grep -c 'deleteProjectV2Field' "${FIX}/gh.log")" -eq 0 ]
}

@test "project_status_convert on a converted board makes one read and no change (#1519)" {
    write_project "$(all_states_json)" null '[{"id":"W_ADD","name":"Item added to project","enabled":true}]'
    project_status_convert "P1" 2> /dev/null
    [ "$(wc -l < "${FIX}/gh.log")" -eq 1 ]
    [ "$(printf '%s' "${PROJECT_STATUS_FIELD}" | jq -r '.options | length')" -eq 10 ]
}

@test "project_status_convert keeps the failed step when the option update, run in a subshell, is refused (#1519)" {
    write_project "${NEW_BOARD_STATUS}" null '[]'
    touch "${FIX}/fail-update-field"
    project_status_convert "P1" 2> /dev/null || true
    [ "${PROJECT_STATUS_FAILED_STEP}" = "renaming and adding the Status options" ]
    [ -z "${PROJECT_STATUS_FIELD}" ]
}

@test "project_status_convert copies Workflow Status values onto Status and only then deletes the old field (#1519)" {
    write_project "${NEW_BOARD_STATUS}" "${LEGACY_FIELD}" "${PR_LINKED}"
    write_update_result
    write_items 1 '[["I1","Approved","Not Started"],["I2",null,"Not Started"],["I3","Complete","Complete"]]'
    write_items 2 '[["I1","Approved","Approved"],["I2",null,"Not Started"],["I3","Complete","Complete"]]'
    run --separate-stderr project_status_convert "P1"
    [ "${status}" -eq 0 ]
    # Only I1 differed, so only it is set.
    [ "$(grep -c 'updateProjectV2ItemFieldValue' "${FIX}/gh.log")" -eq 1 ]
    grep -q '"i":"I1"' "${FIX}/gh.log"
    # The field is deleted after the read-back (the second items read).
    [ "$(grep -n 'deleteProjectV2Field' "${FIX}/gh.log" | cut -d: -f1)" -gt "$(grep -n 'items(first:100' "${FIX}/gh.log" | tail -1 | cut -d: -f1)" ]
    grep -q '"f":"F_LEGACY"' "${FIX}/gh.log"
}

@test "project_status_convert keeps the Workflow Status field when a value does not read back, and names the step (#1519)" {
    write_project "$(all_states_json)" "${LEGACY_FIELD}" '[]'
    write_items 1 '[["I1","Approved","Not Started"]]'
    write_items 2 '[["I1","Approved","Not Started"]]'
    run --separate-stderr project_status_convert "P1"
    [ "${status}" -eq 1 ]
    [ "$(grep -c 'deleteProjectV2Field' "${FIX}/gh.log")" -eq 0 ]
    [[ "${stderr}" == *"checking the copied values"* ]]
}

@test "project_status_convert reads the copied values back again when GitHub still shows the old ones, then deletes the old field (#1519)" {
    # Seen on the credfeto/scratch canary: a read straight after the copy still returned the values
    # from before it, because GitHub's reads lag its writes.
    write_project "$(all_states_json)" "${LEGACY_FIELD}" '[]'
    write_items 1 '[["I1","Approved","Not Started"]]'
    write_items 2 '[["I1","Approved","Not Started"]]'
    write_items 3 '[["I1","Approved","Approved"]]'
    run --separate-stderr project_status_convert "P1"
    [ "${status}" -eq 0 ]
    [ "$(grep -c 'items(first:100' "${FIX}/gh.log")" -eq 3 ]
    grep -q '"f":"F_LEGACY"' "${FIX}/gh.log"
    # Each wait says what it is waiting for, so a pause in the log is explained.
    [[ "${stderr}" == *"for GitHub to show the copied values (read 1 of 5 still differs)"* ]]
}

@test "the read-back waits 15 seconds between reads by default (#1519)" {
    run bash -c 'unset PROJECT_STATUS_READBACK_DELAY_SECS; source "$1"; source "$2"; printf "%s" "${PROJECT_STATUS_READBACK_DELAY_SECS}"' _ "${REPO_ROOT}/lib/core" "${REPO_ROOT}/lib/project-status"
    [ "${output}" = "15" ]
}

@test "project_status_convert gives up after PROJECT_STATUS_READBACK_ATTEMPTS reads that still differ (#1519)" {
    # shellcheck disable=SC2034  # read by lib/project-status
    PROJECT_STATUS_READBACK_ATTEMPTS=3
    write_project "$(all_states_json)" "${LEGACY_FIELD}" '[]'
    write_items 1 '[["I1","Approved","Not Started"]]'
    run --separate-stderr project_status_convert "P1"
    [ "${status}" -eq 1 ]
    # One read before copying, then three read-backs.
    [ "$(grep -c 'items(first:100' "${FIX}/gh.log")" -eq 4 ]
    [[ "${stderr}" == *"after 3 read(s)"* ]]
    [ "$(grep -c 'deleteProjectV2Field' "${FIX}/gh.log")" -eq 0 ]
}

@test "project_status_convert keeps the Workflow Status field when an item's value is not a workflow state (#1519)" {
    write_project "$(all_states_json)" "${LEGACY_FIELD}" '[]'
    write_items 1 '[["I1","Banana",null]]'
    run --separate-stderr project_status_convert "P1"
    [ "${status}" -eq 1 ]
    [ "$(grep -c 'deleteProjectV2Field' "${FIX}/gh.log")" -eq 0 ]
    [ "$(grep -c 'updateProjectV2ItemFieldValue' "${FIX}/gh.log")" -eq 0 ]
    [[ "${stderr}" == *'"Banana", which is not a Status option'* ]]
}

@test "project_status_convert reports the step and makes no later change when the option update is refused (#1519)" {
    write_project "${NEW_BOARD_STATUS}" "${LEGACY_FIELD}" "${PR_LINKED}"
    touch "${FIX}/fail-update-field"
    run --separate-stderr project_status_convert "P1"
    [ "${status}" -eq 1 ]
    [[ "${stderr}" == *"renaming and adding the Status options"* ]]
    [[ "${stderr}" == *"boom: update-field"* ]]
    [ "$(grep -c 'items(first:100\|deleteProjectV2' "${FIX}/gh.log")" -eq 0 ]
}

@test "project_status_convert treats a field or workflow GitHub no longer finds as already deleted (#1519)" {
    # Seen on the credfeto/scratch canary: a read shortly after a conversion still listed the deleted
    # Workflow Status field, so a re-run tried to delete it again.
    write_project "$(all_states_json)" "${LEGACY_FIELD}" "${PR_LINKED}"
    write_items 1 '[["I1","Approved","Approved"]]'
    touch "${FIX}/gone-delete-field" "${FIX}/gone-delete-workflow"
    project_status_convert "P1" 2> /dev/null
    [ -z "${PROJECT_STATUS_FAILED_STEP}" ]
    [ "$(printf '%s' "${PROJECT_STATUS_FIELD}" | jq -r '.id')" = "F_STATUS" ]
}

@test "project_status_convert still fails on any other refusal of a delete (#1519)" {
    write_project "$(all_states_json)" "${LEGACY_FIELD}" '[]'
    write_items 1 '[["I1","Approved","Approved"]]'
    touch "${FIX}/fail-delete-field"
    run --separate-stderr project_status_convert "P1"
    [ "${status}" -eq 1 ]
    [[ "${stderr}" == *"boom: delete-field"* ]]
    [[ "${stderr}" == *"deleting the Workflow Status field"* ]]
}

@test "project_status_convert sets PROJECT_STATUS_FAILED_STEP for the caller's message (#1519)" {
    write_project "$(all_states_json)" null "${PR_LINKED}"
    touch "${FIX}/fail-delete-workflow"
    project_status_convert "P1" > /dev/null 2>&1 || true
    [ "${PROJECT_STATUS_FAILED_STEP}" = 'deleting the "Pull request linked to issue" workflow' ]
}

@test "project_status_convert fails when the project has no built-in Status field (#1519)" {
    printf '%s' '{"data":{"node":{"fields":{"nodes":[]},"workflows":{"nodes":[]}}}}' > "${FIX}/project.json"
    run --separate-stderr project_status_convert "P1"
    [ "${status}" -eq 1 ]
    [[ "${stderr}" == *"no built-in Status field"* ]]
}

@test "project_status_convert treats a response that carries errors as a failure (#1519)" {
    write_project "${NEW_BOARD_STATUS}" null '[]'
    printf '%s' '{"data":{"updateProjectV2Field":null},"errors":[{"message":"Resource not accessible"}]}' > "${FIX}/update-field.json"
    run --separate-stderr project_status_convert "P1"
    [ "${status}" -eq 1 ]
    [[ "${stderr}" == *"Resource not accessible"* ]]
}

@test "the item read pages through every page of a large board (#1519)" {
    printf '%s' '{"data":{"node":{"items":{"pageInfo":{"hasNextPage":true,"endCursor":"C1"},"nodes":[{"id":"I1","legacy":null,"status":null}]}}}}' > "${FIX}/items-1.json"
    printf '%s' '{"data":{"node":{"items":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"I2","legacy":null,"status":null}]}}}}' > "${FIX}/items-2.json"
    run _ps_read_items "P1"
    [ "${status}" -eq 0 ]
    [ "$(printf '%s\n' "${output}" | jq -rs 'map(.id) | join(",")')" = "I1,I2" ]
    grep -q '"c":"C1"' "${FIX}/gh.log"
}
