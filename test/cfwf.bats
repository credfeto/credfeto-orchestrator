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
        '  "repo view") case " $* " in *" --json visibility "*) v="${3,,}"; f="${GH_FIXTURES}/visibility-${v//\//_}"; [ -f "${f}.fail" ] && { if [ -s "${f}.fail" ]; then cat "${f}.fail" >&2; else echo "HTTP 502: Bad Gateway" >&2; fi; exit 1; }; [ -f "${f}.json" ] || { echo "GraphQL: Could not resolve to a Repository with the name ${3}. (repository)" >&2; exit 1; }; emit "${f}.json"; exit 0 ;; esac; [ -f "${GH_FIXTURES}/repo-view.fail" ] && { echo "boom" >&2; exit 1; }; emit "${GH_FIXTURES}/repo-view.json" ;;' \
        '  "project field-list") emit "${GH_FIXTURES}/field-list.json" ;;' \
        '  "project item-add") [ -f "${GH_FIXTURES}/item-add.fail" ] && { echo "boom" >&2; exit 1; }; emit "${GH_FIXTURES}/item-add.json" ;;' \
        '  "project item-edit") [ -f "${GH_FIXTURES}/item-edit.fail" ] && { echo "boom" >&2; exit 1; }; exit 0 ;;' \
        '  "project item-list") [ -f "${GH_FIXTURES}/item-list.fail" ] && { echo "boom" >&2; exit 1; }; emit "${GH_FIXTURES}/item-list.json" ;;' \
        '  "api graphql") [ -f "${GH_FIXTURES}/graphql.fail" ] && { cat "${GH_FIXTURES}/graphql.fail" >&2; exit 1; }; [ -f "${GH_FIXTURES}/graphql.failout" ] && { cat "${GH_FIXTURES}/graphql.failout"; exit 1; }; [ -f "${GH_FIXTURES}/graphql.stderr" ] && cat "${GH_FIXTURES}/graphql.stderr" >&2; emit "${GH_FIXTURES}/graphql-target.json" ;;' \
        '  "pr view") [ -f "${GH_FIXTURES}/pr-view.json" ] || exit 1; emit "${GH_FIXTURES}/pr-view.json" ;;' \
        '  "label list") [ -f "${GH_FIXTURES}/label-list.rewrite" ] && printf "%s\n" "rewritten with /tmp/leak" > "$(cat "${GH_FIXTURES}/label-list.rewrite")"; [ -f "${GH_FIXTURES}/label-list.fail" ] && { echo "boom" >&2; exit 1; }; emit "${GH_FIXTURES}/label-list.json" ;;' \
        '  "label create") [ -f "${GH_FIXTURES}/label-create.fail" ] && { cat "${GH_FIXTURES}/label-create.fail" >&2; exit 1; }; exit 0 ;;' \
        '  "issue create") prev=""; for arg in "$@"; do [ "${prev}" = "--body-file" ] && cp "${arg}" "${GH_FIXTURES}/issue-body.txt"; prev="${arg}"; done; [ -f "${GH_FIXTURES}/issue-create.fail" ] && { echo "boom" >&2; exit 1; }; cat "${GH_FIXTURES}/issue-create.out" ;;' \
        '  "issue view") f="${GH_FIXTURES}/issue-view-$3.json"; [ -f "${f}" ] || exit 1; emit "${f}" ;;' \
        '  "api repos/"*) e="${2%%\?*}"; f="${GH_FIXTURES}/api-${e//\//_}"; [ -f "${f}.fail" ] && { cat "${f}.fail" >&2; exit 1; }; [ -f "${f}.json" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }; emit "${f}.json" ;;' \
        '  "pr comment" | "issue comment") prev=""; for arg in "$@"; do [ "${prev}" = "--body-file" ] && cp "${arg}" "${GH_FIXTURES}/comment-body.txt"; prev="${arg}"; done; readlink /proc/self/fd/0 > "${GH_FIXTURES}/comment-stdin.txt"; [ -f "${GH_FIXTURES}/comment.fail" ] && { echo "boom" >&2; exit 1; }; cat "${GH_FIXTURES}/comment.out" ;;' \
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

# Succeeds when gh was called with exactly the arguments $1, where BODY stands for the --body-file
# path: cfwf hands gh its private copy of the body, whose name mktemp chooses.
issue_create_called_with() {
    sed -E 's/ --body-file [^ ]+( |$)/ --body-file BODY\1/' "${GH_LOG}" | grep -qxF -- "$1"
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
        [[ "${output}" == *"pr checks"*"(exit 0, 3, 4 or 5)"* ]]
        [[ "${output}" == *"comment add"* ]]
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
    [[ "${output}" == *"and so are the title and each --label"* ]]

    run "${SCRIPT}" help body
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"cfwf body check --repo <owner/repo> --body-file <file|->"* ]]
    [[ "${output}" == *"and exits 8"* ]]
    [[ "${output}" == *"CFWF_PRIVATE_OWNERS"* ]]
    [[ "${output}" == *"There is no option to skip"*"the check."* ]]

    run "${SCRIPT}" help comment
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"cfwf comment add --repo <owner/repo> (--pr <n> | --issue <n>) --body-file <file|->"* ]]
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
    [[ "${output}" == *"unknown command (argument 1; its value is not shown)"* && "${output}" != *frobnicate* ]]
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
    [[ "${output}" == *"unknown option (argument 3; its value is not shown)"* && "${output}" != *--bogus* ]]

    run "${SCRIPT}" workflow-status --set --repo
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"--repo needs a value"* ]]
}

@test "the board ids and the URL are not options any more: they are derived from --repo and --status" {
    local flag
    for flag in --owner --project-number --project-id --field-id --option-id --url; do
        run "${SCRIPT}" workflow-status --set --repo "${REPO}" --issue 1346 --status Approved "${flag}" value
        [ "${status}" -eq 2 ] || { echo "${flag} was accepted" >&2; return 1; }
        [[ "${output}" == *"unknown option (argument 9; its value is not shown)"* ]]
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
    [[ "${output}" == *"unknown --status"* ]]
    [ "$(gh_call_count "project item-add")" -eq 0 ]
    [ "$(gh_call_count "project item-edit")" -eq 0 ]
}

@test "--set refuses an option the board has that is not a workflow state, and writes nothing (#1519)" {
    jq -n '{fields: [{id: "PVTSSF_status", name: "Status", options: [
        {id: "st_3", name: "Approved"}, {id: "x1", name: "Banana"}], type: "ProjectV2SingleSelectField"}]}' > "${GH_FIXTURES}/field-list.json"
    run "${SCRIPT}" workflow-status --set --repo "${REPO}" --issue 1346 --status banana
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"unknown --status (valid: "* && "${output}" != *banana* ]]
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

@test "--set builds the item URL from a number given with leading zeros as that number, without them" {
    run "${SCRIPT}" workflow-status --set --repo "${REPO}" --issue 01346 --status Approved
    [ "${status}" -eq 0 ]
    [ "${output}" = "Set ${ISSUE_URL} to Approved" ]
    grep -qxF "project item-add 74 --owner credfeto --url ${ISSUE_URL} --format json --jq .id" "${GH_LOG}"

    : > "${GH_LOG}"
    run "${SCRIPT}" workflow-status --set --repo "${REPO}" --pr 0001481 --status Approved
    [ "${status}" -eq 0 ]
    grep -qxF "project item-add 74 --owner credfeto --url https://github.com/credfeto/credfeto-orchestrator/pull/1481 --format json --jq .id" "${GH_LOG}"

    : > "${GH_LOG}"
    run "${SCRIPT}" workflow-status --set --repo "${REPO}" --issue 000 --status Approved
    [ "${status}" -eq 0 ]
    grep -qxF "project item-add 74 --owner credfeto --url https://github.com/credfeto/credfeto-orchestrator/issues/0 --format json --jq .id" "${GH_LOG}"
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
    [[ "${output}" == *"unknown --status (valid: "* && "${output}" != *Todo* ]]
    [ "$(gh_call_count "project item-add")" -eq 0 ]
    [ "$(gh_call_count "project item-edit")" -eq 0 ]
}

@test "--set lists the valid statuses when the name is unknown, and writes nothing" {
    run "${SCRIPT}" workflow-status --set --repo "${REPO}" --issue 1346 --status Nonsense
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"unknown --status (valid: Not Started, Planning, Approved, Development, AI Simplify, AI Review, AI Security Review, AI Coverage, Human Review, Complete)"* ]]
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

@test "--check reads a number given with leading zeros as that number, directly and from the listing" {
    run "${SCRIPT}" workflow-status --check --repo "${REPO}" --issue 01346
    [ "${status}" -eq 0 ]
    [ "${output}" = "Approved" ]
    grep -qF -- "-F n=1346 " "${GH_LOG}"

    use_fallback
    run --separate-stderr "${SCRIPT}" workflow-status --check --repo "${REPO}" --issue 01346
    [ "${status}" -eq 0 ]
    [ "${output}" = "Approved" ]
    grep -qF '.content.number==1346 ' "${GH_LOG}"

    use_fallback "GraphQL: Could not resolve to an Issue with the number of 1481."
    run "${SCRIPT}" workflow-status --check --repo "${REPO}" --issue 01481
    [ "${status}" -eq 1 ]
    [ "${output}" = "cfwf: ${REPO}#1481 is not on project 74" ]
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

@test "closing-issue-labels reads a PR number given with leading zeros as that number, without them" {
    write_pr_view "credfeto/credfeto-orchestrator 10"
    jq -n '{labels: [{name: "Medium"}]}' > "${GH_FIXTURES}/issue-view-10.json"
    run "${SCRIPT}" closing-issue-labels --repo "${REPO}" --pr 01481
    [ "${status}" -eq 0 ]
    [ "${output}" = "Medium" ]
    grep -qF "pr view 1481 --repo ${REPO} " "${GH_LOG}"
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

# --- pr comments and pr reply ---------------------------------------------------

DISCUSSION_URL="https://github.com/credfeto/credfeto-orchestrator/pull/42"
TAB=$'\t'

# Replaces the gh stand-in of setup, for these tests only, with one that answers what pr comments
# and pr reply call. It logs each call on one line. A GraphQL call is answered only when its query
# reads review threads, from the fixture named after the cursors it was given (discussion.json for
# the first page, discussion-reviews-r2.json for the page of reviews after the cursor r2), so each
# page is a call of its own; a GET of an inline comment is answered as setup's stand-in answers any
# API path; a POST to .../replies copies the file it is given as the body to reply-body.txt and
# answers from reply.json. An answer is the fixture with the call's own --jq filter applied by the
# real jq; beside a fixture, .fail is the stderr of a failed call (.failout its stdout), .raw an
# answer printed as it is, and .stderr noise on a call that works. When the file rewrite exists,
# the read of an inline comment overwrites the file it names, so a test can change the body file
# after the check. It never reads stdin.
prepare_pr_comments() {
    # shellcheck disable=SC2016  # the stub body must expand when the stub runs, not here
    make_stub_multiline gh \
        'log="$*"; printf "%s\n" "${log//[[:cntrl:]]/ }" >> "${GH_LOG}"' \
        'jq_expr=""; prev=""; body=""; cursors=""' \
        'for arg in "$@"; do' \
        '  [ "${prev}" = "--jq" ] && jq_expr="${arg}"' \
        '  case "${arg}" in' \
        '    body=@*) body="${arg#body=@}" ;;' \
        '    commentsAfter=* | reviewsAfter=* | threadsAfter=*) cursors+="-${arg%%After=*}-${arg#*=}" ;;' \
        '  esac' \
        '  prev="${arg}"' \
        'done' \
        'answer() {' \
        '  if [ -f "$1.fail" ]; then [ ! -f "$1.failout" ] || cat "$1.failout"; cat "$1.fail" >&2; exit 1; fi' \
        '  if [ -f "$1.raw" ]; then cat "$1.raw"; exit 0; fi' \
        '  [ ! -f "$1.stderr" ] || cat "$1.stderr" >&2' \
        '  [ -f "$1.json" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }' \
        '  jq -r "${jq_expr}" < "$1.json"' \
        '  exit "$?"' \
        '}' \
        'case "$1 $2" in' \
        '  "api graphql") case "$*" in *reviewThreads*) answer "${GH_FIXTURES}/discussion${cursors}" ;; esac ;;' \
        '  "api --method") case "$3 $4" in "POST repos/"*"/replies") cp "${body}" "${GH_FIXTURES}/reply-body.txt"; answer "${GH_FIXTURES}/reply" ;; esac ;;' \
        '  "api repos/"*) [ ! -f "${GH_FIXTURES}/rewrite" ] || printf "%s\n" "rewritten with /tmp/leak" > "$(cat "${GH_FIXTURES}/rewrite")"; answer "${GH_FIXTURES}/api-${2//\//_}" ;;' \
        '  "repo view") case " $* " in *" --json visibility "*) v="${3,,}"; f="${GH_FIXTURES}/visibility-${v//\//_}"; [ -f "${f}.fail" ] && { echo "HTTP 502: Bad Gateway" >&2; exit 1; }; [ -f "${f}.json" ] || { echo "GraphQL: Could not resolve to a Repository with the name ${3}. (repository)" >&2; exit 1; }; jq -r "${jq_expr}" < "${f}.json"; exit 0 ;; esac ;;' \
        'esac' \
        'echo "gh stub: unexpected call: $*" >&2; exit 99'
}

# One item of a discussion as GraphQL gives it: $1 the start of its URL fragment, $2 its id, $3 its
# author's login and $4 the author's __typename (none for a deleted account, which has no author),
# $5 its body and $6 its other fields, as JSON. databaseId is a decoy: only fullDatabaseId is read.
discussion_node() {
    jq -n --arg fragment "$1" --arg id "$2" --arg login "$3" --arg type "$4" --arg body "$5" --argjson more "$6" --arg url "${DISCUSSION_URL}" \
        '{fullDatabaseId: $id, databaseId: 1, url: ($url + "#" + $fragment + $id), body: $body,
          author: (if $type == "none" then null else {__typename: $type, login: $login} end),
          authorAssociation: (if $type == "User" then "OWNER" else "NONE" end)} + $more'
}

# A top-level comment: id, login, __typename, body.
issue_comment_node() {
    discussion_node issuecomment- "$1" "$2" "$3" "$4" '{"createdAt": "2026-10-08T10:17:52Z", "isMinimized": false}'
}

# A review: id, login, __typename, state, body.
review_node() {
    discussion_node pullrequestreview- "$1" "$2" "$3" "$5" "{\"state\": \"$4\", \"submittedAt\": \"2026-10-08T14:44:59Z\"}"
}

# An inline comment: id, the id it answers ("" for the first of a thread), its review's id, login,
# __typename, body.
inline_node() {
    local reply_to=null
    [ -z "$2" ] || reply_to="{\"fullDatabaseId\": \"$2\"}"
    discussion_node discussion_r "$1" "$4" "$5" "$6" \
        "{\"replyTo\": ${reply_to}, \"pullRequestReview\": {\"fullDatabaseId\": \"$3\"}, \"createdAt\": \"2026-10-08T15:12:05Z\", \"isMinimized\": false}"
}

# A review thread: resolved and outdated (true or false), path, line (null for none), original
# line, then its inline comments, each an inline_node object.
thread_node() {
    local resolved="$1" outdated="$2" path="$3" line="$4" original="$5"
    shift 5
    printf '%s\n' "$@" | jq -s --argjson resolved "${resolved}" --argjson outdated "${outdated}" --arg path "${path}" \
        --argjson line "${line}" --argjson original "${original}" \
        '{isResolved: $resolved, isOutdated: $outdated, path: $path, line: $line, originalLine: $original,
          comments: {totalCount: length, pageInfo: {hasNextPage: false, endCursor: null}, nodes: .}}'
}

# One list of a page: GitHub's count of the whole list, whether another page follows (true or
# false), that page's cursor ("" for none), then the nodes on this page.
discussion_list() {
    local total="$1" more="$2" cursor="$3"
    shift 3
    printf '%s\n' "$@" | jq -s --argjson total "${total}" --argjson more "${more}" --arg cursor "${cursor}" \
        '{totalCount: $total, pageInfo: {hasNextPage: $more, endCursor: (if $cursor == "" then null else $cursor end)}, nodes: .}'
}

# A list with nothing in it and no other page.
empty_list() {
    discussion_list 0 false ""
}

# Writes the page read with the cursors $1 ("" for the first page, -reviews-r2 for the page of
# reviews after r2): the review decision $2 as JSON, then the comments, the reviews and the threads,
# each a discussion_list object, or "" for a list the page was not asked for, which GitHub leaves
# out of its answer.
write_page() {
    jq -n --argjson decision "$2" --arg comments "$3" --arg reviews "$4" --arg threads "$5" \
        '{data: {repository: {pullRequest: ({reviewDecision: $decision}
            + (if $comments == "" then {} else {comments: ($comments | fromjson)} end)
            + (if $reviews == "" then {} else {reviews: ($reviews | fromjson)} end)
            + (if $threads == "" then {} else {reviewThreads: ($threads | fromjson)} end))}}}' \
        > "${GH_FIXTURES}/discussion$1.json"
}

# A pull request whose whole discussion is the one top-level comment with the body $1.
write_one_comment_page() {
    write_page "" null "$(discussion_list 1 false "" "$(issue_comment_node 7 credfeto User "$1")")" "$(empty_list)" "$(empty_list)"
}

run_pr_comments() {
    run --separate-stderr "${SCRIPT}" pr comments --repo "${REPO}" "$@"
}

# The inline comment 500 of pull request 42, which starts its thread, the answer GitHub gives to a
# reply posted to it, and a body to post.
prepare_pr_reply() {
    prepare_pr_comments
    write_inline_comment 500 "" 42
    jq -n --arg url "${DISCUSSION_URL}#discussion_r900" '{id: 900, html_url: $url, in_reply_to_id: 500}' > "${GH_FIXTURES}/reply.json"
    printf 'Fixed in the next commit.\n\nThanks for spotting it.\n' > "${TEST_TMP}/reply.md"
}

# Writes the inline comment $1 as REST gives it: the id it answers ($2, "" for none) and the pull
# request it is on ($3), named as a proxy in front of the API names it.
write_inline_comment() {
    jq -n --argjson id "$1" --arg parent "$2" --arg pull "$3" \
        '{id: $id, in_reply_to_id: (if $parent == "" then null else ($parent | tonumber) end),
          pull_request_url: ("http://api-proxy.example.com/repos/credfeto/credfeto-orchestrator/pulls/" + $pull)}' \
        | write_api "repos/${REPO}/pulls/comments/$1"
}

run_pr_reply() {
    run --separate-stderr "${SCRIPT}" pr reply --repo "${REPO}" "$@"
}

reply_posts() {
    gh_call_count "api --method POST"
}

