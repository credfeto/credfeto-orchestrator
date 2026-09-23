#!/usr/bin/env bats

load test_helper

SCRIPT="${REPO_ROOT}/containers/base/development-full/scripts/cfwf"

PROJECT_ID="PVT_proj"
FIELD_ID="PVTSSF_wf"
APPROVED_ID="63d36d28"
ISSUE_URL="https://github.com/credfeto/credfeto-orchestrator/issues/1346"

setup() {
    setup_isolated_env
    export GH_LOG="${TEST_TMP}/gh.log"
    export SLEEP_LOG="${TEST_TMP}/sleep.log"
    export GH_FIXTURES="${TEST_TMP}/fixtures"
    mkdir -p "${GH_FIXTURES}"

    # A gh stand-in that applies each call's --jq filter to a fixture with the real jq, so the
    # filters cfwf hands to gh are exercised against real-shaped JSON, not just recorded.
    # The stub body is deliberately single-quoted: it must expand when the stub runs, not here.
    # shellcheck disable=SC2016
    make_stub_multiline gh \
        'printf "%s\n" "$*" >> "${GH_LOG}"' \
        'jq_expr=""; prev=""' \
        'for arg in "$@"; do [ "${prev}" = "--jq" ] && jq_expr="${arg}"; prev="${arg}"; done' \
        'emit() { if [ -n "${jq_expr}" ]; then jq -r "${jq_expr}" < "$1"; else cat "$1"; fi; }' \
        'case "$1 $2" in' \
        '  "project field-list") emit "${GH_FIXTURES}/field-list.json" ;;' \
        '  "project item-add") [ -f "${GH_FIXTURES}/item-add.fail" ] && { echo "boom" >&2; exit 1; }; emit "${GH_FIXTURES}/item-add.json" ;;' \
        '  "project item-edit") [ -f "${GH_FIXTURES}/item-edit.fail" ] && { echo "boom" >&2; exit 1; }; exit 0 ;;' \
        '  "project item-list") n=$(( $(cat "${GH_FIXTURES}/item-list.count" 2>/dev/null || echo 0) + 1 )); echo "${n}" > "${GH_FIXTURES}/item-list.count"; f="${GH_FIXTURES}/item-list.${n}.json"; [ -f "${f}" ] || f="${GH_FIXTURES}/item-list.json"; emit "${f}" ;;' \
        '  "pr view") [ -f "${GH_FIXTURES}/pr-view.json" ] || exit 1; emit "${GH_FIXTURES}/pr-view.json" ;;' \
        '  "issue view") f="${GH_FIXTURES}/issue-view-$3.json"; [ -f "${f}" ] || exit 1; emit "${f}" ;;' \
        '  *) echo "gh stub: unexpected call: $*" >&2; exit 99 ;;' \
        'esac'
    # shellcheck disable=SC2016
    make_stub sleep 'printf "%s\n" "$*" >> "${SLEEP_LOG}"'

    jq -n '{fields: [
        {id: "PVTF_title", name: "Title", type: "ProjectV2Field"},
        {id: "PVTSSF_status", name: "Status", options: [{id: "f75ad846", name: "Todo"}], type: "ProjectV2SingleSelectField"},
        {id: "PVTSSF_wf", name: "Workflow Status", options: [{id: "c79045f6", name: "Planning"}, {id: "63d36d28", name: "Approved"}], type: "ProjectV2SingleSelectField"}
    ], totalCount: 3}' > "${GH_FIXTURES}/field-list.json"
    jq -n '{id: "PVTI_target"}' > "${GH_FIXTURES}/item-add.json"
    write_item_list "Approved"
}

teardown() {
    cleanup_stubs
}

# Writes an item-list fixture whose target item (issue 1346 of this repo) has the given status.
# Includes decoys that share the number in another repo, a PR, and an item with no status.
write_item_list() {
    local status="$1" file="${GH_FIXTURES}/${2:-item-list.json}"
    jq -n --arg s "${status}" '{items: [
        {id: "PVTI_other", content: {number: 1346, repository: "credfeto/other-repo", type: "Issue"}, "workflow Status": "Human Review"},
        {id: "PVTI_target", content: {number: 1346, repository: "credfeto/credfeto-orchestrator", type: "Issue"}, "workflow Status": $s},
        {id: "PVTI_pr", content: {number: 1481, repository: "credfeto/credfeto-orchestrator", type: "PullRequest"}, "workflow Status": "AI Review"},
        {id: "PVTI_nostatus", content: {number: 1500, repository: "credfeto/credfeto-orchestrator", type: "Issue"}}
    ]}' > "${file}"
}

