#!/usr/bin/env bats
# shellcheck disable=SC2154  # stderr is set by run --separate-stderr

bats_require_minimum_version 1.5.0

load test_helper

SCRIPT="${REPO_ROOT}/containers/base/development-full/scripts/cfwf"

REPO="credfeto/credfeto-orchestrator"
ISSUE_URL="https://github.com/credfeto/credfeto-orchestrator/issues/1346"

setup() {
    setup_isolated_env
    export GH_LOG="${TEST_TMP}/gh.log"
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
        '  "repo view") case " $* " in *" --json visibility "*) v="${3,,}"; f="${GH_FIXTURES}/visibility-${v//\//_}"; [ -f "${f}.fail" ] && { echo "HTTP 502: Bad Gateway" >&2; exit 1; }; [ -f "${f}.json" ] || { echo "GraphQL: Could not resolve to a Repository with the name ${3}. (repository)" >&2; exit 1; }; emit "${f}.json"; exit 0 ;; esac; [ -f "${GH_FIXTURES}/repo-view.fail" ] && { echo "boom" >&2; exit 1; }; emit "${GH_FIXTURES}/repo-view.json" ;;' \
        '  "project field-list") emit "${GH_FIXTURES}/field-list.json" ;;' \
        '  "project item-add") [ -f "${GH_FIXTURES}/item-add.fail" ] && { echo "boom" >&2; exit 1; }; emit "${GH_FIXTURES}/item-add.json" ;;' \
        '  "project item-edit") [ -f "${GH_FIXTURES}/item-edit.fail" ] && { echo "boom" >&2; exit 1; }; exit 0 ;;' \
        '  "project item-list") [ -f "${GH_FIXTURES}/item-list.fail" ] && { echo "boom" >&2; exit 1; }; emit "${GH_FIXTURES}/item-list.json" ;;' \
        '  "api graphql") [ -f "${GH_FIXTURES}/graphql.fail" ] && { cat "${GH_FIXTURES}/graphql.fail" >&2; exit 1; }; [ -f "${GH_FIXTURES}/graphql.failout" ] && { cat "${GH_FIXTURES}/graphql.failout"; exit 1; }; [ -f "${GH_FIXTURES}/graphql.stderr" ] && cat "${GH_FIXTURES}/graphql.stderr" >&2; emit "${GH_FIXTURES}/graphql-target.json" ;;' \
        '  "pr view") [ -f "${GH_FIXTURES}/pr-view.json" ] || exit 1; emit "${GH_FIXTURES}/pr-view.json" ;;' \
        '  "label list") [ -f "${GH_FIXTURES}/label-list.fail" ] && { echo "boom" >&2; exit 1; }; emit "${GH_FIXTURES}/label-list.json" ;;' \
        '  "label create") [ -f "${GH_FIXTURES}/label-create.fail" ] && { cat "${GH_FIXTURES}/label-create.fail" >&2; exit 1; }; exit 0 ;;' \
        '  "issue create") prev=""; for arg in "$@"; do [ "${prev}" = "--body-file" ] && cp "${arg}" "${GH_FIXTURES}/issue-body.txt"; prev="${arg}"; done; [ -f "${GH_FIXTURES}/issue-create.fail" ] && { echo "boom" >&2; exit 1; }; cat "${GH_FIXTURES}/issue-create.out" ;;' \
        '  "issue view") f="${GH_FIXTURES}/issue-view-$3.json"; [ -f "${f}" ] || exit 1; emit "${f}" ;;' \
        '  *) echo "gh stub: unexpected call: $*" >&2; exit 99 ;;' \
        'esac'

    write_repo_view "/users/credfeto/projects/74"
    write_field_list
    jq -n '{id: "PVTI_target"}' > "${GH_FIXTURES}/item-add.json"
    write_item_list "Approved"
    write_graphql_target
}

teardown() {
    cleanup_stubs
}

# Writes the repo's linked-projects fixture: the Workflow project at the given path, plus a
# decoy project that is not titled Workflow.
write_repo_view() {
    jq -n --arg path "$1" '{projectsV2: {Nodes: [
        {id: "PVT_other", title: "Roadmap", number: 9, resourcePath: "/users/credfeto/projects/9", closed: false},
        {id: "PVT_proj", title: "Workflow", number: ($path | capture("/projects/(?<n>[0-9]+)$").n | tonumber), resourcePath: $path, closed: false}
    ]}}' > "${GH_FIXTURES}/repo-view.json"
}

# Writes the pr-view fixture: each argument is "owner/repo number" for one closing issue.
write_pr_view() {
    local ref
    for ref in "$@"; do
        jq -n --arg repo "${ref% *}" --arg number "${ref#* }" \
            '{repository: {owner: {login: ($repo | split("/")[0])}, name: ($repo | split("/")[1])}, number: ($number | tonumber)}'
    done | jq -s '{closingIssuesReferences: .}' > "${GH_FIXTURES}/pr-view.json"
}

# The ten workflow states, in board order, one per line.
workflow_states() {
    printf '%s\n' "Not Started" Planning Approved Development "AI Simplify" "AI Review" "AI Security Review" "AI Coverage" "Human Review" Complete
}

# Writes the field-list fixture for a converted board (#1519): the built-in Status field
# (PVTSSF_status) carries the ten workflow states with ids st_1 to st_10 in board order, so Approved
# is st_3 and AI Security Review st_7, and there is no Workflow Status field.
write_field_list() {
    workflow_states | jq -R -s '[split("\n")[:-1] | to_entries[] | {id: ("st_" + (.key + 1 | tostring)), name: .value}]' > "${GH_FIXTURES}/st-options.json"
    jq -n --slurpfile st "${GH_FIXTURES}/st-options.json" '{fields: [
        {id: "PVTF_title", name: "Title", type: "ProjectV2Field"},
        {id: "PVTSSF_status", name: "Status", options: $st[0], type: "ProjectV2SingleSelectField"}
    ], totalCount: 2}' > "${GH_FIXTURES}/field-list.json"
}

# Writes the field-list fixture for a board not converted yet: the built-in Status field still has
# Todo, In Progress and Done, and the old Workflow Status field (PVTSSF_wf) carries the ten states
# with ids wf_1 to wf_10 in board order.
write_legacy_field_list() {
    workflow_states | jq -R -s '[split("\n")[:-1] | to_entries[] | {id: ("wf_" + (.key + 1 | tostring)), name: .value}]' > "${GH_FIXTURES}/wf-options.json"
    jq -n --slurpfile wf "${GH_FIXTURES}/wf-options.json" '{fields: [
        {id: "PVTF_title", name: "Title", type: "ProjectV2Field"},
        {id: "PVTSSF_status", name: "Status", options: [{id: "b_todo", name: "Todo"}, {id: "b_progress", name: "In Progress"}, {id: "b_done", name: "Done"}], type: "ProjectV2SingleSelectField"},
        {id: "PVTSSF_wf", name: "Workflow Status", options: $wf[0], type: "ProjectV2SingleSelectField"}
    ], totalCount: 3}' > "${GH_FIXTURES}/field-list.json"
}

# Writes an item-list fixture for a converted board whose target item (issue 1346 of this repo) has
# the given status. Includes decoys that share the number in another repo, a PR, an item with no
# status and a draft item.
write_item_list() {
    local status="$1" file="${GH_FIXTURES}/item-list.json"
    jq -n --arg s "${status}" '{items: [
        {id: "PVTI_other", content: {number: 1346, repository: "credfeto/other-repo", type: "Issue"}, status: "Human Review"},
        {id: "PVTI_target", content: {number: 1346, repository: "credfeto/credfeto-orchestrator", type: "Issue"}, status: $s},
        {id: "PVTI_pr", content: {number: 1481, repository: "credfeto/credfeto-orchestrator", type: "PullRequest"}, status: "AI Review"},
        {id: "PVTI_nostatus", content: {number: 1500, repository: "credfeto/credfeto-orchestrator", type: "Issue"}},
        {id: "PVTI_draft", content: {type: "DraftIssue", title: "an idea with no repository"}}
    ]}' > "${file}"
}

# Writes the answer to the by-number query for an issue and for a pull request on a converted board.
# Each has an item on a decoy project as well as one on the Workflow project (PVT_proj), so the
# project filter matters.
write_graphql_target() {
    jq -n '{data: {repository: {
        issue: {projectItems: {nodes: [
            {project: {id: "PVT_other"}, legacy: null, status: {name: "Human Review"}},
            {project: {id: "PVT_proj"}, legacy: null, status: {name: "Approved"}}]}},
        pullRequest: {projectItems: {nodes: [
            {project: {id: "PVT_proj"}, legacy: null, status: {name: "AI Review"}}]}}}}}' > "${GH_FIXTURES}/graphql-target.json"
}

# Writes the by-number answer for issue 1346 on the Workflow project, with the given Workflow Status
# and built-in Status values ("null" for none): the item of a board not converted yet.
write_graphql_item() {
    jq -n --argjson legacy "$1" --argjson status "$2" \
        '{data: {repository: {issue: {projectItems: {nodes: [{project: {id: "PVT_proj"}, legacy: $legacy, status: $status}]}}}}}' \
        > "${GH_FIXTURES}/graphql-target.json"
}

# Makes every gh api graphql call fail with the given error text, so cfwf falls back to listing the board.
use_fallback() {
    printf '%s\n' "${1:-GraphQL: something went wrong}" > "${GH_FIXTURES}/graphql.fail"
}

set_args() {
    SET_ARGS=(workflow-status --set --repo "${REPO}" --issue 1346 --status Approved)
}

gh_call_count() {
    grep -cF -- "$1" "${GH_LOG}" || true
}

gh_line_of() {
    grep -nF -- "$1" "${GH_LOG}" | head -1 | cut -d: -f1
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
        [[ "${output}" == *"issue create"* ]]
        [[ "${output}" == *"body check"*"exit 8 when refused"* ]]
    done
}

@test "help <command> prints the usage of that command" {
    run "${SCRIPT}" help workflow-status
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"--repo <owner/repo> (--pr <n> | --issue <n>) --status <name>"* ]]

    run "${SCRIPT}" help closing-issue-labels
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"cfwf closing-issue-labels --repo <owner/repo> --pr <n>"* ]]

    run "${SCRIPT}" help issue
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"cfwf issue create --repo <owner/repo> --priority <priority> --title <title> --body-file <file> [--label <label> ...]"* ]]
    [[ "${output}" == *"there is no --status"* ]]
    [[ "${output}" == *"a bad call leaves no issue behind"* ]]
    [[ "${output}" == *"The body is checked for leaks"* ]]
    [[ "${output}" == *"A refused body exits 8"* ]]

    run "${SCRIPT}" help body
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"cfwf body check --repo <owner/repo> --body-file <file|->"* ]]
    [[ "${output}" == *"and exits 8"* ]]
    [[ "${output}" == *"CFWF_PRIVATE_OWNERS"* ]]
    [[ "${output}" == *"There is no option to skip"*"the check."* ]]
}