@test "pr comments and pr reply help describe the format, the exit codes and the retry rule, and call no gh" {
    local flag key
    for flag in --help -h; do
        run "${SCRIPT}" pr comments "${flag}"
        [ "${status}" -eq 0 ]
        [[ "${output}" == *"Usage: cfwf pr comments --repo <owner/repo> --pr <n>"* ]]
        for key in pr review-decision comment review thread inline in-reply-to author association state created-at \
            submitted-at minimized url resolved outdated path line original-line comments lines; do
            grep -qE "^  ${key} +[^ ]" <<< "${output}" || { echo "no ${key} in the help" >&2; return 1; }
        done
        [[ "${output}" == *"summary comments=<a> reviews=<b> reviews-empty=<c> threads=<d> unresolved=<e> inline=<f>"* ]]
        [[ "${output}" == *"cfwf makes no trust decision"* ]]
        [[ "${output}" == *"line that is not empty and has neither a tab nor a leading \"|\""* ]]
        [[ "${output}" == *"Exit codes: 0 printed; 9 the pull request does not exist (the number of an issue included); 1 a"* ]]
        [[ "${output}" == *"2 a usage error."* ]]

        run "${SCRIPT}" pr reply "${flag}"
        [ "${status}" -eq 0 ]
        [[ "${output}" == *"Usage: cfwf pr reply --repo <owner/repo> --pr <n> --comment-id <id> --body-file <file|->"* ]]
        [[ "${output}" == *"There is no --body."* ]]
        [[ "${output}" == *"A refused"*"body exits 8"* ]]
        [[ "${output}" == *"It posts once and never tries again. When GitHub refuses the post with HTTP 400, 401, 403, 404,"* ]]
        [[ "${output}" == *"any other HTTP 4xx"*"it says the reply may have been posted"* ]]
        [[ "${output}" == *"do not run it again blindly"* ]]
        [[ "${output}" == *"an inline reply can never be"*"taken for one"* ]]
        [[ "${output}" == *"Exit codes: 0 posted; 8 the body was refused; 9 --comment-id is not an inline review comment"* ]]
    done

    run "${SCRIPT}" help
    [[ "${output}" == *"pr comments "*"(exit 9 when not found)"* ]]
    [[ "${output}" == *"pr reply "*"(exit 8 when the body is refused)"* ]]

    run "${SCRIPT}" help pr
    [[ "${output}" == *"Run 'cfwf pr comments --help' and 'cfwf pr reply --help' for reading and answering a pull"* ]]

    run "${SCRIPT}" help workflow-status
    [[ "${output}" == *"--check and 'cfwf pr comments' are the only"*"places cfwf uses GraphQL, and both only read"* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "pr needs a subcommand and names all three, and pr comments usage errors exit 2 before any gh call" {
    prepare_pr_comments
    run --separate-stderr "${SCRIPT}" pr
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: pr needs a subcommand (checks, comments or reply)"* ]]
    [[ "${stderr}" == *"Usage: cfwf pr checks"* ]]

    local -a cases=("" "--pr 42 --pr 43" "--pr 0" "--pr 000" "--pr x42" "--pr -1" "--pr 42 --issue 3" "--pr 42 --json comments"
        "--pr 42 --jq ." "--pr 42 --template x" "--pr 42 --unresolved" "--pr 42 --comment-id 5" "--pr 42 extra" "--pr")
    local args
    for args in "${cases[@]}"; do
        # shellcheck disable=SC2086  # each case is split into its words on purpose
        run_pr_comments ${args}
        [ "${status}" -eq 2 ] || { echo "accepted: ${args} (${status})" >&2; return 1; }
        [ -z "${output}" ]
        [[ "${stderr}" == *"Usage: cfwf pr comments"* ]]
    done

    run --separate-stderr "${SCRIPT}" pr comments --pr 42
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: missing required option --repo"* ]]

    run_pr_comments --repo "${REPO}" --pr 42
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: --repo can only be given once"* ]]

    run_pr_comments
    [[ "${stderr}" == "cfwf: missing required option --pr"* ]]

    run_pr_comments --pr 0
    [[ "${stderr}" == "cfwf: invalid value for --pr: it must be above 0"* ]]

    local stray="gh""p_LEAKMARKER0123456789"
    run_pr_comments --pr 42 "${stray}"
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: unknown option (argument 7; its value is not shown)"* && "${stderr}" != *"${stray}"* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "pr comments prints the comments, the reviews and each thread with its inline comments, in one read-only call" {
    prepare_pr_comments
    local first second
    first="$(thread_node false false src/run.sh 12 12 \
        "$(inline_node 4220417677 "" 5458415384 credfeto User $'This loop never ends when the list is empty.\n\nSee the guard above.')" \
        "$(inline_node 4220734699 4220417677 5458817077 "" none "Fixed.")")"
    second="$(thread_node true false docs/a.md 3 3 "$(inline_node 4230000001 "" 5458415384 credfeto User "Typo.")")"
    write_page "" '"CHANGES_REQUESTED"' \
        "$(discussion_list 1 false "" "$(issue_comment_node 6057704122 github-actions Bot $'<!-- sarif-summary: 0 -->\nNo findings.')")" \
        "$(discussion_list 2 false "" "$(review_node 5458415384 credfeto User CHANGES_REQUESTED "")" "$(review_node 5458817077 credfeto User COMMENTED $' \n\t\n')")" \
        "$(discussion_list 3 false "" "${first}" "${second}" \
            "$(thread_node false true src/old.sh null 7 "$(inline_node 4230000002 "" 5458817077 credfeto User "Still needed?")")")"

    run_pr_comments --pr 42
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    local expected
    expected="$(printf '%s\n' \
        "pr${TAB}${REPO}#42" "review-decision${TAB}CHANGES_REQUESTED" "" \
        "comment${TAB}6057704122" "author${TAB}app/github-actions" "association${TAB}NONE" "created-at${TAB}2026-10-08T10:17:52Z" \
        "minimized${TAB}no" "url${TAB}${DISCUSSION_URL}#issuecomment-6057704122" "lines${TAB}2" "| <!-- sarif-summary: 0 -->" "| No findings." "" \
        "review${TAB}5458415384" "author${TAB}credfeto" "association${TAB}OWNER" "state${TAB}CHANGES_REQUESTED" \
        "submitted-at${TAB}2026-10-08T14:44:59Z" "url${TAB}${DISCUSSION_URL}#pullrequestreview-5458415384" "lines${TAB}0" "" \
        "thread${TAB}4220417677" "resolved${TAB}no" "outdated${TAB}no" "path${TAB}src/run.sh" "line${TAB}12" "original-line${TAB}12" "comments${TAB}2" "" \
        "inline${TAB}4220417677" "in-reply-to${TAB}" "review${TAB}5458415384" "author${TAB}credfeto" "association${TAB}OWNER" \
        "created-at${TAB}2026-10-08T15:12:05Z" "minimized${TAB}no" "url${TAB}${DISCUSSION_URL}#discussion_r4220417677" "lines${TAB}3" \
        "| This loop never ends when the list is empty." "|" "| See the guard above." "" \
        "inline${TAB}4220734699" "in-reply-to${TAB}4220417677" "review${TAB}5458817077" "author${TAB}" "association${TAB}NONE" \
        "created-at${TAB}2026-10-08T15:12:05Z" "minimized${TAB}no" "url${TAB}${DISCUSSION_URL}#discussion_r4220734699" "lines${TAB}1" "| Fixed." "" \
        "thread${TAB}4230000001" "resolved${TAB}yes" "outdated${TAB}no" "path${TAB}docs/a.md" "line${TAB}3" "original-line${TAB}3" "comments${TAB}1" "" \
        "inline${TAB}4230000001" "in-reply-to${TAB}" "review${TAB}5458415384" "author${TAB}credfeto" "association${TAB}OWNER" \
        "created-at${TAB}2026-10-08T15:12:05Z" "minimized${TAB}no" "url${TAB}${DISCUSSION_URL}#discussion_r4230000001" "lines${TAB}1" "| Typo." "" \
        "thread${TAB}4230000002" "resolved${TAB}no" "outdated${TAB}yes" "path${TAB}src/old.sh" "line${TAB}" "original-line${TAB}7" "comments${TAB}1" "" \
        "inline${TAB}4230000002" "in-reply-to${TAB}" "review${TAB}5458817077" "author${TAB}credfeto" "association${TAB}OWNER" \
        "created-at${TAB}2026-10-08T15:12:05Z" "minimized${TAB}no" "url${TAB}${DISCUSSION_URL}#discussion_r4230000002" "lines${TAB}1" "| Still needed?" "" \
        "summary comments=1 reviews=1 reviews-empty=1 threads=3 unresolved=2 inline=4")"
    [ "${output}" = "${expected}" ]

    [ "$(wc -l < "${GH_LOG}")" -eq 1 ]
    local call
    call="$(cat "${GH_LOG}")"
    [[ "${call}" == "api graphql -f query=query("*" -f o=credfeto -f r=credfeto-orchestrator -F n=42 -F comments=true -F reviews=true -F threads=true --jq "* ]]
    [[ "${call}" != *"--repo"* && "${call}" != *mutation* && "${call}" != *After=* && "${call}" != *"--paginate"* ]]
    [[ "${call}" == *"comments(first:100,after:\$commentsAfter) @include(if:\$comments)"* ]]
    [[ "${call}" == *"reviews(first:100,after:\$reviewsAfter) @include(if:\$reviews)"* ]]
    [[ "${call}" == *"reviewThreads(first:100,after:\$threadsAfter) @include(if:\$threads)"* ]]
}

@test "pr comments prints the first block and a summary of zeros for a pull request nobody has said anything on" {
    prepare_pr_comments
    write_page "" null "$(empty_list)" "$(empty_list)" "$(empty_list)"
    run_pr_comments --pr 0042
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' "pr${TAB}${REPO}#42" "review-decision${TAB}" "" "summary comments=0 reviews=0 reviews-empty=0 threads=0 unresolved=0 inline=0")" ]
    [ "$(gh_call_count " -F n=42 ")" -eq 1 ]
}

@test "pr comments prints each review decision as GitHub gives it, and none as an empty value" {
    prepare_pr_comments
    local decision
    for decision in APPROVED CHANGES_REQUESTED REVIEW_REQUIRED; do
        write_page "" "\"${decision}\"" "$(empty_list)" "$(empty_list)" "$(empty_list)"
        run_pr_comments --pr 42
        [ "${status}" -eq 0 ]
        [[ "${output}" == *$'\n'"review-decision${TAB}${decision}"$'\n'* ]]
    done
    write_page "" '"SOMETHING\tNEW\nsummary x"' "$(empty_list)" "$(empty_list)" "$(empty_list)"
    run_pr_comments --pr 42
    [[ "${output}" == *$'\n'"review-decision${TAB}SOMETHING NEW summary x"$'\n'* ]]
}

@test "pr comments prints a user as the login, a bot as app/slug, any other kind as kind/login and a deleted account as empty" {
    prepare_pr_comments
    write_page "" null \
        "$(discussion_list 5 false "" "$(issue_comment_node 1 credfeto User a)" "$(issue_comment_node 2 credfeto Bot b)" \
            "$(issue_comment_node 3 old-import Mannequin c)" "$(issue_comment_node 4 "" none d)" "$(issue_comment_node 5 acme Organization e)")" \
        "$(discussion_list 1 false "" "$(review_node 6 dependabot Bot APPROVED "")")" \
        "$(discussion_list 1 false "" "$(thread_node false false a.sh 1 1 "$(inline_node 7 "" 6 copilot Bot f)")")"
    run_pr_comments --pr 42
    [ "${status}" -eq 0 ]
    [ "$(grep "^author${TAB}" <<< "${output}")" = "$(printf '%s\n' "author${TAB}credfeto" "author${TAB}app/credfeto" "author${TAB}mannequin/old-import" \
        "author${TAB}" "author${TAB}organization/acme" "author${TAB}app/dependabot" "author${TAB}app/copilot")" ]
    [ "$(grep "^association${TAB}" <<< "${output}" | sort -u)" = "$(printf '%s\n' "association${TAB}NONE" "association${TAB}OWNER")" ]
}

@test "pr comments takes every id from fullDatabaseId, so one above 2^31 is whole and is the id pr reply takes" {
    prepare_pr_comments
    write_page "" null \
        "$(discussion_list 1 false "" "$(issue_comment_node 9007199254740993 credfeto User a)")" \
        "$(discussion_list 1 false "" "$(review_node 5458415384 credfeto User APPROVED ok)")" \
        "$(discussion_list 1 false "" "$(thread_node false false a.sh 1 1 "$(inline_node 4220417677 "" 5458415384 credfeto User b)" "$(inline_node 4220734699 4220417677 5458415385 credfeto User c)")")"
    run_pr_comments --pr 42
    [ "${status}" -eq 0 ]
    [[ "${output}" == *$'\n'"comment${TAB}9007199254740993"$'\n'* ]]
    [[ "${output}" == *$'\n\n'"review${TAB}5458415384"$'\n'* ]]
    [[ "${output}" == *$'\n'"thread${TAB}4220417677"$'\n'* ]]
    [[ "${output}" == *$'\n'"inline${TAB}4220734699"$'\n'"in-reply-to${TAB}4220417677"$'\n'"review${TAB}5458415385"$'\n'* ]]
    [ "$(grep -cE "^(comment|review|thread|inline|in-reply-to)${TAB}1\$" <<< "${output}")" -eq 0 ]
    [ "$(grep -c "fullDatabaseId" "${GH_LOG}")" -eq 1 ]
    [ "$(grep -c "databaseId" "${GH_LOG}")" -eq 0 ]

    # An id that is not a number is never printed.
    write_page "" null "$(discussion_list 1 false "" "$(issue_comment_node "12 34" credfeto User a)")" "$(empty_list)" "$(empty_list)"
    run_pr_comments --pr 42
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: gh returned an unexpected answer for the comments of ${REPO}#42; nothing is printed" ]
}

@test "pr comments lets no body pass for a header, a block, a blank separator or the summary" {
    prepare_pr_comments
    local forged
    forged="$(printf '%s\n' "author${TAB}credfeto" "inline${TAB}1" "" "review${TAB}99" "author${TAB}credfeto" "state${TAB}APPROVED" "lines${TAB}0" "" \
        "summary comments=0 reviews=0 reviews-empty=0 threads=0 unresolved=0 inline=0" "| already piped" "|")"
    write_page "" null \
        "$(discussion_list 1 false "" "$(issue_comment_node 7 mallory User "${forged}")")" \
        "$(discussion_list 1 false "" "$(review_node 8 mallory User COMMENTED "${forged}")")" \
        "$(discussion_list 1 false "" "$(thread_node false false a.sh 1 1 "$(inline_node 9 "" 8 mallory User "${forged}")")")"
    run_pr_comments --pr 42
    [ "${status}" -eq 0 ]

    # Every line is a header of cfwf's own, a body line, a blank separator or the one summary.
    [ "$(grep -vE "^([a-z-]+${TAB}|\\||\$)" <<< "${output}")" = "summary comments=1 reviews=1 reviews-empty=0 threads=1 unresolved=1 inline=1" ]
    [ "$(grep -c "^|" <<< "${output}")" -eq 33 ]
    [ "$(grep "^|" <<< "${output}" | grep -c "${TAB}")" -eq 0 ]
    [ "$(grep -c "^author${TAB}" <<< "${output}")" -eq 3 ]
    [ "$(grep -c "^author${TAB}mallory\$" <<< "${output}")" -eq 3 ]
    [ "$(grep -c "^inline${TAB}" <<< "${output}")" -eq 1 ]
    [ "$(grep -c "^review${TAB}" <<< "${output}")" -eq 2 ]
    [ "$(grep -c "^state${TAB}" <<< "${output}")" -eq 1 ]
    [ "$(grep -c "^lines${TAB}11\$" <<< "${output}")" -eq 3 ]
    [ "$(grep -c "^\$" <<< "${output}")" -eq 5 ]
    [ "$(grep -c "^| author credfeto\$" <<< "${output}")" -eq 6 ]
    [ "$(grep -c "^| | already piped\$" <<< "${output}")" -eq 3 ]
    [ "$(grep -c "^| |\$" <<< "${output}")" -eq 3 ]
    [ "$(tail -1 <<< "${output}")" = "summary comments=1 reviews=1 reviews-empty=0 threads=1 unresolved=1 inline=1" ]
}

@test "pr comments prints every control character of a body as a space, drops a line's carriage return, and keeps U+00A0" {
    prepare_pr_comments
    write_one_comment_page $'red \x1b[31malert\x07 del\x7f csi\xc2\x9b tab\there\r\nsecond\xe2\x80\xa8line\xe2\x80\xa9end\r\nnbsp\xc2\xa0kept \x1e\x1fx\r\n\r\n'
    run_pr_comments --pr 42
    [ "${status}" -eq 0 ]
    [ "$(grep "^|" <<< "${output}")" = "$(printf '%s\n' "| red  [31malert  del  csi  tab here" "| second line end" $'| nbsp\xc2\xa0kept   x')" ]
    [[ "${output}" == *$'\n'"lines${TAB}3"$'\n'* ]]
    [ "$(LC_ALL=C grep -c $'[\x01-\x08\x0b-\x1f\x7f]' <<< "${output}")" -eq 0 ]
    [ "$(LC_ALL=C grep -c $'\xc2\x9b\\|\xe2\x80\xa8\\|\xe2\x80\xa9' <<< "${output}")" -eq 0 ]
}

@test "pr comments keeps a path, a login, a state and a URL with control characters or Unicode line ends on one line each" {
    prepare_pr_comments
    local review thread
    review="$(review_node 8 $'mal\nlory\x1b[2J' User APPROVED ok | jq '.state = "APPROVED\nstate\tFORGED\u0000" | .url = "https://example.com/\n\nsummary x"')"
    thread="$(thread_node false false $'src/a\tb\n\nsummary comments=0\x1e\x1f.sh\xe2\x80\xa8author\tcredfeto\xe2\x80\xa9summary x' 1 1 "$(inline_node 9 "" 8 $'bot\tname\xe2\x80\xa8' Bot ok)")"
    write_page "" null "$(empty_list)" "$(discussion_list 1 false "" "${review}")" "$(discussion_list 1 false "" "${thread}")"
    run_pr_comments --pr 42
    [ "${status}" -eq 0 ]
    [[ "${output}" == *$'\n'"author${TAB}mal lory [2J"$'\n'"association${TAB}OWNER"$'\n'"state${TAB}APPROVED state FORGED "$'\n'* ]]
    [[ "${output}" == *$'\n'"url${TAB}https://example.com/  summary x"$'\n'* ]]
    [[ "${output}" == *$'\n'"path${TAB}src/a b  summary comments=0  .sh author credfeto summary x"$'\n'* ]]
    [[ "${output}" == *$'\n'"author${TAB}app/bot name "$'\n'* ]]
    [ "$(LC_ALL=C grep -c $'\xe2\x80\xa8\\|\xe2\x80\xa9' <<< "${output}")" -eq 0 ]
    [ "$(grep -vE "^([a-z-]+${TAB}[^${TAB}]*|\\|.*|)\$" <<< "${output}")" = "summary comments=0 reviews=1 reviews-empty=0 threads=1 unresolved=1 inline=1" ]
    [ "$(wc -l <<< "${output}")" -eq 32 ]
}

@test "pr comments counts the body lines it prints: none for an empty body or one of blank lines only" {
    prepare_pr_comments
    local -a bodies=("" "one line" $'ends in newlines\n\n\n\n' $'\n\n\n' $'\r\n\r\n' $'a\n\n\nb\n' $'  \n \n' $'\n\nleading blank lines')
    local -a counts=(0 1 1 0 0 4 2 3)
    local index
    for index in "${!bodies[@]}"; do
        write_one_comment_page "${bodies[index]}"
        run_pr_comments --pr 42
        [ "${status}" -eq 0 ]
        [[ "${output}" == *$'\n'"lines${TAB}${counts[index]}"$'\n'* ]] || { echo "body ${index}: ${output}" >&2; return 1; }
        [ "$(grep -c "^|" <<< "${output}")" -eq "${counts[index]}" ]
    done
    # A body GitHub leaves out altogether is an empty one.
    write_page "" null "$(discussion_list 1 false "" "$(issue_comment_node 7 credfeto User x | jq 'del(.body) | .isMinimized = true')")" "$(empty_list)" "$(empty_list)"
    run_pr_comments --pr 42
    [ "${status}" -eq 0 ]
    [[ "${output}" == *$'\n'"minimized${TAB}yes"$'\n'*$'\n'"lines${TAB}0"$'\n\n'"summary "* ]]
}

@test "pr comments prints a review with a body or a state of its own, and only counts the blank COMMENTED wrapper" {
    prepare_pr_comments
    write_page "" null "$(empty_list)" \
        "$(discussion_list 5 false "" "$(review_node 1 credfeto User COMMENTED "")" "$(review_node 2 credfeto User COMMENTED "A remark.")" \
            "$(review_node 3 credfeto User APPROVED "")" "$(review_node 4 credfeto User DISMISSED $'\n')" \
            "$(review_node 5 credfeto User PENDING "" | jq '.submittedAt = null | del(.body)')")" \
        "$(empty_list)"
    run_pr_comments --pr 42
    [ "${status}" -eq 0 ]
    [ "$(grep "^review${TAB}" <<< "${output}")" = "$(printf '%s\n' "review${TAB}2" "review${TAB}3" "review${TAB}4" "review${TAB}5")" ]
    [[ "${output}" == *$'\n'"state${TAB}PENDING"$'\n'"submitted-at${TAB}"$'\n'* ]]
    [ "$(tail -1 <<< "${output}")" = "summary comments=0 reviews=4 reviews-empty=1 threads=0 unresolved=0 inline=0" ]
}

@test "pr comments reads each list to its last page, asking each later page for that list alone" {
    prepare_pr_comments
    local list pages
    for list in comments reviews threads; do
        for pages in 2 3; do
            rm -f "${GH_FIXTURES}"/discussion* "${GH_LOG}"
            local -a first=("$(empty_list)" "$(empty_list)" "$(empty_list)") second=("" "" "") third=("" "" "")
            local total="${pages}" more_after_second=false
            [ "${pages}" -eq 2 ] || more_after_second=true
            case "${list}" in
                comments)
                    first[0]="$(discussion_list "${total}" true p2 "$(issue_comment_node 1 credfeto User one)")"
                    second[0]="$(discussion_list "${total}" "${more_after_second}" p3 "$(issue_comment_node 2 credfeto User two)")"
                    third[0]="$(discussion_list "${total}" false "" "$(issue_comment_node 3 credfeto User three)")"
                    ;;
                reviews)
                    first[1]="$(discussion_list "${total}" true p2 "$(review_node 1 credfeto User APPROVED one)")"
                    second[1]="$(discussion_list "${total}" "${more_after_second}" p3 "$(review_node 2 credfeto User APPROVED two)")"
                    third[1]="$(discussion_list "${total}" false "" "$(review_node 3 credfeto User APPROVED three)")"
                    ;;
                threads)
                    first[2]="$(discussion_list "${total}" true p2 "$(thread_node true false a.sh 1 1 "$(inline_node 1 "" 9 credfeto User one)")")"
                    second[2]="$(discussion_list "${total}" "${more_after_second}" p3 "$(thread_node true false a.sh 2 2 "$(inline_node 2 "" 9 credfeto User two)")")"
                    third[2]="$(discussion_list "${total}" false "" "$(thread_node true false a.sh 3 3 "$(inline_node 3 "" 9 credfeto User three)")")"
                    ;;
            esac
            write_page "" null "${first[@]}"
            write_page "-${list}-p2" null "${second[@]}"
            write_page "-${list}-p3" null "${third[@]}"

            run_pr_comments --pr 42
            [ "${status}" -eq 0 ] || { echo "${list} over ${pages} pages: ${stderr}" >&2; return 1; }
            [ -z "${stderr}" ]
            [ "$(grep "^|" <<< "${output}")" = "$(printf '%s\n' "| one" "| two" "| three" | head -"${pages}")" ]
            [ "$(grep -c "^lines${TAB}" <<< "${output}")" -eq "${pages}" ]
            [ "$(wc -l < "${GH_LOG}")" -eq "${pages}" ]

            local -a later=("-F comments=false" "-F reviews=false" "-F threads=false")
            local -A position=([comments]=0 [reviews]=1 [threads]=2)
            later[${position[${list}]}]="-F ${list}=true -f ${list}After=p2"
            [ "$(sed -n 2p "${GH_LOG}" | grep -cF -- " -F n=42 ${later[*]} --jq ")" -eq 1 ]
            [ "$(grep -c "After=" "${GH_LOG}")" -eq "$((pages - 1))" ]
            [ "$(grep -c "After=p3" "${GH_LOG}")" -eq "$((pages - 2))" ]
        done
    done
}

@test "pr comments pages all three lists at once, each with its own cursor, and prints every item once in order" {
    prepare_pr_comments
    write_page "" '"APPROVED"' \
        "$(discussion_list 2 true c2 "$(issue_comment_node 1 credfeto User "comment one")")" \
        "$(discussion_list 3 true r2 "$(review_node 11 credfeto User APPROVED "review one")")" \
        "$(discussion_list 2 true t2 "$(thread_node false false a.sh 1 1 "$(inline_node 21 "" 11 credfeto User "inline one")")")"
    write_page "-comments-c2-reviews-r2-threads-t2" '"APPROVED"' \
        "$(discussion_list 2 false "" "$(issue_comment_node 2 credfeto User "comment two")")" \
        "$(discussion_list 3 true r3 "$(review_node 12 credfeto User COMMENTED "")")" \
        "$(discussion_list 2 false "" "$(thread_node true false a.sh 2 2 "$(inline_node 22 "" 12 credfeto User "inline two")")")"
    write_page "-reviews-r3" '"CHANGES_REQUESTED"' "" "$(discussion_list 3 false "" "$(review_node 13 credfeto User APPROVED "review three")")" ""

    run_pr_comments --pr 42
    [ "${status}" -eq 0 ]
    [ "$(grep "^|" <<< "${output}")" = "$(printf '%s\n' "| comment one" "| comment two" "| review one" "| review three" "| inline one" "| inline two")" ]
    [ "$(tail -1 <<< "${output}")" = "summary comments=2 reviews=2 reviews-empty=1 threads=2 unresolved=1 inline=2" ]
    # The decision printed is the one read last.
    [[ "${output}" == *$'\n'"review-decision${TAB}CHANGES_REQUESTED"$'\n'* ]]
    [ "$(wc -l < "${GH_LOG}")" -eq 3 ]
    [ "$(sed -n 2p "${GH_LOG}" | grep -cF -- "-F comments=true -f commentsAfter=c2 -F reviews=true -f reviewsAfter=r2 -F threads=true -f threadsAfter=t2 --jq")" -eq 1 ]
    [ "$(sed -n 3p "${GH_LOG}" | grep -cF -- "-F comments=false -F reviews=true -f reviewsAfter=r3 -F threads=false --jq")" -eq 1 ]
    [ "$(grep -c mutation "${GH_LOG}")" -eq 0 ]
}