set_args() {
    SET_ARGS=(workflow-status --set --owner credfeto --project-number 74 --project-id "${PROJECT_ID}"
        --field-id "${FIELD_ID}" --option-id "${APPROVED_ID}" --url "${ISSUE_URL}")
}

gh_call_count() {
    grep -cF "$1" "${GH_LOG}" || true
}

# --- help and usage ------------------------------------------------------------

@test "help, --help and -h print the usage listing every command and exit 0" {
    local flag
    for flag in help --help -h; do
        run "${SCRIPT}" "${flag}"
        [ "${status}" -eq 0 ]
        [[ "${output}" == *"Usage: cfwf <command>"* ]]
        [[ "${output}" == *"workflow-status --set"* ]]
        [[ "${output}" == *"workflow-status --check"* ]]
        [[ "${output}" == *"closing-issue-labels"* ]]
    done
}

@test "help <command> prints the usage of that command" {
    run "${SCRIPT}" help workflow-status
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"--project-number <n> --project-id <id>"* ]]

    run "${SCRIPT}" help closing-issue-labels
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"cfwf closing-issue-labels --repo <owner/repo> --pr <n>"* ]]
}

@test "a command's --help prints its usage and exits 0 without calling gh" {
    run "${SCRIPT}" workflow-status --help
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"cfwf workflow-status --set"* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "running with no arguments prints the usage to stderr and exits 2" {
    run "${SCRIPT}"
    [ "${status}" -eq 2 ]
    run bash -c '"$1" 2>&1 >/dev/null' _ "${SCRIPT}"
    [[ "${output}" == *"Usage: cfwf <command>"* ]]
    run bash -c '"$1" 2>/dev/null' _ "${SCRIPT}"
    [ -z "${output}" ]
}

@test "an unknown command exits 2 with the usage on stderr" {
    run bash -c '"$1" frobnicate 2>&1 >/dev/null; exit "${PIPESTATUS[0]}"' _ "${SCRIPT}"
    [[ "${output}" == *"unknown command: frobnicate"* ]]
    [[ "${output}" == *"Usage: cfwf <command>"* ]]
    run "${SCRIPT}" frobnicate
    [ "${status}" -eq 2 ]
}

@test "workflow-status without --set or --check exits 2" {
    run "${SCRIPT}" workflow-status --owner credfeto
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"needs --set or --check"* ]]
}

@test "workflow-status rejects --set together with --check" {
    run "${SCRIPT}" workflow-status --set --check
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"mutually exclusive"* ]]
}

@test "an unknown option and an option missing its value exit 2" {
    run "${SCRIPT}" workflow-status --set --bogus
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"unknown option: --bogus"* ]]

    run "${SCRIPT}" workflow-status --set --owner
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"--owner needs a value"* ]]
}

# --- workflow-status --set -----------------------------------------------------