@test "the workflow-status help states that --set does not read back, the fallback listing limit and the GraphQL exception" {
    run "${SCRIPT}" help workflow-status
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"The fallback listing reads at most 10000 items."* ]]
    [[ "${output}" == *"does not"*"read the value back"* ]]
    [[ "${output}" == *"Do not poll or repeat the write"* ]]
    [[ "${output}" == *"read-only GraphQL query for the single item"* ]]
    [[ "${output}" == *"write uses native gh project commands"* ]]
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
    run "${SCRIPT}" workflow-status --repo "${REPO}"
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

    run "${SCRIPT}" workflow-status --set --repo
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"--repo needs a value"* ]]
}

@test "the board ids and the URL are not options any more: they are derived from --repo and --status" {
    local flag
    for flag in --owner --project-number --project-id --field-id --option-id --url; do
        run "${SCRIPT}" workflow-status --set --repo "${REPO}" --issue 1346 --status Approved "${flag}" value
        [ "${status}" -eq 2 ] || { echo "${flag} was accepted" >&2; return 1; }
        [[ "${output}" == *"unknown option: ${flag}"* ]]
    done
    [ ! -f "${GH_LOG}" ]
}

# --- workflow-status --set -----------------------------------------------------

@test "--set needs --repo, --status and exactly one of --pr and --issue, and never calls gh without them" {
    run "${SCRIPT}" workflow-status --set --issue 1346 --status Approved
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"missing required option --repo"* ]]

    run "${SCRIPT}" workflow-status --set --repo "${REPO}" --issue 1346
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"missing required option --status"* ]]

    run "${SCRIPT}" workflow-status --set --repo "${REPO}" --status Approved
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"--pr or --issue"* ]]

    run "${SCRIPT}" workflow-status --set --repo "${REPO}" --pr 1 --issue 2 --status Approved
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"mutually exclusive"* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "--set rejects values that could alter a jq filter or a URL, without calling gh" {
    local bad
    for bad in 'not-a-repo' 'a/b/c' 'cred feto/x' 'credfeto/x;y' ''; do
        run "${SCRIPT}" workflow-status --set --repo "${bad}" --issue 1346 --status Approved
        [ "${status}" -eq 2 ]
    done
    for bad in '13x46' '' '1;2'; do
        run "${SCRIPT}" workflow-status --set --repo "${REPO}" --issue "${bad}" --status Approved
        [ "${status}" -eq 2 ]
    done
    for bad in '' $'has\ttab' $'has\nnewline'; do
        run "${SCRIPT}" workflow-status --set --repo "${REPO}" --issue 1346 --status "${bad}"
        [ "${status}" -eq 2 ]
    done
    [ ! -f "${GH_LOG}" ]
}

@test "--set treats a status full of jq or shell characters as just an unknown name, and writes nothing" {
    # shellcheck disable=SC2016  # literal characters: proving they are never interpreted
    run "${SCRIPT}" workflow-status --set --repo "${REPO}" --issue 1346 --status 'x") | .id # $(id)'
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"unknown status"* ]]
    [ "$(gh_call_count "project item-add")" -eq 0 ]
    [ "$(gh_call_count "project item-edit")" -eq 0 ]
}

@test "--set refuses an option the board has that is not a workflow state, and writes nothing (#1519)" {
    jq -n '{fields: [{id: "PVTSSF_status", name: "Status", options: [
        {id: "st_3", name: "Approved"}, {id: "x1", name: "Banana"}], type: "ProjectV2SingleSelectField"}]}' > "${GH_FIXTURES}/field-list.json"
    run "${SCRIPT}" workflow-status --set --repo "${REPO}" --issue 1346 --status banana
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"unknown status 'banana'"* ]]
    [ "$(gh_call_count "project item-add")" -eq 0 ]
}

@test "--set reads the project's fields with a limit above the default page size of 30" {
    set_args
    run "${SCRIPT}" "${SET_ARGS[@]}"
    [ "${status}" -eq 0 ]
    grep -qF "project field-list 74 --owner credfeto --format json -L 100 " "${GH_LOG}"
}

@test "--set finds the board from the repo, adds the item and sets the status" {
    set_args
    run "${SCRIPT}" "${SET_ARGS[@]}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == "Set ${ISSUE_URL} to Approved" ]]

    grep -qF "repo view ${REPO} --json projectsV2 " "${GH_LOG}"
    grep -qF "project field-list 74 --owner credfeto --format json " "${GH_LOG}"
    grep -qxF "project item-add 74 --owner credfeto --url ${ISSUE_URL} --format json --jq .id" "${GH_LOG}"
    grep -qxF "project item-edit --project-id PVT_proj --id PVTI_target --field-id PVTSSF_status --single-select-option-id st_3" "${GH_LOG}"
}

@test "--set never reads the board back: no query and no listing after the write" {
    set_args
    run "${SCRIPT}" "${SET_ARGS[@]}"
    [ "${status}" -eq 0 ]
    [ "$(gh_call_count "api graphql")" -eq 0 ]
    [ "$(gh_call_count "project item-list")" -eq 0 ]
}

@test "no gh api graphql call ever carries a mutation" {
    run "${SCRIPT}" workflow-status --check --repo "${REPO}" --issue 1346
    [ "${status}" -eq 0 ]
    [ "$(gh_call_count "api graphql")" -eq 1 ]
    [ "$(gh_call_count "mutation")" -eq 0 ]
}

@test "--set resolves the board, adds the item, sets the Status, and that is the last gh call" {
    set_args
    run "${SCRIPT}" "${SET_ARGS[@]}"
    [ "${status}" -eq 0 ]
    local repo_view field_list add edit
    repo_view=$(gh_line_of "repo view")
    field_list=$(gh_line_of "project field-list")
    add=$(gh_line_of "project item-add")
    edit=$(gh_line_of "--field-id PVTSSF_status ")
    [ "${repo_view}" -lt "${field_list}" ]
    [ "${field_list}" -lt "${add}" ]
    [ "${add}" -lt "${edit}" ]
    [ "${edit}" -eq "$(wc -l < "${GH_LOG}")" ]
    [ "$(gh_call_count "project item-edit")" -eq 1 ]
}

@test "--set sets each of the ten workflow states on the built-in Status of a converted board, with one write (#1519)" {
    local name n=0
    while IFS= read -r name; do
        n=$((n + 1))
        : > "${GH_LOG}"
        run --separate-stderr "${SCRIPT}" workflow-status --set --repo "${REPO}" --issue 1346 --status "${name}"
        [ "${status}" -eq 0 ]
        [ "${output}" = "Set ${ISSUE_URL} to ${name}" ]
        [ -z "${stderr}" ]
        grep -qxF "project item-edit --project-id PVT_proj --id PVTI_target --field-id PVTSSF_status --single-select-option-id st_${n}" "${GH_LOG}"
        [ "$(gh_call_count "project item-edit")" -eq 1 ]
    done < <(workflow_states)
}

@test "--set writes to the Workflow Status field of a board not converted yet, never to its built-in Status (#1519)" {
    write_legacy_field_list
    local name n=0
    while IFS= read -r name; do
        n=$((n + 1))
        : > "${GH_LOG}"
        run --separate-stderr "${SCRIPT}" workflow-status --set --repo "${REPO}" --issue 1346 --status "${name}"
        [ "${status}" -eq 0 ]
        grep -qxF "project item-edit --project-id PVT_proj --id PVTI_target --field-id PVTSSF_wf --single-select-option-id wf_${n}" "${GH_LOG}"
        [ "$(gh_call_count "--field-id PVTSSF_status ")" -eq 0 ]
    done < <(workflow_states)
}

@test "--set writes the Workflow Status field while the board still has it, even when Status already has the state (#1519)" {
    # A board whose conversion stopped after renaming Status but before deleting Workflow Status:
    # --check reads Workflow Status and the next conversion copies it onto Status, so a write to
    # Status alone would be invisible and then overwritten.
    write_legacy_field_list
    jq --slurpfile st "${GH_FIXTURES}/wf-options.json" \
        '.fields |= map(if .name == "Status" then .options = ($st[0] | map(.id |= sub("^wf_"; "st_"))) else . end)' \
        "${GH_FIXTURES}/field-list.json" > "${GH_FIXTURES}/field-list.tmp" && mv "${GH_FIXTURES}/field-list.tmp" "${GH_FIXTURES}/field-list.json"
    set_args
    run "${SCRIPT}" "${SET_ARGS[@]}"
    [ "${status}" -eq 0 ]
    grep -qxF "project item-edit --project-id PVT_proj --id PVTI_target --field-id PVTSSF_wf --single-select-option-id wf_3" "${GH_LOG}"
    [ "$(gh_call_count "project item-edit")" -eq 1 ]
}

@test "--set fails, writing nothing, when the board's Workflow Status field lacks the state (#1519)" {
    jq -n '{fields: [
        {id: "PVTSSF_status", name: "Status", options: [{id: "st_3", name: "Approved"}], type: "ProjectV2SingleSelectField"},
        {id: "PVTSSF_wf", name: "Workflow Status", options: [{id: "wf_2", name: "Planning"}], type: "ProjectV2SingleSelectField"}]}' > "${GH_FIXTURES}/field-list.json"
    set_args
    run "${SCRIPT}" "${SET_ARGS[@]}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"has no 'Approved' option on its Workflow Status field"* ]]
    [ "$(gh_call_count "project item-add")" -eq 0 ]
}

@test "--set says which field it could not write when the write fails (#1519)" {
    touch "${GH_FIXTURES}/item-edit.fail"
    set_args
    run "${SCRIPT}" "${SET_ARGS[@]}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"could not set the Status of ${ISSUE_URL}"* ]]
}

@test "--set ignores a field named Status that has no options, and uses the Workflow Status field" {
    jq -n '{fields: [
        {id: "PVTF_text", name: "Status", type: "ProjectV2Field"},
        {id: "PVTSSF_wf", name: "Workflow Status", options: [{id: "wf_3", name: "Approved"}], type: "ProjectV2SingleSelectField"}]}' > "${GH_FIXTURES}/field-list.json"
    set_args
    run "${SCRIPT}" "${SET_ARGS[@]}"
    [ "${status}" -eq 0 ]
    grep -qxF "project item-edit --project-id PVT_proj --id PVTI_target --field-id PVTSSF_wf --single-select-option-id wf_3" "${GH_LOG}"
}