@test "pr comments prints nothing when a list is shorter than GitHub's count of it, or a page lost a block" {
    prepare_pr_comments
    local list
    local -a lists nodes=("$(issue_comment_node 1 credfeto User one)" "$(review_node 1 credfeto User APPROVED one)"
        "$(thread_node false false a.sh 1 1 "$(inline_node 1 "" 9 credfeto User one)")")
    for list in 0 1 2; do
        lists=("$(empty_list)" "$(empty_list)" "$(empty_list)")
        lists[list]="$(discussion_list 2 false "" "${nodes[list]}")"
        write_page "" null "${lists[@]}"
        run_pr_comments --pr 42
        [ "${status}" -eq 1 ] || { echo "list ${list}: ${status}" >&2; return 1; }
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: the comments of ${REPO}#42 changed or were cut short while they were read; nothing is printed" ]
    done

    # A list that grew while it was read is whole when the items gathered match the last count.
    write_page "" null "$(discussion_list 1 true c2 "$(issue_comment_node 1 credfeto User one)")" "$(empty_list)" "$(empty_list)"
    write_page "-comments-c2" null "$(discussion_list 2 false "" "$(issue_comment_node 2 credfeto User two)")" "" ""
    run_pr_comments --pr 42
    [ "${status}" -eq 0 ]
    [ "$(tail -1 <<< "${output}")" = "summary comments=2 reviews=0 reviews-empty=0 threads=0 unresolved=0 inline=0" ]

    # The page says it held two comments and only one block arrived.
    local row=$'\x1e' sep=$'\x1f'
    printf '%s\n' "${row}comment${sep}1" "comment${TAB}1" "lines${TAB}0" \
        "${row}page${sep}${sep}2${sep}2${sep}false${sep}${sep}0${sep}0${sep}false${sep}${sep}0${sep}0${sep}false${sep}${sep}end" > "${GH_FIXTURES}/discussion.raw"
    run_pr_comments --pr 42
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: the comments of ${REPO}#42 changed or were cut short while they were read; nothing is printed" ]

    # A thread whose own count is above the inline comments it came with, and one that lost a block.
    rm "${GH_FIXTURES}/discussion.raw"
    write_page "" null "$(empty_list)" "$(empty_list)" \
        "$(discussion_list 1 false "" "$(thread_node false false a.sh 1 1 "$(inline_node 1 "" 9 credfeto User one)" | jq '.comments.totalCount = 2')")"
    run_pr_comments --pr 42
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == *"changed or were cut short"* ]]

    printf '%s\n' "${row}thread${sep}false${sep}2${sep}2${sep}no${sep}1" "thread${TAB}1" "${row}inline${sep}${sep}9${sep}1" "inline${TAB}1" \
        "${row}page${sep}${sep}0${sep}0${sep}false${sep}${sep}0${sep}0${sep}false${sep}${sep}1${sep}1${sep}false${sep}${sep}end" > "${GH_FIXTURES}/discussion.raw"
    run_pr_comments --pr 42
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == *"changed or were cut short"* ]]
}

@test "pr comments refuses an answer that is not the pages it asked for, printing nothing" {
    prepare_pr_comments
    local row=$'\x1e' sep=$'\x1f'
    local closed="0${sep}0${sep}false${sep}${sep}0${sep}0${sep}false${sep}${sep}0${sep}0${sep}false${sep}"
    local page="${row}page${sep}${sep}${closed}${sep}end"
    # A page that says it held one thread, and that thread with its one inline comment.
    local thread_page="${row}page${sep}${sep}0${sep}0${sep}false${sep}${sep}0${sep}0${sep}false${sep}${sep}1${sep}1${sep}false${sep}${sep}end"
    local thread="${row}thread${sep}false${sep}1${sep}1${sep}no${sep}1"$'\n'"thread${TAB}1"
    local -a answers=(
        "a line before any block"$'\n'"${page}"
        "${row}comment${sep}1"$'\n'"comment${TAB}1"
        "${row}comment${sep}1"$'\n'"${row}page${sep}${sep}${closed}"
        "${row}issue${sep}1"$'\n'"${page}"
        "${row}"$'\n'"${page}"
        "${row}comment${sep}x1"$'\n'"${page}"
        "${row}inline${sep}${sep}9${sep}1"$'\n'"${page}"
        "${row}thread${sep}false${sep}1${sep}1${sep}no${sep}1"$'\n'"${row}inline${sep}x${sep}9${sep}1"$'\n'"${page}"
        "${row}thread${sep}maybe${sep}1${sep}1${sep}no${sep}1"$'\n'"${page}"
        "${row}thread${sep}false${sep}many${sep}1${sep}no${sep}1"$'\n'"${page}"
        "${row}thread${sep}false${sep}1${sep}x${sep}no${sep}1"$'\n'"${thread_page}"
        # An inline comment with no id of its own, which read gives one field fewer, and rows with a field too many.
        "${thread}"$'\n'"${row}inline${sep}${sep}9${sep}"$'\n'"inline${TAB}"$'\n'"${thread_page}"
        "${thread}"$'\n'"${row}inline${sep}${sep}9${sep}1${sep}2"$'\n'"inline${TAB}2"$'\n'"${thread_page}"
        "${thread}"$'\n'"${row}inline${sep}${sep}x${sep}1"$'\n'"inline${TAB}1"$'\n'"${thread_page}"
        "${row}thread${sep}false${sep}0${sep}0${sep}no${sep}"$'\n'"${thread_page}"
        "${row}comment${sep}1${sep}2"$'\n'"${page}"
        "${row}page${sep}${sep}0${sep}x${sep}false${sep}${sep}0${sep}0${sep}false${sep}${sep}0${sep}0${sep}false${sep}${sep}end"
        "${row}page${sep}${sep}${closed}${sep}fin"
        "${row}page${sep}${sep}none${sep}0${sep}false${sep}${sep}0${sep}0${sep}false${sep}${sep}0${sep}0${sep}false${sep}${sep}end"
        "${row}page${sep}${sep}0${sep}0${sep}perhaps${sep}${sep}0${sep}0${sep}false${sep}${sep}0${sep}0${sep}false${sep}${sep}end"
        ""
    )
    local answer
    for answer in "${answers[@]}"; do
        printf '%s\n' "${answer}" > "${GH_FIXTURES}/discussion.raw"
        run_pr_comments --pr 42
        [ "${status}" -eq 1 ] || { echo "accepted: ${answer}" >&2; return 1; }
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: gh returned an unexpected answer for the comments of ${REPO}#42; nothing is printed" ]
    done

    # The same thread with its inline comment whole is printed, so each answer above was refused for what it lacks.
    printf '%s\n' "${thread}" "${row}inline${sep}${sep}9${sep}1" "inline${TAB}1" "${thread_page}" > "${GH_FIXTURES}/discussion.raw"
    run_pr_comments --pr 42
    [ "${status}" -eq 0 ]
    [ "$(tail -1 <<< "${output}")" = "summary comments=0 reviews=0 reviews-empty=0 threads=1 unresolved=1 inline=1" ]

    # An answer with no pull request in it, were gh ever to give one without an error.
    rm "${GH_FIXTURES}/discussion.raw"
    jq -n '{data: {repository: {pullRequest: null}}}' > "${GH_FIXTURES}/discussion.json"
    run_pr_comments --pr 42
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == *"unexpected answer"* ]]
}

@test "pr comments stops on a cursor that repeats, a cursor it would not send, and a list of more than 100 pages" {
    prepare_pr_comments
    write_page "" null "$(empty_list)" "$(discussion_list 3 true r2 "$(review_node 1 credfeto User APPROVED one)")" "$(empty_list)"
    write_page "-reviews-r2" null "" "$(discussion_list 3 true r2 "$(review_node 2 credfeto User APPROVED two)")" ""
    run_pr_comments --pr 42
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: GitHub returned the same page of the reviews of ${REPO}#42 twice; nothing is printed" ]
    [ "$(wc -l < "${GH_LOG}")" -eq 2 ]

    local cursor
    for cursor in 'a b' 'a"b' 'a,b' '@file' 'a%b' ""; do
        rm -f "${GH_FIXTURES}"/discussion* "${GH_LOG}"
        write_page "" null "$(empty_list)" "$(empty_list)" "$(discussion_list 3 true "${cursor}" "$(thread_node true false a.sh 1 1 "$(inline_node 1 "" 9 credfeto User one)")")"
        run_pr_comments --pr 42
        [ "${status}" -eq 1 ] || { echo "cursor '${cursor}' was sent" >&2; return 1; }
        [ -z "${output}" ]
        [[ "${stderr}" == *"unexpected answer"* ]]
        [ "$(wc -l < "${GH_LOG}")" -eq 1 ]
    done

    # GitHub's cursors are base64, and one with every character of that alphabet is sent as it is.
    rm -f "${GH_FIXTURES}"/discussion* "${GH_LOG}"
    write_page "" null "$(discussion_list 1 true "Y3Vy+c29y_Onb-yOpHP=" )" "$(empty_list)" "$(empty_list)"
    write_page "-comments-Y3Vy+c29y_Onb-yOpHP=" null "$(discussion_list 1 false "" "$(issue_comment_node 1 credfeto User one)")" "" ""
    run_pr_comments --pr 42
    [ "${status}" -eq 0 ]
    [ "$(grep -cF -- "-f commentsAfter=Y3Vy+c29y_Onb-yOpHP= " "${GH_LOG}")" -eq 1 ]

    rm -f "${GH_FIXTURES}"/discussion* "${GH_LOG}"
    local page
    write_page "" null "$(discussion_list 0 true c1)" "$(empty_list)" "$(empty_list)"
    for page in {1..99}; do
        printf '{"data":{"repository":{"pullRequest":{"reviewDecision":null,"comments":{"totalCount":0,"pageInfo":{"hasNextPage":true,"endCursor":"c%s"},"nodes":[]}}}}}\n' \
            "$((page + 1))" > "${GH_FIXTURES}/discussion-comments-c${page}.json"
    done
    run_pr_comments --pr 42
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: the comments of ${REPO}#42 run to more than 100 pages; nothing is printed" ]
    [ "$(wc -l < "${GH_LOG}")" -eq 100 ]
}

@test "pr comments refuses a thread with more comments than one page holds, naming it, and prints nothing" {
    prepare_pr_comments
    write_page "" null \
        "$(discussion_list 1 false "" "$(issue_comment_node 1 credfeto User one)")" "$(empty_list)" \
        "$(discussion_list 2 false "" "$(thread_node true false a.sh 1 1 "$(inline_node 21 "" 9 credfeto User one)")" \
            "$(thread_node false false b.sh 1 1 "$(inline_node 4220417677 "" 9 credfeto User two)" | jq '.comments.pageInfo.hasNextPage = true | .comments.totalCount = 101')")"
    run_pr_comments --pr 42
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: the thread that starts with the inline comment 4220417677 of ${REPO}#42 has more than 100 comments, which cfwf cannot read; nothing is printed" ]
}

@test "pr comments prints nothing, never part of a list, when a later page fails" {
    prepare_pr_comments
    write_page "" null "$(discussion_list 2 true c2 "$(issue_comment_node 1 credfeto User one)")" "$(empty_list)" "$(empty_list)"
    printf 'gh: Bad Gateway (HTTP 502)\n' > "${GH_FIXTURES}/discussion-comments-c2.fail"
    run_pr_comments --pr 42
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not read the comments of ${REPO}#42: gh: Bad Gateway (HTTP 502)" ]
    [ "$(wc -l < "${GH_LOG}")" -eq 2 ]
}

@test "pr comments exits 9 for a number that is not a pull request, and 1 for any other failed read" {
    prepare_pr_comments
    local number
    for number in 999999 1499; do
        printf 'gh: Could not resolve to a PullRequest with the number of %s.\n' "${number}" > "${GH_FIXTURES}/discussion.fail"
        printf '{"data":{"repository":{"pullRequest":null}},"errors":[{"type":"NOT_FOUND"}]}' > "${GH_FIXTURES}/discussion.failout"
        run_pr_comments --pr "${number}"
        [ "${status}" -eq 9 ]
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: the pull request ${REPO}#${number} was not found" ]
    done

    printf "gh: Could not resolve to a Repository with the name 'credfeto/credfeto-orchestrator'.\n" > "${GH_FIXTURES}/discussion.fail"
    run_pr_comments --pr 42
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not read the comments of ${REPO}#42: gh: Could not resolve to a Repository with the name 'credfeto/credfeto-orchestrator'." ]

    # The words of GitHub's not-found answer in what gh printed, a comment's body say, are not that answer.
    printf 'gh: Bad Gateway (HTTP 502)\n' > "${GH_FIXTURES}/discussion.fail"
    printf '{"body":"Could not resolve to a PullRequest with the number of 42."}' > "${GH_FIXTURES}/discussion.failout"
    run_pr_comments --pr 42
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: could not read the comments of ${REPO}#42: gh: Bad Gateway (HTTP 502)" ]

    printf 'connection reset \x1b[31mby peer\nsecond line\n' > "${GH_FIXTURES}/discussion.fail"
    rm "${GH_FIXTURES}/discussion.failout"
    run_pr_comments --pr 42
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not read the comments of ${REPO}#42: connection reset [31mby peer" ]
}

@test "pr comments never lets what gh writes to stderr on a successful read reach its output, and leaves no temporary file" {
    prepare_pr_comments
    local scratch="${TEST_TMP}/tmp"
    mkdir -p "${scratch}"
    write_one_comment_page "A comment."
    printf 'warning: a newer gh is available\nsummary comments=9\n' > "${GH_FIXTURES}/discussion.stderr"
    TMPDIR="${scratch}" run_pr_comments --pr 42
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [[ "${output}" != *"newer gh"* ]]
    [ "$(tail -1 <<< "${output}")" = "summary comments=1 reviews=0 reviews-empty=0 threads=0 unresolved=0 inline=0" ]
    [ -z "$(ls -A "${scratch}")" ]
}

@test "pr reply usage errors exit 2 before any gh call" {
    prepare_pr_reply
    local body="${TEST_TMP}/reply.md"
    local -a cases=(
        "--pr 42 --comment-id 500"
        "--pr 42 --body-file ${body}"
        "--comment-id 500 --body-file ${body}"
        "--pr 42 --pr 43 --comment-id 500 --body-file ${body}"
        "--pr 42 --comment-id 500 --comment-id 501 --body-file ${body}"
        "--pr 42 --comment-id 500 --body-file ${body} --body-file ${body}"
        "--pr 0 --comment-id 500 --body-file ${body}"
        "--pr 42 --comment-id 50a --body-file ${body}"
        "--pr 42 --comment-id -500 --body-file ${body}"
        "--pr 42 --comment-id +500 --body-file ${body}"
        "--pr 42 --comment-id 0 --body-file ${body}"
        "--pr 42 --comment-id 000 --body-file ${body}"
        "--pr 42 --comment-id 12345678901234567890 --body-file ${body}"
        "--pr 42 --comment-id 500 --body text"
        "--pr 42 --comment-id 500 --body-file ${body} --sha ${HEAD_SHA}"
        "--pr 42 --comment-id 500 --body-file"
    )
    local args
    for args in "${cases[@]}"; do
        # shellcheck disable=SC2086  # each case is split into its words on purpose
        run_pr_reply ${args}
        [ "${status}" -eq 2 ] || { echo "accepted: ${args} (${status})" >&2; return 1; }
        [ -z "${output}" ]
        [[ "${stderr}" == *"Usage: cfwf pr reply"* ]]
    done

    run --separate-stderr "${SCRIPT}" pr reply --pr 42 --comment-id 500 --body-file "${body}"
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: missing required option --repo"* ]]

    run_pr_reply --repo "${REPO}" --pr 42 --comment-id 500 --body-file "${body}"
    [[ "${stderr}" == "cfwf: --repo can only be given once"* ]]
    run_pr_reply --pr 42 --body-file "${body}"
    [[ "${stderr}" == "cfwf: missing required option --comment-id"* ]]
    run_pr_reply --pr 42 --comment-id 500
    [[ "${stderr}" == "cfwf: missing required option --body-file"* ]]
    run_pr_reply --pr 42 --comment-id 12345678901234567890 --body-file "${body}"
    [[ "${stderr}" == "cfwf: invalid value for --comment-id: it must be a number of at most 19 digits"* ]]
    run_pr_reply --pr 42 --comment-id 0 --body-file "${body}"
    [[ "${stderr}" == "cfwf: invalid value for --comment-id: it must be above 0"* ]]

    local stray="gh""p_LEAKMARKER0123456789"
    run_pr_reply --pr 42 --comment-id 500 --body "${stray}"
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: unknown option (argument 9; its value is not shown)"* && "${stderr}" != *"${stray}"* ]]
    run_pr_reply --pr 42 --comment-id 500 --body-file "${body}" "${stray}"
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: unknown option (argument 11; its value is not shown)"* && "${stderr}" != *"${stray}"* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "pr reply reads the comment, posts the body once to the thread's first comment and prints the new comment" {
    prepare_pr_reply
    run_pr_reply --pr 42 --comment-id 500 --body-file "${TEST_TMP}/reply.md"
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ "${output}" = "$(printf '%s\n' "inline${TAB}900" "in-reply-to${TAB}500" "url${TAB}${DISCUSSION_URL}#discussion_r900")" ]
    cmp "${TEST_TMP}/reply.md" "${GH_FIXTURES}/reply-body.txt"

    [ "$(wc -l < "${GH_LOG}")" -eq 2 ]
    [[ "$(sed -n 1p "${GH_LOG}")" == "api repos/${REPO}/pulls/comments/500 --jq "* ]]
    [[ "$(sed -n 2p "${GH_LOG}")" == "api --method POST repos/${REPO}/pulls/42/comments/500/replies -F body=@"*" --jq "* ]]
    [ "$(grep -c -- "--repo\|in_reply_to=\|-f body=\|${TEST_TMP}/reply.md\|Fixed in the next commit" "${GH_LOG}")" -eq 0 ]
}

@test "pr reply posts to the thread's first comment when the id is that of a reply, and drops leading zeros" {
    prepare_pr_reply
    write_inline_comment 501 500 42
    run_pr_reply --pr 0042 --comment-id 000501 --body-file "${TEST_TMP}/reply.md"
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' "inline${TAB}900" "in-reply-to${TAB}500" "url${TAB}${DISCUSSION_URL}#discussion_r900")" ]
    [ "$(gh_call_count "api repos/${REPO}/pulls/comments/501 ")" -eq 1 ]
    [ "$(gh_call_count "api --method POST repos/${REPO}/pulls/42/comments/500/replies ")" -eq 1 ]
    [ "$(reply_posts)" -eq 1 ]
}