@test "--set names the first missing required option and never calls gh" {
    run "${SCRIPT}" workflow-status --set --owner credfeto --project-number 74
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"missing required option --project-id"* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "--set rejects values that could alter the jq filters or the URL, without calling gh" {
    set_args
    local bad
    for bad in 'x") | .id #' 'has space' 'a;b' ''; do
        run "${SCRIPT}" workflow-status --set --owner credfeto --project-number 74 --project-id "${PROJECT_ID}" \
            --field-id "${FIELD_ID}" --option-id "${bad}" --url "${ISSUE_URL}"
        [ "${status}" -eq 2 ]
    done
    run "${SCRIPT}" workflow-status --set --owner credfeto --project-number 74 --project-id "${PROJECT_ID}" \
        --field-id "${FIELD_ID}" --option-id "${APPROVED_ID}" --url "https://example.com/credfeto/x/issues/1"
    [ "${status}" -eq 2 ]
    run "${SCRIPT}" workflow-status --set --owner 'cred/feto' --project-number 74 --project-id "${PROJECT_ID}" \
        --field-id "${FIELD_ID}" --option-id "${APPROVED_ID}" --url "${ISSUE_URL}"
    [ "${status}" -eq 2 ]
    run "${SCRIPT}" workflow-status --set --owner credfeto --project-number '74; rm' --project-id "${PROJECT_ID}" \
        --field-id "${FIELD_ID}" --option-id "${APPROVED_ID}" --url "${ISSUE_URL}"
    [ "${status}" -eq 2 ]
    [ ! -f "${GH_LOG}" ]
}

@test "--set adds the item, sets the field to the option, then reads it back" {
    set_args
    run "${SCRIPT}" "${SET_ARGS[@]}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"${ISSUE_URL} is now Approved"* ]]

    grep -qxF "project item-add 74 --owner credfeto --url ${ISSUE_URL} --format json --jq .id" "${GH_LOG}"
    grep -qxF "project item-edit --project-id ${PROJECT_ID} --id PVTI_target --field-id ${FIELD_ID} --single-select-option-id ${APPROVED_ID}" "${GH_LOG}"
    grep -qF "project item-list 74 --owner credfeto --format json -L 1000 " "${GH_LOG}"
}

@test "--set adds the item before editing it" {
    set_args
    run "${SCRIPT}" "${SET_ARGS[@]}"
    [ "${status}" -eq 0 ]
    local add_line edit_line
    add_line=$(grep -nF "project item-add" "${GH_LOG}" | head -1 | cut -d: -f1)
    edit_line=$(grep -nF "project item-edit" "${GH_LOG}" | head -1 | cut -d: -f1)
    [ "${add_line}" -lt "${edit_line}" ]
}

@test "--set reads the board with a limit above the default page size of 30" {
    set_args
    run "${SCRIPT}" "${SET_ARGS[@]}"
    [ "${status}" -eq 0 ]
    [ "$(gh_call_count "project item-list")" -ge 1 ]
    [ "$(gh_call_count "project item-list 74 --owner credfeto --format json -L 1000 ")" -eq "$(gh_call_count "project item-list")" ]
}

@test "--set retries the read-back with backoff until the value persists" {
    write_item_list "Planning" item-list.1.json
    write_item_list "Planning" item-list.2.json
    write_item_list "Approved" item-list.3.json
    set_args
    run "${SCRIPT}" "${SET_ARGS[@]}"
    [ "${status}" -eq 0 ]
    [ "$(gh_call_count "project item-list")" -eq 3 ]
    [ "$(cat "${SLEEP_LOG}")" = "$(printf '1\n2')" ]
}

@test "--set gives up after 3 read-back attempts and exits non-zero" {
    write_item_list "Planning"
    set_args
    run "${SCRIPT}" "${SET_ARGS[@]}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"did not persist after 3 attempts"* ]]
    [[ "${output}" == *"wanted 'Approved', last read 'Planning'"* ]]
    [ "$(gh_call_count "project item-list")" -eq 3 ]
}

@test "--set fails before writing anything when the option is not on the field" {
    set_args
    run "${SCRIPT}" workflow-status --set --owner credfeto --project-number 74 --project-id "${PROJECT_ID}" \
        --field-id "${FIELD_ID}" --option-id "deadbeef" --url "${ISSUE_URL}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"option deadbeef was not found"* ]]
    [ "$(gh_call_count "project item-add")" -eq 0 ]
    [ "$(gh_call_count "project item-edit")" -eq 0 ]
}

@test "--set does not edit when adding the item fails" {
    touch "${GH_FIXTURES}/item-add.fail"
    set_args
    run "${SCRIPT}" "${SET_ARGS[@]}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"could not add ${ISSUE_URL}"* ]]
    [ "$(gh_call_count "project item-edit")" -eq 0 ]
}

@test "--set exits non-zero and does not read back when the edit fails" {
    touch "${GH_FIXTURES}/item-edit.fail"
    set_args
    run "${SCRIPT}" "${SET_ARGS[@]}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"could not set the Workflow Status"* ]]
    [ "$(gh_call_count "project item-list")" -eq 0 ]
}

@test "--set refuses an unexpected item id rather than putting it in a jq filter" {
    jq -n '{id: "x\") | .id #"}' > "${GH_FIXTURES}/item-add.json"
    set_args
    run "${SCRIPT}" "${SET_ARGS[@]}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"unexpected item id"* ]]
    [ "$(gh_call_count "project item-edit")" -eq 0 ]
}

# --- workflow-status --check ---------------------------------------------------

@test "--check prints the status of the item in the named repo, ignoring the same number elsewhere" {
    run "${SCRIPT}" workflow-status --check --owner credfeto --project-number 74 \
        --repo credfeto/credfeto-orchestrator --issue 1346
    [ "${status}" -eq 0 ]
    [ "${output}" = "Approved" ]
}

@test "--check --pr finds a pull request item and --issue does not match it" {
    run "${SCRIPT}" workflow-status --check --owner credfeto --project-number 74 \
        --repo credfeto/credfeto-orchestrator --pr 1481
    [ "${status}" -eq 0 ]
    [ "${output}" = "AI Review" ]

    run "${SCRIPT}" workflow-status --check --owner credfeto --project-number 74 \
        --repo credfeto/credfeto-orchestrator --issue 1481
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"is not on project 74"* ]]
}