@test "--set matches the board's option name without regard to case (#1519)" {
    jq -n '{fields: [{id: "PVTSSF_status", name: "Status", options: [{id: "st_3", name: "APPROVED"}], type: "ProjectV2SingleSelectField"}]}' > "${GH_FIXTURES}/field-list.json"
    set_args
    run "${SCRIPT}" "${SET_ARGS[@]}"
    [ "${status}" -eq 0 ]
    grep -qxF "project item-edit --project-id PVT_proj --id PVTI_target --field-id PVTSSF_status --single-select-option-id st_3" "${GH_LOG}"
}

@test "--set names a pull request with --pr and builds its /pull/ URL" {
    run "${SCRIPT}" workflow-status --set --repo "${REPO}" --pr 1481 --status Approved
    grep -qxF "project item-add 74 --owner credfeto --url https://github.com/credfeto/credfeto-orchestrator/pull/1481 --format json --jq .id" "${GH_LOG}"
}

@test "--set matches the status name without regard to case and handles names with spaces" {
    run "${SCRIPT}" workflow-status --set --repo "${REPO}" --issue 1346 --status "ai security review"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Set ${ISSUE_URL} to AI Security Review"* ]]
    grep -qxF "project item-edit --project-id PVT_proj --id PVTI_target --field-id PVTSSF_status --single-select-option-id st_7" "${GH_LOG}"
}

@test "--set refuses a built-in option that is not a workflow state, such as Todo, before calling gh (#1519)" {
    write_legacy_field_list
    run "${SCRIPT}" workflow-status --set --repo "${REPO}" --issue 1346 --status Todo
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"unknown status 'Todo'"* ]]
    [ "$(gh_call_count "project item-add")" -eq 0 ]
    [ "$(gh_call_count "project item-edit")" -eq 0 ]
}

@test "--set lists the valid statuses when the name is unknown, and writes nothing" {
    run "${SCRIPT}" workflow-status --set --repo "${REPO}" --issue 1346 --status Nonsense
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"unknown status 'Nonsense' (valid: Not Started, Planning, Approved, Development, AI Simplify, AI Review, AI Security Review, AI Coverage, Human Review, Complete)"* ]]
    [ "$(gh_call_count "project item-add")" -eq 0 ]
}

@test "--set takes the owner from the project's own path, so an org project uses the org" {
    write_repo_view "/orgs/acme/projects/3"
    set_args
    run "${SCRIPT}" "${SET_ARGS[@]}"
    [ "${status}" -eq 0 ]
    grep -qF "project field-list 3 --owner acme " "${GH_LOG}"
    grep -qF "project item-add 3 --owner acme " "${GH_LOG}"
}

@test "--set fails when no project titled Workflow is linked to the repo" {
    jq -n '{projectsV2: {Nodes: [{id: "PVT_other", title: "Roadmap", number: 9, resourcePath: "/users/credfeto/projects/9"}]}}' > "${GH_FIXTURES}/repo-view.json"
    set_args
    run "${SCRIPT}" "${SET_ARGS[@]}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"no project titled Workflow is linked to ${REPO}"* ]]
    [ "$(gh_call_count "project ")" -eq 0 ]
}

@test "--set fails rather than guess when two projects titled Workflow are linked" {
    jq -n '{projectsV2: {Nodes: [
        {id: "PVT_a", title: "Workflow", number: 1, resourcePath: "/users/credfeto/projects/1"},
        {id: "PVT_b", title: "Workflow", number: 2, resourcePath: "/users/credfeto/projects/2"}]}}' > "${GH_FIXTURES}/repo-view.json"
    set_args
    run "${SCRIPT}" "${SET_ARGS[@]}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"more than one project titled Workflow"* ]]
    [ "$(gh_call_count "project ")" -eq 0 ]
}

@test "--set fails when neither the Status nor a Workflow Status field has the state (#1519)" {
    jq -n '{fields: [{id: "PVTSSF_status", name: "Status", options: [{id: "f75ad846", name: "Todo"}], type: "ProjectV2SingleSelectField"}]}' > "${GH_FIXTURES}/field-list.json"
    set_args
    run "${SCRIPT}" "${SET_ARGS[@]}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"has no 'Approved' option on its Status field"* ]]
    [ "$(gh_call_count "project item-add")" -eq 0 ]
}

@test "--set fails when the repo's projects cannot be read" {
    touch "${GH_FIXTURES}/repo-view.fail"
    set_args
    run "${SCRIPT}" "${SET_ARGS[@]}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"could not read the projects of ${REPO}"* ]]
}

@test "--set does not edit when adding the item fails" {
    touch "${GH_FIXTURES}/item-add.fail"
    set_args
    run "${SCRIPT}" "${SET_ARGS[@]}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"could not add ${ISSUE_URL}"* ]]
    [ "$(gh_call_count "project item-edit")" -eq 0 ]
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

@test "--check reads the item directly and prints its status, ignoring an item on another project" {
    run "${SCRIPT}" workflow-status --check --repo "${REPO}" --issue 1346
    [ "${status}" -eq 0 ]
    [ "${output}" = "Approved" ]
    [ "$(gh_call_count "project item-list")" -eq 0 ]
    grep -qF -- "-f o=credfeto -f r=credfeto-orchestrator -F n=1346" "${GH_LOG}"
    grep -qF 'select(.project.id=="PVT_proj")' "${GH_LOG}"
    grep -qF 'projectItems(first:100)' "${GH_LOG}"
}

@test "--check --issue asks for issue(number:) and --pr asks for pullRequest(number:)" {
    run "${SCRIPT}" workflow-status --check --repo "${REPO}" --issue 1346
    [ "${status}" -eq 0 ]
    # shellcheck disable=SC2016  # literal GraphQL variable syntax as logged by the stand-in
    grep -qF 'issue(number:$n)' "${GH_LOG}"

    : > "${GH_LOG}"
    run "${SCRIPT}" workflow-status --check --repo "${REPO}" --pr 1481
    [ "${status}" -eq 0 ]
    [ "${output}" = "AI Review" ]
    # shellcheck disable=SC2016
    grep -qF 'pullRequest(number:$n)' "${GH_LOG}"
}

@test "--check treats GitHub's no-such-issue answer as not on the board, without a fallback or a warning" {
    use_fallback "GraphQL: Could not resolve to an Issue with the number of 1481."
    run "${SCRIPT}" workflow-status --check --repo "${REPO}" --issue 1481
    [ "${status}" -eq 1 ]
    [ "${output}" = "cfwf: ${REPO}#1481 is not on project 74" ]
    [ "$(gh_call_count "project item-list")" -eq 0 ]
}

@test "--check exits non-zero when the item is on no Workflow project item" {
    jq -n '{data: {repository: {pullRequest: {projectItems: {nodes: [{project: {id: "PVT_other"}, fieldValueByName: {name: "Human Review"}}]}}}}}' > "${GH_FIXTURES}/graphql-target.json"
    run "${SCRIPT}" workflow-status --check --repo "${REPO}" --pr 99999
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"${REPO}#99999 is not on project 74"* ]]
}

@test "--check passes the repository through as given, since GitHub matches it without regard to case" {
    run "${SCRIPT}" workflow-status --check --repo Credfeto/CREDFETO-Orchestrator --issue 1346
    [ "${status}" -eq 0 ]
    [ "${output}" = "Approved" ]
    grep -qF -- "-f o=Credfeto -f r=CREDFETO-Orchestrator" "${GH_LOG}"
}

@test "--check falls back to listing the board when the direct read fails, ignoring the same number in another repo and a draft item, and warning on stderr only" {
    use_fallback
    run --separate-stderr "${SCRIPT}" workflow-status --check --repo "${REPO}" --issue 1346
    [ "${status}" -eq 0 ]
    [ "${output}" = "Approved" ]
    grep -qF "project item-list 74 --owner credfeto --format json -L 10000 " "${GH_LOG}"
    [[ "${stderr}" == *"cfwf: warning: the direct GraphQL read failed (GraphQL: something went wrong); falling back to listing the board"* ]]
}

@test "--check --pr finds a pull request item and --issue does not match it, on the fallback" {
    use_fallback
    run --separate-stderr "${SCRIPT}" workflow-status --check --repo "${REPO}" --pr 1481
    [ "${status}" -eq 0 ]
    [ "${output}" = "AI Review" ]

    run --separate-stderr "${SCRIPT}" workflow-status --check --repo "${REPO}" --issue 1481
    [ "${status}" -eq 1 ]
}

@test "--check, on the fallback, matches the repository without regard to case" {
    use_fallback
    run --separate-stderr "${SCRIPT}" workflow-status --check --repo Credfeto/CREDFETO-Orchestrator --issue 1346
    [ "${status}" -eq 0 ]
    [ "${output}" = "Approved" ]
}

@test "--check only treats GitHub's no-such-issue or no-such-pull-request answer as not found; any other error falls back" {
    use_fallback "GraphQL: Could not resolve to a Repository with the name 'credfeto/credfeto-orchestrator'."
    run --separate-stderr "${SCRIPT}" workflow-status --check --repo "${REPO}" --issue 1346
    [ "${status}" -eq 0 ]
    [ "${output}" = "Approved" ]
    [ "$(gh_call_count "project item-list")" -ge 1 ]
}

@test "anything gh writes to stderr on a successful read never ends up in the value" {
    printf '%s\n' "A new release of gh is available: 2.99.0" > "${GH_FIXTURES}/graphql.stderr"
    run --separate-stderr "${SCRIPT}" workflow-status --check --repo "${REPO}" --issue 1346
    [ "${status}" -eq 0 ]
    [ "${output}" = "Approved" ]
}

@test "the fallback warning quotes only the first line of an error body gh printed on stdout, at most 200 characters" {
    { printf 'x%.0s' $(seq 1 300); printf '\nsecond line\n'; } > "${GH_FIXTURES}/graphql.failout"
    run --separate-stderr "${SCRIPT}" workflow-status --check --repo "${REPO}" --issue 1346
    [[ "${stderr}" == *"read failed ($(printf 'x%.0s' $(seq 1 200)));"* ]]
    [[ "${stderr}" != *"second line"* ]]
    [[ "${stderr}" != *"$(printf 'x%.0s' $(seq 1 201))"* ]]
}