@test "pr reply exits 9 without posting for an id that is not an inline comment of that pull request" {
    prepare_pr_reply
    run_pr_reply --pr 42 --comment-id 777 --body-file "${TEST_TMP}/reply.md"
    [ "${status}" -eq 9 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: the comment 777 is not an inline review comment of ${REPO}#42" ]
    [ "$(reply_posts)" -eq 0 ]

    # The same comment on another pull request of the repository, and on one whose number only ends alike.
    local pull
    for pull in 43 142 4; do
        write_inline_comment 500 "" "${pull}"
        run_pr_reply --pr 42 --comment-id 500 --body-file "${TEST_TMP}/reply.md"
        [ "${status}" -eq 9 ] || { echo "pull ${pull}: ${status}" >&2; return 1; }
        [ "${stderr}" = "cfwf: the comment 500 is not an inline review comment of ${REPO}#42" ]
    done
    [ "$(reply_posts)" -eq 0 ]

    # The host and the repository in the comment's own URL are not compared: a proxy answers with its own.
    jq -n '{id: 500, in_reply_to_id: null, pull_request_url: "https://api.github.com/repos/renamed-owner/renamed/pulls/42"}' | write_api "repos/${REPO}/pulls/comments/500"
    run_pr_reply --pr 42 --comment-id 500 --body-file "${TEST_TMP}/reply.md"
    [ "${status}" -eq 0 ]
    [ "$(reply_posts)" -eq 1 ]
}

@test "pr reply fails without posting when the comment cannot be read or the answer is not that comment" {
    prepare_pr_reply
    fail_api "repos/${REPO}/pulls/comments/500"
    run_pr_reply --pr 42 --comment-id 500 --body-file "${TEST_TMP}/reply.md"
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not read the comment 500 of ${REPO}: gh: Bad Gateway (HTTP 502)" ]

    rm "$(api_fixture "repos/${REPO}/pulls/comments/500").fail"
    local answer
    for answer in '{id: 501, in_reply_to_id: null, pull_request_url: "x/pulls/42"}' '{id: 500, in_reply_to_id: "abc", pull_request_url: "x/pulls/42"}' '{}'; do
        jq -n "${answer}" | write_api "repos/${REPO}/pulls/comments/500"
        run_pr_reply --pr 42 --comment-id 500 --body-file "${TEST_TMP}/reply.md"
        [ "${status}" -eq 1 ] || { echo "accepted: ${answer}" >&2; return 1; }
        [ "${stderr}" = "cfwf: gh returned an unexpected answer for the comment 500 of ${REPO}" ]
    done
    # An answer cut short before its last field, which read would otherwise take as a comment of this pull request.
    printf '500\x1f\x1fx/pulls/42\n' > "$(api_fixture "repos/${REPO}/pulls/comments/500").raw"
    run_pr_reply --pr 42 --comment-id 500 --body-file "${TEST_TMP}/reply.md"
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: gh returned an unexpected answer for the comment 500 of ${REPO}" ]
    [ "$(reply_posts)" -eq 0 ]
}

@test "pr reply reads the body from stdin, posts the copy it checked, and leaves no temporary file" {
    prepare_pr_reply
    local scratch="${TEST_TMP}/tmp"
    mkdir -p "${scratch}"
    TMPDIR="${scratch}" run_pr_reply --pr 42 --comment-id 500 --body-file - <<< "A reply from stdin"
    [ "${status}" -eq 0 ]
    [ "$(cat "${GH_FIXTURES}/reply-body.txt")" = "A reply from stdin" ]
    [ -z "$(ls -A "${scratch}")" ]

    TMPDIR="${scratch}" run_pr_reply --pr 42 --comment-id 500 --body-file - < /dev/null
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: the body is empty" ]
    [ -z "$(ls -A "${scratch}")" ]

    printf 'A line.\n/tmp/leak\n' > "${TEST_TMP}/leak.md"
    TMPDIR="${scratch}" run_pr_reply --pr 42 --comment-id 500 --body-file "${TEST_TMP}/leak.md"
    [ "${status}" -eq 8 ]
    [ -z "$(ls -A "${scratch}")" ]

    printf 'gh: Bad Gateway (HTTP 502)\n' > "${GH_FIXTURES}/reply.fail"
    TMPDIR="${scratch}" run_pr_reply --pr 42 --comment-id 500 --body-file "${TEST_TMP}/reply.md"
    [ "${status}" -eq 1 ]
    [ -z "$(ls -A "${scratch}")" ]
    rm "${GH_FIXTURES}/reply.fail"

    # The body file is rewritten by the read of the comment, after the check: what is posted is the copy.
    cp "${TEST_TMP}/reply.md" "${TEST_TMP}/checked.md"
    printf '%s\n' "${TEST_TMP}/reply.md" > "${GH_FIXTURES}/rewrite"
    run_pr_reply --pr 42 --comment-id 500 --body-file "${TEST_TMP}/reply.md"
    [ "${status}" -eq 0 ]
    [[ "$(cat "${TEST_TMP}/reply.md")" == rewritten* ]]
    cmp "${TEST_TMP}/checked.md" "${GH_FIXTURES}/reply-body.txt"
}

@test "pr reply refuses a leaking body with exit 8, naming the rule and line only, before reading or posting anything" {
    prepare_pr_reply
    local token
    token="$(leak_tokens | head -1)"
    local -a leaks=("${token}" "see /home/someone/notes" $'a bell \x07 here' $'bad \xff byte')
    local -a rules=("token" "host path" "control character" "invalid UTF-8")
    local index
    for index in "${!leaks[@]}"; do
        write_leak_body "${leaks[index]}"
        run_pr_reply --pr 42 --comment-id 500 --body-file "${TEST_TMP}/leak.md"
        assert_refused "${status}" "${output}" "${stderr}" "${rules[index]}" "${leaks[index]}"
    done

    printf 'x%.0s' {1..65537} > "${TEST_TMP}/long.md"
    run_pr_reply --pr 42 --comment-id 500 --body-file "${TEST_TMP}/long.md"
    [ "${status}" -eq 8 ]
    [ "${stderr}" = "cfwf: body refused: too long" ]
    [ ! -f "${GH_LOG}" ]

    write_visibility "${REPO}" PUBLIC
    write_visibility credfeto/secret-plans PRIVATE
    write_leak_body "As in credfeto/secret-plans#5."
    run_pr_reply --pr 42 --comment-id 500 --body-file "${TEST_TMP}/leak.md"
    assert_refused "${status}" "${output}" "${stderr}" "private repository" "secret-plans"
    [ "$(gh_call_count "api ")" -eq 0 ]

    # A body of exactly the limit is posted.
    printf 'x%.0s' {1..65536} > "${TEST_TMP}/long.md"
    run_pr_reply --pr 42 --comment-id 500 --body-file "${TEST_TMP}/long.md"
    [ "${status}" -eq 0 ]
    cmp "${TEST_TMP}/long.md" "${GH_FIXTURES}/reply-body.txt"
}

@test "pr reply refuses a blank, missing or unreadable body as a runtime failure, without calling gh" {
    prepare_pr_reply
    printf ' \n\t\n' > "${TEST_TMP}/blank.md"
    run_pr_reply --pr 42 --comment-id 500 --body-file "${TEST_TMP}/blank.md"
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: the body is empty" ]

    local path
    for path in "${TEST_TMP}/nope.md" "${TEST_TMP}"; do
        run_pr_reply --pr 42 --comment-id 500 --body-file "${path}"
        [ "${status}" -eq 1 ]
        [ "${stderr}" = "cfwf: cannot read the --body-file" ]
    done
    [ -z "${output}" ]
    [ ! -f "${GH_LOG}" ]
}

@test "pr reply posts a body holding a plan sign-off keyword: only an issue's top-level comments are read for one" {
    prepare_pr_reply
    # Each keyword is built from pieces, so this file never holds one as a word.
    local keyword
    for keyword in "appr""oved" "LG""TM"; do
        printf 'Looks right to me: %s.\n\n%s\n' "${keyword}" "${keyword}" > "${TEST_TMP}/reply.md"
        run_pr_reply --pr 42 --comment-id 500 --body-file "${TEST_TMP}/reply.md"
        [ "${status}" -eq 0 ]
        cmp "${TEST_TMP}/reply.md" "${GH_FIXTURES}/reply-body.txt"
    done
    [ "$(reply_posts)" -eq 2 ]
}

@test "pr reply never posts twice: a status that refuses the post says not posted, and any other failure that it may have been posted" {
    prepare_pr_reply
    local error
    for error in "gh: Validation Failed (HTTP 422)" "gh: Not Found (HTTP 404)" "gh: Resource not accessible by integration (HTTP 403)" \
        "gh: Problems parsing JSON (HTTP 400)" "gh: Bad credentials (HTTP 401)" "gh: Gone (HTTP 410)"; do
        : > "${GH_LOG}"
        printf '%s\n' "${error}" > "${GH_FIXTURES}/reply.fail"
        run_pr_reply --pr 42 --comment-id 500 --body-file "${TEST_TMP}/reply.md"
        [ "${status}" -eq 1 ]
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: the reply was not posted: ${error}" ]
        [ "$(reply_posts)" -eq 1 ]
    done

    local check="run 'cfwf pr comments' and look for it in the thread before posting again"
    # Any other status, the rest of 4xx included, and a refusing status that is not how the line ends.
    for error in "gh: Bad Gateway (HTTP 502)" "Post \"https://api.github.com/x\": context deadline exceeded" "said HTTP 422 somewhere, with no status of its own" \
        "gh: Request Timeout (HTTP 408)" "gh: Conflict (HTTP 409)" "gh: Too Many Requests (HTTP 429)" "gh: Unavailable For Legal Reasons (HTTP 451)" \
        "gh: HTTP 404" "gh: the proxy said (HTTP 422) and went on" "gh: Not Found (HTTP 4040)" "gh: Server Error (HTTP 5422)"; do
        : > "${GH_LOG}"
        printf '%s\n' "${error}" > "${GH_FIXTURES}/reply.fail"
        run_pr_reply --pr 42 --comment-id 500 --body-file "${TEST_TMP}/reply.md"
        [ "${status}" -eq 1 ]
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: the reply may have been posted (${error}); ${check}" ]
        [ "$(reply_posts)" -eq 1 ]
    done

    # A refusing status on a later line of gh's error is not the answer to the post.
    : > "${GH_LOG}"
    printf 'gh: Bad Gateway (HTTP 502)\ngh: Validation Failed (HTTP 422)\n' > "${GH_FIXTURES}/reply.fail"
    run_pr_reply --pr 42 --comment-id 500 --body-file "${TEST_TMP}/reply.md"
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: the reply may have been posted (gh: Bad Gateway (HTTP 502)); ${check}" ]
    [ "$(reply_posts)" -eq 1 ]

    : > "${GH_LOG}"
    : > "${GH_FIXTURES}/reply.fail"
    run_pr_reply --pr 42 --comment-id 500 --body-file "${TEST_TMP}/reply.md"
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: the reply may have been posted (gh gave no error text); ${check}" ]
    [ "$(reply_posts)" -eq 1 ]
    rm "${GH_FIXTURES}/reply.fail"

    # gh said it worked, with an answer that is not the new comment.
    local answer
    for answer in "" "not a comment" $'900\x1fhttp://github.com/o/r/pull/42#discussion_r900\x1fend' $'900\x1fhttps://github.com/o/r/pull/43#discussion_r900\x1fend' \
        $'900\x1fhttps://github.com/o/r/pull/42#discussion_r901\x1fend' $'9x\x1fhttps://github.com/o/r/pull/42#discussion_r9x\x1fend' \
        $'900\x1fhttps://github.com/o/r/pull/42#discussion_r900 and more\x1fend' $'900\x1fhttps://github.com/o/r/pull/42#discussion_r900'; do
        : > "${GH_LOG}"
        printf '%s\n' "${answer}" > "${GH_FIXTURES}/reply.raw"
        run_pr_reply --pr 42 --comment-id 500 --body-file "${TEST_TMP}/reply.md"
        [ "${status}" -eq 1 ] || { echo "accepted: ${answer}" >&2; return 1; }
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: the reply may have been posted (gh returned an unexpected answer); ${check}" ]
        [ "$(reply_posts)" -eq 1 ]
    done
    rm "${GH_FIXTURES}/reply.raw"

    # A renamed repository, or a proxy with its own host, answers with another host and name.
    jq -n '{id: 901, html_url: "https://github.example.com:8443/new-owner/new.name/pull/42#discussion_r901"}' > "${GH_FIXTURES}/reply.json"
    run_pr_reply --pr 42 --comment-id 500 --body-file "${TEST_TMP}/reply.md"
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' "inline${TAB}901" "in-reply-to${TAB}500" "url${TAB}https://github.example.com:8443/new-owner/new.name/pull/42#discussion_r901")" ]
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
    [[ "${output}" == *"unknown issue subcommand (argument 2; its value is not shown)"* && "${output}" != *frobnicate* ]]
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
    issue_create_called_with "issue create --repo ${REPO} --title A new issue --body-file BODY --label High --label -wip"
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
    [[ "${output}" == *"unknown option ("* ]]
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

@test "a character count that fails or is not a number is a runtime failure (exit 1), never too long or a pass" {
    printf 'A short body.\n' > "${TEST_TMP}/leak.md"
    local real_wc failure
    real_wc=$(command -v wc)
    # Each pass makes the character count (wc -m) fail one way: an error status, then garbage on
    # stdout with status 0. Every other wc is the real one.
    for failure in "echo 'wc: read error' >&2; exit 1" "echo 'not a count'; exit 0"; do
        make_stub_multiline wc \
            "case \" \$* \" in *\" -m \"*) ${failure} ;; esac" \
            "exec ${real_wc} \"\$@\""
        run_body_check
        [ "${status}" -eq 1 ]
        [ "${stderr##*$'\n'}" = "cfwf: could not count the characters of the body" ]
        [ ! -f "${GH_LOG}" ]
    done
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
    for bad in "no-slash" "a/b/c" "a b/c" 'a/b;rm' "" "../.." "./x" "x/." "x/.." "../repo"; do
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
    [[ "${output}" == *"unknown --priority (expected Security, Urgent, High, Medium or Low)"* && "${output}" != *Critical* ]]
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
        issue_create_called_with "issue create --repo ${REPO} --title A new issue --body-file BODY --label ${canonical}"
    done
}

@test "a priority given as --label is refused in any case, pointing at --priority, and nothing is created" {
    prepare_issue_create
    create_args Low
    local row given canonical
    for row in "Urgent|Urgent" "urgent|Urgent" "HIGH|High" "security|Security" "Medium|Medium" "low|Low"; do
        given="${row%|*}"
        canonical="${row#*|}"
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
    [[ "${output}" == *"invalid value for --label: it must not contain a comma or a control character"* && "${output}" != *"a,b"* ]]

    run "${SCRIPT}" "${CREATE_ARGS[@]}" --label $'a\nb'
    [ "${status}" -eq 2 ]

    run "${SCRIPT}" issue create --repo "${REPO}" --priority High --title "" --body-file "${TEST_TMP}/body.md"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"invalid value for --title"* ]]

    run "${SCRIPT}" issue create --repo "${REPO}" --priority High --title $'a\tb' --body-file "${TEST_TMP}/body.md"
    [ "${status}" -eq 2 ]
    [ ! -f "${GH_LOG}" ]
}

@test "a usage error names the option and the rule but never echoes the value, which could hold a token" {
    prepare_issue_create
    create_args
    local secret="LEAKMARKER0123456789" flag
    for flag in --title --label --body-file --repo; do
        # The bad value comes first, so it is parsed before the same option given by create_args.
        run --separate-stderr "${SCRIPT}" issue create "${flag}" "${secret}"$'\tx' "${CREATE_ARGS[@]:2}"
        [ "${status}" -eq 2 ] || { echo "${flag} was accepted" >&2; return 1; }
        [[ "${stderr}" == "cfwf: invalid value for ${flag}: it must "* ]]
        [[ "${stderr}" != *"${secret}"* ]]
    done

    run --separate-stderr "${SCRIPT}" issue create --repo "${REPO}" --priority "${secret}" --title T --body-file "${TEST_TMP}/body.md"
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: unknown --priority "* && "${stderr}" != *"${secret}"* ]]

    for flag in --pr --status; do
        run --separate-stderr "${SCRIPT}" workflow-status --set --repo "${REPO}" --issue 1346 --status Approved "${flag}" "${secret}"$'\tx'
        [ "${status}" -eq 2 ]
        [[ "${stderr}" == "cfwf: invalid value for ${flag}: it must "* && "${stderr}" != *"${secret}"* ]]
    done
    [ ! -f "${GH_LOG}" ]

    run --separate-stderr "${SCRIPT}" workflow-status --set --repo "${REPO}" --issue 1346 --status "${secret}"
    [ "${status}" -eq 1 ]
    [[ "${stderr}" == "cfwf: unknown --status "* && "${stderr}" != *"${secret}"* ]]
}

@test "issue create rejects the options that belong to workflow-status, and unknown ones" {
    prepare_issue_create
    create_args
    local flag
    for flag in --status --pr --issue --set --check --bogus; do
        run "${SCRIPT}" "${CREATE_ARGS[@]}" "${flag}" 1
        [ "${status}" -eq 2 ] || { echo "${flag} was accepted" >&2; return 1; }
        [[ "${output}" == *"unknown option (argument 11; its value is not shown)"* ]]
    done
    [ ! -f "${GH_LOG}" ]
}

@test "issue create refuses one argument that holds two of its flags as an unknown option" {
    prepare_issue_create
    run --separate-stderr "${SCRIPT}" issue create "--title --body-file" x --repo "${REPO}" --priority High --title T --body-file "${TEST_TMP}/body.md"
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == *"unknown option (argument 3; its value is not shown)"* && "${stderr}" != *"--title --body-file"* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "a token-shaped stray argument is named by its position, never echoed, as a command, a subcommand or an option" {
    prepare_issue_create
    local secret="ghp_${RANDOM}abcdefghijklmnopqrstuvwxyz0123456789"
    run --separate-stderr "${SCRIPT}" "${secret}"
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: unknown command (argument 1; its value is not shown)"* && "${stderr}" != *"${secret}"* ]]

    run --separate-stderr "${SCRIPT}" body "${secret}"
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: unknown body subcommand (argument 2; its value is not shown)"* && "${stderr}" != *"${secret}"* ]]

    # An unquoted title: --title takes the first word, and the token after it is a stray argument.
    run --separate-stderr "${SCRIPT}" issue create --repo "${REPO}" --priority High --title Rotate "${secret}" now --body-file "${TEST_TMP}/body.md"
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: unknown option (argument 9; its value is not shown)"* && "${stderr}" != *"${secret}"* ]]
    [ -z "${output}" ]
    [ ! -f "${GH_LOG}" ]
}

@test "an option that workflow-status does not have is not accepted there either" {
    local flag
    for flag in --priority --title --body-file --label; do
        run "${SCRIPT}" workflow-status --set --repo "${REPO}" --issue 1346 --status Approved "${flag}" value
        [ "${status}" -eq 2 ]
        [[ "${output}" == *"unknown option (argument 9; its value is not shown)"* ]]
    done
    [ ! -f "${GH_LOG}" ]
}

@test "issue create refuses a missing, unreadable, empty or blank body, without calling gh" {
    prepare_issue_create
    create_args
    run "${SCRIPT}" issue create --repo "${REPO}" --priority High --title T --body-file "${TEST_TMP}/nope.md"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"cfwf: cannot read the --body-file"* && "${output}" != *"${TEST_TMP}"* ]]

    : > "${TEST_TMP}/empty.md"
    run "${SCRIPT}" issue create --repo "${REPO}" --priority High --title T --body-file "${TEST_TMP}/empty.md"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"the body is empty"* ]]

    printf ' \n\t\n' > "${TEST_TMP}/blank.md"
    run "${SCRIPT}" issue create --repo "${REPO}" --priority High --title T --body-file "${TEST_TMP}/blank.md"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"the body is empty"* ]]

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
    [[ "${output}" == *"the body is empty"* ]]
    assert_nothing_created
}

@test "issue create hands gh the private copy it checked, so a body file rewritten after the check is never posted" {
    prepare_issue_create
    cp "${TEST_TMP}/body.md" "${TEST_TMP}/checked.md"
    printf '%s\n' "${TEST_TMP}/body.md" > "${GH_FIXTURES}/label-list.rewrite"
    create_args
    run "${SCRIPT}" "${CREATE_ARGS[@]}"
    [ "${status}" -eq 0 ]
    # The rewrite happened, between the check and the issue create, and gh still got the checked text.
    [[ "$(cat "${TEST_TMP}/body.md")" == rewritten* ]]
    cmp "${TEST_TMP}/checked.md" "${GH_FIXTURES}/issue-body.txt"
    [ "$(gh_call_count "--body-file ${TEST_TMP}/body.md")" -eq 0 ]
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

    issue_create_called_with "issue create --repo ${REPO} --title A new issue --body-file BODY --label High"
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
    issue_create_called_with "issue create --repo ${REPO} --title A new issue --body-file BODY --label High --label cfwf"
    [ "$(gh_call_count "label create")" -eq 0 ]
}

@test "issue create creates a missing standard label with its standard colour and description" {
    prepare_issue_create
    create_args
    run "${SCRIPT}" "${CREATE_ARGS[@]}" --label AI-Work --label "on hold"
    [ "${status}" -eq 0 ]
    grep -qxF "label create --repo ${REPO} --color ffa500 --description Work for an AI Agent -- AI-Work" "${GH_LOG}"
    grep -qxF "label create --repo ${REPO} --color ff0000 --description Do not work on this -- On Hold" "${GH_LOG}"
    issue_create_called_with "issue create --repo ${REPO} --title A new issue --body-file BODY --label High --label AI-Work --label On Hold"
}