@test "--check exits non-zero when the item is not on the board" {
    run "${SCRIPT}" workflow-status --check --owner credfeto --project-number 74 \
        --repo credfeto/credfeto-orchestrator --pr 99999
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"credfeto/credfeto-orchestrator#99999 is not on project 74"* ]]
}

@test "--check reports (unset) for an item with no Workflow Status" {
    run "${SCRIPT}" workflow-status --check --owner credfeto --project-number 74 \
        --repo credfeto/credfeto-orchestrator --issue 1500
    [ "${status}" -eq 0 ]
    [ "${output}" = "(unset)" ]
}

@test "--check needs exactly one of --pr and --issue, and a repo" {
    run "${SCRIPT}" workflow-status --check --owner credfeto --project-number 74 --repo credfeto/credfeto-orchestrator
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"--pr or --issue"* ]]

    run "${SCRIPT}" workflow-status --check --owner credfeto --project-number 74 \
        --repo credfeto/credfeto-orchestrator --pr 1 --issue 2
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"mutually exclusive"* ]]

    run "${SCRIPT}" workflow-status --check --owner credfeto --project-number 74 --pr 1
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"missing required option --repo"* ]]
}

@test "--check reads the board with a limit above the default page size of 30" {
    run "${SCRIPT}" workflow-status --check --owner credfeto --project-number 74 \
        --repo credfeto/credfeto-orchestrator --pr 1481
    [ "${status}" -eq 0 ]
    grep -qF "project item-list 74 --owner credfeto --format json -L 1000 " "${GH_LOG}"
}

# --- closing-issue-labels ------------------------------------------------------

@test "closing-issue-labels prints the sorted, de-duplicated labels of every closing issue without Blocked or On-Hold" {
    jq -n '{closingIssuesReferences: [{number: 10}, {number: 11}]}' > "${GH_FIXTURES}/pr-view.json"
    jq -n '{labels: [{name: "Medium"}, {name: "AI-Work"}, {name: "Blocked"}]}' > "${GH_FIXTURES}/issue-view-10.json"
    jq -n '{labels: [{name: "AI-Work"}, {name: "Security"}, {name: "On-Hold"}]}' > "${GH_FIXTURES}/issue-view-11.json"

    run "${SCRIPT}" closing-issue-labels --repo credfeto/credfeto-orchestrator --pr 1481
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf 'AI-Work\nMedium\nSecurity')" ]
}

@test "closing-issue-labels does not exclude labels that merely contain Blocked or On-Hold" {
    jq -n '{closingIssuesReferences: [{number: 10}]}' > "${GH_FIXTURES}/pr-view.json"
    jq -n '{labels: [{name: "Blocked-by-upstream"}, {name: "Not-On-Hold"}]}' > "${GH_FIXTURES}/issue-view-10.json"

    run "${SCRIPT}" closing-issue-labels --repo credfeto/credfeto-orchestrator --pr 1481
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf 'Blocked-by-upstream\nNot-On-Hold')" ]
}

@test "closing-issue-labels prints nothing and exits 0 when the PR closes no issues" {
    jq -n '{closingIssuesReferences: []}' > "${GH_FIXTURES}/pr-view.json"
    run "${SCRIPT}" closing-issue-labels --repo credfeto/credfeto-orchestrator --pr 1481
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "closing-issue-labels warns about an issue it cannot read and still reports the others" {
    jq -n '{closingIssuesReferences: [{number: 10}, {number: 11}]}' > "${GH_FIXTURES}/pr-view.json"
    jq -n '{labels: [{name: "Medium"}]}' > "${GH_FIXTURES}/issue-view-11.json"

    run bash -c '"$1" closing-issue-labels --repo credfeto/credfeto-orchestrator --pr 1481 2>&1 >/dev/null' _ "${SCRIPT}"
    [[ "${output}" == *"could not fetch the labels of credfeto/credfeto-orchestrator#10"* ]]

    run bash -c '"$1" closing-issue-labels --repo credfeto/credfeto-orchestrator --pr 1481 2>/dev/null' _ "${SCRIPT}"
    [ "${output}" = "Medium" ]
}

@test "closing-issue-labels exits non-zero when the PR itself cannot be read" {
    run "${SCRIPT}" closing-issue-labels --repo credfeto/credfeto-orchestrator --pr 1481
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"could not read the closing issues of credfeto/credfeto-orchestrator#1481"* ]]
}

@test "closing-issue-labels requires --repo and --pr" {
    run "${SCRIPT}" closing-issue-labels --pr 1481
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"missing required option --repo"* ]]

    run "${SCRIPT}" closing-issue-labels --repo credfeto/credfeto-orchestrator
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"missing required option --pr"* ]]
}