@test "the fallback warning never carries terminal escape sequences from the error text" {
    printf 'boom \033[31mred\033[0m and a bell\a\n' > "${GH_FIXTURES}/graphql.failout"
    run --separate-stderr "${SCRIPT}" workflow-status --check --repo "${REPO}" --issue 1346
    [[ "${stderr}" == *"read failed (boom [31mred[0m and a bell);"* ]]
    [[ "${stderr}" != *$'\033'* ]]
    [[ "${stderr}" != *$'\a'* ]]
}

@test "cfwf leaves no temporary file behind, whether the direct read works or fails" {
    export TMPDIR="${TEST_TMP}/tmp"
    mkdir -p "${TMPDIR}"

    run "${SCRIPT}" workflow-status --check --repo "${REPO}" --issue 1346
    [ "${status}" -eq 0 ]
    [ -z "$(ls -A "${TMPDIR}")" ]

    use_fallback
    run --separate-stderr "${SCRIPT}" workflow-status --check --repo "${REPO}" --issue 1346
    [ "${status}" -eq 0 ]
    [ -z "$(ls -A "${TMPDIR}")" ]
}

@test "--check reports when neither the direct read nor the listing works" {
    use_fallback
    touch "${GH_FIXTURES}/item-list.fail"
    run "${SCRIPT}" workflow-status --check --repo "${REPO}" --issue 1346
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"could not read the status of ${REPO}#1346: both the direct query and the listing of project 74 failed"* ]]
}

@test "a closed project titled Workflow is ignored, so a replaced board does not make discovery ambiguous" {
    jq -n '{projectsV2: {Nodes: [
        {id: "PVT_old", title: "Workflow", number: 2, resourcePath: "/users/credfeto/projects/2", closed: true},
        {id: "PVT_proj", title: "Workflow", number: 74, resourcePath: "/users/credfeto/projects/74", closed: false}]}}' > "${GH_FIXTURES}/repo-view.json"
    run "${SCRIPT}" workflow-status --check --repo "${REPO}" --issue 1346
    [ "${status}" -eq 0 ]
    grep -qF 'select(.project.id=="PVT_proj")' "${GH_LOG}"
}

@test "--check prints only the status name, with no parenthetical (#1519)" {
    run "${SCRIPT}" workflow-status --check --repo "${REPO}" --issue 1346
    [ "${status}" -eq 0 ]
    [ "${output}" = "Approved" ]
    [[ "${output}" != *"("* ]]
}

@test "--check reports (unset) for an item with no status" {
    write_graphql_item null null
    run "${SCRIPT}" workflow-status --check --repo "${REPO}" --issue 1346
    [ "${status}" -eq 0 ]
    [ "${output}" = "(unset)" ]
}

@test "--check reads the Workflow Status of a board not converted yet, and ignores its built-in Todo, In Progress or Done (#1519)" {
    write_graphql_item '{"name":"AI Review"}' '{"name":"In Progress"}'
    run "${SCRIPT}" workflow-status --check --repo "${REPO}" --issue 1346
    [ "${status}" -eq 0 ]
    [ "${output}" = "AI Review" ]

    write_graphql_item null '{"name":"Todo"}'
    run "${SCRIPT}" workflow-status --check --repo "${REPO}" --issue 1346
    [ "${status}" -eq 0 ]
    [ "${output}" = "(unset)" ]
}

@test "--check asks for the Status and the Workflow Status in the one query (#1519)" {
    run "${SCRIPT}" workflow-status --check --repo "${REPO}" --issue 1346
    [ "${status}" -eq 0 ]
    grep -qF 'legacy:fieldValueByName(name:"Workflow Status")' "${GH_LOG}"
    grep -qF 'status:fieldValueByName(name:"Status")' "${GH_LOG}"
    [ "$(gh_call_count "api graphql")" -eq 1 ]
}

@test "--check, on the fallback, reports (unset) for an item with no status" {
    use_fallback
    run --separate-stderr "${SCRIPT}" workflow-status --check --repo "${REPO}" --issue 1500
    [ "${status}" -eq 0 ]
    [ "${output}" = "(unset)" ]
}

@test "--check, on the fallback, reads the Workflow Status of a board not converted yet (#1519)" {
    use_fallback
    jq '.items[1] += {"workflow Status": "Human Review", status: "In Progress"}' "${GH_FIXTURES}/item-list.json" > "${GH_FIXTURES}/item-list.tmp" && mv "${GH_FIXTURES}/item-list.tmp" "${GH_FIXTURES}/item-list.json"
    run --separate-stderr "${SCRIPT}" workflow-status --check --repo "${REPO}" --issue 1346
    [ "${status}" -eq 0 ]
    [ "${output}" = "Human Review" ]
}

@test "--check needs --repo and exactly one of --pr and --issue, and takes no --status" {
    run "${SCRIPT}" workflow-status --check --repo "${REPO}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"--pr or --issue"* ]]

    run "${SCRIPT}" workflow-status --check --repo "${REPO}" --pr 1 --issue 2
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"mutually exclusive"* ]]

    run "${SCRIPT}" workflow-status --check --pr 1
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"missing required option --repo"* ]]

    run "${SCRIPT}" workflow-status --check --repo "${REPO}" --pr 1 --status Approved
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"--status is only valid with --set"* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "--check fails when no project titled Workflow is linked to the repo" {
    jq -n '{projectsV2: {Nodes: []}}' > "${GH_FIXTURES}/repo-view.json"
    run "${SCRIPT}" workflow-status --check --repo "${REPO}" --pr 1481
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"no project titled Workflow is linked to ${REPO}"* ]]
}

# --- closing-issue-labels ------------------------------------------------------

@test "closing-issue-labels prints the sorted, de-duplicated labels of every closing issue without Blocked or On-Hold" {
    write_pr_view "${REPO} 10" "${REPO} 11"
    jq -n '{labels: [{name: "Medium"}, {name: "AI-Work"}, {name: "Blocked"}]}' > "${GH_FIXTURES}/issue-view-10.json"
    jq -n '{labels: [{name: "AI-Work"}, {name: "Security"}, {name: "On-Hold"}]}' > "${GH_FIXTURES}/issue-view-11.json"

    run "${SCRIPT}" closing-issue-labels --repo credfeto/credfeto-orchestrator --pr 1481
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf 'AI-Work\nMedium\nSecurity')" ]
}

@test "closing-issue-labels does not exclude labels that merely contain Blocked or On-Hold" {
    write_pr_view "${REPO} 10"
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

@test "closing-issue-labels warns about an issue it cannot read, still prints the others, and exits non-zero" {
    write_pr_view "${REPO} 10" "${REPO} 11"
    jq -n '{labels: [{name: "Medium"}]}' > "${GH_FIXTURES}/issue-view-11.json"

    run bash -c '"$1" closing-issue-labels --repo credfeto/credfeto-orchestrator --pr 1481 2>&1 >/dev/null' _ "${SCRIPT}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"could not fetch the labels of credfeto/credfeto-orchestrator#10"* ]]

    run bash -c '"$1" closing-issue-labels --repo credfeto/credfeto-orchestrator --pr 1481 2>/dev/null' _ "${SCRIPT}"
    [ "${status}" -eq 1 ]
    [ "${output}" = "Medium" ]
}

@test "closing-issue-labels reads each closing issue from its own repository, not the PR's" {
    write_pr_view "${REPO} 10" "other-org/other-repo 11"
    jq -n '{labels: [{name: "Medium"}]}' > "${GH_FIXTURES}/issue-view-10.json"
    jq -n '{labels: [{name: "Security"}]}' > "${GH_FIXTURES}/issue-view-11.json"

    run "${SCRIPT}" closing-issue-labels --repo "${REPO}" --pr 1481
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf 'Medium\nSecurity')" ]
    grep -qF "issue view 10 --repo ${REPO} " "${GH_LOG}"
    grep -qF "issue view 11 --repo other-org/other-repo " "${GH_LOG}"
}

@test "closing-issue-labels skips a malformed closing issue reference with a warning" {
    jq -n '{closingIssuesReferences: [{number: 10, repository: {owner: {login: "bad owner"}, name: "x"}}, {number: 11, repository: {owner: {login: "credfeto"}, name: "credfeto-orchestrator"}}]}' > "${GH_FIXTURES}/pr-view.json"
    jq -n '{labels: [{name: "Medium"}]}' > "${GH_FIXTURES}/issue-view-11.json"

    run bash -c '"$1" closing-issue-labels --repo credfeto/credfeto-orchestrator --pr 1481 2>&1 >/dev/null' _ "${SCRIPT}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"unexpected closing issue reference"* ]]
    run bash -c '"$1" closing-issue-labels --repo credfeto/credfeto-orchestrator --pr 1481 2>/dev/null' _ "${SCRIPT}"
    [ "${status}" -eq 1 ]
    [ "${output}" = "Medium" ]
}