@test "issue create creates any other missing label with the colour gh picks, passing no colour or description" {
    prepare_issue_create
    create_args
    run "${SCRIPT}" "${CREATE_ARGS[@]}" --label "brand new"
    [ "${status}" -eq 0 ]
    grep -qxF "label create --repo ${REPO} -- brand new" "${GH_LOG}"
    issue_create_called_with "issue create --repo ${REPO} --title A new issue --body-file BODY --label High --label brand new"
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

    TMPDIR="${scratch}" run "${SCRIPT}" issue create --repo "${REPO}" --priority High --title T --body-file "${TEST_TMP}/body.md"
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

# Makes the visibility lookup of the repository $1 fail the way a proxy or network fault would, or
# with the error $2 when one is given.
fail_visibility() {
    printf '%s' "${2:-}" > "$(visibility_fixture "$1").fail"
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
    printf 'A clean first line.\n\n%s\nA clean last line.\n' "$1" > "${TEST_TMP}/leak.md"
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
    printf '%s\n' "gh""p_${tail}" "gh""o_${tail}" "gh""s_${tail}" "gh""u_${tail}" "gh""r_${tail}" "github""_pat_${tail}" "gl""pat-${tail}" \
        "AKI""A$(printf 'Q%.0s' {1..16})" "-----BEGIN RSA PRIV""ATE KEY-----" "-----BEGIN PRIV""ATE KEY-----" \
        "xo""xb-${tail}" "xo""xa-${tail}" "xo""xp-${tail}" "xo""xr-${tail}" "xo""xs-${tail}" \
        "sk-""ant-api03-${tail}" "sk-""proj-${tail}" "https://disc""ord.com/api/webhooks/123456/${tail}" \
        "disc""ordapp.com/api/webhooks/1/${tail}" "Discord.com/api/web""hooks/42/x" \
        "Authorization: Bear""er abc" "-H 'authorization: bear""er ${tail}'" "{\"Authorization\": \"Bear""er ${tail}\"}" \
        "AUTHORIZATION: BEAR""ER x" "Bear""er ${tail}${tail}" "(bear""er ${tail}${tail})" \
        "Bear""er 0abcdefghijklmnopqrst" "Bear""er abcdefghijklmnopqrs9" "BEAR""ER abcdefghijklmnopqrstuvwxyz-7" \
        "GH_TO""KEN=${tail}" "export DB_PASS""WORD=${tail}" "MY_SEC""RET=${tail}" "(API_K""EY=${tail})" \
        "TO""KEN=${tail}" "K""EY=${tail}" "GH_TO""KEN=\"${tail}\"" "GH_TO""KEN='${tail}'" "AWS_2_SEC""RET=${tail}"
    leak_credential_forms
}

# Prints the character $1 repeated $2 times.
run_of() {
    local padding
    printf -v padding '%*s' "$2" ''
    printf '%s' "${padding// /$1}"
}

# Prints a URL of the scheme $1 whose user is $2 and whose password is $3, built from pieces so
# that no secret scanner takes this file to hold a URL with a password.
url_with_password() {
    printf '%s:/%s/%s:%s@%s' "$1" "" "$2" "$3" "example.com/path"
}

# The keys of an exact length, the Authorization headers, the URL passwords and the x-access-token
# user, built from pieces for the same reason as leak_tokens, which ends with them. A header is
# refused for having a value and a URL for having a password, so a placeholder is here too.
leak_credential_forms() {
    local tail="LEAKMARKER0123456789"
    printf '%s\n' "np""m_$(run_of a 36)" "AI""za$(run_of b 33)_-" "sk""-$(run_of c 48)" "ASI""A$(run_of Q 16)" \
        "np""m_$(run_of a 37)" "AI""za$(run_of b 36)" "sk""-$(run_of c 49)" \
        "Authorization: Bas""ic ${tail}=" "-H 'authorization: bas""ic ${tail}'" "{\"Authorization\": \"Bas""ic ${tail}\"}" \
        "AUTHORIZATION=BAS""IC x" "Authorization: Bas""ic <base64>" "Authorization: Bas""ic \$CREDENTIALS" \
        "-H \"Authorization: Bas""ic \${{ secrets.CREDENTIALS }}\"" \
        "Authorization: Bear""er <token>" "Authorization: Bear""er \$GH_TOKEN" \
        "-H \"Authorization: Bear""er \${{ secrets.GITHUB_TOKEN }}\"" \
        "Authorization: Dig""est username=\"user\", response=\"${tail}\"" "Authorization: Negot""iate ${tail}" \
        "Authorization: tok""en ${tail}" "authorization: AWS4-HMAC-SHA256 Credential=${tail}/aws4_request" \
        "Authorization: ${tail}" "Authorization:${tail}" "authorization=x" "Authorization: <value>" \
        "{\"Authorization\": \"\"}" "\`Authorization:\` is the header" \
        "-d \"{\\\"Authorization\\\": \\\"Bas""ic ${tail}\\\"}\"" "{\\\"Proxy-Authorization\\\":\\\"Dig""est ${tail}\\\"}" \
        "Proxy-Authorization: Bas""ic ${tail}" "-H 'proxy-authorization: bear""er x'" "PROXY-AUTHORIZATION=${tail}" \
        "{\"Proxy-Authorization\": \"Dig""est ${tail}\"}" "Proxy-Authorization: <value>" \
        "$(url_with_password https user "${tail}")" "$(url_with_password postgres app hunter)" \
        "$(url_with_password https "" "${tail}")" "$(url_with_password https user "${tail}:xxx")" \
        "$(url_with_password https user password)" "$(url_with_password https user PASSWORD)" \
        "$(url_with_password https user Password)" "$(url_with_password https user "<password>")" \
        "$(url_with_password https user "***")" "$(url_with_password https user xxx)" "$(url_with_password https user XXXX)" \
        "$(url_with_password https user "\$DB_PASSWORD")" "$(url_with_password postgres app "\${DB_PASSWORD}")" \
        "$(url_with_password https user "<password>")?to=someone@example.com" \
        "$(url_with_password https x-access-token "${tail}")" "x-access-token"":${tail}@""example.com" \
        "$(url_with_password https x-access-token "\${{secrets.GITHUB_TOKEN}}")" \
        "$(url_with_password https x-access-token "<token>")" "x-access-token"":<token>@""example.com" \
        "x-access-token"":\$GH_TOKEN@""example.com" "x-access-token"":***@""example.com" \
        "{\"url\":\"$(url_with_password postgres app "${tail}")\",\"email\":\"someone@example.com\"}" \
        "{\"url\":\"https:/""/user:password@localhost\",\"email\":\"someone@example.com\"}" \
        "\`https:/""/user:xxx@localhost:8080\`,\`someone@example.com\`" \
        "https:/""/user:${tail}@localhost?at=12:30" "https:/""/user:${tail}@localhost#line:5" \
        "http://localhost:8080,someone@example.com" "'http://localhost:8080','someone@example.com'" \
        "ssh:/""/git@localhost:22,someone@example.com" "https:/""/user:@localhost,someone@example.com" \
        "docker:/""/alpine:3.20@sha256:0123abcd" \
        "$(url_with_password https user "password@${tail}")" "x-access-token"":xxx@${tail}@""example.com" \
        "$(url_with_password https user "@${tail}")" "$(url_with_password https user "@@${tail}")" \
        "$(url_with_password https "" "@${tail}")" "$(url_with_password https x-access-token "@${tail}")" \
        "x-access-token"":@${tail}@""example.com" \
        "$(url_with_password smtp "someone@example.com" "${tail}")" "$(url_with_password imap "a@b@example.com" hunter)" \
        "$(url_with_password smtp "someone@example.com" "<password>")" "$(url_with_password smtp "someone@example.com" "@hunter")"
}

# Text that looks like one of the credential forms and is not: a key one character short, a key
# prefix inside a longer word, an Authorization header name with no value, or a URL with no
# password (a user name alone, an empty password or a port).
harmless_credential_shapes() {
    printf '%s\n' "np""m_$(run_of a 35) is one short" "npm_config_registry and npm_package_version" \
        "AI""za$(run_of b 34) is one short" "sk""-$(run_of c 47) is one short" "de""sk-$(run_of c 48)" \
        "ASI""A$(run_of Q 15) is one short" \
        "Authorization:" "Authorization: " "\"Authorization\":" "Proxy-Authorization:" "authorization =" \
        "The Authorization header carries the credential." "Set the Proxy-Authorization header with a Basic value." \
        "Authorization header: Bearer" "Basic authentication sends an Authorization header." "The basic steps are below." \
        "Digest and Negotiate are Authorization schemes too." \
        "The user name is x-access-token: the token follows it." "x-access-token:@example.com" \
        "$(url_with_password https x-access-token "\${{ secrets.GITHUB_TOKEN }}")" \
        "{\"url\":\"http://localhost:8080\",\"email\":\"someone@example.com\"}" \
        "\`http://localhost:8080\`,\`someone@example.com\`" "http://localhost:8080/path" \
        "https://example.com:8080/path?user=someone@example.com" "ssh://git@example.com:22/path" "http://[::1]:8080/path" \
        "https://example.com:8080?user=someone@example.com and https://example.com:8080#someone@example.com" \
        "https://example.com?at=12:30&to=someone@example.com" "https://example.com#line:5@someone" \
        "https://user@example.com?at=12:30&to=someone@example.com" \
        "Mail someone@example.com about https://example.com:8443 and ask @someone at 12:30." \
        "https:/""/user:@example.com/path" "https:/""/user:@example.com/path?to=someone@example.com" \
        "https:/""/user:@localhost, then mail someone@example.com" \
        "$(url_with_password smtp "someone@example.com" "")" "smtp://someone@example.com@smtp.example.com/path" \
        "ssh://git@example.com" "https://user@example.com" "ssh://git@example.com:22" "git@example.com:owner/repo.git" \
        "ssh://git@example.com:owner/repo.git" "docker://alpine@sha256:0123abcd" \
        "docker://library/alpine:3.20@sha256:0123abcd" "image: alpine:3.20@sha256:0123abcd" \
        "https://user@example.com:8080/path?to=someone@example.com" "ssh://git@localhost:22, then mail someone@example.com"
}

@test "issue create refuses a body with any token form with exit 8, naming the rule and line only, before calling gh" {
    prepare_issue_create
    local token
    while IFS= read -r token; do
        write_leak_body "the value is ${token} here"
        run_issue_create_leak
        assert_refused "${status}" "${output}" "${stderr}" token "${token}"
        [ ! -f "${GH_LOG}" ]
    done < <(leak_tokens)
}

@test "body check passes a key one character short, a key prefix inside a word, an Authorization header name with no value and a URL with no password" {
    local body
    while IFS= read -r body; do
        printf '%s\n' "${body}" > "${TEST_TMP}/leak.md"
        run_body_check
        [ "${status}" -eq 0 ] || { echo "refused: ${body}" >&2; return 1; }
        [ -z "${output}" ]
        [ -z "${stderr}" ]
        [ ! -f "${GH_LOG}" ]
    done < <(harmless_credential_shapes)
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
    for path in /home/someone/work /Users/someone/work /root/.ssh /run/user/1000/scratch /tmp/claude-out; do
        for start in "" " " '"' "'" '`' "(" "[" "=" "file://" ":" "," "*" "_" "<" "{" "|" "/"; do
            write_leak_body "${start:+see }${start}${path}/file"
            run_issue_create_leak
            assert_refused "${status}" "${output}" "${stderr}" "host path" "${path}"
            [ ! -f "${GH_LOG}" ]
        done
    done
}

@test "body check still refuses a host path after punctuation that does not follow a slash, at a line start, or after a run of slashes" {
    local body
    for body in "_/home/someone/x_" "__/tmp/claude-out__" "**/root/.ssh**" "see a,/run/user/1000/x" "see /_/home/someone/x" \
        "///home/someone/x" "x//tmp/claude-out" "https://example.com//home/someone"; do
        write_leak_body "${body}"
        run_body_check
        assert_refused "${status}" "${output}" "${stderr}" "host path" "someone"
    done
}

@test "body check refuses a home, a user runtime directory or tmp deeper inside an absolute path, and a Windows drive path under Users" {
    local path start
    for path in /mnt/c/Users/someone/work /var/home/someone/work /private/tmp/claude-out /var/tmp/x /var/run/user/1000/x /a.b/tmp/x \
        /var/root/.ssh /mnt/x/root/y; do
        for start in "" " " '"' "(" "=" ":" "," "*" "file://"; do
            write_leak_body "${start:+see }${start}${path}/file"
            run_body_check
            assert_refused "${status}" "${output}" "${stderr}" "host path" "${path}"
        done
    done
    for path in 'C:\Users\someone\x' 'c:/users/someone/x' 'D:\\USERS\\someone' '(C:\Users\someone)'; do
        write_leak_body "see ${path}"
        run_body_check
        assert_refused "${status}" "${output}" "${stderr}" "host path" "someone"
    done
}

@test "issue create refuses a body with a control character other than tab and newline, before calling gh" {
    prepare_issue_create
    local control
    for control in '\000' '\001' '\010' '\013' '\014' '\015' '\033' '\037' '\177' '\302\200' '\302\205' '\302\233' '\302\237'; do
        printf "A clean first line.\n\nsecret%bvalue\nA clean last line.\n" "${control}" > "${TEST_TMP}/leak.md"
        run_issue_create_leak
        assert_refused "${status}" "${output}" "${stderr}" "control character" "secret"
        [ ! -f "${GH_LOG}" ]
    done
}

@test "the first rule that matches wins, in the order token, host path, control character, invalid UTF-8, too long" {
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

    printf 'a\205b\nc\033d\n' > "${TEST_TMP}/leak.md"
    run_body_check
    [ "${stderr}" = "cfwf: body refused: control character (line 2)" ]

    {
        printf 'a\205b\n'
        head -c 65537 /dev/zero | tr '\0' 'x'
    } > "${TEST_TMP}/leak.md"
    run_body_check
    [ "${stderr}" = "cfwf: body refused: invalid UTF-8 (line 1)" ]
}

@test "a body, a title or a label that is not valid UTF-8 is refused with exit 8, naming only the line, before calling gh" {
    prepare_issue_create
    local bytes
    # A Latin-1 or CP1252 C1 byte alone, any byte that never starts UTF-8, a lead byte with no
    # continuation, an overlong NUL, a UTF-16 surrogate, a code point above U+10FFFF, and a
    # continuation byte straight after a whole character.
    for bytes in '\205' '\237' '\377' '\300' '\342\202' '\300\200' '\355\240\200' '\364\220\200\200' '\303\251\251'; do
        printf "A clean first line.\n\nsecret%bvalue\nA clean last line.\n" "${bytes}" > "${TEST_TMP}/leak.md"
        run_issue_create_leak
        assert_refused "${status}" "${output}" "${stderr}" "invalid UTF-8" "secret"
        [ ! -f "${GH_LOG}" ]

        run --separate-stderr "${SCRIPT}" issue create --repo "${REPO}" --priority High --title "$(printf "a%bb" "${bytes}")" --body-file "${TEST_TMP}/body.md"
        [ "${status}" -eq 8 ]
        [ "${stderr}" = "cfwf: title refused: invalid UTF-8" ]

        run --separate-stderr "${SCRIPT}" issue create --repo "${REPO}" --priority High --title T --body-file "${TEST_TMP}/body.md" --label "$(printf "a%bb" "${bytes}")"
        [ "${status}" -eq 8 ]
        [ "${stderr}" = "cfwf: label refused: invalid UTF-8" ]
        [ ! -f "${GH_LOG}" ]
    done
}

@test "body check passes a body with no leaks, printing nothing and calling gh for nothing" {
    printf '%s\n' \
        "Tabs$(printf '\t')are fine, as are multi-byte characters: $(printf '\303\251 \303\274 \346\227\245 \302\240 \302\251 \342\200\256 \304\200')." \
        "Relative paths such as test/cfwf.bats, lib/state and containers/base/x are fine." \
        "So are /usr/local/bin/cfwf, ~/work, ~/tmp/x, ~/work/home/x, ./tmp/x, ./a/tmp/x, ../home/x, tmp/notes, src/tmp/x, a/b/home/x, a/b/root/x, /users/x and example.com/home/x." \
        "URL paths pass too: https://example.com/home/x, http://h/tmp/x, //cdn.example.com/tmp/x, https://example.com/var/home/x and https://example.com/var/root/x." \
        "So does a URL path segment of punctuation: https://example.com/_/home/x, https://example.com/a/*/tmp/x, http://h/,/Users/x and https://example.com/:/root/x." \
        "So do Windows paths not under Users, a drive letter inside a word, and a relative one: C:\\Program Files\\x, abc:\\Users\\x, docs\\Users\\x." \
        "Words such as keyboard, laughs_at, monkey and the word TOKEN alone are fine, as is KEY = value." \
        "A token prefix on its own, gh""p_, is fine." \
        "credfeto/other-repo with no link and no number is not looked up." > "${TEST_TMP}/leak.md"
    run_body_check
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    [ -z "${stderr}" ]
    [ ! -f "${GH_LOG}" ]
}

@test "body check passes a token prefix, Bearer with no token after it or a webhook placeholder with no secret after it" {
    local body
    while IFS= read -r body; do
        printf '%s\n' "${body}" > "${TEST_TMP}/leak.md"
        run_body_check
        [ "${status}" -eq 0 ] || { echo "refused: ${body}" >&2; return 1; }
        [ -z "${stderr}" ]
    done << 'BODIES'
An Anthropic key starts sk-ant- and a project key sk-proj- on their own.
desk-proj-x and task-ant-y are words.
A Slack prefix such as xoxz-abc is not one of the token forms.
A Bearer token is sent in the Authorization header.
Bearer <token>
Bearer authentication is used.
Bearer authentication-mechanism-description
The bearer token-based-authentication-scheme is used.
Bearer Authentication-Mechanism-Description.
Bearer abcdefghijklmnopqrstuvwxyz
Bearer abcdefghijklmnopqr9
https://discord.com/api/webhooks/<id>/<token>
discord.com/api/webhooks/123456/<token>
BODIES
}

@test "body check passes a NAME=value whose name only ends in the letters, or whose value is a reference" {
    local body
    while IFS= read -r body; do
        printf '%s\n' "${body}" > "${TEST_TMP}/leak.md"
        run_body_check
        [ "${status}" -eq 0 ] || { echo "refused: ${body}" >&2; return 1; }
        [ -z "${stderr}" ]
    done << 'BODIES'
MONKEY=banana
TURKEY=x
MYTOKEN=x
my_api_key=x
GITHUB_TOKEN=${{ secrets.GITHUB_TOKEN }}
GH_TOKEN=${GH_TOKEN}
API_KEY=$API_KEY
GH_TOKEN="${GH_TOKEN}"
GH_TOKEN='$GH_TOKEN'
GH_TOKEN=
GH_TOKEN= x
BODIES
}

@test "a public target refuses a link to, or a reference to, a private repository, without naming it" {
    write_visibility "${REPO}" PUBLIC
    write_visibility credfeto/hidden-thing PRIVATE
    local reference
    for reference in "https://github.com/credfeto/hidden-thing/issues/4" "github.com/credfeto/hidden-thing" \
        "credfeto/hidden-thing#12" "(credfeto/hidden-thing#12)" "https://www.github.com/credfeto/hidden-thing.git" \
        "https://GitHub.COM/credfeto/hidden-thing" "git@github.com:credfeto/hidden-thing.git" \
        "https://api.github.com/repos/credfeto/hidden-thing/issues/4" "https://raw.githubusercontent.com/credfeto/hidden-thing/main/README.md" \
        "RAW.GITHUBUSERCONTENT.COM/credfeto/hidden-thing" "the clone...github.com/credfeto/hidden-thing" "(.github.com/credfeto/hidden-thing)"; do
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

@test "links to GitHub's other pages, such as starred lists, Copilot and the team plan, pass with no lookup" {
    write_leak_body "see https://github.com/stars/someone/lists/tools, github.com/copilot/c/abc123, https://github.com/team/compare and https://github.com/dashboard/feed"
    run_body_check
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ ! -f "${GH_LOG}" ]
}

@test "a link to the target's own wiki passes with no lookup, and another repository's wiki is looked up as that repository" {
    write_leak_body "see https://github.com/${REPO}.wiki, git@github.com:${REPO}.wiki.git and https://github.com/${REPO}/wiki/Home"
    run_body_check
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ ! -f "${GH_LOG}" ]

    write_visibility "${REPO}" PUBLIC
    write_visibility credfeto/hidden-thing PRIVATE
    local reference
    for reference in "https://github.com/credfeto/hidden-thing.wiki" "github.com/credfeto/hidden-thing.WIKI.git"; do
        write_leak_body "see ${reference} here"
        rm -f "${GH_LOG}"
        run_body_check
        assert_refused "${status}" "${output}" "${stderr}" "private repository" "hidden-thing"
        [ "$(visibility_lookups credfeto/hidden-thing)" -eq 1 ]
    done
}

@test "a pasted image or file, or one on GitHub's image hosts, passes on a public target with no lookup" {
    write_visibility "${REPO}" PUBLIC
    write_leak_body "![img](https://github.com/user-attachments/assets/0f1e2d3c-4b5a-6978-8a9b-0c1d2e3f4a5b) and [log](https://github.com/user-attachments/files/123/build.log), https://user-images.githubusercontent.com/1/2.png, https://private-user-images.githubusercontent.com/1/3.png and https://github.com/${REPO}/assets/1/4"
    run_body_check
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ ! -f "${GH_LOG}" ]
}

@test "a gist, another GitHub host or a host that only ends in github.com is not a repository link, and passes with no lookup" {
    write_visibility "${REPO}" PUBLIC
    write_leak_body "see https://gist.github.com/credfeto/abc123, https://docs.github.com/en/actions, notgithub.com/credfeto/hidden-thing, my-github.com/credfeto/hidden-thing and https://api.github.com/users/credfeto"
    run_body_check
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
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
    assert_refused "${status}" "${output}" "${stderr}" "private repository" "hidden-thing"
}

@test "a visibility lookup that fails is a runtime failure (exit 1), never a pass or a refusal" {
    write_visibility "${REPO}" PUBLIC
    fail_visibility credfeto/flaky-thing
    write_leak_body "see credfeto/flaky-thing#3"
    run_body_check
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: could not read the visibility of the repository named on line 3 of the body" ]

    # Access denied (an organisation enforcing SSO, or a proxy) is not "not found": it fails closed
    # as a runtime failure rather than counting as private.
    rm -f "${GH_FIXTURES}"/visibility-credfeto_flaky-thing.*
    fail_visibility credfeto/flaky-thing $'HTTP 403: Resource protected by organization SAML enforcement\n'
    run_body_check
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: could not read the visibility of the repository named on line 3 of the body" ]

    rm -f "${GH_FIXTURES}"/visibility-*
    fail_visibility "${REPO}"
    run_body_check
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: could not read the visibility of ${REPO}" ]
}

@test "a target repository GitHub does not show the caller is a runtime failure (exit 1), never a pass" {
    write_visibility credfeto/hidden-thing PRIVATE
    local reference
    for reference in "credfeto/hidden-thing#3" "https://github.com/credfeto/hidden-thing" "secret-org/plans"; do
        write_leak_body "see ${reference}"
        CFWF_PRIVATE_OWNERS="secret-org" run --separate-stderr "${SCRIPT}" body check --repo credfeto/no-such-repo --body-file "${TEST_TMP}/leak.md"
        [ "${status}" -eq 1 ]
        [ "${stderr}" = "cfwf: the repository credfeto/no-such-repo was not found, or the caller cannot see it" ]
        [ -z "${output}" ]
    done

    prepare_issue_create
    rm -f "${GH_LOG}"
    run --separate-stderr "${SCRIPT}" issue create --repo credfeto/no-such-repo --priority High --title "see credfeto/hidden-thing#3" --body-file "${TEST_TMP}/body.md"
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: the repository credfeto/no-such-repo was not found, or the caller cannot see it" ]
    assert_nothing_created
}

@test "a target repository GitHub does not show the caller is never looked up when the text names no other repository" {
    rm -f "${GH_LOG}"
    write_leak_body "see credfeto/no-such-repo#3, which is the target itself, and test/cfwf.bats"
    run --separate-stderr "${SCRIPT}" body check --repo credfeto/no-such-repo --body-file "${TEST_TMP}/leak.md"
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ ! -f "${GH_LOG}" ]
}

@test "a grep that fails while scanning the body is a runtime failure (exit 1), never a pass" {
    write_visibility "${REPO}" PUBLIC
    write_visibility credfeto/open-thing PUBLIC
    write_leak_body "see credfeto/open-thing#1 and https://github.com/credfeto/open-thing"
    local real_grep flags
    real_grep=$(command -v grep)
    # Each pass makes one of the scans fail: the rule scans (-naE), the UTF-8 scan alone (-xv), the
    # link scan (-inoaE) and the owner/repo scan (-noaE). Every other grep is the real one.
    for flags in -naE -xv -inoaE -noaE; do
        make_stub_multiline grep \
            "case \" \$* \" in *\" ${flags} \"*) echo 'grep: read error' >&2; exit 2 ;; esac" \
            "exec ${real_grep} \"\$@\""
        rm -f "${GH_LOG}"
        run_body_check
        [ "${status}" -eq 1 ]
        [ "${stderr##*$'\n'}" = "cfwf: could not scan the body" ]
        [ ! -f "${GH_LOG}" ]
    done
}

