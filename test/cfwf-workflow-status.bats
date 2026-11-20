#!/usr/bin/env bats
# shellcheck disable=SC2154  # stderr is set by run --separate-stderr

bats_require_minimum_version 1.5.0

load test_helper
load cfwf_helper

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

@test "--check treats GitHub's no-such-pull-request answer as not on the board, without a fallback or a warning" {
    use_fallback "GraphQL: Could not resolve to a PullRequest with the number of 1481."
    run "${SCRIPT}" workflow-status --check --repo "${REPO}" --pr 1481
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

@test "closing-issue-labels leaves out Blocked and On Hold in any case, On Hold spelt with a space or a hyphen" {
    write_pr_view "${REPO} 10" "other-org/other-repo 11"
    jq -n '{labels: [{name: "blocked"}, {name: "On Hold"}, {name: "Medium"}]}' > "${GH_FIXTURES}/issue-view-10.json"
    jq -n '{labels: [{name: "BLOCKED"}, {name: "on hold"}, {name: "ON-HOLD"}]}' > "${GH_FIXTURES}/issue-view-11.json"

    run "${SCRIPT}" closing-issue-labels --repo credfeto/credfeto-orchestrator --pr 1481
    [ "${status}" -eq 0 ]
    [ "${output}" = "Medium" ]
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