@test "closing-issue-labels rejects the options that belong to workflow-status" {
    local flag
    for flag in "--status Approved" "--issue 3" "--set" "--check"; do
        # shellcheck disable=SC2086
        run "${SCRIPT}" closing-issue-labels --repo credfeto/credfeto-orchestrator --pr 1481 ${flag}
        [ "${status}" -eq 2 ] || { echo "${flag} was accepted" >&2; return 1; }
        [[ "${output}" == *"takes only --repo and --pr"* ]]
    done
    [ ! -f "${GH_LOG}" ]
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

# --- issue create --------------------------------------------------------------

NEW_ISSUE_URL="https://github.com/credfeto/credfeto-orchestrator/issues/1600"

# The fixtures "issue create" needs on top of setup: a body file, the labels the repo already has,
# and the URL gh prints for a new issue. The default board is converted, so Not Started is st_1.
prepare_issue_create() {
    printf 'The body of the issue.\n\nWith a second paragraph and a trailing line.\n' > "${TEST_TMP}/body.md"
    jq -n '[{name: "High"}, {name: "cfwf"}]' > "${GH_FIXTURES}/label-list.json"
    printf '%s\n' "${NEW_ISSUE_URL}" > "${GH_FIXTURES}/issue-create.out"
}

create_args() {
    CREATE_ARGS=(issue create --repo "${REPO}" --priority "${1:-High}" --title "A new issue" --body-file "${TEST_TMP}/body.md")
}

# Nothing was written: no label, no issue and no board item.
assert_nothing_created() {
    [ "$(gh_call_count "label create")" -eq 0 ]
    [ "$(gh_call_count "issue create")" -eq 0 ]
    [ "$(gh_call_count "project item-add")" -eq 0 ]
    [ "$(gh_call_count "project item-edit")" -eq 0 ]
}

@test "issue needs a subcommand, and an unknown one is refused" {
    run "${SCRIPT}" issue
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"issue needs a subcommand (create)"* ]]

    run "${SCRIPT}" issue frobnicate
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"unknown issue subcommand: frobnicate"* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "issue --help and issue create --help print the usage without calling gh" {
    run "${SCRIPT}" issue --help
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Usage: cfwf issue create"* ]]

    run "${SCRIPT}" issue create --help
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Usage: cfwf issue create"* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "issue create needs --repo, --priority, --title and --body-file, and never calls gh without them" {
    prepare_issue_create
    run "${SCRIPT}" issue create --priority High --title T --body-file "${TEST_TMP}/body.md"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"missing required option --repo"* ]]

    run "${SCRIPT}" issue create --repo "${REPO}" --title T --body-file "${TEST_TMP}/body.md"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"--priority is required (Security, Urgent, High, Medium or Low)"* ]]

    run "${SCRIPT}" issue create --repo "${REPO}" --priority High --body-file "${TEST_TMP}/body.md"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"missing required option --title"* ]]

    run "${SCRIPT}" issue create --repo "${REPO}" --priority High --title T
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"missing required option --body-file"* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "issue create creates a label whose name starts with a dash without gh reading it as a flag" {
    prepare_issue_create
    create_args
    run "${SCRIPT}" "${CREATE_ARGS[@]}" --label -wip
    [ "${status}" -eq 0 ]
    grep -qxF "label create --repo ${REPO} -- -wip" "${GH_LOG}"
    grep -qxF "issue create --repo ${REPO} --title A new issue --body-file ${TEST_TMP}/body.md --label High --label -wip" "${GH_LOG}"
}

@test "issue create refuses --title given twice, like --priority and --body-file" {
    prepare_issue_create
    create_args
    run "${SCRIPT}" "${CREATE_ARGS[@]}" --title "Another"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"--title can only be given once"* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "issue create rejects a blank or over-long title or label, without calling gh" {
    prepare_issue_create
    create_args
    run "${SCRIPT}" issue create --repo "${REPO}" --priority High --title "   " --body-file "${TEST_TMP}/body.md"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"invalid value for --title: it must not be blank or longer than 256 characters"* ]]

    run "${SCRIPT}" issue create --repo "${REPO}" --priority High --title "$(printf 'x%.0s' {1..257})" --body-file "${TEST_TMP}/body.md"
    [ "${status}" -eq 2 ]

    run "${SCRIPT}" "${CREATE_ARGS[@]}" --label " "
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"invalid value for --label: it must not be blank or longer than 50 characters"* ]]

    run "${SCRIPT}" "${CREATE_ARGS[@]}" --label "$(printf 'x%.0s' {1..51})"
    [ "${status}" -eq 2 ]
    [ ! -f "${GH_LOG}" ]

    run "${SCRIPT}" issue create --repo "${REPO}" --priority High --title "$(printf 'x%.0s' {1..256})" --body-file "${TEST_TMP}/body.md" --label "$(printf 'y%.0s' {1..50})"
    [ "${status}" -eq 0 ]
}

@test "issue create counts characters, not bytes, against the title and label limits, in any locale" {
    prepare_issue_create
    local accented
    accented=$(printf '\303\251%.0s' {1..200})
    LC_ALL=C.UTF-8 bash -c 'v=$(printf "\303\251"); [ "${#v}" -eq 1 ]' || skip "no C.UTF-8 locale on this host"
    LC_ALL=C run "${SCRIPT}" issue create --repo "${REPO}" --priority High --title "${accented}" --body-file "${TEST_TMP}/body.md" --label "$(printf '\303\251%.0s' {1..50})"
    [ "${status}" -eq 0 ]
}

@test "issue create refuses to count a title, a label or a body when the C.UTF-8 locale is not installed" {
    run bash -c 'source "$1"; utf8_locale_available() { return 1; }; CURRENT_COMMAND=issue; parse_issue_options --title T' _ "${SCRIPT}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"the C.UTF-8 locale is not installed"* ]]

    run bash -c 'source "$1"; utf8_locale_available() { return 1; }; CURRENT_COMMAND=issue; parse_issue_options --label bug' _ "${SCRIPT}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"the C.UTF-8 locale is not installed"* ]]

    printf 'body\n' > "${TEST_TMP}/body.md"
    run bash -c 'source "$1"; utf8_locale_available() { return 1; }; check_body_for_leaks "$2" credfeto/repo' _ "${SCRIPT}" "${TEST_TMP}/body.md"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"the C.UTF-8 locale is not installed"* ]]
}

@test "issue create --help and a usage error do not need the C.UTF-8 locale" {
    run bash -c 'source "$1"; utf8_locale_available() { return 1; }; CURRENT_COMMAND=issue; parse_issue_options --help' _ "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == "Usage: cfwf issue create"* ]]

    run bash -c 'source "$1"; utf8_locale_available() { return 1; }; CURRENT_COMMAND=issue; parse_issue_options --bogus' _ "${SCRIPT}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"unknown option: --bogus"* ]]
}

@test "the C.UTF-8 locale check passes where the locale is installed" {
    LC_ALL=C.UTF-8 bash -c 'v=$(printf "\303\251"); [ "${#v}" -eq 1 ]' || skip "no C.UTF-8 locale on this host"
    run bash -c 'source "$1"; utf8_locale_available' _ "${SCRIPT}"
    [ "${status}" -eq 0 ]
}

@test "issue create refuses a body over GitHub's 65536 characters with exit 8 before calling gh, and accepts exactly that many" {
    prepare_issue_create
    head -c 65537 /dev/zero | tr '\0' 'x' > "${TEST_TMP}/long.md"
    run --separate-stderr "${SCRIPT}" issue create --repo "${REPO}" --priority High --title T --body-file "${TEST_TMP}/long.md"
    [ "${status}" -eq 8 ]
    [ "${stderr}" = "cfwf: body refused: too long" ]
    [ ! -f "${GH_LOG}" ]

    head -c 65536 /dev/zero | tr '\0' 'x' > "${TEST_TMP}/limit.md"
    run "${SCRIPT}" issue create --repo "${REPO}" --priority High --title T --body-file "${TEST_TMP}/limit.md"
    [ "${status}" -eq 0 ]
}

@test "issue create refuses --repo given twice, so a second one can never redirect the issue" {
    prepare_issue_create
    create_args
    run "${SCRIPT}" "${CREATE_ARGS[@]}" --repo credfeto/other-repo
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"--repo can only be given once"* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "issue create rejects a --repo that is not owner/repo, without calling gh" {
    prepare_issue_create
    local bad
    for bad in "no-slash" "a/b/c" "a b/c" 'a/b;rm' ""; do
        run "${SCRIPT}" issue create --repo "${bad}" --priority High --title T --body-file "${TEST_TMP}/body.md"
        [ "${status}" -eq 2 ] || { echo "--repo '${bad}' was accepted" >&2; return 1; }
        [[ "${output}" == *"invalid value for --repo"* ]]
    done
    [ ! -f "${GH_LOG}" ]
}

@test "issue create rejects an unknown priority and lists the valid ones, without calling gh" {
    prepare_issue_create
    create_args Critical
    run "${SCRIPT}" "${CREATE_ARGS[@]}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"unknown priority 'Critical' (expected Security, Urgent, High, Medium or Low)"* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "issue create refuses --priority given twice, because an issue has one priority" {
    prepare_issue_create
    create_args
    run "${SCRIPT}" "${CREATE_ARGS[@]}" --priority Low
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"--priority can only be given once"* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "issue create accepts each of the five priorities in any case and applies the canonical label" {
    prepare_issue_create
    local given canonical
    for row in "security|Security" "URGENT|Urgent" "High|High" "mEdIuM|Medium" "low|Low"; do
        given="${row%|*}"
        canonical="${row#*|}"
        : > "${GH_LOG}"
        create_args "${given}"
        run "${SCRIPT}" "${CREATE_ARGS[@]}"
        [ "${status}" -eq 0 ]
        grep -qxF "issue create --repo ${REPO} --title A new issue --body-file ${TEST_TMP}/body.md --label ${canonical}" "${GH_LOG}"
    done
}

@test "a priority given as --label is refused in any case, pointing at --priority, and nothing is created" {
    prepare_issue_create
    local row given canonical
    for row in "Urgent|Urgent" "urgent|Urgent" "HIGH|High" "security|Security" "Medium|Medium" "low|Low"; do
        given="${row%|*}"
        canonical="${row#*|}"
        create_args Low
        run "${SCRIPT}" "${CREATE_ARGS[@]}" --label "${given}"
        [ "${status}" -eq 2 ] || { echo "--label ${given} was accepted" >&2; return 1; }
        [[ "${output}" == *"'${given}' is a priority; use --priority ${canonical}, not --label"* ]]
    done
    [ ! -f "${GH_LOG}" ]
}

@test "a priority label is refused among other labels too, whatever its position" {
    prepare_issue_create
    create_args
    run "${SCRIPT}" "${CREATE_ARGS[@]}" --label Bug --label Urgent --label cfwf
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"'Urgent' is a priority; use --priority Urgent, not --label"* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "issue create rejects a label with a comma or a control character, and an empty title, without calling gh" {
    prepare_issue_create
    create_args
    run "${SCRIPT}" "${CREATE_ARGS[@]}" --label "a,b"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"invalid value for --label: a,b"* ]]

    run "${SCRIPT}" "${CREATE_ARGS[@]}" --label $'a\nb'
    [ "${status}" -eq 2 ]

    run "${SCRIPT}" issue create --repo "${REPO}" --priority High --title "" --body-file "${TEST_TMP}/body.md"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"invalid value for --title"* ]]

    run "${SCRIPT}" issue create --repo "${REPO}" --priority High --title $'a\tb' --body-file "${TEST_TMP}/body.md"
    [ "${status}" -eq 2 ]
    [ ! -f "${GH_LOG}" ]
}

@test "issue create rejects the options that belong to workflow-status, and unknown ones" {
    prepare_issue_create
    create_args
    local flag
    for flag in --status --pr --issue --set --check --bogus; do
        run "${SCRIPT}" "${CREATE_ARGS[@]}" "${flag}" 1
        [ "${status}" -eq 2 ] || { echo "${flag} was accepted" >&2; return 1; }
        [[ "${output}" == *"unknown option: ${flag}"* ]]
    done
    [ ! -f "${GH_LOG}" ]
}