@test "an owner in CFWF_PRIVATE_OWNERS is refused with no lookup, even as a bare owner/repo" {
    write_visibility "${REPO}" PUBLIC
    local reference
    for reference in "secret-org/plans" "https://github.com/Secret-Org/plans/issues/1" "secret-org/plans#4" "\`other-hidden/plans\`" \
        "https://raw.githubusercontent.com/secret-org/plans/main/x" "https://api.github.com/repos/secret-org/plans" \
        "REPO=secret-org/plans" "repo:secret-org/plans" "?r=secret-org/plans#1" "x@secret-org/plans@abc1234"; do
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

@test "a reference in Markdown emphasis is still checked, and an underscore inside a word is not a boundary" {
    write_visibility "${REPO}" PUBLIC
    write_visibility credfeto/hidden-thing PRIVATE
    write_visibility credfeto/open-thing PUBLIC
    local body
    for body in "see _credfeto/hidden-thing#5_" "see __credfeto/hidden-thing#5__" "_credfeto/hidden-thing#5_ first" \
        "see *credfeto/hidden-thing#5*" "see **credfeto/hidden-thing@abc1234**" "(_credfeto/hidden-thing@abc1234_)"; do
        write_leak_body "${body}"
        run_body_check
        assert_refused "${status}" "${output}" "${stderr}" "private repository" "hidden-thing"
    done

    for body in "see _secret-org/plans_" "see __secret-org/plans__"; do
        write_leak_body "${body}"
        CFWF_PRIVATE_OWNERS="secret-org" run_body_check
        assert_refused "${status}" "${output}" "${stderr}" "private repository" "plans"
    done

    write_leak_body "see _credfeto/open-thing#5_ and *credfeto/open-thing#6*"
    rm -f "${GH_LOG}"
    run_body_check
    [ "${status}" -eq 0 ]
    [ "$(visibility_lookups credfeto/open-thing)" -eq 1 ]

    # An underscore inside a word, or a #n followed by more than closing underscores, is not a
    # reference, so nothing is looked up.
    for body in "see my_credfeto/hidden-thing#5" "see credfeto/hidden-thing#5_x" "see /_credfeto/hidden-thing#5_" "see =_credfeto/hidden-thing#5_"; do
        write_leak_body "${body}"
        rm -f "${GH_LOG}"
        run_body_check
        [ "${status}" -eq 0 ] || { echo "${body} was refused" >&2; return 1; }
        [ ! -f "${GH_LOG}" ]
    done
    write_leak_body "see my_secret-org/plans"
    CFWF_PRIVATE_OWNERS="secret-org" run_body_check
    [ "${status}" -eq 0 ]
}

@test "a #n inside a longer word, or an owner/repo#n inside a path or a URL, is not a cross-reference, and passes with no lookup" {
    write_visibility "${REPO}" PUBLIC
    write_visibility credfeto/hidden-thing PRIVATE
    local body
    for body in "docs/setup.md#1-prerequisites" "fix/foo#12abc" "src/app.ts#12_x" "fix/foo#12-bar" "credfeto/hidden-thing#1x" \
        "https://example.com/?p=credfeto/hidden-thing#1" "user@credfeto/hidden-thing#1" "~credfeto/hidden-thing#1" \
        "localhost:8080/hidden-thing#1" "https://example.com:8443/credfeto/hidden-thing#1" "a&b=credfeto/hidden-thing#1" "%2Fcredfeto/hidden-thing#1" "+credfeto/hidden-thing#1"; do
        write_leak_body "see ${body} here"
        rm -f "${GH_LOG}"
        run_body_check
        [ "${status}" -eq 0 ] || { echo "refused: ${body}" >&2; return 1; }
        [ -z "${stderr}" ]
        [ ! -f "${GH_LOG}" ]
    done
}

@test "standalone cross-references side by side are each checked, so a private one after a public one is refused" {
    write_visibility "${REPO}" PUBLIC
    write_visibility credfeto/open-thing PUBLIC
    write_visibility credfeto/hidden-thing PRIVATE
    local body
    for body in "credfeto/open-thing#1 credfeto/hidden-thing#2" "credfeto/open-thing#1,credfeto/hidden-thing#2." \
        "(credfeto/open-thing#1)(credfeto/hidden-thing#2)" "credfeto/hidden-thing#2" "Related:credfeto/hidden-thing#2" \
        "Fixes:credfeto/hidden-thing@abc1234" "x:credfeto/hidden-thing#2"; do
        write_leak_body "${body}"
        run_body_check
        assert_refused "${status}" "${output}" "${stderr}" "private repository" "hidden-thing"
    done
}

@test "a public target refuses a codeload link or an owner/repo@sha autolink to a private repository" {
    write_visibility "${REPO}" PUBLIC
    write_visibility credfeto/hidden-thing PRIVATE
    write_visibility credfeto/open-thing PUBLIC
    local sha40 reference
    sha40=$(printf 'a%.0s' {1..40})
    for reference in "https://codeload.github.com/credfeto/hidden-thing/zip/refs/heads/main" "codeload.github.com/credfeto/hidden-thing/tar.gz/v1" \
        "credfeto/hidden-thing@abc1234" "credfeto/hidden-thing@ABC1234." "(credfeto/hidden-thing@${sha40})" "credfeto/open-thing#1 credfeto/hidden-thing@abc1234"; do
        write_leak_body "see ${reference}"
        run_body_check
        assert_refused "${status}" "${output}" "${stderr}" "private repository" "hidden-thing"
    done
}

@test "an @ that is not followed by a commit SHA alone, or a host that only ends in codeload.github.com, passes with no lookup" {
    write_visibility "${REPO}" PUBLIC
    write_visibility credfeto/hidden-thing PRIVATE
    local body
    for body in "credfeto/hidden-thing@abc123" "credfeto/hidden-thing@$(printf 'a%.0s' {1..41})" "credfeto/hidden-thing@abc1234x" \
        "credfeto/hidden-thing@abc1234-x" "credfeto/hidden-thing@v1.2.3" "actions/checkout@v4" "notcodeload.github.com/credfeto/hidden-thing" \
        "x@credfeto/hidden-thing@abc1234"; do
        write_leak_body "see ${body} here"
        rm -f "${GH_LOG}"
        run_body_check
        [ "${status}" -eq 0 ] || { echo "refused: ${body}" >&2; return 1; }
        [ -z "${stderr}" ]
        [ ! -f "${GH_LOG}" ]
    done
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

@test "issue create refuses a title or a label with a token or a host path, naming only the rule, before calling gh" {
    prepare_issue_create
    local leak
    for leak in "fix gh""p_LEAKMARKER0123456789 now" "see /home/someone/work" "set MY_SEC""RET=LEAKMARKER" "clone $(url_with_password https user LEAKMARKER)"; do
        run --separate-stderr "${SCRIPT}" issue create --repo "${REPO}" --priority High --title "${leak}" --body-file "${TEST_TMP}/body.md"
        [ "${status}" -eq 8 ]
        [[ "${stderr}" == "cfwf: title refused: "@(token|host path) ]]
        [[ "${stderr}" != *LEAKMARKER* && "${stderr}" != *someone* ]]
        [ -z "${output}" ]

        run --separate-stderr "${SCRIPT}" issue create --repo "${REPO}" --priority High --title T --body-file "${TEST_TMP}/body.md" --label ok --label "${leak}"
        [ "${status}" -eq 8 ]
        [[ "${stderr}" == "cfwf: label refused: "@(token|host path) ]]
        [[ "${stderr}" != *LEAKMARKER* && "${stderr}" != *someone* ]]
        [ -z "${output}" ]
    done
    [ ! -f "${GH_LOG}" ]

    run --separate-stderr "${SCRIPT}" issue create --repo "${REPO}" --priority High --title "see /tmp/x" --body-file "${TEST_TMP}/body.md"
    [ "${stderr}" = "cfwf: title refused: host path" ]
    run --separate-stderr "${SCRIPT}" issue create --repo "${REPO}" --priority High --title T --body-file "${TEST_TMP}/body.md" --label "see /tmp/x"
    [ "${stderr}" = "cfwf: label refused: host path" ]
}

@test "issue create refuses a title or a label naming a private repository on a public target, before any write" {
    prepare_issue_create
    write_visibility "${REPO}" PUBLIC
    write_visibility credfeto/hidden-thing PRIVATE
    run --separate-stderr "${SCRIPT}" issue create --repo "${REPO}" --priority High --title "port credfeto/hidden-thing#3" --body-file "${TEST_TMP}/body.md"
    [ "${status}" -eq 8 ]
    [ "${stderr}" = "cfwf: title refused: private repository" ]
    assert_nothing_created
    [ "$(gh_call_count "label list")" -eq 0 ]

    run --separate-stderr "${SCRIPT}" issue create --repo "${REPO}" --priority High --title T --body-file "${TEST_TMP}/body.md" --label "credfeto/hidden-thing#3"
    [ "${status}" -eq 8 ]
    [ "${stderr}" = "cfwf: label refused: private repository" ]
    assert_nothing_created

    fail_visibility credfeto/flaky-thing
    run --separate-stderr "${SCRIPT}" issue create --repo "${REPO}" --priority High --title "see credfeto/flaky-thing#1" --body-file "${TEST_TMP}/body.md"
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: could not read the visibility of the repository named in the title" ]
    assert_nothing_created
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
    [[ "${stderr}" == *"unknown body subcommand (argument 2; its value is not shown)"* && "${stderr}" != *frobnicate* ]]

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
    [[ "${stderr}" == *"unknown option (argument 7; its value is not shown)"* ]]

    run --separate-stderr "${SCRIPT}" body check --repo "${REPO}" --repo credfeto/other --body-file "${TEST_TMP}/leak.md"
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == *"--repo can only be given once"* ]]

    run --separate-stderr "${SCRIPT}" body check --repo "no-slash" --body-file "${TEST_TMP}/leak.md"
    [ "${status}" -eq 2 ]

    local flag
    for flag in --skip-leak-check --force "--repo --body-file"; do
        run --separate-stderr "${SCRIPT}" body check --repo "${REPO}" --body-file "${TEST_TMP}/leak.md" "${flag}"
        [ "${status}" -eq 2 ]
        [[ "${stderr}" == *"unknown option (argument 7; its value is not shown)"* && "${stderr}" != *"${flag}"* ]]
    done
    [ ! -f "${GH_LOG}" ]
}

@test "body check refuses a missing or blank body as a runtime failure, without calling gh" {
    run --separate-stderr "${SCRIPT}" body check --repo "${REPO}" --body-file "${TEST_TMP}/nope.md"
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: cannot read the --body-file" ]

    printf ' \n' > "${TEST_TMP}/blank.md"
    run --separate-stderr "${SCRIPT}" body check --repo "${REPO}" --body-file "${TEST_TMP}/blank.md"
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: the body is empty" ]
    [ ! -f "${GH_LOG}" ]
}

# --- pr checks ------------------------------------------------------------------

HEAD_SHA="1111111111111111111111111111111111111111"
OLD_SHA="2222222222222222222222222222222222222222"
COMPLETED_AT="2026-10-01T12:00:00Z"

# The fixture path (without .json or .fail) the gh stub reads for the API endpoint $1, query left out.
api_fixture() {
    local endpoint="${1%%\?*}"
    printf '%s/api-%s' "${GH_FIXTURES}" "${endpoint//\//_}"
}

# Writes the JSON on stdin as the answer to the API endpoint $1.
write_api() {
    cat > "$(api_fixture "$1").json"
}

# Makes the API endpoint $1 fail with the error text $2 (a proxy's 502 by default).
fail_api() {
    printf '%s\n' "${2:-gh: Bad Gateway (HTTP 502)}" > "$(api_fixture "$1").fail"
}

# One check run: name, conclusion ("" for none), id, then optionally its status (completed when it
# has a conclusion, in_progress otherwise; "" for that default), the commit it ran on (HEAD_SHA), the
# id of the app that made it (GitHub Actions, 15368) and the id of its check suite (1).
check_run() {
    local status="${4:-}"
    [ -n "${status}" ] || { [ -n "$2" ] && status=completed || status=in_progress; }
    jq -n --arg name "$1" --arg conclusion "$2" --argjson id "$3" --arg status "${status}" \
        --arg sha "${5:-${HEAD_SHA}}" --arg at "${COMPLETED_AT}" --argjson app "${6:-15368}" --argjson suite "${7:-1}" \
        '{name: $name, id: $id, head_sha: $sha, status: $status,
          conclusion: (if $conclusion == "" then null else $conclusion end),
          completed_at: (if $conclusion == "" then null else $at end),
          app: {id: $app, slug: "app-\($app)"}, check_suite: {id: $suite}}'
}

# Writes the check runs of the commit $1: the rest of the arguments, each a check_run object.
write_check_runs() {
    local sha="$1"
    shift
    printf '%s\n' "$@" | jq -s '{total_count: length, check_runs: .}' | write_api "repos/${REPO}/commits/${sha}/check-runs"
}

# One commit status: context, state, id.
commit_status() {
    jq -n --arg context "$1" --arg state "$2" --argjson id "$3" --arg at "${COMPLETED_AT}" \
        '{context: $context, state: $state, id: $id, updated_at: $at}'
}

# Writes the combined status of the commit $1: the rest of the arguments, each a commit_status object.
write_statuses() {
    local sha="$1"
    shift
    printf '%s\n' "$@" | jq -s '{state: "pending", sha: "'"${sha}"'", statuses: .}' \
        | write_api "repos/${REPO}/commits/${sha}/status"
}

# Writes the branch $1, its tip at HEAD_SHA, with no branch protection, as GitHub shows it to a
# caller with read access.
write_branch() {
    jq -n --arg name "$1" --arg sha "${HEAD_SHA}" '{name: $name, commit: {sha: $sha}, protected: false,
        protection: {enabled: false, required_status_checks: {enforcement_level: "off", contexts: [], checks: []}}}' \
        | write_api "repos/${REPO}/branches/$1"
}

# Writes the branch $1, its tip at HEAD_SHA, with classic branch protection requiring the checks
# named by the rest of the arguments, each name or name#<app id>. As GitHub lists them, contexts
# repeats every name, and checks has each but the first (one set up before checks existed) with its
# app id, or null for any source.
write_protection() {
    local branch="$1"
    shift
    jq -n --arg name "${branch}" --arg sha "${HEAD_SHA}" --args '{name: $name, commit: {sha: $sha}, protected: true,
        protection: {enabled: true, required_status_checks: {enforcement_level: "non_admins",
            contexts: ($ARGS.positional | map(split("#")[0])),
            checks: ($ARGS.positional[1:] | map(split("#") | {context: .[0], app_id: (.[1] // null | if . == null then null else tonumber end)}))}}}' "$@" \
        | write_api "repos/${REPO}/branches/${branch}"
}

# Writes the rules that apply to the branch $1: a required_status_checks rule naming the rest of
# the arguments, each name or name#<integration id>, beside a rule of another type.
write_rulesets() {
    local branch="$1"
    shift
    jq -n --args '[{type: "pull_request", parameters: {required_approving_review_count: 1}},
        {type: "required_status_checks", parameters: {required_status_checks: ($ARGS.positional
            | map(split("#") | {context: .[0]} + (if .[1] == null then {} else {integration_id: (.[1] | tonumber)} end)))}}]' "$@" \
        | write_api "repos/${REPO}/rules/branches/${branch}"
}

# Writes the rules that apply to the branch $1 as GitHub answers a branch no ruleset applies to:
# an empty list, never a 404.
write_no_rulesets() {
    printf '[]\n' | write_api "repos/${REPO}/rules/branches/$1"
}

# PR 42, whose head is HEAD_SHA and whose base, main, requires build; build passed and nothing else
# ran. Each test changes what it needs.
prepare_pr_checks() {
    jq -n --arg sha "${HEAD_SHA}" '{number: 42, head: {sha: $sha}, base: {ref: "main"}}' | write_api "repos/${REPO}/pulls/42"
    write_protection main build
    write_no_rulesets main
    write_check_runs "${HEAD_SHA}" "$(check_run build success 11)"
    write_statuses "${HEAD_SHA}"
}

run_pr_checks() {
    run --separate-stderr "${SCRIPT}" pr checks --repo "${REPO}" "$@"
}

@test "pr checks help, from help pr, pr -h and pr checks -h, describes every exit code and calls no gh" {
    local invocation
    for invocation in "help pr" "pr -h" "pr checks --help" "pr checks -h"; do
        # shellcheck disable=SC2086  # each invocation is split into its words on purpose
        run "${SCRIPT}" ${invocation}
        [ "${status}" -eq 0 ]
        [[ "${output}" == *"cfwf pr checks --repo <owner/repo> (--pr <n> | --sha <40-hex> | --branch <name>) [--all]"* ]]
        [[ "${output}" == *"Exit codes: 0 every judged check passed; 3 at least one failed; 4 none failed and at least one is"*"pending; 5 the head has no check runs or statuses at all"* ]]
        [[ "${output}" == *"1 a runtime failure"*"never reported as a failed check; 2 a usage error."* ]]
        [[ "${output}" == *"never waits or polls"* ]]
    done
    [ ! -f "${GH_LOG}" ]
}

@test "pr checks refuses an owner or repository of . or .., which would change the API path, before any gh call" {
    local bad
    for bad in "../.." "./x" "x/." "x/.." "../repo" "owner/.."; do
        run --separate-stderr "${SCRIPT}" pr checks --repo "${bad}" --pr 42
        [ "${status}" -eq 2 ] || { echo "--repo '${bad}' was accepted (${status})" >&2; return 1; }
        [ -z "${output}" ]
        [[ "${stderr}" == *"invalid value for --repo: neither the owner nor the repository can be . or .."* ]]
        [[ "${stderr}" != *"${bad}"* ]]
    done
    [ ! -f "${GH_LOG}" ]

    # A name that only starts with a dot, such as .github, is a real repository and is still taken.
    run --separate-stderr "${SCRIPT}" pr checks --repo owner/.github --pr 42
    [ "${status}" -eq 1 ]
    [ "$(gh_call_count "api repos/owner/.github/pulls/42 ")" -eq 1 ]
}

@test "pr checks usage errors exit 2 before any gh call" {
    local sha_upper="${HEAD_SHA^^}"
    local -a cases=(
        "--sha 111111111111111111111111111111111111111"
        "--sha 111111111111111111111111111111111111111g"
        "--sha 11111111111111111111111111111111111111111"
        "--pr 42 --sha ${HEAD_SHA}"
        "--pr 42 --branch main"
        "--sha ${HEAD_SHA} --branch main"
        ""
        "--pr 42 --pr 43"
        "--sha ${sha_upper} --sha ${HEAD_SHA}"
        "--branch main --branch dev"
        "--pr x42"
        "--pr 42 --json name"
        "--pr 42 --jq ."
        "--pr 42 --template x"
        "--pr 42 --watch"
        "--pr 42 --interval 10"
        "--pr 42 -i 10"
        "--pr 42 --required"
        "--pr 42 --all extra"
        "--branch -main"
        "--branch /main"
        "--branch a..b"
        "--branch a//b"
        "--branch a/"
        "--branch .hidden"
        "--branch main.lock"
        "--branch a.lock/b"
        "--branch a@{1}"
        "--branch HEAD"
        "--branch @{-1}"
        "--branch a."
        "--pr"
    )
    local args
    for args in "${cases[@]}"; do
        # shellcheck disable=SC2086  # each case is split into its words on purpose
        run_pr_checks ${args}
        [ "${status}" -eq 2 ] || { echo "accepted: ${args} (${status})" >&2; return 1; }
        [ -z "${output}" ]
        [[ "${stderr}" == *"Usage: cfwf pr checks"* ]]
    done

    run --separate-stderr "${SCRIPT}" pr checks --pr 42
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == *"missing required option --repo"* ]]

    local branch
    for branch in "bad name" "bad?x" "bad*" $'bad\tx' "bad~1" "bad:x" "bad^x" "bad@{x" "bad[x" 'bad\x' $'bad\x7fx'; do
        run_pr_checks --branch "${branch}"
        [ "${status}" -eq 2 ]
        [[ "${stderr%%$'\n'*}" == "cfwf: invalid value for --branch: "* && "${stderr%%$'\n'*}" != *"${branch}"* ]]
    done

    run_pr_checks --pr 42 --json name
    [[ "${stderr}" == *"unknown option (argument 7; its value is not shown)"* && "${stderr%%$'\n'*}" != *json* ]]

    run_pr_checks --pr 42 --branch main
    [[ "${stderr}" == *"give exactly one of --pr, --sha and --branch"* ]]

    run --separate-stderr "${SCRIPT}" pr frobnicate
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == *"unknown pr subcommand"* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "pr checks exits 0 when every required check passed, reading the PR head, its base's required checks and both result sources" {
    prepare_pr_checks
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    [ "${output}" = "build"$'\t'"pass"$'\t'"${COMPLETED_AT}"$'\t'"11"$'\n'"summary passed=1 failed=0 pending=0 head=${HEAD_SHA}" ]
    [ -z "${stderr}" ]
    [ "$(gh_call_count "api repos/${REPO}/pulls/42 ")" -eq 1 ]
    [ "$(gh_call_count "api repos/${REPO}/branches/main --jq ")" -eq 1 ]
    [ "$(gh_call_count "/protection")" -eq 0 ]
    [ "$(gh_call_count "api repos/${REPO}/rules/branches/main?per_page=100 --paginate ")" -eq 1 ]
    [ "$(gh_call_count "api repos/${REPO}/commits/${HEAD_SHA}/check-runs?per_page=100&filter=all --paginate ")" -eq 1 ]
    [ "$(gh_call_count "api repos/${REPO}/commits/${HEAD_SHA}/status?per_page=100 --paginate ")" -eq 1 ]
    [ "$(gh_call_count " api graphql")" -eq 0 ]
}

@test "pr checks reads a PR number given with leading zeros as that number, without them" {
    run_pr_checks --pr 042
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: ${REPO}#42 was not found" ]

    prepare_pr_checks
    : > "${GH_LOG}"
    run_pr_checks --pr 00042
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"summary passed=1 failed=0 pending=0 head=${HEAD_SHA}" ]]
    [ "$(gh_call_count "api repos/${REPO}/pulls/42 ")" -eq 1 ]
    [ "$(gh_call_count "pulls/0")" -eq 0 ]
}

@test "pr checks exits 3 for each failing conclusion, and for a conclusion it does not know" {
    prepare_pr_checks
    local conclusion
    for conclusion in failure cancelled timed_out action_required startup_failure stale something_new; do
        write_check_runs "${HEAD_SHA}" "$(check_run build "${conclusion}" 11)"
        run_pr_checks --pr 42
        [ "${status}" -eq 3 ] || { echo "${conclusion}: ${status}" >&2; return 1; }
        [ "${output}" = "build"$'\t'"fail"$'\t'"${COMPLETED_AT}"$'\t'"11"$'\n'"summary passed=0 failed=1 pending=0 head=${HEAD_SHA}" ]
    done
}

@test "pr checks counts skipped and neutral as passed" {
    prepare_pr_checks
    write_protection main build lint
    write_check_runs "${HEAD_SHA}" "$(check_run build skipped 11)" "$(check_run lint neutral 12)"
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"summary passed=2 failed=0 pending=0 head=${HEAD_SHA}" ]]
}

@test "pr checks exits 4 for a run in progress, and counts a run with a conclusion as finished whatever its status" {
    prepare_pr_checks
    write_check_runs "${HEAD_SHA}" "$(check_run build "" 11)"
    run_pr_checks --pr 42
    [ "${status}" -eq 4 ]
    [ "${output}" = "build"$'\t'"pending"$'\t'$'\t'"11"$'\n'"summary passed=0 failed=0 pending=1 head=${HEAD_SHA}" ]

    write_check_runs "${HEAD_SHA}" "$(check_run build "" 11 completed)"
    run_pr_checks --pr 42
    [ "${status}" -eq 4 ]

    write_check_runs "${HEAD_SHA}" "$(check_run build success 11 in_progress)"
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]

    write_check_runs "${HEAD_SHA}" "$(check_run build failure 11 queued)"
    run_pr_checks --pr 42
    [ "${status}" -eq 3 ]
}

@test "pr checks counts a required check with no run as pending, and a failure still wins over it" {
    prepare_pr_checks
    write_protection main build lint
    run_pr_checks --pr 42
    [ "${status}" -eq 4 ]
    [ "${output}" = "build"$'\t'"pass"$'\t'"${COMPLETED_AT}"$'\t'"11"$'\n'"lint"$'\t'"pending"$'\t'$'\t'$'\n'"summary passed=1 failed=0 pending=1 head=${HEAD_SHA}" ]

    run_pr_checks --pr 42 --all
    [ "${status}" -eq 4 ]
    [[ "${output}" == *"lint"$'\t'"pending"$'\t'$'\t'* ]]

    write_check_runs "${HEAD_SHA}" "$(check_run build failure 11)"
    run_pr_checks --pr 42
    [ "${status}" -eq 3 ]
}

@test "pr checks exits 5 when the head has no check runs or statuses at all" {
    prepare_pr_checks
    write_check_runs "${HEAD_SHA}"
    write_protection main
    run_pr_checks --pr 42
    [ "${status}" -eq 5 ]
    [ "${output}" = "summary passed=0 failed=0 pending=0 head=${HEAD_SHA}" ]

    # A draft-gated PR has none until it is marked ready, even where checks are required.
    write_protection main build
    run_pr_checks --pr 42
    [ "${status}" -eq 5 ]
    [ "${output}" = "build"$'\t'"pending"$'\t'$'\t'$'\n'"summary passed=0 failed=0 pending=1 head=${HEAD_SHA}" ]
}

@test "pr checks judges only the required checks, unless --all is given" {
    prepare_pr_checks
    write_check_runs "${HEAD_SHA}" "$(check_run build success 11)" "$(check_run optional failure 12)"
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    [ "$(grep -c optional <<< "${output}")" -eq 0 ]

    run_pr_checks --pr 42 --all
    [ "${status}" -eq 3 ]
    [[ "${output}" == *"optional"$'\t'"fail"$'\t'"${COMPLETED_AT}"$'\t'"12"* ]]
    [[ "${output}" == *"summary passed=1 failed=1 pending=0"* ]]
}

@test "pr checks matches a required check pinned to an app only with a run from that app, and any other by name alone" {
    prepare_pr_checks
    # build must come from GitHub Actions (15368); another app's build does not satisfy it.
    write_protection main first build#15368
    write_check_runs "${HEAD_SHA}" "$(check_run first success 10 "" "" 57789 3)" "$(check_run build success 11 "" "" 57789 4)"
    run_pr_checks --pr 42
    [ "${status}" -eq 4 ]
    [ "${output}" = "build"$'\t'"pending"$'\t'$'\t'$'\n'"first"$'\t'"pass"$'\t'"${COMPLETED_AT}"$'\t'"10"$'\n'"summary passed=1 failed=0 pending=1 head=${HEAD_SHA}" ]

    # Nor does a commit status, which carries no app.
    write_statuses "${HEAD_SHA}" "$(commit_status build success 31)"
    run_pr_checks --pr 42
    [ "${status}" -eq 4 ]
    [[ "${output}" == "build"$'\t'"pending"$'\t'$'\t'$'\n'* ]]

    # But a failed commit status of its name fails it, on its own or beside a pass from that app.
    write_statuses "${HEAD_SHA}" "$(commit_status build failure 31)"
    run_pr_checks --pr 42
    [ "${status}" -eq 3 ]
    [[ "${output}" == "build"$'\t'"fail"$'\t'"${COMPLETED_AT}"$'\t'"31"$'\n'* ]]
    write_check_runs "${HEAD_SHA}" "$(check_run first success 10 "" "" 57789 3)" "$(check_run build success 12 "" "" 15368 5)"
    run_pr_checks --pr 42
    [ "${status}" -eq 3 ]
    [[ "${output}" == "build"$'\t'"fail"$'\t'"${COMPLETED_AT}"$'\t'"31"$'\n'* ]]
    write_statuses "${HEAD_SHA}" "$(commit_status build pending 31)"
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    write_statuses "${HEAD_SHA}" "$(commit_status build success 31)"

    write_check_runs "${HEAD_SHA}" "$(check_run first success 10 "" "" 57789 3)" "$(check_run build success 11 "" "" 57789 4)" \
        "$(check_run build success 12 "" "" 15368 5)"
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"build"$'\t'"pass"$'\t'"${COMPLETED_AT}"$'\t'"12"$'\n'* ]]

    # The pinned app's own failure fails it, whatever another app says; a failure from another
    # app does not.
    write_statuses "${HEAD_SHA}"
    write_check_runs "${HEAD_SHA}" "$(check_run first success 10)" "$(check_run build failure 13 "" "" 57789 4)" \
        "$(check_run build success 12 "" "" 15368 5)"
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]

    # A name required for any source (app_id null) takes every result of that name.
    write_protection main first build
    run_pr_checks --pr 42
    [ "${status}" -eq 3 ]

    # A ruleset pins an app through integration_id.
    write_branch main
    write_rulesets main lint#15368
    write_check_runs "${HEAD_SHA}" "$(check_run lint success 14 "" "" 57789 6)"
    run_pr_checks --pr 42
    [ "${status}" -eq 4 ]
    [[ "${output}" == "lint"$'\t'"pending"$'\t'$'\t'$'\n'* ]]
}

@test "pr checks shows the app of each line of a name required more than once, keeping four columns" {
    prepare_pr_checks
    write_protection main first build#15368 build#57789
    write_check_runs "${HEAD_SHA}" "$(check_run first success 10)" "$(check_run build success 11 "" "" 15368 5)" \
        "$(check_run build failure 12 "" "" 57789 6)"
    run_pr_checks --pr 42
    [ "${status}" -eq 3 ]
    [ "${output}" = "build (app 15368)"$'\t'"pass"$'\t'"${COMPLETED_AT}"$'\t'"11"$'\n'"build (app 57789)"$'\t'"fail"$'\t'"${COMPLETED_AT}"$'\t'"12"$'\n'"first"$'\t'"pass"$'\t'"${COMPLETED_AT}"$'\t'"10"$'\n'"summary passed=2 failed=1 pending=0 head=${HEAD_SHA}" ]

    # Required from an app and from any source: only the pinned line names its app.
    write_branch main
    write_rulesets main build build#15368
    write_check_runs "${HEAD_SHA}" "$(check_run build success 11 "" "" 15368 5)"
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    [ "${output}" = "build"$'\t'"pass"$'\t'"${COMPLETED_AT}"$'\t'"11"$'\n'"build (app 15368)"$'\t'"pass"$'\t'"${COMPLETED_AT}"$'\t'"11"$'\n'"summary passed=2 failed=0 pending=0 head=${HEAD_SHA}" ]
    [ "$(awk -F '\t' 'NF != 4' <<< "${output}")" = "summary passed=2 failed=0 pending=0 head=${HEAD_SHA}" ]
}

@test "pr checks judges every check when the branch requires none" {
    prepare_pr_checks
    jq -n --arg sha "${HEAD_SHA}" '{name: "main", commit: {sha: $sha}}' | write_api "repos/${REPO}/branches/main"
    write_rulesets main
    write_check_runs "${HEAD_SHA}" "$(check_run build success 11)" "$(check_run optional failure 12)"
    run_pr_checks --pr 42
    [ "${status}" -eq 3 ]
    [[ "${output}" == *"summary passed=1 failed=1 pending=0"* ]]
}

@test "pr checks reads required checks from branch protection, from rulesets, from both without duplicates, and from neither" {
    prepare_pr_checks
    write_check_runs "${HEAD_SHA}" "$(check_run a success 1)" "$(check_run b success 2)" "$(check_run c success 3)" "$(check_run d failure 4)"

    write_protection main a b
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    [ "$(cut -sf1 <<< "${output}" | paste -sd ' ')" = "a b" ]

    write_branch main
    write_rulesets main b c
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    [ "$(cut -sf1 <<< "${output}" | paste -sd ' ')" = "b c" ]

    write_protection main a b
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    [ "$(cut -sf1 <<< "${output}" | paste -sd ' ')" = "a b c" ]
    [[ "${output}" == *"passed=3 failed=0 pending=0"* ]]

    write_branch main
    write_no_rulesets main
    run_pr_checks --pr 42
    [ "${status}" -eq 3 ]
    [ "$(cut -sf1 <<< "${output}" | paste -sd ' ')" = "a b c d" ]

    # Required checks switched off on a protected branch can still be listed; they require nothing.
    jq -n --arg sha "${HEAD_SHA}" '{name: "main", commit: {sha: $sha}, protected: true,
        protection: {enabled: true, required_status_checks: {enforcement_level: "off", contexts: ["a"], checks: [{context: "b"}]}}}' \
        | write_api "repos/${REPO}/branches/main"
    run_pr_checks --pr 42
    [ "${status}" -eq 3 ]
    [ "$(cut -sf1 <<< "${output}" | paste -sd ' ')" = "a b c d" ]
}

@test "pr checks treats a 404 from the rulesets as a failed read (exit 1), never as no rulesets" {
    # GitHub answers a branch no ruleset applies to with an empty list, so a 404 means the rules
    # could not be read; taking it as none would judge only the checks that happen to be present.
    prepare_pr_checks
    write_branch main
    rm "$(api_fixture "repos/${REPO}/rules/branches/main").json"
    run_pr_checks --pr 42
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not read the rulesets of ${REPO}: gh: Not Found (HTTP 404)" ]

    fail_api "repos/${REPO}/rules/branches/main" "gh: Resource not accessible by integration (HTTP 403)"
    run_pr_checks --pr 42
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not read the rulesets of ${REPO}: gh: Resource not accessible by integration (HTTP 403)" ]
}

@test "pr checks reads the 403 for a plan with no rulesets as no rulesets, and still judges the branch protection" {
    # A private repository on GitHub Free cannot have rulesets, and GitHub refuses the read.
    prepare_pr_checks
    fail_api "repos/${REPO}/rules/branches/main" \
        "gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)"
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    [ "${output}" = "build"$'\t'"pass"$'\t'"${COMPLETED_AT}"$'\t'"11"$'\n'"summary passed=1 failed=0 pending=0 head=${HEAD_SHA}" ]
    [ -z "${stderr}" ]

    write_check_runs "${HEAD_SHA}" "$(check_run build failure 11)"
    run_pr_checks --pr 42
    [ "${status}" -eq 3 ]

    # The same text with any other status is still a failed read.
    fail_api "repos/${REPO}/rules/branches/main" \
        "gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 404)"
    run_pr_checks --pr 42
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
}

@test "pr checks --branch judges the branch tip against that branch's required checks" {
    write_protection release/v2 build
    write_no_rulesets release/v2
    write_check_runs "${HEAD_SHA}" "$(check_run build success 11)"
    write_statuses "${HEAD_SHA}"
    run_pr_checks --branch release/v2
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"head=${HEAD_SHA}" ]]
    [ "$(gh_call_count "api repos/${REPO}/branches/release/v2 --jq")" -eq 1 ]
    [ "$(gh_call_count "/protection")" -eq 0 ]
    [ "$(gh_call_count "api repos/${REPO}/rules/branches/release/v2?per_page=100 ")" -eq 1 ]

    run_pr_checks --branch gone
    [ "${status}" -eq 1 ]
    [[ "${stderr}" == "cfwf: the --branch was not found in ${REPO}" ]]

    # The one read of the branch gives both its tip and its protection, so a failure of it names
    # the --branch.
    : > "${GH_LOG}"
    fail_api "repos/${REPO}/branches/release/v2"
    run_pr_checks --branch release/v2
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not read the --branch of ${REPO}: gh: Bad Gateway (HTTP 502)" ]
    [ "$(gh_call_count "branches/release/v2")" -eq 1 ]
}

@test "pr checks --branch judges a name as git does, even run from a repository where @{-1} names a branch" {
    local repo="${TEST_TMP}/checkout"
    git init -q -b main "${repo}"
    git -C "${repo}" -c user.name=test -c user.email=test@example.com -c commit.gpgsign=false \
        commit -q --allow-empty -m first
    git -C "${repo}" switch -q -c feature
    cd "${repo}"
    [ "$(git -C "${repo}" rev-parse --abbrev-ref '@{-1}')" = main ]
    local branch
    for branch in '@{-1}' HEAD -main main.lock a..b; do
        run_pr_checks --branch "${branch}"
        [ "${status}" -eq 2 ] || { echo "accepted: ${branch} (${status})" >&2; return 1; }
        [[ "${stderr%%$'\n'*}" == "cfwf: invalid value for --branch: "* ]]
        [ ! -s "${GH_LOG}" ]
    done
}

@test "pr checks percent-encodes a branch name git allows but an API path cannot hold as it is, rather than refusing it" {
    jq -n --arg sha "${HEAD_SHA}" '{number: 42, head: {sha: $sha}, base: {ref: "release/v2+lts"}}' | write_api "repos/${REPO}/pulls/42"
    write_protection "release/v2%2Blts" build
    write_rulesets "release/v2%2Blts" lint
    write_check_runs "${HEAD_SHA}" "$(check_run build success 11)" "$(check_run lint success 12)"
    write_statuses "${HEAD_SHA}"
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"passed=2 failed=0 pending=0"* ]]
    [ "$(gh_call_count "api repos/${REPO}/branches/release/v2%2Blts --jq ")" -eq 1 ]
    [ "$(gh_call_count "api repos/${REPO}/rules/branches/release/v2%2Blts?per_page=100 ")" -eq 1 ]

    # A non-ASCII letter is encoded byte by byte, and % itself is encoded, so it can never be read
    # as an escape.
    write_protection "feat/caf%C3%A9%40x%25y" build
    write_no_rulesets "feat/caf%C3%A9%40x%25y"
    run_pr_checks --branch "$(printf 'feat/caf\xc3\xa9@x%%y')"
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ "$(gh_call_count "api repos/${REPO}/branches/feat/caf%C3%A9%40x%25y --jq ")" -eq 1 ]

    # git allows @ alone as a branch name (only the whole ref @ is refused), so cfwf does too.
    write_protection "%40" build
    write_no_rulesets "%40"
    run_pr_checks --branch @
    [ "${status}" -eq 0 ]
    [ "$(gh_call_count "api repos/${REPO}/branches/%40 --jq ")" -eq 1 ]

    # A base branch GitHub returns that git itself would never allow is an unexpected answer.
    jq -n --arg sha "${HEAD_SHA}" '{number: 42, head: {sha: $sha}, base: {ref: "a..b"}}' | write_api "repos/${REPO}/pulls/42"
    run_pr_checks --pr 42
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: gh returned an unexpected branch whose required checks apply for ${REPO}" ]
}

@test "pr checks --pr reads the branch and the rulesets of a base branch with a slash at the same path, the slash kept as it is" {
    jq -n --arg sha "${HEAD_SHA}" '{number: 42, head: {sha: $sha}, base: {ref: "release/1.0"}}' | write_api "repos/${REPO}/pulls/42"
    write_protection release/1.0 build
    write_rulesets release/1.0 lint
    write_check_runs "${HEAD_SHA}" "$(check_run build success 11)" "$(check_run lint failure 12)"
    write_statuses "${HEAD_SHA}"
    run_pr_checks --pr 42
    [ "${status}" -eq 3 ]
    [[ "${output}" == *"lint"$'\t'"fail"$'\t'"${COMPLETED_AT}"$'\t'"12"* ]]
    [[ "${output}" == *"summary passed=1 failed=1 pending=0 head=${HEAD_SHA}" ]]
    [ "$(gh_call_count "api repos/${REPO}/branches/release/1.0 --jq ")" -eq 1 ]
    [ "$(gh_call_count "api repos/${REPO}/rules/branches/release/1.0?per_page=100 --paginate ")" -eq 1 ]
    [ "$(gh_call_count "%2F")" -eq 0 ]
}

@test "pr checks --sha judges that commit, given in any case, against the default branch's required checks" {
    jq -n '{default_branch: "trunk"}' | write_api "repos/${REPO}"
    write_protection trunk build
    write_no_rulesets trunk
    write_check_runs "${HEAD_SHA}" "$(check_run build success 11)"
    write_statuses "${HEAD_SHA}"
    run_pr_checks --sha "${HEAD_SHA^^}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"head=${HEAD_SHA}" ]]
    [ "$(gh_call_count "api repos/${REPO}/branches/trunk --jq ")" -eq 1 ]
    [ "$(gh_call_count "branches/main")" -eq 0 ]
    [ "$(gh_call_count "pulls/")" -eq 0 ]
}

@test "pr checks never counts a run on an older head" {
    prepare_pr_checks
    write_check_runs "${OLD_SHA}" "$(check_run build failure 9 completed "${OLD_SHA}")"
    write_check_runs "${HEAD_SHA}" "$(check_run build success 11)"
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    [[ "${output}" == "build"$'\t'"pass"$'\t'"${COMPLETED_AT}"$'\t'"11"$'\n'* ]]
    [ "$(gh_call_count "${OLD_SHA}")" -eq 0 ]
}

@test "pr checks keeps the newest run of each name, whatever the order GitHub lists them in" {
    prepare_pr_checks
    write_check_runs "${HEAD_SHA}" "$(check_run build success 21)" "$(check_run build failure 20)"
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    [[ "${output}" == *$'\t'"21"$'\n'* ]]

    write_check_runs "${HEAD_SHA}" "$(check_run build success 20)" "$(check_run build "" 21)"
    run_pr_checks --pr 42
    [ "${status}" -eq 4 ]
}

@test "pr checks judges the newest run of a name from each app across check suites, and fails a name when that of any app failed" {
    prepare_pr_checks
    # The PR was marked ready, which started a new check suite and, with cancel-in-progress, left the
    # draft's run cancelled in the old one: the newer success in the later suite clears it.
    write_check_runs "${HEAD_SHA}" "$(check_run build cancelled 100 "" "" 15368 7)" "$(check_run build success 101 "" "" 15368 8)"
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    [ "${output}" = "build"$'\t'"pass"$'\t'"${COMPLETED_AT}"$'\t'"101"$'\n'"summary passed=1 failed=0 pending=0 head=${HEAD_SHA}" ]

    # A newer success clears an older failure the same way, whatever order GitHub lists them in.
    write_check_runs "${HEAD_SHA}" "$(check_run build success 101 "" "" 15368 8)" "$(check_run build failure 100 "" "" 15368 7)"
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    [[ "${output}" == "build"$'\t'"pass"$'\t'"${COMPLETED_AT}"$'\t'"101"$'\n'* ]]

    # A newer failure in a later suite fails the name after an older success.
    write_check_runs "${HEAD_SHA}" "$(check_run build success 100 "" "" 15368 7)" "$(check_run build failure 101 "" "" 15368 8)"
    run_pr_checks --pr 42
    [ "${status}" -eq 3 ]
    [ "${output}" = "build"$'\t'"fail"$'\t'"${COMPLETED_AT}"$'\t'"101"$'\n'"summary passed=0 failed=1 pending=0 head=${HEAD_SHA}" ]

    # A newer run still going in a later suite keeps the name pending.
    write_check_runs "${HEAD_SHA}" "$(check_run build success 101 "" "" 15368 8)" "$(check_run build "" 102 "" "" 15368 9)"
    run_pr_checks --pr 42
    [ "${status}" -eq 4 ]
    [[ "${output}" == "build"$'\t'"pending"$'\t'$'\t'"102"$'\n'* ]]

    # A re-run adds its runs to the same suite, and the newest replaces the failure there too.
    write_check_runs "${HEAD_SHA}" "$(check_run build failure 100 "" "" 15368 7)" "$(check_run build success 103 "" "" 15368 7)"
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    [[ "${output}" == "build"$'\t'"pass"$'\t'"${COMPLETED_AT}"$'\t'"103"$'\n'* ]]

    # Two apps reporting build are each judged on their own newest run, so a failure from one still
    # fails the name after the other, newer, succeeds.
    write_check_runs "${HEAD_SHA}" "$(check_run build failure 100 "" "" 57789 9)" "$(check_run build success 101 "" "" 15368 8)"
    run_pr_checks --pr 42
    [ "${status}" -eq 3 ]
    [[ "${output}" == "build"$'\t'"fail"$'\t'"${COMPLETED_AT}"$'\t'"100"$'\n'* ]]
}

@test "pr checks never lets a skipped run replace a run of its name that ran, whatever their order" {
    prepare_pr_checks
    # A relabelled PR starts a new suite whose job skips itself: the older failure still fails it.
    write_check_runs "${HEAD_SHA}" "$(check_run build failure 100 "" "" 15368 7)" "$(check_run build skipped 101 "" "" 15368 8)"
    run_pr_checks --pr 42
    [ "${status}" -eq 3 ]
    [ "${output}" = "build"$'\t'"fail"$'\t'"${COMPLETED_AT}"$'\t'"100"$'\n'"summary passed=0 failed=1 pending=0 head=${HEAD_SHA}" ]

    # The same whatever order GitHub lists them in.
    write_check_runs "${HEAD_SHA}" "$(check_run build skipped 101 "" "" 15368 8)" "$(check_run build failure 100 "" "" 15368 7)"
    run_pr_checks --pr 42
    [ "${status}" -eq 3 ]
    [[ "${output}" == "build"$'\t'"fail"$'\t'"${COMPLETED_AT}"$'\t'"100"$'\n'* ]]

    # An older success with a newer skipped run passes on the success.
    write_check_runs "${HEAD_SHA}" "$(check_run build success 100 "" "" 15368 7)" "$(check_run build skipped 101 "" "" 15368 8)"
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    [ "${output}" = "build"$'\t'"pass"$'\t'"${COMPLETED_AT}"$'\t'"100"$'\n'"summary passed=1 failed=0 pending=0 head=${HEAD_SHA}" ]

    # Only skipped runs (a check skipped while the PR was a draft, with nothing newer) pass, on the newest.
    write_check_runs "${HEAD_SHA}" "$(check_run build skipped 100 "" "" 15368 7)" "$(check_run build skipped 101 "" "" 15368 8)"
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    [ "${output}" = "build"$'\t'"pass"$'\t'"${COMPLETED_AT}"$'\t'"101"$'\n'"summary passed=1 failed=0 pending=0 head=${HEAD_SHA}" ]

    # An older skipped run with a newer failure fails.
    write_check_runs "${HEAD_SHA}" "$(check_run build skipped 100 "" "" 15368 7)" "$(check_run build failure 101 "" "" 15368 8)"
    run_pr_checks --pr 42
    [ "${status}" -eq 3 ]
    [ "${output}" = "build"$'\t'"fail"$'\t'"${COMPLETED_AT}"$'\t'"101"$'\n'"summary passed=0 failed=1 pending=0 head=${HEAD_SHA}" ]

    # A run that has not finished replaces a skipped one, and still replaces an older failure.
    write_check_runs "${HEAD_SHA}" "$(check_run build skipped 100 "" "" 15368 7)" "$(check_run build "" 101 "" "" 15368 8)"
    run_pr_checks --pr 42
    [ "${status}" -eq 4 ]
    [[ "${output}" == "build"$'\t'"pending"$'\t'$'\t'"101"$'\n'* ]]

    write_check_runs "${HEAD_SHA}" "$(check_run build failure 100 "" "" 15368 7)" "$(check_run build "" 101 "" "" 15368 8)"
    run_pr_checks --pr 42
    [ "${status}" -eq 4 ]
    [[ "${output}" == "build"$'\t'"pending"$'\t'$'\t'"101"$'\n'* ]]

    # A run that decided is never replaced by a newer skipped run, whatever its conclusion.
    local conclusion
    for conclusion in timed_out action_required; do
        write_check_runs "${HEAD_SHA}" "$(check_run build skipped 101 "" "" 15368 8)" "$(check_run build "${conclusion}" 100 "" "" 15368 7)"
        run_pr_checks --pr 42
        [ "${status}" -eq 3 ] || { echo "${conclusion}: ${status}" >&2; return 1; }
        [[ "${output}" == "build"$'\t'"fail"$'\t'"${COMPLETED_AT}"$'\t'"100"$'\n'* ]]
    done
}