@test "an option that workflow-status does not have is not accepted there either" {
    local flag
    for flag in --priority --title --body-file --label; do
        run "${SCRIPT}" workflow-status --set --repo "${REPO}" --issue 1346 --status Approved "${flag}" value
        [ "${status}" -eq 2 ]
        [[ "${output}" == *"unknown option: ${flag}"* ]]
    done
    [ ! -f "${GH_LOG}" ]
}

@test "issue create refuses a missing, unreadable, empty or blank body, without calling gh" {
    prepare_issue_create
    create_args
    run "${SCRIPT}" issue create --repo "${REPO}" --priority High --title T --body-file "${TEST_TMP}/nope.md"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"cannot read the body file: ${TEST_TMP}/nope.md"* ]]

    : > "${TEST_TMP}/empty.md"
    run "${SCRIPT}" issue create --repo "${REPO}" --priority High --title T --body-file "${TEST_TMP}/empty.md"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"the issue body is empty"* ]]

    printf ' \n\t\n' > "${TEST_TMP}/blank.md"
    run "${SCRIPT}" issue create --repo "${REPO}" --priority High --title T --body-file "${TEST_TMP}/blank.md"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"the issue body is empty"* ]]

    run "${SCRIPT}" issue create --repo "${REPO}" --priority High --title T --body-file "${TEST_TMP}"
    [ "${status}" -eq 1 ]
    [ ! -f "${GH_LOG}" ]
}

@test "issue create reads the body from stdin for --body-file -, and an empty stdin is refused" {
    prepare_issue_create
    run "${SCRIPT}" issue create --repo "${REPO}" --priority High --title "A new issue" --body-file - <<< "A body from stdin"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${NEW_ISSUE_URL}" ]
    [ "$(cat "${GH_FIXTURES}/issue-body.txt")" = "A body from stdin" ]

    : > "${GH_LOG}"
    run "${SCRIPT}" issue create --repo "${REPO}" --priority High --title "A new issue" --body-file - < /dev/null
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"the issue body is empty"* ]]
    assert_nothing_created
}

@test "issue create hands the body file to gh unchanged" {
    prepare_issue_create
    create_args
    run "${SCRIPT}" "${CREATE_ARGS[@]}"
    [ "${status}" -eq 0 ]
    cmp "${TEST_TMP}/body.md" "${GH_FIXTURES}/issue-body.txt"
}

@test "issue create fails, creating nothing, when no project titled Workflow is linked to the repo" {
    prepare_issue_create
    jq -n '{projectsV2: {Nodes: [{id: "PVT_other", title: "Roadmap", number: 9, resourcePath: "/users/credfeto/projects/9", closed: false}]}}' > "${GH_FIXTURES}/repo-view.json"
    create_args
    run "${SCRIPT}" "${CREATE_ARGS[@]}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"no project titled Workflow is linked to ${REPO}"* ]]
    assert_nothing_created
    [ "$(gh_call_count "label list")" -eq 0 ]
}

@test "issue create fails, creating nothing, when the board has no Not Started option" {
    prepare_issue_create
    jq -n '{fields: [{id: "PVTSSF_status", name: "Status", options: [{id: "st_2", name: "Planning"}], type: "ProjectV2SingleSelectField"}], totalCount: 1}' > "${GH_FIXTURES}/field-list.json"
    create_args
    run "${SCRIPT}" "${CREATE_ARGS[@]}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"has no 'Not Started' option"* ]]
    assert_nothing_created
}

@test "issue create makes the issue, puts it on the board as Not Started and prints only the URL" {
    prepare_issue_create
    create_args
    run --separate-stderr "${SCRIPT}" "${CREATE_ARGS[@]}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${NEW_ISSUE_URL}" ]
    [ -z "${stderr}" ]

    grep -qxF "issue create --repo ${REPO} --title A new issue --body-file ${TEST_TMP}/body.md --label High" "${GH_LOG}"
    grep -qxF "project item-add 74 --owner credfeto --url ${NEW_ISSUE_URL} --format json --jq .id" "${GH_LOG}"
    grep -qxF "project item-edit --project-id PVT_proj --id PVTI_target --field-id PVTSSF_status --single-select-option-id st_1" "${GH_LOG}"
    [ "$(gh_call_count "project item-edit")" -eq 1 ]
}

@test "issue create checks everything first: board, then labels, then the issue, then the board writes, and never reads back" {
    prepare_issue_create
    create_args
    run "${SCRIPT}" "${CREATE_ARGS[@]}"
    [ "${status}" -eq 0 ]
    local repo_view field_list label_list issue add edit
    repo_view=$(gh_line_of "repo view")
    field_list=$(gh_line_of "project field-list")
    label_list=$(gh_line_of "label list")
    issue=$(gh_line_of "issue create")
    add=$(gh_line_of "project item-add")
    edit=$(gh_line_of "--field-id PVTSSF_status ")
    [ "${repo_view}" -lt "${field_list}" ]
    [ "${field_list}" -lt "${label_list}" ]
    [ "${label_list}" -lt "${issue}" ]
    [ "${issue}" -lt "${add}" ]
    [ "${add}" -lt "${edit}" ]
    [ "${edit}" -eq "$(wc -l < "${GH_LOG}")" ]
    [ "$(gh_call_count "api graphql")" -eq 0 ]
    [ "$(gh_call_count "project item-list")" -eq 0 ]
}

@test "issue create reads the labels of the repo with a limit above gh's default of 30" {
    prepare_issue_create
    create_args
    run "${SCRIPT}" "${CREATE_ARGS[@]}"
    [ "${status}" -eq 0 ]
    grep -qF "label list --repo ${REPO} --limit 1000 --json name" "${GH_LOG}"
}

@test "issue create applies the priority and each given label, once each, and creates none that exist" {
    prepare_issue_create
    create_args
    run "${SCRIPT}" "${CREATE_ARGS[@]}" --label cfwf --label CFWF
    [ "${status}" -eq 0 ]
    grep -qxF "issue create --repo ${REPO} --title A new issue --body-file ${TEST_TMP}/body.md --label High --label cfwf" "${GH_LOG}"
    [ "$(gh_call_count "label create")" -eq 0 ]
}

@test "issue create creates a missing standard label with its standard colour and description" {
    prepare_issue_create
    create_args
    run "${SCRIPT}" "${CREATE_ARGS[@]}" --label AI-Work --label "on hold"
    [ "${status}" -eq 0 ]
    grep -qxF "label create --repo ${REPO} --color ffa500 --description Work for an AI Agent -- AI-Work" "${GH_LOG}"
    grep -qxF "label create --repo ${REPO} --color ff0000 --description Do not work on this -- On Hold" "${GH_LOG}"
    grep -qxF "issue create --repo ${REPO} --title A new issue --body-file ${TEST_TMP}/body.md --label High --label AI-Work --label On Hold" "${GH_LOG}"
}

@test "issue create creates any other missing label with the colour gh picks, passing no colour or description" {
    prepare_issue_create
    create_args
    run "${SCRIPT}" "${CREATE_ARGS[@]}" --label "brand new"
    [ "${status}" -eq 0 ]
    grep -qxF "label create --repo ${REPO} -- brand new" "${GH_LOG}"
    grep -qxF "issue create --repo ${REPO} --title A new issue --body-file ${TEST_TMP}/body.md --label High --label brand new" "${GH_LOG}"
}

@test "issue create creates a missing priority label with its standard colour and description" {
    prepare_issue_create
    create_args Medium
    run "${SCRIPT}" "${CREATE_ARGS[@]}"
    [ "${status}" -eq 0 ]
    grep -qxF "label create --repo ${REPO} --color ffff00 --description Medium Priority -- Medium" "${GH_LOG}"
}

@test "issue create does not create a label that exists in another case" {
    prepare_issue_create
    jq -n '[{name: "high"}, {name: "bug"}]' > "${GH_FIXTURES}/label-list.json"
    create_args
    run "${SCRIPT}" "${CREATE_ARGS[@]}" --label Bug
    [ "${status}" -eq 0 ]
    [ "$(gh_call_count "label create")" -eq 0 ]
}

@test "issue create treats an already-exists answer to a label create as done, and any other failure as fatal before the issue" {
    prepare_issue_create
    printf 'HTTP 422: Validation Failed (already_exists)\n' > "${GH_FIXTURES}/label-create.fail"
    create_args
    run "${SCRIPT}" "${CREATE_ARGS[@]}" --label "brand new"
    [ "${status}" -eq 0 ]

    : > "${GH_LOG}"
    printf 'HTTP 403: Resource not accessible\nsecond line\n' > "${GH_FIXTURES}/label-create.fail"
    run "${SCRIPT}" "${CREATE_ARGS[@]}" --label "brand new"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"could not create the label 'brand new' in ${REPO}: HTTP 403: Resource not accessible"* ]]
    [[ "${output}" != *"second line"* ]]
    [ "$(gh_call_count "issue create")" -eq 0 ]
    [ "$(gh_call_count "project item-add")" -eq 0 ]
}

@test "issue create fails, creating nothing, when the labels of the repo cannot be read" {
    prepare_issue_create
    touch "${GH_FIXTURES}/label-list.fail"
    create_args
    run "${SCRIPT}" "${CREATE_ARGS[@]}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"could not read the labels of ${REPO}"* ]]
    [[ "${output}" != *"already created"* ]]
    assert_nothing_created
}

@test "issue create exits 1 without touching the board when gh cannot create the issue" {
    prepare_issue_create
    touch "${GH_FIXTURES}/issue-create.fail"
    create_args
    run "${SCRIPT}" "${CREATE_ARGS[@]}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"could not create the issue in ${REPO}"* ]]
    [ "$(gh_call_count "project item-add")" -eq 0 ]
}

@test "issue create refuses a result that is not an issue URL" {
    prepare_issue_create
    create_args
    printf 'something odd\n' > "${GH_FIXTURES}/issue-create.out"
    run "${SCRIPT}" "${CREATE_ARGS[@]}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"unexpected result for the new issue, which may have been created: something odd"* ]]
    [[ "${output}" != *"the issue was already created"* ]]
    [ "$(gh_call_count "project item-add")" -eq 0 ]
}

@test "issue create puts a new issue on the board when gh answers with another host, such as a proxy" {
    prepare_issue_create
    printf 'https://github-proxy.example.com/credfeto/credfeto-orchestrator/issues/7\n' > "${GH_FIXTURES}/issue-create.out"
    create_args
    run "${SCRIPT}" "${CREATE_ARGS[@]}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "https://github-proxy.example.com/credfeto/credfeto-orchestrator/issues/7" ]
    grep -qF "project item-add 74 --owner credfeto --url https://github-proxy.example.com/credfeto/credfeto-orchestrator/issues/7 " "${GH_LOG}"
}