@test "pr checks lets a newer skipped run replace an older cancelled one, which was superseded, not decided, whatever their order" {
    prepare_pr_checks
    # cancel-in-progress cancels the older run when a relabelled PR starts a suite whose job skips
    # itself: GitHub passes the check on the skipped run, and so does pr checks.
    local expected="build"$'\t'"pass"$'\t'"${COMPLETED_AT}"$'\t'"101"$'\n'"summary passed=1 failed=0 pending=0 head=${HEAD_SHA}"
    write_check_runs "${HEAD_SHA}" "$(check_run build cancelled 100 "" "" 15368 7)" "$(check_run build skipped 101 "" "" 15368 8)"
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    [ "${output}" = "${expected}" ]

    write_check_runs "${HEAD_SHA}" "$(check_run build skipped 101 "" "" 15368 8)" "$(check_run build cancelled 100 "" "" 15368 7)"
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    [ "${output}" = "${expected}" ]

    # A failure that a newer run superseded stays superseded when that run was cancelled in turn,
    # in any listing order.
    write_check_runs "${HEAD_SHA}" "$(check_run build failure 99 "" "" 15368 6)" "$(check_run build skipped 101 "" "" 15368 8)" \
        "$(check_run build cancelled 100 "" "" 15368 7)"
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    [ "${output}" = "${expected}" ]

    write_check_runs "${HEAD_SHA}" "$(check_run build skipped 101 "" "" 15368 8)" "$(check_run build cancelled 100 "" "" 15368 7)" \
        "$(check_run build failure 99 "" "" 15368 6)"
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    [ "${output}" = "${expected}" ]

    # A cancelled run alone, or one newer than the skipped run, still fails.
    write_check_runs "${HEAD_SHA}" "$(check_run build cancelled 100 "" "" 15368 7)"
    run_pr_checks --pr 42
    [ "${status}" -eq 3 ]
    [ "${output}" = "build"$'\t'"fail"$'\t'"${COMPLETED_AT}"$'\t'"100"$'\n'"summary passed=0 failed=1 pending=0 head=${HEAD_SHA}" ]

    write_check_runs "${HEAD_SHA}" "$(check_run build cancelled 101 "" "" 15368 8)" "$(check_run build skipped 100 "" "" 15368 7)"
    run_pr_checks --pr 42
    [ "${status}" -eq 3 ]
    [[ "${output}" == "build"$'\t'"fail"$'\t'"${COMPLETED_AT}"$'\t'"101"$'\n'* ]]

    # A newer run that ran replaces a cancelled one, as any newer run does.
    write_check_runs "${HEAD_SHA}" "$(check_run build success 101 "" "" 15368 8)" "$(check_run build cancelled 100 "" "" 15368 7)"
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    [ "${output}" = "build"$'\t'"pass"$'\t'"${COMPLETED_AT}"$'\t'"101"$'\n'"summary passed=1 failed=0 pending=0 head=${HEAD_SHA}" ]
}

@test "pr checks judges commit statuses, and a check run and a status of the same name must both pass" {
    prepare_pr_checks
    write_protection main build ci/legacy ci/error ci/waiting
    write_statuses "${HEAD_SHA}" "$(commit_status build success 31)" "$(commit_status ci/legacy success 32)"
    run_pr_checks --pr 42
    [[ "${output}" == *"build"$'\t'"pass"$'\t'"${COMPLETED_AT}"$'\t'"31"* ]]
    [[ "${output}" == *"ci/legacy"$'\t'"pass"$'\t'"${COMPLETED_AT}"$'\t'"32"* ]]

    write_statuses "${HEAD_SHA}" "$(commit_status build failure 31)"
    run_pr_checks --pr 42
    [ "${status}" -eq 3 ]
    [[ "${output}" == *"build"$'\t'"fail"$'\t'"${COMPLETED_AT}"$'\t'"31"* ]]

    write_statuses "${HEAD_SHA}" "$(commit_status ci/legacy failure 32)" "$(commit_status ci/error error 33)" "$(commit_status ci/waiting pending 34)"
    run_pr_checks --pr 42
    [ "${status}" -eq 3 ]
    [[ "${output}" == *"ci/error"$'\t'"fail"$'\t'"${COMPLETED_AT}"$'\t'"33"* ]]
    [[ "${output}" == *"ci/legacy"$'\t'"fail"* ]]
    [[ "${output}" == *"ci/waiting"$'\t'"pending"$'\t'$'\t'"34"* ]]
    [[ "${output}" == *"summary passed=1 failed=2 pending=1"* ]]
}

@test "pr checks puts a check name with a tab or a newline on one line of the output" {
    prepare_pr_checks
    write_protection main
    write_check_runs "${HEAD_SHA}" "$(check_run $'odd\tname\nhere' success 11)"
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    [ "${output}" = "odd name here"$'\t'"pass"$'\t'"${COMPLETED_AT}"$'\t'"11"$'\n'"summary passed=1 failed=0 pending=0 head=${HEAD_SHA}" ]
}

@test "pr checks prints every C0, DEL and C1 control in a check name as a space, and keeps U+00A0, just past C1" {
    prepare_pr_checks
    write_protection main
    # ESC, U+009B (CSI, a one-character escape in C1), U+0085 (NEL) and DEL are controls; U+00A0,
    # just past C1, is not. gh's --jq (gojq) reads [[:cntrl:]] as ASCII only, so the range is
    # written out; this stub runs jq, so the test pins the range, not the engine.
    write_check_runs "${HEAD_SHA}" "$(check_run $'a\x1b[1mb\xc2\x9b31mc\xc2\x85d\x7fe\xc2\xa0f' success 11)"
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    [ "${output}" = "a [1mb 31mc d e"$'\xc2\xa0'"f"$'\t'"pass"$'\t'"${COMPLETED_AT}"$'\t'"11"$'\n'"summary passed=1 failed=0 pending=0 head=${HEAD_SHA}" ]
}

@test "pr checks keeps apart two names that differ only in a control character, though both print alike" {
    prepare_pr_checks
    write_protection main
    write_check_runs "${HEAD_SHA}" "$(check_run $'a\tb' failure 11)" "$(check_run "a b" success 12)"
    run_pr_checks --pr 42
    [ "${status}" -eq 3 ]
    [ "${output}" = "a b"$'\t'"fail"$'\t'"${COMPLETED_AT}"$'\t'"11"$'\n'"a b"$'\t'"pass"$'\t'"${COMPLETED_AT}"$'\t'"12"$'\n'"summary passed=1 failed=1 pending=0 head=${HEAD_SHA}" ]

    # A required name matches only the name it is, byte for byte.
    write_protection main "a b"
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    [ "${output}" = "a b"$'\t'"pass"$'\t'"${COMPLETED_AT}"$'\t'"12"$'\n'"summary passed=1 failed=0 pending=0 head=${HEAD_SHA}" ]
}

@test "pr checks judges a check really named like the app label of a name required twice apart from that name" {
    prepare_pr_checks
    write_branch main
    write_rulesets main foo#15368 foo#57789 "foo (app 15368)"
    write_check_runs "${HEAD_SHA}" "$(check_run foo success 11 "" "" 15368 5)" "$(check_run foo success 12 "" "" 57789 6)" \
        "$(check_run "foo (app 15368)" failure 13 "" "" 15368 5)"
    run_pr_checks --pr 42
    [ "${status}" -eq 3 ]
    [ "${output}" = "foo (app 15368)"$'\t'"fail"$'\t'"${COMPLETED_AT}"$'\t'"13"$'\n'"foo (app 15368)"$'\t'"pass"$'\t'"${COMPLETED_AT}"$'\t'"11"$'\n'"foo (app 57789)"$'\t'"pass"$'\t'"${COMPLETED_AT}"$'\t'"12"$'\n'"summary passed=2 failed=1 pending=0 head=${HEAD_SHA}" ]
}

@test "pr checks keeps a check named summary apart from the summary line, the only line with no tab" {
    prepare_pr_checks
    write_protection main summary
    write_check_runs "${HEAD_SHA}" "$(check_run summary success 11)"
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    [ "${output}" = "summary"$'\t'"pass"$'\t'"${COMPLETED_AT}"$'\t'"11"$'\n'"summary passed=1 failed=0 pending=0 head=${HEAD_SHA}" ]
    [ "$(grep -v $'\t' <<< "${output}")" = "summary passed=1 failed=0 pending=0 head=${HEAD_SHA}" ]
    [ "$(grep -c $'\t' <<< "${output}")" -eq 1 ]
}

@test "pr checks reports a transport failure as a runtime failure (exit 1), never as a failed check" {
    local endpoint
    for endpoint in "repos/${REPO}/pulls/42" \
        "repos/${REPO}/branches/main" \
        "repos/${REPO}/rules/branches/main" \
        "repos/${REPO}/commits/${HEAD_SHA}/check-runs" \
        "repos/${REPO}/commits/${HEAD_SHA}/status"; do
        rm -f "${GH_FIXTURES}"/api-*
        prepare_pr_checks
        write_check_runs "${HEAD_SHA}" "$(check_run build failure 11)"
        fail_api "${endpoint}"
        run_pr_checks --pr 42
        [ "${status}" -eq 1 ] || { echo "${endpoint}: ${status}" >&2; return 1; }
        [ -z "${output}" ]
        [[ "${stderr}" == "cfwf: could not read "*": gh: Bad Gateway (HTTP 502)" ]]
        [ "$(grep -c fail <<< "${stderr}")" -eq 0 ]
    done

    rm -f "${GH_FIXTURES}"/api-*
    prepare_pr_checks
    fail_api "repos/${REPO}/branches/main" "gh: Resource not accessible by integration (HTTP 403)"
    run_pr_checks --pr 42
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: could not read the branch protection of ${REPO}: gh: Resource not accessible by integration (HTTP 403)" ]
}

@test "pr checks needs no admin rights: the protection endpoint, which answers 403 without them, is never read" {
    prepare_pr_checks
    write_protection main build lint
    fail_api "repos/${REPO}/branches/main/protection/required_status_checks" "gh: Resource not accessible by integration (HTTP 403)"
    fail_api "repos/${REPO}/branches/main/protection" "gh: Resource not accessible by integration (HTTP 403)"
    run_pr_checks --pr 42
    [ "${status}" -eq 4 ]
    [[ "${output}" == *"lint"$'\t'"pending"$'\t'* ]]
    [ -z "${stderr}" ]
    [ "$(gh_call_count "/protection")" -eq 0 ]
}

@test "pr checks treats a missing PR, base branch or commit as a runtime failure (exit 1)" {
    run_pr_checks --pr 42
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: ${REPO}#42 was not found" ]

    prepare_pr_checks
    rm "$(api_fixture "repos/${REPO}/branches/main").json"
    write_rulesets main build
    run_pr_checks --pr 42
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: the branch whose required checks apply was not found in ${REPO}" ]

    # GitHub answers a --sha that is not in the repository with 422, not 404.
    rm -f "${GH_FIXTURES}"/api-*
    jq -n '{default_branch: "main"}' | write_api "repos/${REPO}"
    write_protection main build
    write_no_rulesets main
    fail_api "repos/${REPO}/commits/${HEAD_SHA}/check-runs" "gh: No commit found for SHA: ${HEAD_SHA} (HTTP 422)"
    run_pr_checks --sha "${HEAD_SHA}"
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: the commit ${HEAD_SHA} was not found in ${REPO}" ]

    # Any other 422 is a failed read, not a missing commit.
    fail_api "repos/${REPO}/commits/${HEAD_SHA}/check-runs" "gh: Validation Failed (HTTP 422)"
    run_pr_checks --sha "${HEAD_SHA}"
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not read the check runs of ${HEAD_SHA}: gh: Validation Failed (HTTP 422)" ]
}

# --- comment add ---------------------------------------------------------------

COMMENT_PR_URL="https://github.com/credfeto/credfeto-orchestrator/pull/1623#issuecomment-4242"
COMMENT_ISSUE_URL="https://github.com/credfeto/credfeto-orchestrator/issues/1585#issuecomment-4343"

prepare_comment() {
    printf 'A comment.\n\nWith a second paragraph.\n' > "${TEST_TMP}/comment.md"
    printf '%s\n' "${1-${COMMENT_PR_URL}}" > "${GH_FIXTURES}/comment.out"
}

run_comment_add() {
    run --separate-stderr "${SCRIPT}" comment add --repo "${REPO}" "$@"
}

@test "comment add posts on a PR with gh pr comment, stdin closed, and prints only the comment URL" {
    prepare_comment
    run_comment_add --pr 1623 --body-file "${TEST_TMP}/comment.md" <<< "stray stdin"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${COMMENT_PR_URL}" ]
    [ -z "${stderr}" ]
    issue_create_called_with "pr comment 1623 --repo ${REPO} --body-file BODY"
    [ "$(wc -l < "${GH_LOG}")" -eq 1 ]
    cmp "${TEST_TMP}/comment.md" "${GH_FIXTURES}/comment-body.txt"
    [ "$(cat "${GH_FIXTURES}/comment-stdin.txt")" = /dev/null ]
    [ "$(gh_call_count "--body-file ${TEST_TMP}/comment.md")" -eq 0 ]
}

@test "comment add posts on an issue with gh issue comment" {
    prepare_comment "${COMMENT_ISSUE_URL}"
    run_comment_add --issue 1585 --body-file "${TEST_TMP}/comment.md"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${COMMENT_ISSUE_URL}" ]
    issue_create_called_with "issue comment 1585 --repo ${REPO} --body-file BODY"
    [ "$(gh_call_count "pr comment")" -eq 0 ]
    cmp "${TEST_TMP}/comment.md" "${GH_FIXTURES}/comment-body.txt"
}

@test "comment add reads the body from stdin for --body-file -, and an empty stdin is refused without calling gh" {
    prepare_comment
    run_comment_add --pr 1623 --body-file - <<< "A comment from stdin"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${COMMENT_PR_URL}" ]
    [ "$(cat "${GH_FIXTURES}/comment-body.txt")" = "A comment from stdin" ]

    rm -f "${GH_LOG}"
    run_comment_add --pr 1623 --body-file - < /dev/null
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: the body is empty" ]
    [ ! -f "${GH_LOG}" ]
}

@test "comment add usage errors exit 2 with the usage on stderr and never call gh" {
    prepare_comment
    local body="${TEST_TMP}/comment.md"

    run_comment_add --body-file "${body}"
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == *"missing required option --pr or --issue"* ]]
    [[ "${stderr}" == *"Usage: cfwf comment add"* ]]

    run_comment_add --pr 1 --issue 2 --body-file "${body}"
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == *"--pr or --issue can only be given once, and not both"* ]]

    run_comment_add --pr 1 --pr 2 --body-file "${body}"
    [ "${status}" -eq 2 ]

    local number
    for number in abc 1a -1 "" "1 2"; do
        run_comment_add --pr "${number}" --body-file "${body}"
        [ "${status}" -eq 2 ]
        run_comment_add --issue "${number}" --body-file "${body}"
        [ "${status}" -eq 2 ]
    done
    [[ "${stderr}" == *"invalid value for --issue: it must be a number"* ]]

    run_comment_add --pr 1
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == *"missing required option --body-file"* ]]

    run_comment_add --pr 1 --body-file "${body}" --body-file "${body}"
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == *"--body-file can only be given once"* ]]

    run_comment_add --pr 1 --body-file
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == *"--body-file needs a value"* ]]

    run --separate-stderr "${SCRIPT}" comment add --pr 1 --body-file "${body}"
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == *"missing required option --repo"* ]]

    local flag
    for flag in --body --edit-last --json --jq --title --status; do
        run_comment_add --pr 1 --body-file "${body}" "${flag}" value
        [ "${status}" -eq 2 ]
        [ "${stderr%%$'\n'*}" = "cfwf: unknown option (argument 9; its value is not shown)" ]
    done

    run_comment_add --pr 1 --edit-last --body-file "${body}"
    [ "${status}" -eq 2 ]
    [ ! -f "${GH_LOG}" ]
}

@test "comment add refuses a missing, unreadable, empty or blank body as a runtime failure, without calling gh" {
    run_comment_add --pr 1 --body-file "${TEST_TMP}/nope.md"
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: cannot read the --body-file" ]

    run_comment_add --pr 1 --body-file "${TEST_TMP}"
    [ "${status}" -eq 1 ]

    : > "${TEST_TMP}/empty.md"
    run_comment_add --pr 1 --body-file "${TEST_TMP}/empty.md"
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: the body is empty" ]

    printf ' \n\t\n' > "${TEST_TMP}/blank.md"
    run_comment_add --issue 1 --body-file "${TEST_TMP}/blank.md"
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: the body is empty" ]
    [ ! -f "${GH_LOG}" ]
}

@test "comment add refuses a leaking body with exit 8, naming the rule only, and posts nothing" {
    prepare_comment
    local secret="gh""p_LEAKMARKER0123456789"
    write_leak_body "the value is ${secret} here"
    run_comment_add --pr 1623 --body-file "${TEST_TMP}/leak.md"
    assert_refused "${status}" "${output}" "${stderr}" token "${secret}"

    write_leak_body "see /home/someone/notes"
    run_comment_add --issue 1585 --body-file "${TEST_TMP}/leak.md"
    assert_refused "${status}" "${output}" "${stderr}" "host path" "/home/someone"
    [ ! -f "${GH_LOG}" ]
}

@test "comment add refuses a body naming a private repository on a public target, before posting" {
    prepare_comment
    write_visibility "${REPO}" PUBLIC
    write_visibility credfeto/secret-thing PRIVATE
    write_leak_body "see credfeto/secret-thing#3"
    run_comment_add --pr 1623 --body-file "${TEST_TMP}/leak.md"
    assert_refused "${status}" "${output}" "${stderr}" "private repository" "secret-thing"
    [ "$(gh_call_count "comment")" -eq 0 ]
}

@test "comment add refuses a plan-approval keyword outside a quote with exit 8, in any case, naming only the line" {
    prepare_comment
    local line
    for line in "Approved" "lgtm" "LGTM, ship it" "This is APPROVED." "  approved" "the plan is (approved)" "x - Lgtm" "- > approved" "_Approved_" "__LGTM__" "so _lgtm_." "    > approved" $'\t> lgtm'; do
        write_leak_body "${line}"
        run_comment_add --pr 1623 --body-file "${TEST_TMP}/leak.md"
        assert_refused "${status}" "${output}" "${stderr}" "approval keyword" "${line}"
    done
    [ ! -f "${GH_LOG}" ]
}

@test "comment add posts a plan-approval keyword inside a Markdown quote, and a longer word holding the letters" {
    prepare_comment
    local line
    for line in "> approved" ">LGTM" "   > The human said: Approved" "> > lgtm" "disapproved" "unapproved_change" "lgtm2" "approvedness" "plan_approved" "approved_change" "x_lgtm_y"; do
        write_leak_body "${line}"
        rm -f "${GH_LOG}"
        run_comment_add --pr 1623 --body-file "${TEST_TMP}/leak.md"
        [ "${status}" -eq 0 ]
        [ "${output}" = "${COMMENT_PR_URL}" ]
        cmp "${TEST_TMP}/leak.md" "${GH_FIXTURES}/comment-body.txt"
    done
}

@test "comment add runs the leak check before the keyword rule" {
    prepare_comment
    printf 'lgtm\n/tmp/x\n' > "${TEST_TMP}/both.md"
    run_comment_add --pr 1623 --body-file "${TEST_TMP}/both.md"
    [ "${status}" -eq 8 ]
    [ "${stderr}" = "cfwf: body refused: host path (line 2)" ]
}

@test "body check does not apply the plan-approval keyword rule" {
    write_leak_body "approved"
    run_body_check
    [ "${status}" -eq 0 ]
}

@test "comment add accepts a comment URL from another host, and a pull URL for an issue number" {
    prepare_comment "https://proxy.example.com:8443/credfeto/renamed/pull/1585#issuecomment-1"
    run_comment_add --issue 1585 --body-file "${TEST_TMP}/comment.md"
    [ "${status}" -eq 0 ]
    [ "${output}" = "https://proxy.example.com:8443/credfeto/renamed/pull/1585#issuecomment-1" ]

    printf 'gh says something first\n%s\n' "${COMMENT_PR_URL}" > "${GH_FIXTURES}/comment.out"
    run_comment_add --pr 1623 --body-file "${TEST_TMP}/comment.md"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${COMMENT_PR_URL}" ]
}

@test "comment add posts on a number given with leading zeros as that number, without them" {
    prepare_comment
    run_comment_add --pr 01623 --body-file "${TEST_TMP}/comment.md"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${COMMENT_PR_URL}" ]
    issue_create_called_with "pr comment 1623 --repo ${REPO} --body-file BODY"

    rm -f "${GH_LOG}"
    prepare_comment "https://github.com/credfeto/credfeto-orchestrator/issues/0#issuecomment-1"
    run_comment_add --issue 000 --body-file "${TEST_TMP}/comment.md"
    [ "${status}" -eq 0 ]
    issue_create_called_with "issue comment 0 --repo ${REPO} --body-file BODY"
}

@test "comment add exits 1, printing nothing on stdout, when the result is not the comment URL of the target" {
    local url
    for url in "" "https://github.com/credfeto/credfeto-orchestrator/pull/1623" \
        "https://github.com/credfeto/credfeto-orchestrator/pull/1624#issuecomment-1" \
        "http://github.com/credfeto/credfeto-orchestrator/pull/1623#issuecomment-1" \
        "https://github.com/credfeto/credfeto-orchestrator/pull/1623#issuecomment-" \
        "https://github.com/credfeto/credfeto-orchestrator/commit/1623#issuecomment-1" \
        "https://github.com/credfeto/credfeto-orchestrator/pull/1623#issuecomment-1 trailing"; do
        prepare_comment "${url}"
        run_comment_add --pr 1623 --body-file "${TEST_TMP}/comment.md"
        [ "${status}" -eq 1 ]
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: gh returned an unexpected result for the comment, which may have been posted on ${REPO}#1623" ]
    done
}

@test "comment add exits 1 when gh cannot post the comment" {
    prepare_comment
    touch "${GH_FIXTURES}/comment.fail"
    run_comment_add --issue 1585 --body-file "${TEST_TMP}/comment.md"
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == *"cfwf: could not post the comment on ${REPO}#1585"* ]]
}

@test "comment help, -h and a missing or unknown subcommand, none of which call gh" {
    local args
    for args in "help comment add" "help comment" "comment add -h" "comment add --help" "comment -h" "comment --help"; do
        # shellcheck disable=SC2086  # each entry is a list of words
        run --separate-stderr "${SCRIPT}" ${args}
        [ "${status}" -eq 0 ]
        [[ "${output}" == "Usage: cfwf comment add"* ]]
        [[ "${output}" == *"two plan-approval keywords"* ]]
        [[ "${output}" == *'with "(line <n>)" where there is one'* ]]
    done

    run --separate-stderr "${SCRIPT}" comment
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == *"comment needs a subcommand (add)"* ]]

    run --separate-stderr "${SCRIPT}" comment edit
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == *"unknown comment subcommand (argument 2; its value is not shown)"* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "comment add leaves no temporary file behind, for a stdin body, a refusal and a run that succeeds" {
    prepare_comment
    local scratch="${TEST_TMP}/tmp"
    mkdir -p "${scratch}"

    TMPDIR="${scratch}" run_comment_add --pr 1623 --body-file - <<< "from stdin"
    [ "${status}" -eq 0 ]
    [ -z "$(ls -A "${scratch}")" ]

    TMPDIR="${scratch}" run_comment_add --pr 1623 --body-file - <<< "lgtm"
    [ "${status}" -eq 8 ]
    [ -z "$(ls -A "${scratch}")" ]

    touch "${GH_FIXTURES}/comment.fail"
    TMPDIR="${scratch}" run_comment_add --pr 1623 --body-file "${TEST_TMP}/comment.md"
    [ "${status}" -eq 1 ]
    [ -z "$(ls -A "${scratch}")" ]
}