@test "issue create refuses an answer that is not an https issue URL, whatever the host" {
    prepare_issue_create
    create_args
    local answer
    for answer in "http://github.com/credfeto/credfeto-orchestrator/issues/7" "https://github.com/credfeto/credfeto-orchestrator/pull/7" "https://github.com/credfeto/issues/7" "https://ho st/credfeto/credfeto-orchestrator/issues/7"; do
        printf '%s\n' "${answer}" > "${GH_FIXTURES}/issue-create.out"
        run "${SCRIPT}" "${CREATE_ARGS[@]}"
        [ "${status}" -eq 1 ]
        [[ "${output}" == *"unexpected result for the new issue"* ]]
    done
    [ "$(gh_call_count "project item-add")" -eq 0 ]
}

@test "issue create puts a new issue on the board even when a renamed repository answers with its new name" {
    prepare_issue_create
    printf 'https://github.com/credfeto/renamed-repo/issues/5\n' > "${GH_FIXTURES}/issue-create.out"
    create_args
    run "${SCRIPT}" "${CREATE_ARGS[@]}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "https://github.com/credfeto/renamed-repo/issues/5" ]
    grep -qF "project item-add 74 --owner credfeto --url https://github.com/credfeto/renamed-repo/issues/5 " "${GH_LOG}"
}

@test "issue create accepts the repository in a different case in the returned URL, and uses the last line of gh's output" {
    prepare_issue_create
    printf 'Creating issue in repo\nhttps://github.com/CredFeto/Credfeto-Orchestrator/issues/1600\n' > "${GH_FIXTURES}/issue-create.out"
    create_args
    run "${SCRIPT}" "${CREATE_ARGS[@]}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "https://github.com/CredFeto/Credfeto-Orchestrator/issues/1600" ]
}

@test "issue create exits 1 and names the issue URL on stderr when the board write is rejected, printing nothing on stdout" {
    prepare_issue_create
    create_args
    touch "${GH_FIXTURES}/item-edit.fail"
    run --separate-stderr "${SCRIPT}" "${CREATE_ARGS[@]}"
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == *"could not set the Status of ${NEW_ISSUE_URL}"* ]]
    [[ "${stderr}" == *"the issue was already created: ${NEW_ISSUE_URL}"* ]]

    rm "${GH_FIXTURES}/item-edit.fail"
    touch "${GH_FIXTURES}/item-add.fail"
    run --separate-stderr "${SCRIPT}" "${CREATE_ARGS[@]}"
    [ "${status}" -eq 1 ]
    [[ "${stderr}" == *"the issue was already created: ${NEW_ISSUE_URL}"* ]]
}

@test "issue create sets Not Started on the Workflow Status field of a board not converted yet (#1519)" {
    prepare_issue_create
    write_legacy_field_list
    create_args
    run --separate-stderr "${SCRIPT}" "${CREATE_ARGS[@]}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${NEW_ISSUE_URL}" ]
    grep -qxF "project item-edit --project-id PVT_proj --id PVTI_target --field-id PVTSSF_wf --single-select-option-id wf_1" "${GH_LOG}"
    [ "$(gh_call_count "project item-edit")" -eq 1 ]
}

@test "issue create leaves no temporary file behind, for a stdin body, a failed run and a run that succeeds" {
    prepare_issue_create
    local scratch="${TEST_TMP}/tmp"
    mkdir -p "${scratch}"

    TMPDIR="${scratch}" run "${SCRIPT}" issue create --repo "${REPO}" --priority High --title T --body-file - <<< "from stdin"
    [ "${status}" -eq 0 ]
    [ -z "$(ls -A "${scratch}")" ]

    touch "${GH_FIXTURES}/issue-create.fail"
    TMPDIR="${scratch}" run "${SCRIPT}" issue create --repo "${REPO}" --priority High --title T --body-file - <<< "from stdin"
    [ "${status}" -eq 1 ]
    [ -z "$(ls -A "${scratch}")" ]

    TMPDIR="${scratch}" run "${SCRIPT}" issue create --repo "${REPO}" --priority High --title T --body-file - < /dev/null
    [ "${status}" -eq 1 ]
    [ -z "$(ls -A "${scratch}")" ]
}

# --- body leak check -----------------------------------------------------------

# Writes the answer to a visibility lookup of the repository $1 (PUBLIC, PRIVATE or INTERNAL). A
# repository with no answer written is one GitHub does not show the caller.
write_visibility() {
    jq -n --arg v "$2" '{visibility: $v}' > "$(visibility_fixture "$1").json"
}

# Makes the visibility lookup of the repository $1 fail the way a proxy or network fault would.
fail_visibility() {
    touch "$(visibility_fixture "$1").fail"
}

# Prints the fixture path, without extension, that the gh stub reads for a visibility lookup of
# the repository $1: lower-cased, with the slash turned into an underscore.
visibility_fixture() {
    local name="${1,,}"
    printf '%s' "${GH_FIXTURES}/visibility-${name//\//_}"
}

visibility_lookups() {
    gh_call_count "repo view $1 --json visibility"
}

# Writes the body file: two clean lines, then the given text as line 3, then a clean last line.
write_leak_body() {
    printf 'A clean first line.\n\nLine three: %s\nA clean last line.\n' "$1" > "${TEST_TMP}/leak.md"
}

run_body_check() {
    run --separate-stderr "${SCRIPT}" body check --repo "${REPO}" --body-file "${TEST_TMP}/leak.md"
}

run_issue_create_leak() {
    run --separate-stderr "${SCRIPT}" issue create --repo "${REPO}" --priority High --title T --body-file "${TEST_TMP}/leak.md"
}

# Given a run's status, stdout and stderr: it exited 8 naming the rule $4 and line 3, printed
# nothing on stdout, and did not echo the text $5 that matched.
assert_refused() {
    local run_status="$1" run_output="$2" run_stderr="$3" rule="$4" secret="$5"
    [ "${run_status}" -eq 8 ]
    [ "${run_stderr}" = "cfwf: body refused: ${rule} (line 3)" ]
    [ -z "${run_output}" ]
    [[ "${run_stderr}" != *"${secret}"* ]]
}

# The token forms, built from pieces so that no secret scanner flags this file.
leak_tokens() {
    local tail="LEAKMARKER0123456789"
    printf '%s\n' "gh""p_${tail}" "gh""o_${tail}" "gh""s_${tail}" "github""_pat_${tail}" "gl""pat-${tail}" \
        "AKI""A$(printf 'Q%.0s' {1..16})" "-----BEGIN RSA PRIV""ATE KEY-----" "-----BEGIN PRIV""ATE KEY-----" \
        "xo""xb-${tail}" "xo""xa-${tail}" "xo""xp-${tail}" \
        "GH_TO""KEN=${tail}" "export DB_PASS""WORD=${tail}" "MY_SEC""RET=${tail}" "(API_K""EY=${tail})"
}

@test "issue create refuses a body with any token form with exit 8, naming the rule and line only, before calling gh" {
    prepare_issue_create
    local token
    while IFS= read -r token; do
        write_leak_body "the value is ${token} here"
        rm -f "${GH_LOG}"
        run_issue_create_leak
        assert_refused "${status}" "${output}" "${stderr}" token "${token}"
        [ ! -f "${GH_LOG}" ]
    done < <(leak_tokens)
}

@test "body check refuses a token at the very start of the body, and one after punctuation" {
    local body
    for body in "gh""p_abc def" "url?t=gh""p_abc"; do
        printf '%s\n' "${body}" > "${TEST_TMP}/leak.md"
        run_body_check
        [ "${status}" -eq 8 ]
        [ "${stderr}" = "cfwf: body refused: token (line 1)" ]
    done
}

@test "issue create refuses a body naming a host path, from any of the starts of a path, before calling gh" {
    prepare_issue_create
    local path start
    for path in /home/someone/work /root/.ssh /run/user/1000/scratch /tmp/claude-out; do
        for start in "" " " '"' "'" '`' "(" "[" "="; do
            if [ -z "${start}" ]; then
                printf 'first\n\n%s/file\nlast\n' "${path}" > "${TEST_TMP}/leak.md"
            else
                write_leak_body "see ${start}${path}/file"
            fi
            rm -f "${GH_LOG}"
            run_issue_create_leak
            assert_refused "${status}" "${output}" "${stderr}" "host path" "${path}"
            [ ! -f "${GH_LOG}" ]
        done
    done
}

@test "issue create refuses a body with a control character other than tab and newline, before calling gh" {
    prepare_issue_create
    local control
    for control in '\000' '\001' '\010' '\013' '\014' '\015' '\033' '\037' '\177'; do
        printf "A clean first line.\n\nLine three: secret%bvalue\nA clean last line.\n" "${control}" > "${TEST_TMP}/leak.md"
        rm -f "${GH_LOG}"
        run_issue_create_leak
        assert_refused "${status}" "${output}" "${stderr}" "control character" "secret"
        [ ! -f "${GH_LOG}" ]
    done
}

@test "the first rule that matches wins, in the order token, host path, control character, too long" {
    printf 'a /tmp/x path\n%s\n' "gh""p_abc" > "${TEST_TMP}/leak.md"
    run_body_check
    [ "${stderr}" = "cfwf: body refused: token (line 2)" ]

    printf 'a\033b\nsee /tmp/x\n' > "${TEST_TMP}/leak.md"
    run_body_check
    [ "${stderr}" = "cfwf: body refused: host path (line 2)" ]

    {
        printf 'a\033b\n'
        head -c 65537 /dev/zero | tr '\0' 'x'
    } > "${TEST_TMP}/leak.md"
    run_body_check
    [ "${stderr}" = "cfwf: body refused: control character (line 1)" ]
}

@test "body check passes a body with no leaks, printing nothing and calling gh for nothing" {
    printf '%s\n' \
        "Tabs$(printf '\t')are fine, as are multi-byte characters: $(printf '\303\251 \303\274 \346\227\245')." \
        "Relative paths such as test/cfwf.bats, lib/state and containers/base/x are fine." \
        "So are /usr/local/bin/cfwf, /var/tmp/x, ~/work and tmp/notes." \
        "Words such as keyboard, laughs_at, monkey and the word TOKEN alone are fine, as is KEY = value." \
        "A token prefix on its own, gh""p_, is fine." \
        "credfeto/other-repo with no link and no number is not looked up." > "${TEST_TMP}/leak.md"
    run_body_check
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    [ -z "${stderr}" ]
    [ ! -f "${GH_LOG}" ]
}

@test "a public target refuses a link to, or a reference to, a private repository, without naming it" {
    write_visibility "${REPO}" PUBLIC
    write_visibility credfeto/hidden-thing PRIVATE
    local reference
    for reference in "https://github.com/credfeto/hidden-thing/issues/4" "github.com/credfeto/hidden-thing" \
        "credfeto/hidden-thing#12" "(credfeto/hidden-thing#12)" "https://www.github.com/credfeto/hidden-thing.git" \
        "https://GitHub.COM/credfeto/hidden-thing" "git@github.com:credfeto/hidden-thing.git"; do
        write_leak_body "see ${reference} for details"
        rm -f "${GH_LOG}"
        run_body_check
        assert_refused "${status}" "${output}" "${stderr}" "private repository" "hidden-thing"
        [ "$(visibility_lookups credfeto/hidden-thing)" -eq 1 ]
    done
}

@test "a repository GitHub does not show the caller counts as private, and so does an internal one" {
    write_visibility "${REPO}" PUBLIC
    write_leak_body "see https://github.com/credfeto/not-visible/pull/2"
    run_body_check
    assert_refused "${status}" "${output}" "${stderr}" "private repository" "not-visible"

    write_visibility credfeto/inside INTERNAL
    write_leak_body "see credfeto/inside#2"
    run_body_check
    assert_refused "${status}" "${output}" "${stderr}" "private repository" "inside"
}

@test "a private target accepts the same reference to a private repository, and looks nothing else up" {
    write_visibility "${REPO}" PRIVATE
    write_visibility credfeto/hidden-thing PRIVATE
    write_leak_body "see https://github.com/credfeto/hidden-thing/issues/4 and credfeto/hidden-thing#5"
    run_body_check
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ "$(visibility_lookups "${REPO}")" -eq 1 ]
    [ "$(visibility_lookups credfeto/hidden-thing)" -eq 0 ]
}

@test "a reference to the target itself or to a GitHub page that is not a repository passes with no lookup" {
    write_leak_body "see https://github.com/Credfeto/Credfeto-Orchestrator/pull/1 and ${REPO}#2 and https://github.com/orgs/credfeto/projects/74 and https://github.com/advisories/GHSA-abcd-efgh-ijkl"
    run_body_check
    [ "${status}" -eq 0 ]
    [ ! -f "${GH_LOG}" ]
}

@test "a link with an ellipsis or a bare .git for the repository names none, and passes with no lookup" {
    write_visibility "${REPO}" PUBLIC
    write_leak_body "the repositories under https://github.com/credfeto/... and github.com/credfeto/.git"
    run_body_check
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ ! -f "${GH_LOG}" ]
}

@test "a reference to a public repository passes, and each repository is looked up once per run" {
    write_visibility "${REPO}" PUBLIC
    write_visibility credfeto/open-thing PUBLIC
    printf '%s\n' "https://github.com/credfeto/open-thing/issues/1" "credfeto/open-thing#2" \
        "https://github.com/credfeto/open-thing.git" "git@github.com:credfeto/open-thing.git" "CREDFETO/OPEN-THING#3" "https://github.com/credfeto/open-thing." > "${TEST_TMP}/leak.md"
    run_body_check
    [ "${status}" -eq 0 ]
    [ "$(gh_call_count "--json visibility")" -eq 2 ]
    [ "$(visibility_lookups "${REPO}")" -eq 1 ]
    [ "$(visibility_lookups credfeto/open-thing)" -eq 1 ]
}

@test "the first private reference in the body is the one refused, after the public ones before it pass" {
    write_visibility "${REPO}" PUBLIC
    write_visibility credfeto/open-thing PUBLIC
    write_visibility credfeto/hidden-thing PRIVATE
    printf '%s\n' "credfeto/open-thing#1" "fine" "https://github.com/credfeto/hidden-thing" "credfeto/hidden-thing#9" > "${TEST_TMP}/leak.md"
    run_body_check
    [ "${status}" -eq 8 ]
    [ "${stderr}" = "cfwf: body refused: private repository (line 3)" ]
}

@test "a visibility lookup that fails is a runtime failure (exit 1), never a pass or a refusal" {
    write_visibility "${REPO}" PUBLIC
    fail_visibility credfeto/flaky-thing
    write_leak_body "see credfeto/flaky-thing#3"
    run_body_check
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: could not read the visibility of the repository named on line 3 of the body" ]

    rm -f "${GH_FIXTURES}"/visibility-*
    fail_visibility "${REPO}"
    run_body_check
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: could not read the visibility of ${REPO}" ]
}

@test "an owner in CFWF_PRIVATE_OWNERS is refused with no lookup, even as a bare owner/repo" {
    write_visibility "${REPO}" PUBLIC
    local reference
    for reference in "secret-org/plans" "https://github.com/Secret-Org/plans/issues/1" "secret-org/plans#4" "\`other-hidden/plans\`"; do
        write_leak_body "see ${reference}"
        rm -f "${GH_LOG}"
        CFWF_PRIVATE_OWNERS="secret-org other-hidden" run_body_check
        assert_refused "${status}" "${output}" "${stderr}" "private repository" "plans"
        [ "$(gh_call_count "--json visibility")" -eq "$(visibility_lookups "${REPO}")" ]
    done
}

@test "a bare owner/repo inside a longer path is not read as a reference to a listed owner" {
    write_visibility "${REPO}" PUBLIC
    write_leak_body "see src/secret-org/plans and docs.secret-org/plans"
    CFWF_PRIVATE_OWNERS="secret-org" run_body_check
    [ "${status}" -eq 0 ]
    [ ! -f "${GH_LOG}" ]
}

@test "a value in CFWF_PRIVATE_OWNERS that is not an owner is a runtime failure" {
    write_visibility "${REPO}" PUBLIC
    write_leak_body "see credfeto/x#1"
    CFWF_PRIVATE_OWNERS="good bad/owner" run_body_check
    [ "${status}" -eq 1 ]
    [[ "${stderr}" == *"CFWF_PRIVATE_OWNERS holds a value that is not an owner"* ]]
}

@test "issue create refuses a body naming a private repository before any board read or write" {
    prepare_issue_create
    write_visibility "${REPO}" PUBLIC
    write_leak_body "see https://github.com/credfeto/hidden-thing/issues/4"
    run_issue_create_leak
    assert_refused "${status}" "${output}" "${stderr}" "private repository" "hidden-thing"
    assert_nothing_created
    [ "$(gh_call_count "label list")" -eq 0 ]
    [ "$(gh_call_count "project field-list")" -eq 0 ]
    [ "$(gh_call_count "--json projectsV2")" -eq 0 ]
}

@test "issue create checks the stdin copy it hands to gh, and refuses a leak there before any write" {
    prepare_issue_create
    run --separate-stderr "${SCRIPT}" issue create --repo "${REPO}" --priority High --title T --body-file - <<< "a path /tmp/out"
    [ "${status}" -eq 8 ]
    [ "${stderr}" = "cfwf: body refused: host path (line 1)" ]
    [ ! -f "${GH_LOG}" ]
}

@test "body check reads the body from stdin, and leaves no temporary file behind" {
    local scratch="${TEST_TMP}/tmp"
    mkdir -p "${scratch}"
    write_visibility "${REPO}" PUBLIC
    write_visibility credfeto/open-thing PUBLIC
    TMPDIR="${scratch}" run --separate-stderr "${SCRIPT}" body check --repo "${REPO}" --body-file - <<< "see credfeto/open-thing#1"
    [ "${status}" -eq 0 ]
    [ "$(visibility_lookups credfeto/open-thing)" -eq 1 ]
    [ -z "$(ls -A "${scratch}")" ]

    TMPDIR="${scratch}" run --separate-stderr "${SCRIPT}" body check --repo "${REPO}" --body-file - <<< "see /home/x/y"
    [ "${status}" -eq 8 ]
    [ -z "$(ls -A "${scratch}")" ]
}

@test "body check help and usage errors, none of which call gh" {
    run "${SCRIPT}" body check --help
    [ "${status}" -eq 0 ]
    [[ "${output}" == "Usage: cfwf body check"* ]]

    run "${SCRIPT}" body -h
    [ "${status}" -eq 0 ]
    [[ "${output}" == "Usage: cfwf body check"* ]]

    run --separate-stderr "${SCRIPT}" body
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == *"body needs a subcommand (check)"* ]]

    run --separate-stderr "${SCRIPT}" body frobnicate
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == *"unknown body subcommand: frobnicate"* ]]

    printf 'clean\n' > "${TEST_TMP}/leak.md"
    run --separate-stderr "${SCRIPT}" body check --body-file "${TEST_TMP}/leak.md"
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == *"missing required option --repo"* ]]
    [[ "${stderr}" == *"Usage: cfwf body check"* ]]

    run --separate-stderr "${SCRIPT}" body check --repo "${REPO}"
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == *"missing required option --body-file"* ]]

    run --separate-stderr "${SCRIPT}" body check --repo "${REPO}" --body-file "${TEST_TMP}/leak.md" --title T
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == *"unknown option: --title"* ]]

    run --separate-stderr "${SCRIPT}" body check --repo "${REPO}" --repo credfeto/other --body-file "${TEST_TMP}/leak.md"
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == *"--repo can only be given once"* ]]

    run --separate-stderr "${SCRIPT}" body check --repo "no-slash" --body-file "${TEST_TMP}/leak.md"
    [ "${status}" -eq 2 ]

    local flag
    for flag in --skip-leak-check --force; do
        run --separate-stderr "${SCRIPT}" body check --repo "${REPO}" --body-file "${TEST_TMP}/leak.md" "${flag}"
        [ "${status}" -eq 2 ]
        [[ "${stderr}" == *"unknown option: ${flag}"* ]]
    done
    [ ! -f "${GH_LOG}" ]
}

@test "body check refuses a missing or blank body as a runtime failure, without calling gh" {
    run --separate-stderr "${SCRIPT}" body check --repo "${REPO}" --body-file "${TEST_TMP}/nope.md"
    [ "${status}" -eq 1 ]
    [[ "${stderr}" == *"cannot read the body file"* ]]

    printf ' \n' > "${TEST_TMP}/blank.md"
    run --separate-stderr "${SCRIPT}" body check --repo "${REPO}" --body-file "${TEST_TMP}/blank.md"
    [ "${status}" -eq 1 ]
    [ ! -f "${GH_LOG}" ]
}
