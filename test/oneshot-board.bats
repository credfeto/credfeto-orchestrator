#!/usr/bin/env bats
# shellcheck disable=SC2329  # functions in @test bodies are invoked indirectly via 'run'
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are used inside run() subshells where shellcheck cannot trace them

bats_require_minimum_version 1.5.0

load test_helper
load oneshot_helper

# --- fetch_board_approved_items unit tests ------------------------------------

@test "fetch_board_approved_items is a no-op when _WF_PROJECT_ID is empty" {
    _WF_PROJECT_ID=""
    make_stub gh 'printf "called\n"; exit 0'
    local call_count_file="${TEST_TMP}/gh_calls"
    make_stub gh "printf 'called\n' >> ${call_count_file}; exit 0"
    fetch_board_approved_items
    local count
    count=$(wc -l < "${call_count_file}" 2>/dev/null || printf '0\n')
    [ "${count}" -eq 0 ]
}

@test "fetch_board_approved_items populates _WF_APPROVED_ITEMS for Approved board items" {
    _WF_PROJECT_ID="PVT_test"
    _WF_OPTION_IDS[Approved]="opt_approved"
    local items_json='{"data":{"node":{"items":{"nodes":[{"content":{"number":42,"repository":{"nameWithOwner":"owner/repo"}},"fieldValues":{"nodes":[{"optionId":"opt_approved"}]}},{"content":{"number":99,"repository":{"nameWithOwner":"owner/repo"}},"fieldValues":{"nodes":[{"optionId":"opt_other"}]}}]}}}}'
    make_stub gh "printf '%s\n' '${items_json}'"
    fetch_board_approved_items
    [ "${_WF_APPROVED_ITEMS["owner/repo/42"]:-}" = "1" ]
    [ "${_WF_APPROVED_ITEMS["owner/repo/99"]:-}" != "1" ]
}

@test "fetch_board_approved_items caches per repo and does not re-call gh on second call" {
    _WF_PROJECT_ID="PVT_test"
    _WF_OPTION_IDS[Approved]="opt_approved"
    local call_count_file="${TEST_TMP}/gh_calls"
    local items_json='{"data":{"node":{"items":{"nodes":[]}}}}'
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
printf 'called\n' >> "${call_count_file}"
printf '%s\n' '${items_json}'
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    fetch_board_approved_items
    fetch_board_approved_items
    local count
    count=$(wc -l < "${call_count_file}" 2>/dev/null || printf '0\n')
    [ "${count}" -eq 1 ]
}

@test "fetch_board_approved_items handles gh failure gracefully and leaves items empty" {
    _WF_PROJECT_ID="PVT_test"
    _WF_OPTION_IDS[Approved]="opt_approved"
    make_stub gh 'exit 1'
    fetch_board_approved_items
    [ -z "${_WF_APPROVED_ITEMS[*]:-}" ]
}

@test "fetch_board_approved_items paginates and finds item on second page" {
    _WF_PROJECT_ID="PVT_test"
    _WF_OPTION_IDS[Approved]="opt_approved"
    local call_count_file="${TEST_TMP}/gh_calls"
    local page1='{"data":{"node":{"items":{"pageInfo":{"endCursor":"cursor_page2","hasNextPage":true},"nodes":[{"content":{"number":1,"repository":{"nameWithOwner":"owner/repo"}},"fieldValues":{"nodes":[{"optionId":"opt_approved"}]}}]}}}}'
    local page2='{"data":{"node":{"items":{"pageInfo":{"endCursor":null,"hasNextPage":false},"nodes":[{"content":{"number":2,"repository":{"nameWithOwner":"owner/repo"}},"fieldValues":{"nodes":[{"optionId":"opt_approved"}]}}]}}}}'
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
count=\$(wc -l < "${call_count_file}" 2>/dev/null || printf '0\n')
printf 'call\n' >> "${call_count_file}"
if [ "\${count}" -eq 0 ]; then
    printf '%s\n' '${page1}'
else
    printf '%s\n' '${page2}'
fi
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    fetch_board_approved_items
    [ "${_WF_APPROVED_ITEMS["owner/repo/1"]:-}" = "1" ]
    [ "${_WF_APPROVED_ITEMS["owner/repo/2"]:-}" = "1" ]
}

@test "fetch_board_approved_items forwards cursor to second-page request" {
    _WF_PROJECT_ID="PVT_test"
    _WF_OPTION_IDS[Approved]="opt_approved"
    local call_count_file="${TEST_TMP}/gh_calls"
    local args_file="${TEST_TMP}/gh_args"
    local page1='{"data":{"node":{"items":{"pageInfo":{"endCursor":"cursor_page2","hasNextPage":true},"nodes":[{"content":{"number":1,"repository":{"nameWithOwner":"owner/repo"}},"fieldValues":{"nodes":[{"optionId":"opt_approved"}]}}]}}}}'
    local page2='{"data":{"node":{"items":{"pageInfo":{"endCursor":null,"hasNextPage":false},"nodes":[]}}}}'
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
count=\$(wc -l < "${call_count_file}" 2>/dev/null || printf '0\n')
printf 'call\n' >> "${call_count_file}"
printf '%s\n' "\$*" >> "${args_file}"
if [ "\${count}" -eq 0 ]; then
    printf '%s\n' '${page1}'
else
    printf '%s\n' '${page2}'
fi
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    fetch_board_approved_items
    grep -q 'cursor=cursor_page2' "${args_file}"
}

@test "fetch_board_approved_items uses fieldValues(first:50) in the GraphQL query" {
    _WF_PROJECT_ID="PVT_test"
    _WF_OPTION_IDS[Approved]="opt_approved"
    local args_file="${TEST_TMP}/gh_args"
    local items_json='{"data":{"node":{"items":{"pageInfo":{"endCursor":null,"hasNextPage":false},"nodes":[]}}}}'
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${args_file}"
printf '%s\n' '${items_json}'
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    fetch_board_approved_items
    grep -q 'fieldValues(first:50)' "${args_file}"
}

@test "fetch_board_approved_items matches approved item when optionId is beyond tenth fieldValue" {
    _WF_PROJECT_ID="PVT_test"
    _WF_OPTION_IDS[Approved]="opt_approved"
    local fv
    fv='[{"optionId":"x"},{"optionId":"x"},{"optionId":"x"},{"optionId":"x"},{"optionId":"x"},{"optionId":"x"},{"optionId":"x"},{"optionId":"x"},{"optionId":"x"},{"optionId":"x"},{"optionId":"x"},{"optionId":"x"},{"optionId":"x"},{"optionId":"x"},{"optionId":"opt_approved"}]'
    local items_json
    items_json='{"data":{"node":{"items":{"pageInfo":{"endCursor":null,"hasNextPage":false},"nodes":[{"content":{"number":5,"repository":{"nameWithOwner":"owner/repo"}},"fieldValues":{"nodes":'"${fv}"'}}]}}}}'
    make_stub gh "printf '%s\n' '${items_json}'"
    fetch_board_approved_items
    [ "${_WF_APPROVED_ITEMS["owner/repo/5"]:-}" = "1" ]
}

@test "fetch_board_approved_items skips re-fetch for already-fetched repo while still fetching a new repo" {
    _WF_PROJECT_ID="PVT_test"
    _WF_OPTION_IDS[Approved]="opt_approved"
    local call_count_file="${TEST_TMP}/gh_calls"
    local items_a='{"data":{"node":{"items":{"pageInfo":{"endCursor":null,"hasNextPage":false},"nodes":[{"content":{"number":1,"repository":{"nameWithOwner":"owner/repo-a"}},"fieldValues":{"nodes":[{"optionId":"opt_approved"}]}}]}}}}'
    local items_b='{"data":{"node":{"items":{"pageInfo":{"endCursor":null,"hasNextPage":false},"nodes":[{"content":{"number":2,"repository":{"nameWithOwner":"owner/repo-b"}},"fieldValues":{"nodes":[{"optionId":"opt_approved"}]}}]}}}}'
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
count=\$(wc -l < "${call_count_file}" 2>/dev/null || printf '0\n')
printf 'call\n' >> "${call_count_file}"
if [ "\${count}" -eq 0 ]; then
    printf '%s\n' '${items_a}'
else
    printf '%s\n' '${items_b}'
fi
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    REPO_FULL="owner/repo-a"
    fetch_board_approved_items
    fetch_board_approved_items
    REPO_FULL="owner/repo-b"
    fetch_board_approved_items
    local count
    count=$(wc -l < "${call_count_file}" 2>/dev/null || printf '0\n')
    [ "${count}" -eq 2 ]
    [ "${_WF_APPROVED_ITEMS["owner/repo-a/1"]:-}" = "1" ]
    [ "${_WF_APPROVED_ITEMS["owner/repo-b/2"]:-}" = "1" ]
}

# --- fetch_board_item_statuses / board_substatus_for_item (#1136) --------------

@test "fetch_board_item_statuses is a no-op when _WF_PROJECT_ID is empty" {
    _WF_PROJECT_ID=""
    local call_count_file="${TEST_TMP}/gh_calls"
    make_stub gh "printf 'called\n' >> ${call_count_file}; exit 0"
    fetch_board_item_statuses
    local count
    count=$(wc -l < "${call_count_file}" 2>/dev/null || printf '0\n')
    [ "${count}" -eq 0 ]
}

@test "fetch_board_item_statuses populates option IDs for both Issues and PRs" {
    _WF_PROJECT_ID="PVT_test"
    local items_json='{"data":{"node":{"items":{"nodes":[
        {"content":{"number":42,"repository":{"nameWithOwner":"owner/repo"}},"fieldValues":{"nodes":[{"optionId":"opt_dev","field":{"name":"Status"}}]}},
        {"content":{"number":7,"repository":{"nameWithOwner":"owner/repo"}},"fieldValues":{"nodes":[{"optionId":"opt_review","field":{"name":"Status"}}]}}
    ]}}}}'
    make_stub gh "printf '%s\n' '${items_json}'"
    fetch_board_item_statuses
    [ "${_WF_ITEM_STATUS_OPTION_ID["owner/repo/42"]:-}" = "opt_dev" ]
    [ "${_WF_ITEM_STATUS_OPTION_ID["owner/repo/7"]:-}" = "opt_review" ]
}

@test "fetch_board_item_statuses ignores fieldValues for a field other than Status, including the old Workflow Status (#1519)" {
    _WF_PROJECT_ID="PVT_test"
    local items_json='{"data":{"node":{"items":{"nodes":[
        {"content":{"number":42,"repository":{"nameWithOwner":"owner/repo"}},"fieldValues":{"nodes":[{"optionId":"opt_other","field":{"name":"Some Other Field"}},{"optionId":"opt_legacy","field":{"name":"Workflow Status"}}]}}
    ]}}}}'
    make_stub gh "printf '%s\n' '${items_json}'"
    fetch_board_item_statuses
    [ -z "${_WF_ITEM_STATUS_OPTION_ID["owner/repo/42"]:-}" ]
}

@test "fetch_board_item_statuses caches per repo and does not re-call gh on second call" {
    _WF_PROJECT_ID="PVT_test"
    local call_count_file="${TEST_TMP}/gh_calls"
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
printf 'called\n' >> "${call_count_file}"
printf '%s\n' '{"data":{"node":{"items":{"nodes":[]}}}}'
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    fetch_board_item_statuses
    fetch_board_item_statuses
    local count
    count=$(wc -l < "${call_count_file}" 2>/dev/null || printf '0\n')
    [ "${count}" -eq 1 ]
}

@test "workflow_status_name_for_option_id returns the matching status name" {
    _WF_OPTION_IDS[Development]="opt_dev"
    _WF_OPTION_IDS["Human Review"]="opt_review"
    run workflow_status_name_for_option_id "opt_dev"
    [ "${output}" = "Development" ]
}

@test "workflow_status_name_for_option_id returns empty for an unrecognised option ID" {
    _WF_OPTION_IDS[Development]="opt_dev"
    run workflow_status_name_for_option_id "opt_nonexistent"
    [ -z "${output}" ]
}

@test "workflow_status_name_for_option_id returns empty for an empty option ID" {
    run workflow_status_name_for_option_id ""
    [ -z "${output}" ]
}

@test "board_substatus_for_item returns Unknown when the board is not configured" {
    _WF_PROJECT_ID=""
    discover_or_create_workflow_project() { return 0; }
    run board_substatus_for_item 42
    [ "${output}" = "Unknown" ]
}

@test "board_substatus_for_item calls discover_or_create_workflow_project first (#1136 review)" {
    # Most notify_discord_blocked_item call sites fire before the per-item work block's own
    # discovery call ever runs — board_substatus_for_item must trigger discovery itself so it
    # doesn't always report Unknown for those.
    _WF_PROJECT_ID=""
    local call_log="${TEST_TMP}/discover_calls"
    discover_or_create_workflow_project() { printf 'called\n' >> "${call_log}"; }
    board_substatus_for_item 42
    [ -f "${call_log}" ]
}

@test "board_substatus_for_item returns the resolved status name for a known item" {
    set_repo_context "org/repo"
    # Simulates discovery having already resolved this repo's project — the fast-path guard
    # in discover_or_create_workflow_project (_WF_CACHED_REPO == REPO_FULL) makes it a no-op
    # so it does not overwrite the project ID set up below via a real (unstubbed) discovery.
    _WF_CACHED_REPO="org/repo"
    _WF_PROJECT_ID="PVT_test"
    _WF_OPTION_IDS[Development]="opt_dev"
    local items_json='{"data":{"node":{"items":{"nodes":[
        {"content":{"number":42,"repository":{"nameWithOwner":"org/repo"}},"fieldValues":{"nodes":[{"optionId":"opt_dev","field":{"name":"Status"}}]}}
    ]}}}}'
    make_stub gh "printf '%s\n' '${items_json}'"
    run board_substatus_for_item 42
    [ "${output}" = "Development" ]
}

@test "board_substatus_for_item returns Unknown for an item not yet on the board" {
    set_repo_context "org/repo"
    _WF_CACHED_REPO="org/repo"
    _WF_PROJECT_ID="PVT_test"
    make_stub gh 'printf "%s\n" "{\"data\":{\"node\":{\"items\":{\"nodes\":[]}}}}"'
    run board_substatus_for_item 999
    [ "${output}" = "Unknown" ]
}

@test "board_substatus_for_item re-resolves the project when REPO_FULL changes across repos (#1136 review)" {
    # Regression coverage for the multi-repo staleness bug: a stale _WF_PROJECT_ID left over
    # from a previously processed repo must not silently poison this repo's lookup.
    set_repo_context "repo-a/repo-a"
    _WF_CACHED_REPO="repo-a/repo-a"
    _WF_PROJECT_ID="PVT_stale_from_repo_a"
    discover_or_create_workflow_project() {
        _WF_PROJECT_ID="PVT_repo_b"
        _WF_CACHED_REPO="${REPO_FULL}"
    }
    local items_json='{"data":{"node":{"items":{"nodes":[
        {"content":{"number":7,"repository":{"nameWithOwner":"repo-b/repo-b"}},"fieldValues":{"nodes":[{"optionId":"opt_review","field":{"name":"Status"}}]}}
    ]}}}}'
    make_stub gh "printf '%s\n' '${items_json}'"
    set_repo_context "repo-b/repo-b"
    _WF_OPTION_IDS["Human Review"]="opt_review"
    run board_substatus_for_item 7
    [ "${output}" = "Human Review" ]
}

# --- pr_review_pipeline_finished_without_auto_merge (#1479) -----------------

@test "pr_review_pipeline_finished_without_auto_merge is false when autoMergeRequest is already set" {
    # Short-circuits on the pr_json check alone - board_substatus_for_item must never be called
    # when auto-merge IS supported and armed, so a stub that would die/fail if called proves this.
    board_substatus_for_item() { die "must not be called when autoMergeRequest is set"; }
    run pr_review_pipeline_finished_without_auto_merge '{"autoMergeRequest":{"enabledAt":"now"}}' 42
    [ "${status}" -ne 0 ]
}

@test "pr_review_pipeline_finished_without_auto_merge is true when autoMergeRequest is null and the board says Human Review" {
    board_substatus_for_item() { printf 'Human Review\n'; }
    run pr_review_pipeline_finished_without_auto_merge '{"autoMergeRequest":null}' 42
    [ "${status}" -eq 0 ]
}

@test "pr_review_pipeline_finished_without_auto_merge is false when autoMergeRequest is null but the board says something else" {
    board_substatus_for_item() { printf 'Development\n'; }
    run pr_review_pipeline_finished_without_auto_merge '{"autoMergeRequest":null}' 42
    [ "${status}" -ne 0 ]
}

@test "pr_review_pipeline_finished_without_auto_merge is false when autoMergeRequest is null and the board is not configured" {
    board_substatus_for_item() { printf 'Unknown\n'; }
    run pr_review_pipeline_finished_without_auto_merge '{"autoMergeRequest":null}' 42
    [ "${status}" -ne 0 ]
}

@test "pr_review_pipeline_finished_without_auto_merge is false when autoMergeRequest is absent entirely" {
    board_substatus_for_item() { printf 'Human Review\n'; }
    run pr_review_pipeline_finished_without_auto_merge '{}' 42
    [ "${status}" -eq 0 ]
}

@test "pr_review_pipeline_finished_without_auto_merge passes the item id through to board_substatus_for_item" {
    local call_log="${TEST_TMP}/board_substatus_calls"
    board_substatus_for_item() { printf '%s\n' "$1" >> "${call_log}"; printf 'Human Review\n'; }
    run pr_review_pipeline_finished_without_auto_merge '{"autoMergeRequest":null}' 1479
    [ "${status}" -eq 0 ]
    grep -qx '1479' "${call_log}"
}

# --- fetch_single_item_workflow_status (#1474) ------------------------------

@test "fetch_single_item_workflow_status returns Unknown when the board is not configured" {
    _WF_PROJECT_ID=""
    discover_or_create_workflow_project() { return 0; }
    run fetch_single_item_workflow_status "PullRequest" 42
    [ "${output}" = "Unknown" ]
}

@test "fetch_single_item_workflow_status resolves the status name for a single PR via node-id then item-id" {
    # Each gh invocation here uses its own --jq filter (matching real gh's behaviour), so the
    # stub must return the already-extracted value directly, not the wrapping JSON envelope —
    # unlike update_workflow_status's own gh stubs elsewhere, which only assert the call
    # happened and never check the extracted value downstream.
    set_repo_context "org/repo"
    discover_or_create_workflow_project() { _WF_PROJECT_ID="PVT_test"; }
    _WF_OPTION_IDS[Development]="opt_dev"
    make_stub gh 'case "$*" in
        *"pulls/42"*) printf "PR_node_42\n" ;;
        *"addProjectV2ItemById"*) printf "item_42\n" ;;
        *"fieldValueByName"*) printf "opt_dev\n" ;;
        *) exit 1 ;;
    esac'
    run fetch_single_item_workflow_status "PullRequest" 42
    [ "${output}" = "Development" ]
}

@test "fetch_single_item_workflow_status uses the issues API path for an Issue" {
    set_repo_context "org/repo"
    discover_or_create_workflow_project() { _WF_PROJECT_ID="PVT_test"; }
    _WF_OPTION_IDS[Development]="opt_dev"
    local call_log="${TEST_TMP}/gh_calls"
    make_stub gh 'printf "%s\n" "$*" >> "'"${call_log}"'"
        case "$*" in
        *"issues/42"*) printf "Issue_node_42\n" ;;
        *"addProjectV2ItemById"*) printf "item_42\n" ;;
        *"fieldValueByName"*) printf "opt_dev\n" ;;
        *) exit 1 ;;
        esac'
    run fetch_single_item_workflow_status "Issue" 42
    [ "${output}" = "Development" ]
    grep -q "issues/42" "${call_log}"
}

@test "fetch_single_item_workflow_status returns Unknown when the node ID lookup fails" {
    set_repo_context "org/repo"
    discover_or_create_workflow_project() { _WF_PROJECT_ID="PVT_test"; }
    make_stub gh 'exit 1'
    run fetch_single_item_workflow_status "PullRequest" 42
    [ "${output}" = "Unknown" ]
}

@test "fetch_single_item_workflow_status returns Unknown for an item not on the board" {
    set_repo_context "org/repo"
    discover_or_create_workflow_project() { _WF_PROJECT_ID="PVT_test"; }
    make_stub gh 'case "$*" in
        *"pulls/42"*) printf "PR_node_42\n" ;;
        *"addProjectV2ItemById"*) printf "item_42\n" ;;
        *"fieldValueByName"*) printf "\n" ;;
        *) exit 1 ;;
    esac'
    run fetch_single_item_workflow_status "PullRequest" 42
    [ "${output}" = "Unknown" ]
}

# --- _wf_status_ordinal (#1276) ---------------------------------------------

@test "_wf_status_ordinal returns the index of a known status name" {
    run _wf_status_ordinal "Not Started"
    [ "${output}" = "0" ]
    run _wf_status_ordinal "Development"
    [ "${output}" = "3" ]
    run _wf_status_ordinal "Complete"
    [ "${output}" = "9" ]
}

@test "_wf_status_ordinal returns empty for an unrecognised or blank status name" {
    run _wf_status_ordinal "Bogus"
    [ -z "${output}" ]
    run _wf_status_ordinal ""
    [ -z "${output}" ]
}

# --- issue_plan_approved_or_later (#1321) -------------------------------------

@test "issue_plan_approved_or_later returns true for a card exactly on Approved" {
    board_substatus_for_item() { printf 'Approved'; }
    run issue_plan_approved_or_later 42
    [ "${output}" = "true" ]
}

@test "issue_plan_approved_or_later returns true for a card that has progressed past Approved" {
    # Derived from the canonical column order (_WF_STATUS_ORDER, lib/globals) rather than a
    # hardcoded list, so this stays correct if a column is ever renamed/added/removed.
    local approved_idx status
    approved_idx=$(_wf_status_ordinal "Approved")
    for status in "${_WF_STATUS_ORDER[@]:$((approved_idx + 1))}"; do
        # shellcheck disable=SC2317 # invoked indirectly via issue_plan_approved_or_later
        board_substatus_for_item() { printf '%s' "${status}"; }
        run issue_plan_approved_or_later 42
        [ "${output}" = "true" ]
    done
}

@test "issue_plan_approved_or_later returns false for a card that has not reached Approved yet" {
    board_substatus_for_item() { printf 'Planning'; }
    run issue_plan_approved_or_later 42
    [ "${output}" = "false" ]

    board_substatus_for_item() { printf 'Not Started'; }
    run issue_plan_approved_or_later 42
    [ "${output}" = "false" ]
}

@test "issue_plan_approved_or_later returns false when the item is not on the board" {
    board_substatus_for_item() { printf 'Unknown'; }
    run issue_plan_approved_or_later 42
    [ "${output}" = "false" ]
}

@test "issue_plan_approved_or_later returns false when no board is configured" {
    _WF_PROJECT_ID=""
    discover_or_create_workflow_project() { return 0; }
    run issue_plan_approved_or_later 42
    [ "${output}" = "false" ]
}

# --- sync_pr_workflow_status_from_linked_issues (#1276) ----------------------

@test "sync_pr_workflow_status_from_linked_issues advances a PR whose linked issue is further along" {
    _WF_PROJECT_ID="PVT_test"
    board_substatus_for_item() {
        case "$1" in
            383) printf 'Development' ;;
            412) printf 'Unknown' ;;
        esac
    }
    _wf_lookup_item_on_board() { printf 'absent'; }
    local status_log="${TEST_TMP}/status_calls"
    update_workflow_status() { printf '%s %s %s\n' "$1" "$2" "$3" >> "${status_log}"; }
    make_stub gh 'printf "383\n"'

    sync_pr_workflow_status_from_linked_issues 412 "false"
    grep -q 'PullRequest 412 Development' "${status_log}"
}

@test "sync_pr_workflow_status_from_linked_issues never lowers a PR's card that is already ahead of its issue" {
    _WF_PROJECT_ID="PVT_test"
    board_substatus_for_item() {
        case "$1" in
            383) printf 'Development' ;;
            412) printf 'AI Review' ;;
        esac
    }
    local status_log="${TEST_TMP}/status_calls"
    update_workflow_status() { printf '%s %s %s\n' "$1" "$2" "$3" >> "${status_log}"; }
    make_stub gh 'printf "383\n"'

    sync_pr_workflow_status_from_linked_issues 412 "false"
    [ ! -f "${status_log}" ]
}

@test "sync_pr_workflow_status_from_linked_issues floors the mirrored status at Development even if the issue is only Approved" {
    _WF_PROJECT_ID="PVT_test"
    board_substatus_for_item() {
        case "$1" in
            383) printf 'Approved' ;;
            412) printf 'Unknown' ;;
        esac
    }
    _wf_lookup_item_on_board() { printf 'absent'; }
    local status_log="${TEST_TMP}/status_calls"
    update_workflow_status() { printf '%s %s %s\n' "$1" "$2" "$3" >> "${status_log}"; }
    make_stub gh 'printf "383\n"'

    sync_pr_workflow_status_from_linked_issues 412 "false"
    grep -q 'PullRequest 412 Development' "${status_log}"
}

@test "sync_pr_workflow_status_from_linked_issues falls back to first-touch Not Started when there is no linked issue" {
    _WF_PROJECT_ID="PVT_test"
    local status_log="${TEST_TMP}/status_calls"
    update_workflow_status() { printf '%s %s %s\n' "$1" "$2" "$3" >> "${status_log}"; }
    make_stub gh 'printf ""'

    sync_pr_workflow_status_from_linked_issues 500 "true"
    grep -q 'PullRequest 500 Not Started' "${status_log}"
}

@test "sync_pr_workflow_status_from_linked_issues with no linked issue and not first touch does nothing" {
    _WF_PROJECT_ID="PVT_test"
    local status_log="${TEST_TMP}/status_calls"
    update_workflow_status() { printf '%s %s %s\n' "$1" "$2" "$3" >> "${status_log}"; }
    make_stub gh 'printf ""'

    sync_pr_workflow_status_from_linked_issues 500 "false"
    [ ! -f "${status_log}" ]
}

@test "sync_pr_workflow_status_from_linked_issues is a no-op when the board is not configured" {
    _WF_PROJECT_ID=""
    local call_log="${TEST_TMP}/gh_calls"
    make_stub gh "printf 'called\n' >> ${call_log}"
    sync_pr_workflow_status_from_linked_issues 412 "false"
    [ ! -f "${call_log}" ]
}

@test "sync_pr_workflow_status_from_linked_issues leaves the card alone when the PR's own card cannot be read (#1688)" {
    _WF_PROJECT_ID="PVT_test"
    board_substatus_for_item() {
        case "$1" in
            383) printf 'Development' ;;
            412) printf 'Unknown' ;;
        esac
    }
    _wf_lookup_item_on_board() { printf 'unknown'; }
    local status_log="${TEST_TMP}/status_calls"
    update_workflow_status() { printf '%s %s %s\n' "$1" "$2" "$3" >> "${status_log}"; }
    make_stub gh 'printf "383\n"'

    run sync_pr_workflow_status_from_linked_issues 412 "false"
    [ "${status}" -eq 0 ]
    [ ! -f "${status_log}" ]
    [[ "${output}" == *"could not read PullRequest #412's card"* ]]
}

@test "sync_pr_workflow_status_from_linked_issues sets the floor on a card that is on the board with no status (#1688)" {
    _WF_PROJECT_ID="PVT_test"
    board_substatus_for_item() {
        case "$1" in
            383) printf 'Development' ;;
            412) printf 'Unknown' ;;
        esac
    }
    _wf_lookup_item_on_board() { printf 'present'; }
    local status_log="${TEST_TMP}/status_calls"
    update_workflow_status() { printf '%s %s %s\n' "$1" "$2" "$3" >> "${status_log}"; }
    make_stub gh 'printf "383\n"'

    sync_pr_workflow_status_from_linked_issues 412 "false"
    grep -q 'PullRequest 412 Development' "${status_log}"
}

@test "sync_pr_workflow_status_from_linked_issues never lowers a card the board listing left out (#1688)" {
    # End to end through the real board_substatus_for_item: the listing is empty, but the PR's
    # own card reads AI Review, so nothing may be written.
    set_repo_context "org/repo"
    _WF_CACHED_REPO="org/repo"
    _WF_PROJECT_ID="PVT_test"
    _WF_OPTION_IDS[Development]="opt_dev"
    _WF_OPTION_IDS["AI Review"]="opt_review"
    local status_log="${TEST_TMP}/status_calls"
    update_workflow_status() { printf '%s %s %s\n' "$1" "$2" "$3" >> "${status_log}"; }
    cat > "${STUB_BIN}/gh" << 'STUBEOF'
#!/usr/bin/env bash
case "$*" in
    *closingIssuesReferences*) printf '383\n' ;;
    *issueOrPullRequest*)
        if [[ "$*" == *"i=412"* ]]; then
            printf '%s\n' '{"data":{"repository":{"issueOrPullRequest":{"projectItems":{"nodes":[{"project":{"id":"PVT_test"},"fieldValueByName":{"optionId":"opt_review"}}]}}}}}'
        else
            printf '%s\n' '{"data":{"repository":{"issueOrPullRequest":{"projectItems":{"nodes":[{"project":{"id":"PVT_test"},"fieldValueByName":{"optionId":"opt_dev"}}]}}}}}'
        fi ;;
    *) printf '%s\n' '{"data":{"node":{"items":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}' ;;
esac
STUBEOF
    chmod +x "${STUB_BIN}/gh"

    sync_pr_workflow_status_from_linked_issues 412 "false"
    [ ! -f "${status_log}" ]
}

# --- _wf_lookup_item_on_board (#1688) -------------------------------------------

@test "_wf_lookup_item_on_board reports present and records the card's status" {
    set_repo_context "org/repo"
    _WF_PROJECT_ID="PVT_test"
    make_stub gh "printf '%s\n' '{\"data\":{\"repository\":{\"issueOrPullRequest\":{\"projectItems\":{\"nodes\":[{\"project\":{\"id\":\"PVT_other\"},\"fieldValueByName\":null},{\"project\":{\"id\":\"PVT_test\"},\"fieldValueByName\":{\"optionId\":\"opt_review\"}}]}}}}}'"
    _wf_lookup_item_on_board 42 > "${TEST_TMP}/out"
    [ "$(cat "${TEST_TMP}/out")" = "present" ]
    [ "${_WF_ITEM_STATUS_OPTION_ID["org/repo/42"]:-}" = "opt_review" ]
    [ "${_WF_ITEM_BOARD_PRESENCE["org/repo/42"]:-}" = "present" ]
}

@test "_wf_lookup_item_on_board reports present for a card with no status and records no option" {
    set_repo_context "org/repo"
    _WF_PROJECT_ID="PVT_test"
    make_stub gh "printf '%s\n' '{\"data\":{\"repository\":{\"issueOrPullRequest\":{\"projectItems\":{\"nodes\":[{\"project\":{\"id\":\"PVT_test\"},\"fieldValueByName\":null}]}}}}}'"
    run _wf_lookup_item_on_board 42
    [ "${output}" = "present" ]
}

@test "_wf_lookup_item_on_board reports absent when only other boards hold the item" {
    set_repo_context "org/repo"
    _WF_PROJECT_ID="PVT_test"
    make_stub gh "printf '%s\n' '{\"data\":{\"repository\":{\"issueOrPullRequest\":{\"projectItems\":{\"nodes\":[{\"project\":{\"id\":\"PVT_other\"},\"fieldValueByName\":null}]}}}}}'"
    run _wf_lookup_item_on_board 42
    [ "${output}" = "absent" ]
}

@test "_wf_lookup_item_on_board reports unknown when the read fails" {
    set_repo_context "org/repo"
    _WF_PROJECT_ID="PVT_test"
    make_stub gh 'exit 1'
    run _wf_lookup_item_on_board 42
    [ "${output}" = "unknown" ]
}

@test "_wf_lookup_item_on_board reports unknown for an unexpected response" {
    set_repo_context "org/repo"
    _WF_PROJECT_ID="PVT_test"
    make_stub gh "printf '%s\n' '{\"data\":{\"repository\":null}}'"
    run _wf_lookup_item_on_board 42
    [ "${output}" = "unknown" ]
}

@test "_wf_lookup_item_on_board reports unknown without calling gh when the board is not configured" {
    set_repo_context "org/repo"
    _WF_PROJECT_ID=""
    local call_log="${TEST_TMP}/gh_calls"
    make_stub gh "printf 'called\n' >> ${call_log}"
    run _wf_lookup_item_on_board 42
    [ "${output}" = "unknown" ]
    [ ! -f "${call_log}" ]
}

@test "_wf_lookup_item_on_board reads each item once per process" {
    set_repo_context "org/repo"
    _WF_PROJECT_ID="PVT_test"
    local call_log="${TEST_TMP}/gh_calls"
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
printf 'called\n' >> "${call_log}"
printf '%s\n' '{"data":{"repository":{"issueOrPullRequest":{"projectItems":{"nodes":[]}}}}}'
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    _wf_lookup_item_on_board 42 > /dev/null
    _wf_lookup_item_on_board 42 > /dev/null
    [ "$(wc -l < "${call_log}")" -eq 1 ]
}

@test "board_substatus_for_item reads the item's own card when the board listing leaves it out (#1688)" {
    set_repo_context "org/repo"
    _WF_CACHED_REPO="org/repo"
    _WF_PROJECT_ID="PVT_test"
    _WF_OPTION_IDS["AI Review"]="opt_review"
    cat > "${STUB_BIN}/gh" << 'STUBEOF'
#!/usr/bin/env bash
case "$*" in
    *issueOrPullRequest*) printf '%s\n' '{"data":{"repository":{"issueOrPullRequest":{"projectItems":{"nodes":[{"project":{"id":"PVT_test"},"fieldValueByName":{"optionId":"opt_review"}}]}}}}}' ;;
    *) printf '%s\n' '{"data":{"node":{"items":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}' ;;
esac
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    run board_substatus_for_item 1050
    [ "${output}" = "AI Review" ]
}

@test "fetch_board_item_statuses warns when a page after the first comes back empty (#1688)" {
    set_repo_context "org/repo"
    _WF_PROJECT_ID="PVT_test"
    cat > "${STUB_BIN}/gh" << 'STUBEOF'
#!/usr/bin/env bash
if [[ "$*" == *"cursor="* ]]; then
    printf '%s\n' '{"data":{"node":{"items":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}'
else
    printf '%s\n' '{"data":{"node":{"items":{"pageInfo":{"hasNextPage":true,"endCursor":"c1"},"nodes":[{"content":{"number":1,"repository":{"nameWithOwner":"org/repo"}},"fieldValues":{"nodes":[{"optionId":"opt_dev","field":{"name":"Status"}}]}}]}}}}'
fi
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    run fetch_board_item_statuses
    [[ "${output}" == *"returned an empty page"* ]]
}

@test "fetch_board_item_statuses does not warn for an empty board" {
    set_repo_context "org/repo"
    _WF_PROJECT_ID="PVT_test"
    make_stub gh "printf '%s\n' '{\"data\":{\"node\":{\"items\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[]}}}}'"
    run fetch_board_item_statuses
    [[ "${output}" != *"returned an empty page"* ]]
}

# --- coarse_status_for_substatus (#1136) ----------------------------------------

@test "coarse_status_for_substatus maps Not Started and Planning to To Do" {
    run coarse_status_for_substatus "Not Started"
    [ "${output}" = "To Do" ]
    run coarse_status_for_substatus "Planning"
    [ "${output}" = "To Do" ]
}

@test "coarse_status_for_substatus maps the active phases to In Progress" {
    for phase in Approved Development "AI Simplify" "AI Review" "AI Security Review" "AI Coverage" "Human Review"; do
        run coarse_status_for_substatus "${phase}"
        [ "${output}" = "In Progress" ]
    done
}

@test "coarse_status_for_substatus maps Complete to Done" {
    run coarse_status_for_substatus "Complete"
    [ "${output}" = "Done" ]
}

@test "coarse_status_for_substatus maps an unrecognised sub-status to Unknown" {
    run coarse_status_for_substatus "Unknown"
    [ "${output}" = "Unknown" ]
    run coarse_status_for_substatus ""
    [ "${output}" = "Unknown" ]
}

# --- priority_for_labels (#1136) -------------------------------------------------

@test "priority_for_labels matches Security with highest precedence" {
    run priority_for_labels '[{"name":"Low"},{"name":"Urgent"},{"name":"Security"}]'
    [ "${output}" = "Security" ]
}

@test "priority_for_labels matches Urgent over High" {
    run priority_for_labels '[{"name":"High"},{"name":"Urgent"}]'
    [ "${output}" = "Urgent" ]
}

@test "priority_for_labels matches each single priority label correctly" {
    run priority_for_labels '[{"name":"High"}]'
    [ "${output}" = "High" ]
    run priority_for_labels '[{"name":"Medium"}]'
    [ "${output}" = "Medium" ]
    run priority_for_labels '[{"name":"Low"}]'
    [ "${output}" = "Low" ]
}

@test "priority_for_labels is case-insensitive" {
    run priority_for_labels '[{"name":"URGENT"}]'
    [ "${output}" = "Urgent" ]
}

@test "priority_for_labels returns Undefined when no priority label is present" {
    run priority_for_labels '[{"name":"AI-Work"},{"name":"bug"}]'
    [ "${output}" = "Undefined" ]
}

@test "priority_for_labels returns Undefined for an empty labels array" {
    run priority_for_labels '[]'
    [ "${output}" = "Undefined" ]
}

@test "priority_for_labels returns Undefined without dying on malformed JSON" {
    run priority_for_labels 'not json'
    [ "${status}" -eq 0 ]
    [ "${output}" = "Undefined" ]
}

# --- priority_name_for_rank (#1375) ----------------------------------------------

@test "priority_name_for_rank maps every defined rank to its name" {
    run priority_name_for_rank "0"
    [ "${output}" = "Default" ]
    run priority_name_for_rank "1"
    [ "${output}" = "Low" ]
    run priority_name_for_rank "2"
    [ "${output}" = "Medium" ]
    run priority_name_for_rank "3"
    [ "${output}" = "High" ]
    run priority_name_for_rank "4"
    [ "${output}" = "Urgent" ]
    run priority_name_for_rank "5"
    [ "${output}" = "Security" ]
}

@test "priority_name_for_rank returns Undefined for an out-of-range rank" {
    run priority_name_for_rank "6"
    [ "${output}" = "Undefined" ]
    run priority_name_for_rank "-1"
    [ "${output}" = "Undefined" ]
}

@test "priority_name_for_rank returns Undefined for a missing or non-numeric rank" {
    run priority_name_for_rank ""
    [ "${output}" = "Undefined" ]
    run priority_name_for_rank "abc"
    [ "${output}" = "Undefined" ]
}

# --- round-progress enrichment (#1375) ---------------------------------------

@test "_round_marker_and_cap_for_substatus returns the marker and cap for each bounded-loop phase" {
    run _round_marker_and_cap_for_substatus "AI Simplify"
    [[ "${output}" == "Simplify: applied cleanups"$'\t'"${MAX_SIMPLIFY_ITERATIONS}" ]]
    run _round_marker_and_cap_for_substatus "AI Review"
    [[ "${output}" == "Code review round:"$'\t'"${MAX_CODE_REVIEW_ITERATIONS}" ]]
    run _round_marker_and_cap_for_substatus "AI Security Review"
    [[ "${output}" == "Security review round:"$'\t'"${MAX_SECURITY_REVIEW_ITERATIONS}" ]]
    run _round_marker_and_cap_for_substatus "AI Coverage"
    [[ "${output}" == " - returning to Development"$'\t'"${MAX_COVERAGE_ITERATIONS}" ]]
}

@test "_round_marker_and_cap_for_substatus returns empty for a non-bounded-loop substatus" {
    run _round_marker_and_cap_for_substatus "Development"
    [ -z "${output}" ]
    run _round_marker_and_cap_for_substatus "Human Review"
    [ -z "${output}" ]
    run _round_marker_and_cap_for_substatus "Unknown"
    [ -z "${output}" ]
}

@test "count_pr_comments_matching counts only comments containing the marker" {
    set_repo_context "org/repo"
    make_stub gh 'printf "%s" "{\"comments\":[{\"body\":\"Code review round: fixed 2 findings\"},{\"body\":\"unrelated\"},{\"body\":\"Code review round: fixed 1 finding\"}]}"'
    run count_pr_comments_matching "5" "Code review round:"
    [ "${output}" = "2" ]
}

@test "count_pr_comments_matching returns 0 when nothing matches or the fetch fails" {
    set_repo_context "org/repo"
    make_stub gh 'printf "%s" "{\"comments\":[{\"body\":\"unrelated\"}]}"'
    run count_pr_comments_matching "5" "Code review round:"
    [ "${output}" = "0" ]

    make_stub gh 'exit 1'
    run count_pr_comments_matching "5" "Code review round:"
    [ "${output}" = "0" ]
}

@test "count_pr_comments_matching filters a given comments_json without fetching via gh (#1375)" {
    set_repo_context "org/repo"
    local gh_call_log="${TEST_TMP}/gh_calls"
    make_stub gh "printf 'called\n' >> '${gh_call_log}'"
    local comments_json='[{"body":"Code review round: fixed 2 findings"},{"body":"unrelated"}]'

    run count_pr_comments_matching "5" "Code review round:" "${comments_json}"
    [ "${output}" = "1" ]
    [ ! -f "${gh_call_log}" ]
}

@test "coverage_summary_for_branch reads Overall percentages from the branch's own COVERAGE.md via origin, not the working tree" {
    set_repo_context "org/repo"
    setup_local_git_remote >/dev/null
    git -C "${REPO_WORK_DIR}" checkout -b feature/cov >/dev/null 2>&1
    cat > "${REPO_WORK_DIR}/COVERAGE.md" <<'EOF'
# Coverage

## .NET
| Project | Line Coverage |
| --- | --- |
| Credfeto.Foo | 82.1% |
| **Overall (.NET)** | **82.1%** |

## Node
| Package | Line Coverage |
| --- | --- |
| **Overall (Node)** | **91.4%** |

## Shell

excluded
EOF
    git -C "${REPO_WORK_DIR}" add COVERAGE.md
    git -C "${REPO_WORK_DIR}" -c commit.gpgsign=false commit -q -m "coverage"
    git -C "${REPO_WORK_DIR}" push origin feature/cov >/dev/null 2>&1
    # The working tree is left checked out on feature/cov above, but the function must not rely
    # on that — switch back to main to prove it reads via origin/<branch>, not the working tree.
    git -C "${REPO_WORK_DIR}" checkout main >/dev/null 2>&1
    git -C "${REPO_WORK_DIR}" fetch origin >/dev/null 2>&1

    run coverage_summary_for_branch "feature/cov"
    [ "${output}" = ".NET 82.1%, Node 91.4%" ]
}

@test "coverage_summary_for_branch returns empty when COVERAGE.md does not exist on the branch" {
    set_repo_context "org/repo"
    setup_local_git_remote >/dev/null
    run coverage_summary_for_branch "main"
    [ -z "${output}" ]
}

@test "coverage_summary_for_branch returns empty for a missing branch name or repo checkout" {
    set_repo_context "org/repo"
    run coverage_summary_for_branch ""
    [ -z "${output}" ]

    REPO_WORK_DIR="${TEST_TMP}/nonexistent/repo"
    run coverage_summary_for_branch "main"
    [ -z "${output}" ]
}

@test "enrich_substatus_with_round_progress appends the round count for AI Review" {
    set_repo_context "org/repo"
    make_stub gh 'printf "%s" "{\"comments\":[{\"body\":\"Code review round: fixed 2 findings\"}]}"'
    run enrich_substatus_with_round_progress "5" "AI Review" ""
    [ "${output}" = "AI Review (round 1 of ${MAX_CODE_REVIEW_ITERATIONS})" ]
}

@test "enrich_substatus_with_round_progress appends round count and coverage percentages for AI Coverage" {
    set_repo_context "org/repo"
    setup_local_git_remote >/dev/null
    git -C "${REPO_WORK_DIR}" checkout -b feature/cov2 >/dev/null 2>&1
    printf '## .NET\n| **Overall (.NET)** | **75.0%%** |\n' > "${REPO_WORK_DIR}/COVERAGE.md"
    git -C "${REPO_WORK_DIR}" add COVERAGE.md
    git -C "${REPO_WORK_DIR}" -c commit.gpgsign=false commit -q -m "coverage"
    git -C "${REPO_WORK_DIR}" push origin feature/cov2 >/dev/null 2>&1
    git -C "${REPO_WORK_DIR}" fetch origin >/dev/null 2>&1

    make_stub gh 'printf "%s" "{\"comments\":[{\"body\":\".NET 75.0%% < main 80.0%% - returning to Development\"}]}"'
    run enrich_substatus_with_round_progress "5" "AI Coverage" "feature/cov2"
    [ "${output}" = "AI Coverage (round 1 of ${MAX_COVERAGE_ITERATIONS}, .NET 75.0%)" ]
}

@test "enrich_substatus_with_round_progress falls back to round count only when COVERAGE.md has no summary" {
    set_repo_context "org/repo"
    make_stub gh 'printf "%s" "{\"comments\":[]}"'
    run enrich_substatus_with_round_progress "5" "AI Coverage" ""
    [ "${output}" = "AI Coverage (round 0 of ${MAX_COVERAGE_ITERATIONS})" ]
}

@test "enrich_substatus_with_round_progress leaves a non-bounded-loop substatus unchanged" {
    set_repo_context "org/repo"
    run enrich_substatus_with_round_progress "5" "Human Review" ""
    [ "${output}" = "Human Review" ]
    run enrich_substatus_with_round_progress "5" "Unknown" ""
    [ "${output}" = "Unknown" ]
}

@test "enrich_substatus_with_round_progress uses a given comments_json without fetching via gh (#1375)" {
    set_repo_context "org/repo"
    local gh_call_log="${TEST_TMP}/gh_calls"
    make_stub gh "printf 'called\n' >> '${gh_call_log}'"
    local comments_json='[{"body":"Code review round: fixed 2 findings"}]'

    run enrich_substatus_with_round_progress "5" "AI Review" "" "${comments_json}"
    [ "${output}" = "AI Review (round 1 of ${MAX_CODE_REVIEW_ITERATIONS})" ]
    [ ! -f "${gh_call_log}" ]
}

# --- _build_wf_section unit tests ---------------------------------------------

@test "_build_wf_section outputs nothing when _WF_PROJECT_ID is empty" {
    _WF_PROJECT_ID=""
    run _build_wf_section pr 9
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "_build_wf_section outputs the cfwf set and check commands for the item instead of the project and field ids (#1650)" {
    _WF_PROJECT_ID="PVT_abc123"
    _WF_STATUS_FIELD_ID="PVTSSF_def456"
    REPO_FULL="owner/repo"
    run _build_wf_section pr 9
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Set this pull request's status:  cfwf workflow-status --set --repo owner/repo --pr 9 --status \"<Status>\""* ]]
    [[ "${output}" == *"Read this pull request's status: cfwf workflow-status --check --repo owner/repo --pr 9"* ]]
    [[ "${output}" == *"Never update the board with gh project or gh api graphql; they are denied."* ]]
    [[ "${output}" != *"PVT_abc123"* ]]
    [[ "${output}" != *"PVTSSF_def456"* ]]
    run _build_wf_section issue 3
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Set this issue's status:  cfwf workflow-status --set --repo owner/repo --issue 3 --status \"<Status>\""* ]]
    [[ "${output}" == *"Read this issue's status: cfwf workflow-status --check --repo owner/repo --issue 3"* ]]
}

@test "_build_wf_section outputs all ten status names in board order and no option ids (#1650)" {
    _WF_PROJECT_ID="PVT_test"
    _WF_STATUS_FIELD_ID="PVTSSF_test"
    _WF_OPTION_IDS["Not Started"]="opt1"
    _WF_OPTION_IDS[Planning]="opt2"
    _WF_OPTION_IDS[Approved]="opt3"
    _WF_OPTION_IDS[Development]="opt4"
    _WF_OPTION_IDS["AI Simplify"]="opt4b"
    _WF_OPTION_IDS["AI Review"]="opt5"
    _WF_OPTION_IDS["AI Security Review"]="opt6"
    _WF_OPTION_IDS["AI Coverage"]="opt6b"
    _WF_OPTION_IDS["Human Review"]="opt7"
    _WF_OPTION_IDS[Complete]="opt8"
    run _build_wf_section pr 9
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Its Status values, in order: Not Started, Planning, Approved, Development, AI Simplify, AI Review, AI Security Review, AI Coverage, Human Review, Complete."* ]]
    local id
    for id in opt1 opt2 opt3 opt4 opt5 opt6 opt7 opt8; do
        [[ "${output}" != *"${id}"* ]]
    done
}

@test "_build_wf_section lists AI Coverage between AI Security Review and Human Review" {
    _WF_PROJECT_ID="PVT_test"
    run _build_wf_section pr 9
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"AI Security Review, AI Coverage, Human Review"* ]]
}

# --- project_cache_file_path / load_project_cache / save_project_cache / --------------
# --- invalidate_project_cache unit tests ------------------------------------------------

@test "project_cache_file_path returns a path under SESSION_BASE_DIR" {
    [ "$(project_cache_file_path)" = "${SESSION_BASE_DIR}/project-cache.json" ]
}

@test "load_project_cache returns 1 when no cache file exists" {
    run load_project_cache
    [ "${status}" -eq 1 ]
}

@test "load_project_cache returns 1 and does not populate globals for a stale (TTL-expired) entry" {
    local stale_at=$(( $(date +%s) - 7200 ))
    jq -n --arg repo "${REPO_FULL}" --argjson cached_at "${stale_at}" \
        '{repo: $repo, project_id: "PVT_stale", status_field_id: "PVTSSF_stale", option_ids: {"Planning":"oid1"}, cached_at: $cached_at}' \
        > "$(project_cache_file_path)"
    PROJECT_CACHE_TTL=3600
    run load_project_cache
    [ "${status}" -eq 1 ]
}

@test "load_project_cache returns 1 for a cache file belonging to a different repo" {
    jq -n --argjson cached_at "$(date +%s)" \
        '{repo: "other/repo", project_id: "PVT_other", status_field_id: "PVTSSF_other", option_ids: {}, cached_at: $cached_at}' \
        > "$(project_cache_file_path)"
    run load_project_cache
    [ "${status}" -eq 1 ]
}

@test "load_project_cache returns 1 for an entry from another cache version, so an old Workflow Status field id is never served (#1519)" {
    jq -n --arg repo "${REPO_FULL}" --argjson cached_at "$(date +%s)" \
        '{repo: $repo, project_id: "PVT_old", status_field_id: "PVTSSF_workflow_status", option_ids: {"Planning":"oid1"}, builtin_field_id: "PVTSSF_b", builtin_option_ids: {}, cached_at: $cached_at}' \
        > "$(project_cache_file_path)"
    run load_project_cache
    [ "${status}" -eq 1 ]
    jq -n --arg repo "${REPO_FULL}" --argjson cached_at "$(date +%s)" \
        '{repo: $repo, project_id: "PVT_old", status_field_id: "PVTSSF_old", option_ids: {}, cache_version: "1", cached_at: $cached_at}' \
        > "$(project_cache_file_path)"
    run load_project_cache
    [ "${status}" -eq 1 ]
    load_project_cache || true
    [ -z "${_WF_PROJECT_ID}" ]
    [ -z "${_WF_CACHED_REPO}" ]
}

@test "load_project_cache populates _WF_PROJECT_ID/_WF_STATUS_FIELD_ID/_WF_OPTION_IDS/_WF_CACHED_REPO on a fresh hit" {
    jq -n --arg repo "${REPO_FULL}" --arg v "${PROJECT_CACHE_VERSION}" --argjson cached_at "$(date +%s)" \
        '{repo: $repo, project_id: "PVT_hit", status_field_id: "PVTSSF_hit", option_ids: {"Planning":"oid1","Development":"oid2"}, cache_version: $v, cached_at: $cached_at}' \
        > "$(project_cache_file_path)"
    run load_project_cache
    [ "${status}" -eq 0 ]
    load_project_cache
    [ "${_WF_PROJECT_ID}" = "PVT_hit" ]
    [ "${_WF_STATUS_FIELD_ID}" = "PVTSSF_hit" ]
    [ "${_WF_OPTION_IDS[Planning]}" = "oid1" ]
    [ "${_WF_OPTION_IDS[Development]}" = "oid2" ]
    [ "${_WF_CACHED_REPO}" = "${REPO_FULL}" ]
}

@test "save_project_cache writes a JSON file, stamped with the cache version, readable by load_project_cache" {
    _WF_PROJECT_ID="PVT_saved"
    _WF_STATUS_FIELD_ID="PVTSSF_saved"
    unset _WF_OPTION_IDS
    declare -gA _WF_OPTION_IDS
    _WF_OPTION_IDS["Planning"]="oid1"
    _WF_OPTION_IDS["Development"]="oid2"
    save_project_cache
    [ -f "$(project_cache_file_path)" ]
    run jq -r '.repo' "$(project_cache_file_path)"
    [ "${output}" = "${REPO_FULL}" ]
    run jq -r '.project_id' "$(project_cache_file_path)"
    [ "${output}" = "PVT_saved" ]
    run jq -r '.cache_version' "$(project_cache_file_path)"
    [ "${output}" = "${PROJECT_CACHE_VERSION}" ]
    run jq -r 'has("builtin_field_id") or has("builtin_option_ids")' "$(project_cache_file_path)"
    [ "${output}" = "false" ]

    _WF_PROJECT_ID=""
    _WF_STATUS_FIELD_ID=""
    unset _WF_OPTION_IDS
    declare -gA _WF_OPTION_IDS
    load_project_cache
    [ "${_WF_PROJECT_ID}" = "PVT_saved" ]
    [ "${_WF_STATUS_FIELD_ID}" = "PVTSSF_saved" ]
    [ "${_WF_OPTION_IDS[Planning]}" = "oid1" ]
    [ "${_WF_OPTION_IDS[Development]}" = "oid2" ]
}

@test "invalidate_project_cache removes the disk cache file and clears in-memory globals" {
    _WF_PROJECT_ID="PVT_saved"
    _WF_STATUS_FIELD_ID="PVTSSF_saved"
    unset _WF_OPTION_IDS
    declare -gA _WF_OPTION_IDS
    _WF_OPTION_IDS["Planning"]="oid1"
    save_project_cache
    _WF_CACHE["${REPO_FULL}:discovered"]="1"
    _WF_CACHE["${REPO_FULL}:project_id"]="PVT_saved"
    _WF_CACHE["${REPO_FULL}:field_id"]="PVTSSF_saved"
    _WF_CACHE["${REPO_FULL}:opt_names"]="Planning"$'\n'
    _WF_CACHE["${REPO_FULL}:opt:Planning"]="oid1"
    _WF_CACHED_REPO="${REPO_FULL}"

    invalidate_project_cache

    [ ! -f "$(project_cache_file_path)" ]
    [ -z "${_WF_CACHE["${REPO_FULL}:discovered"]:-}" ]
    [ -z "${_WF_CACHE["${REPO_FULL}:project_id"]:-}" ]
    [ -z "${_WF_CACHE["${REPO_FULL}:opt:Planning"]:-}" ]
    [ -z "${_WF_CACHED_REPO}" ]
    [ -z "${_WF_PROJECT_ID}" ]
    [ "${#_WF_OPTION_IDS[@]}" -eq 0 ]
}

# --- discover_or_create_workflow_project unit tests ---------------------------

@test "discover_or_create_workflow_project leaves _WF_PROJECT_ID empty when gh graphql fails" {
    make_stub gh 'exit 1'
    discover_or_create_workflow_project
    [ -z "${_WF_PROJECT_ID}" ]
}

@test "discover_or_create_workflow_project warns with error content when gh graphql fails with stderr output" {
    make_stub gh 'printf "HTTP 422 Unprocessable Entity\n" >&2; exit 1'
    run discover_or_create_workflow_project
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"GraphQL query failed"* ]]
    [[ "${output}" == *"HTTP 422"* ]]
}

@test "discover_or_create_workflow_project warns with auth hint when gh graphql error mentions scope" {
    make_stub gh 'printf "Your token is missing the project scope\n" >&2; exit 1'
    run discover_or_create_workflow_project
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"gh auth refresh -s project"* ]]
}

@test "discover_or_create_workflow_project warns with auth hint when gh graphql error mentions permission" {
    make_stub gh 'printf "Insufficient permissions to access this resource\n" >&2; exit 1'
    run discover_or_create_workflow_project
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"gh auth refresh -s project"* ]]
}

@test "discover_or_create_workflow_project warns with auth hint when gh graphql error mentions authorization" {
    make_stub gh 'printf "Unauthorized: authorization required\n" >&2; exit 1'
    run discover_or_create_workflow_project
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"gh auth refresh -s project"* ]]
}

# Prints a projectsV2 node list holding one converted "Workflow" project (#1519): built-in Status
# field $2 carries the ten workflow states with ids o0..o9 in board order (so Planning is o1 and
# Development o3), there is no Workflow Status field, and no Default Workflow is enabled.
converted_board_nodes() {
    local project_id="$1" field_id="$2"
    project_status_names | jq -R . | jq -sc --arg p "${project_id}" --arg f "${field_id}" \
        '[{id: $p, title: "Workflow", fields: {nodes: [{id: $f, name: "Status", options: (to_entries | map({id: "o\(.key)", name: .value, color: "GRAY", description: ""}))}]}, workflows: {nodes: []}}]'
}

# Writes a gh stub that answers the projectsV2 discovery query with $1 (a node list) and logs every
# call's arguments to ${TEST_TMP}/gh_calls; any other call exits $2 (default 1).
stub_discovery() {
    printf '%s' "$1" > "${TEST_TMP}/projects.json"
    # shellcheck disable=SC2016  # the stub body expands at stub run time
    make_stub_multiline gh \
        'printf "%s\n" "$*" >> "'"${TEST_TMP}"'/gh_calls"' \
        'if [[ "$*" == *"projectsV2"* ]]; then printf "{\"nodes\":%s,\"pageInfo\":{\"endCursor\":null,\"hasNextPage\":false}}\n" "$(cat "'"${TEST_TMP}"'/projects.json")"; exit 0; fi' \
        "exit ${2:-1}"
}

@test "discover_or_create_workflow_project populates the ids from a converted board's built-in Status, with no conversion call (#1519)" {
    stub_discovery "$(converted_board_nodes PVT_found PVTSSF_status)"
    project_status_convert() { printf 'called\n' >> "${TEST_TMP}/convert_calls"; return 1; }
    discover_or_create_workflow_project
    [ "${_WF_PROJECT_ID}" = "PVT_found" ]
    [ "${_WF_STATUS_FIELD_ID}" = "PVTSSF_status" ]
    [ "${_WF_OPTION_IDS[Planning]}" = "o1" ]
    [ "${_WF_OPTION_IDS[Development]}" = "o3" ]
    [ "${#_WF_OPTION_IDS[@]}" -eq 10 ]
    [ ! -f "${TEST_TMP}/convert_calls" ]
    [ -z "${_WF_CONVERSION_FAILED}" ]
}

@test "discover_or_create_workflow_project asks for the Default Workflows in the discovery query, so a converted board costs no extra call (#1519)" {
    stub_discovery "$(converted_board_nodes PVT_found PVTSSF_status)"
    discover_or_create_workflow_project
    grep -q 'workflows(first:30){nodes{id name enabled}}' "${TEST_TMP}/gh_calls"
    [ "$(grep -c 'projectsV2' "${TEST_TMP}/gh_calls")" -eq 1 ]
}

@test "discover_or_create_workflow_project converts a board that still uses Workflow Status and uses the converted field (#1519)" {
    stub_discovery '[{"id":"PVT_old","title":"Workflow","fields":{"nodes":[{"id":"PVTSSF_b","name":"Status","options":[{"id":"bt","name":"Todo"}]},{"id":"PVTSSF_w","name":"Workflow Status","options":[{"id":"w1","name":"Planning"}]}]},"workflows":{"nodes":[]}}]'
    project_status_convert() {
        printf '%s\n' "$1" >> "${TEST_TMP}/convert_calls"
        PROJECT_STATUS_FIELD='{"id":"PVTSSF_b","name":"Status","options":[{"id":"bt","name":"Not Started"},{"id":"n1","name":"Planning"}]}'
    }
    discover_or_create_workflow_project
    [ "$(cat "${TEST_TMP}/convert_calls")" = "PVT_old" ]
    [ "${_WF_PROJECT_ID}" = "PVT_old" ]
    [ "${_WF_STATUS_FIELD_ID}" = "PVTSSF_b" ]
    [ "${_WF_OPTION_IDS[Not Started]}" = "bt" ]
    [ "${_WF_OPTION_IDS[Planning]}" = "n1" ]
    [ -z "${_WF_CONVERSION_FAILED}" ]
}

@test "discover_or_create_workflow_project, when a conversion step is refused, alerts, marks the repo failed and leaves the board off (#1519)" {
    stub_discovery '[{"id":"PVT_old","title":"Workflow","fields":{"nodes":[{"id":"PVTSSF_w","name":"Workflow Status","options":[]}]},"workflows":{"nodes":[]}}]'
    project_status_convert() {
        PROJECT_STATUS_FAILED_STEP="deleting the Workflow Status field"
        return 1
    }
    notify_discord_board_conversion_failed() { printf '%s|%s\n' "$1" "$2" >> "${TEST_TMP}/alerts"; }
    run discover_or_create_workflow_project
    [[ "${output}" == *"failed at deleting the Workflow Status field"* ]]
    discover_or_create_workflow_project 2> /dev/null
    [ "${_WF_CONVERSION_FAILED}" = "1" ]
    [ -z "${_WF_PROJECT_ID}" ]
    [ "$(tail -1 "${TEST_TMP}/alerts")" = "${REPO_FULL}|deleting the Workflow Status field" ]
    [ ! -f "$(project_cache_file_path)" ]
}

@test "discover_or_create_workflow_project does not retry a failed conversion, with no API call, until PROJECT_CACHE_TTL has passed (#1519)" {
    stub_discovery '[{"id":"PVT_old","title":"Workflow","fields":{"nodes":[{"id":"PVTSSF_w","name":"Workflow Status","options":[]}]},"workflows":{"nodes":[]}}]'
    project_status_convert() { printf 'x\n' >> "${TEST_TMP}/convert_calls"; PROJECT_STATUS_FAILED_STEP="a step"; return 1; }
    notify_discord_board_conversion_failed() { :; }
    discover_or_create_workflow_project 2> /dev/null
    [ "$(wc -l < "${TEST_TMP}/convert_calls")" -eq 1 ]

    # A later tick: in-memory state is gone, but the marker on disk still holds the failure.
    unset _WF_CACHE
    declare -gA _WF_CACHE
    _WF_CONVERSION_FAILED=""
    : > "${TEST_TMP}/gh_calls"
    discover_or_create_workflow_project 2> /dev/null
    [ "${_WF_CONVERSION_FAILED}" = "1" ]
    [ "$(wc -l < "${TEST_TMP}/convert_calls")" -eq 1 ]
    [ ! -s "${TEST_TMP}/gh_calls" ]

    # Once the marker is older than PROJECT_CACHE_TTL the conversion is tried again, and a success
    # removes the marker.
    unset _WF_CACHE
    declare -gA _WF_CACHE
    printf '%s\n' "$(( $(date +%s) - PROJECT_CACHE_TTL - 1 ))" > "${SESSION_BASE_DIR}/board-conversion-failed"
    project_status_convert() { printf 'x\n' >> "${TEST_TMP}/convert_calls"; PROJECT_STATUS_FIELD='{"id":"PVTSSF_b","name":"Status","options":[{"id":"n1","name":"Not Started"}]}'; }
    discover_or_create_workflow_project 2> /dev/null
    [ "$(wc -l < "${TEST_TMP}/convert_calls")" -eq 2 ]
    [ -z "${_WF_CONVERSION_FAILED}" ]
    [ "${_WF_PROJECT_ID}" = "PVT_old" ]
    [ ! -f "${SESSION_BASE_DIR}/board-conversion-failed" ]
}

@test "discover_or_create_workflow_project does not carry another repository's remembered failure over to a healthy one (#1519)" {
    # Found in review: after repo A was discovered, a remembered failure for repo B left the flag
    # set, and the fast path for A returned without clearing it, so A was skipped too.
    stub_discovery "$(converted_board_nodes PVT_repo_a PVTSSF_a1)" 0
    REPO_FULL="owner/repo-a"; OWNER="owner"; REPO="repo-a"; SESSION_BASE_DIR="${TEST_TMP}/sessions/a"
    discover_or_create_workflow_project
    [ -z "${_WF_CONVERSION_FAILED}" ]

    REPO_FULL="owner/repo-b"; OWNER="owner"; REPO="repo-b"; SESSION_BASE_DIR="${TEST_TMP}/sessions/b"
    mkdir -p "${SESSION_BASE_DIR}"
    date +%s > "${SESSION_BASE_DIR}/board-conversion-failed"
    discover_or_create_workflow_project
    [ "${_WF_CONVERSION_FAILED}" = "1" ]

    REPO_FULL="owner/repo-a"; OWNER="owner"; REPO="repo-a"; SESSION_BASE_DIR="${TEST_TMP}/sessions/a"
    discover_or_create_workflow_project
    [ -z "${_WF_CONVERSION_FAILED}" ]
    [ "${_WF_PROJECT_ID}" = "PVT_repo_a" ]
    [ "${_WF_STATUS_FIELD_ID}" = "PVTSSF_a1" ]
}

@test "discover_or_create_workflow_project clears a leftover failure flag on the fast path for the repository it last discovered (#1519)" {
    stub_discovery "$(converted_board_nodes PVT_repo_a PVTSSF_a1)" 0
    discover_or_create_workflow_project
    _WF_CONVERSION_FAILED="1"
    : > "${TEST_TMP}/gh_calls"
    discover_or_create_workflow_project
    [ -z "${_WF_CONVERSION_FAILED}" ]
    [ ! -s "${TEST_TMP}/gh_calls" ]
}

@test "discover_or_create_workflow_project says nothing about a missing failure marker, the usual case (#1519)" {
    stub_discovery "$(converted_board_nodes PVT_found PVTSSF_status)"
    run --separate-stderr discover_or_create_workflow_project
    [ "${status}" -eq 0 ]
    [[ "${stderr}" != *"No such file"* ]]
    [[ "${stderr}" != *"board-conversion-failed"* ]]
}

@test "discover_or_create_workflow_project converts a project it has just created (#1519)" {
    stub_discovery '[]'
    _wf_create_project() { printf '{"id":"PVT_new","title":"Workflow","fields":{"nodes":[]},"workflows":{"nodes":[]}}\n'; }
    project_status_convert() {
        printf '%s\n' "$1" >> "${TEST_TMP}/convert_calls"
        PROJECT_STATUS_FIELD='{"id":"PVTSSF_new","name":"Status","options":[{"id":"ns","name":"Not Started"}]}'
    }
    discover_or_create_workflow_project
    [ "$(cat "${TEST_TMP}/convert_calls")" = "PVT_new" ]
    [ "${_WF_PROJECT_ID}" = "PVT_new" ]
    [ "${_WF_STATUS_FIELD_ID}" = "PVTSSF_new" ]
    [ -f "$(project_cache_file_path)" ]
}

@test "discover_or_create_workflow_project keeps an option name containing a pipe whole and does not let it overwrite another option (#1493)" {
    stub_discovery "$(converted_board_nodes PVT_found PVTSSF_status | jq -c '.[0].fields.nodes[0].options += [{id: "oid_pipe", name: "Plan|ning", color: "GRAY", description: ""}]')"
    discover_or_create_workflow_project
    [ "${_WF_OPTION_IDS[Planning]}" = "o1" ]
    [ "${_WF_OPTION_IDS[Plan|ning]}" = "oid_pipe" ]
}

@test "discover_or_create_workflow_project persists a disk cache file after live discovery" {
    stub_discovery "$(converted_board_nodes PVT_found PVTSSF_status)"
    discover_or_create_workflow_project
    [ -f "$(project_cache_file_path)" ]
    run jq -r '.project_id' "$(project_cache_file_path)"
    [ "${output}" = "PVT_found" ]
    run jq -r '.status_field_id' "$(project_cache_file_path)"
    [ "${output}" = "PVTSSF_status" ]
    run jq -r '.repo' "$(project_cache_file_path)"
    [ "${output}" = "${REPO_FULL}" ]
}

@test "discover_or_create_workflow_project reads from disk cache without invoking gh when in-memory cache is empty" {
    jq -n --arg repo "${REPO_FULL}" --arg v "${PROJECT_CACHE_VERSION}" --argjson cached_at "$(date +%s)" \
        '{repo: $repo, project_id: "PVT_disk", status_field_id: "PVTSSF_disk", option_ids: {"Planning":"oid1"}, cache_version: $v, cached_at: $cached_at}' \
        > "$(project_cache_file_path)"
    make_stub gh 'exit 1'
    discover_or_create_workflow_project
    [ "${_WF_PROJECT_ID}" = "PVT_disk" ]
    [ "${_WF_STATUS_FIELD_ID}" = "PVTSSF_disk" ]
    [ "${_WF_OPTION_IDS[Planning]}" = "oid1" ]
    [ "${_WF_CACHED_REPO}" = "${REPO_FULL}" ]
    [ "${_WF_CACHE["${REPO_FULL}:field_id"]}" = "PVTSSF_disk" ]
}

@test "discover_or_create_workflow_project returns immediately on second call for same repo when first succeeded" {
    stub_discovery "$(converted_board_nodes PVT_cache PVTSSF_status)" 0
    discover_or_create_workflow_project
    local count_after_first
    count_after_first=$(wc -l < "${TEST_TMP}/gh_calls")
    discover_or_create_workflow_project
    # Second call must not invoke gh at all (cache hit)
    [ "$(wc -l < "${TEST_TMP}/gh_calls")" -eq "${count_after_first}" ]
}

@test "discover_or_create_workflow_project re-discovers when repo changes" {
    local call_count_file="${TEST_TMP}/gh_calls"
    make_stub gh "printf 'called\n' >> ${call_count_file}; exit 1"
    _WF_CACHED_REPO="other/repo"
    discover_or_create_workflow_project
    local count
    count=$(wc -l < "${call_count_file}" 2>/dev/null || printf '0\n')
    [ "${count}" -ge 1 ]
}

@test "discover_or_create_workflow_project restores cached globals without re-calling gh when switching back to a previously discovered repo" {
    stub_discovery "$(converted_board_nodes PVT_repo_a PVTSSF_a1)" 0
    REPO_FULL="owner/repo-a"
    OWNER="owner"
    REPO="repo-a"
    discover_or_create_workflow_project
    REPO_FULL="owner/repo-b"
    OWNER="owner"
    REPO="repo-b"
    discover_or_create_workflow_project
    local count_after_b
    count_after_b=$(wc -l < "${TEST_TMP}/gh_calls")
    REPO_FULL="owner/repo-a"
    OWNER="owner"
    REPO="repo-a"
    discover_or_create_workflow_project
    [ "$(wc -l < "${TEST_TMP}/gh_calls")" -eq "${count_after_b}" ]
    [ "${_WF_PROJECT_ID}" = "PVT_repo_a" ]
    [ "${_WF_STATUS_FIELD_ID}" = "PVTSSF_a1" ]
    [ "${_WF_OPTION_IDS[Planning]}" = "o1" ]
    [ "${_WF_OPTION_IDS[Development]}" = "o3" ]
}

@test "discover_or_create_workflow_project enables Projects when hasProjectsEnabled is false" {
    printf '%s' "$(converted_board_nodes PVT_found PVTSSF_status)" > "${TEST_TMP}/projects.json"
    local gh_log="${TEST_TMP}/gh_calls"
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${gh_log}"
if [[ "\$*" == *"hasProjectsEnabled"* ]]; then printf 'false\n'; exit 0; fi
if [[ "\$*" == *"repo edit"* ]]; then exit 0; fi
if [[ "\$*" == *"projectsV2"* ]]; then printf '{"nodes":%s,"pageInfo":{"endCursor":null,"hasNextPage":false}}\n' "\$(cat "${TEST_TMP}/projects.json")"; exit 0; fi
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    discover_or_create_workflow_project
    grep -q 'enable-projects' "${gh_log}"
    [ "${_WF_PROJECT_ID}" = "PVT_found" ]
}

@test "discover_or_create_workflow_project finds project on the second page" {
    printf '%s' "$(converted_board_nodes PVT_page2 PVTSSF_p2)" > "${TEST_TMP}/projects.json"
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
if [[ "\$*" == *"projectsV2"* ]]; then
    if [[ "\$*" == *"cursor="* ]]; then
        printf '{"nodes":%s,"pageInfo":{"endCursor":null,"hasNextPage":false}}\n' "\$(cat "${TEST_TMP}/projects.json")"
    else
        printf '{"nodes":[],"pageInfo":{"endCursor":"cursor_page2","hasNextPage":true}}\n'
    fi
    exit 0
fi
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    discover_or_create_workflow_project
    [ "${_WF_PROJECT_ID}" = "PVT_page2" ]
    [ "${_WF_STATUS_FIELD_ID}" = "PVTSSF_p2" ]
    [ "${_WF_OPTION_IDS[Planning]}" = "o1" ]
}

@test "discover_or_create_workflow_project stops pagination when hasNextPage is true but endCursor is absent" {
    local graphql_call_count_file="${TEST_TMP}/graphql_calls"
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
if [[ "\$*" == *"projectsV2"* ]]; then
    printf 'called\n' >> "${graphql_call_count_file}"
    printf '{"nodes":[],"pageInfo":{"endCursor":null,"hasNextPage":true}}\n'
    exit 0
fi
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    _wf_create_project() { return 1; }
    discover_or_create_workflow_project
    [ -z "${_WF_PROJECT_ID}" ]
    local count
    count=$(wc -l < "${graphql_call_count_file}" 2>/dev/null || printf '0\n')
    [ "${count}" -eq 1 ]
}

# --- _wf_create_project / _wf_invite_trusted_collaborators unit tests ---------

@test "_wf_create_project falls through to user query when org query exits non-zero" {
    local gh_log="${TEST_TMP}/gh_calls"
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${gh_log}"
if [[ "\$*" == *"organization"* ]]; then
    printf '{"data":{"organization":null},"errors":[{"message":"NOT_FOUND"}]}\n'
    exit 1
fi
if [[ "\$*" == *"user(login"* ]]; then
    printf 'U_abc123\n'
    exit 0
fi
if [[ "\$*" == *"repository(owner"* ]]; then
    printf 'R_repo123\n'
    exit 0
fi
if [[ "\$*" == *"createProjectV2"* ]]; then
    printf '{"data":{"createProjectV2":{"projectV2":{"id":"PVT_new"}}}}\n'
    exit 0
fi
printf '{}\n'; exit 0
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    get_trusted_logins() { printf '["testuser"]\n'; }
    _wf_invite_trusted_collaborators() { return 0; }
    _wf_create_project
    grep -q 'user(login' "${gh_log}"
    grep -q 'createProjectV2' "${gh_log}"
}

@test "_wf_create_project falls through to user query when org query outputs a JSON blob" {
    local gh_log="${TEST_TMP}/gh_calls"
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${gh_log}"
if [[ "\$*" == *"organization"* ]]; then
    printf '{"data":{"organization":null},"errors":[{"message":"NOT_FOUND"}]}\n'
    exit 0
fi
if [[ "\$*" == *"user(login"* ]]; then
    printf 'U_abc123\n'
    exit 0
fi
if [[ "\$*" == *"repository(owner"* ]]; then
    printf 'R_repo123\n'
    exit 0
fi
if [[ "\$*" == *"createProjectV2"* ]]; then
    printf '{"data":{"createProjectV2":{"projectV2":{"id":"PVT_new"}}}}\n'
    exit 0
fi
printf '{}\n'; exit 0
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    get_trusted_logins() { printf '["testuser"]\n'; }
    _wf_invite_trusted_collaborators() { return 0; }
    _wf_create_project
    grep -q 'user(login' "${gh_log}"
    grep -q 'createProjectV2' "${gh_log}"
}

@test "_wf_create_project warns and returns 1 when both org and user queries return nothing" {
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
if [[ "\$*" == *"organization"* ]] || [[ "\$*" == *"user(login"* ]]; then
    exit 1
fi
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    run _wf_create_project
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"cannot resolve owner node ID"* ]]
}

@test "_wf_create_project passes repositoryId to createProjectV2 for repo-scoped project" {
    local gh_log="${TEST_TMP}/gh_calls"
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${gh_log}"
if [[ "\$*" == *"organization"* ]]; then printf 'O_owner\n'; exit 0; fi
if [[ "\$*" == *"user(login"* ]]; then printf 'U_user\n'; exit 0; fi
if [[ "\$*" == *"repository(owner"* ]]; then printf 'R_repo\n'; exit 0; fi
if [[ "\$*" == *"createProjectV2"* ]]; then
    printf '{"data":{"createProjectV2":{"projectV2":{"id":"PVT_scoped"}}}}\n'; exit 0
fi
printf '{}\n'; exit 0
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    _wf_invite_trusted_collaborators() { return 0; }
    _wf_create_project
    grep -q 'repositoryId' "${gh_log}"
    run grep -q 'linkProjectV2ToRepository' "${gh_log}"
    [ "${status}" -ne 0 ]
}

@test "_wf_create_project warns and returns 1 when repo node ID cannot be resolved" {
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
if [[ "\$*" == *"organization"* ]]; then printf 'O_owner\n'; exit 0; fi
if [[ "\$*" == *"user(login"* ]]; then printf 'U_user\n'; exit 0; fi
if [[ "\$*" == *"repository(owner"* ]]; then exit 1; fi
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    run _wf_create_project
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"cannot resolve repo node ID"* ]]
}

@test "_wf_invite_trusted_collaborators skips copilot bot and invites real users" {
    local gh_log="${TEST_TMP}/gh_calls"
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${gh_log}"
if [[ "\$*" == *"user(login"* ]]; then
    printf '{"data":{"u0":{"id":"U_real"}}}\n'
    exit 0
fi
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    get_trusted_logins() { printf '["someuser","copilot-pull-request-reviewer"]\n'; }
    _wf_invite_trusted_collaborators "PVT_test"
    run grep -c 'user(login' "${gh_log}"
    [ "${output}" -eq 1 ]
    run grep -q 'copilot' "${gh_log}"
    [ "${status}" -ne 0 ]
}

@test "_wf_invite_trusted_collaborators is a no-op when no logins resolve to a node ID" {
    local gh_log="${TEST_TMP}/gh_calls"
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${gh_log}"
printf '{"data":{"u0":{"id":null}}}\n'; exit 0
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    get_trusted_logins() { printf '["ghost"]\n'; }
    run _wf_invite_trusted_collaborators "PVT_test"
    [ "${status}" -eq 0 ]
    run grep -q 'updateProjectV2Collaborators' "${gh_log}"
    [ "${status}" -ne 0 ]
}

@test "_wf_invite_trusted_collaborators warns and returns 0 when updateProjectV2Collaborators fails" {
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
if [[ "\$*" == *"user(login"* ]]; then
    printf '{"data":{"u0":{"id":"U_real"}}}\n'; exit 0
fi
exit 1
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    get_trusted_logins() { printf '["someuser"]\n'; }
    run _wf_invite_trusted_collaborators "PVT_test"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"updateProjectV2Collaborators failed"* ]]
}

@test "_wf_invite_trusted_collaborators batches multiple user lookups into a single gh call" {
    local gh_log="${TEST_TMP}/gh_calls"
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${gh_log}"
if [[ "\$*" == *"u0:user"* ]]; then
    printf '{"data":{"u0":{"id":"U_alice"},"u1":{"id":"U_bob"}}}\n'
    exit 0
fi
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    get_trusted_logins() { printf '["alice","bob"]\n'; }
    _wf_invite_trusted_collaborators "PVT_test"
    run grep -c 'u0:user' "${gh_log}"
    [ "${output}" -eq 1 ]
    run grep -q 'u1:user' "${gh_log}"
    [ "${status}" -eq 0 ]
    run grep -q -- '--input' "${gh_log}"
    [ "${status}" -eq 0 ]
}

# --- update_workflow_status unit tests ----------------------------------------

@test "update_workflow_status is a no-op when _WF_PROJECT_ID is empty" {
    _WF_PROJECT_ID=""
    local call_log="${TEST_TMP}/gh_calls"
    make_stub gh "printf 'called\n' >> ${call_log}; exit 0"
    run update_workflow_status "Issue" "42" "Planning"
    [ ! -f "${call_log}" ]
    [[ "${output}" != *"adding Issue #42 to board"* ]]
}

@test "update_workflow_status warns and returns 0 when status name is unknown" {
    _WF_PROJECT_ID="PVT_test"
    _WF_STATUS_FIELD_ID="PVTSSF_test"
    unset _WF_OPTION_IDS
    declare -A _WF_OPTION_IDS
    run update_workflow_status "Issue" "42" "NonExistentStatus"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"unknown status"* ]]
}

@test "update_workflow_status logs info when starting to add item to board" {
    _WF_PROJECT_ID="PVT_test"
    _WF_STATUS_FIELD_ID="PVTSSF_test"
    _WF_OPTION_IDS[Planning]="opt_planning"
    make_stub gh 'exit 1'
    run update_workflow_status "Issue" "99" "Planning"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"adding Issue #99 to board with status 'Planning'"* ]]
}

@test "update_workflow_status calls gh api to get node_id and update project" {
    _WF_PROJECT_ID="PVT_proj"
    _WF_STATUS_FIELD_ID="PVTSSF_field"
    _WF_OPTION_IDS[Planning]="opt_planning"
    local call_log="${TEST_TMP}/gh_calls"
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${call_log}"
if [[ "\$*" == *"node_id"* ]]; then
    printf 'NODE_abc\n'
    exit 0
fi
if [[ "\$*" == *"addProjectV2ItemById"* ]]; then
    printf '{"data":{"addProjectV2ItemById":{"item":{"id":"PVTI_item1"}}}}\n'
    exit 0
fi
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    update_workflow_status "Issue" "42" "Planning"
    grep -q 'node_id' "${call_log}"
    grep -q 'addProjectV2ItemById' "${call_log}"
    grep -q 'updateProjectV2ItemFieldValue' "${call_log}"
}

@test "update_workflow_status warns and returns 0 when node_id lookup fails" {
    _WF_PROJECT_ID="PVT_proj"
    _WF_STATUS_FIELD_ID="PVTSSF_field"
    _WF_OPTION_IDS[Planning]="opt_planning"
    make_stub gh 'exit 1'
    run update_workflow_status "Issue" "42" "Planning"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"failed to get node ID"* ]]
}

@test "update_workflow_status logs info after successfully adding item to board" {
    _WF_PROJECT_ID="PVT_proj"
    _WF_STATUS_FIELD_ID="PVTSSF_field"
    _WF_OPTION_IDS[Planning]="opt_planning"
    make_stub gh 'printf "PVTI_item1\n"; exit 0'
    run update_workflow_status "Issue" "42" "Planning"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"added to board with status 'Planning'"* ]]
}

@test "update_workflow_status warns with error content when addProjectV2ItemById fails" {
    _WF_PROJECT_ID="PVT_proj"
    _WF_STATUS_FIELD_ID="PVTSSF_field"
    _WF_OPTION_IDS[Planning]="opt_planning"
    cat > "${STUB_BIN}/gh" << 'STUBEOF'
#!/usr/bin/env bash
if [[ "$*" == *"addProjectV2ItemById"* ]]; then
    printf 'GraphQL error: project not found\n' >&2
    exit 1
fi
printf 'NODE_abc\n'
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    run update_workflow_status "Issue" "42" "Planning"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"failed to add Issue #42 to project"* ]]
    [[ "${output}" == *"project not found"* ]]
}

@test "update_workflow_status invalidates the disk project cache when addProjectV2ItemById fails" {
    _WF_PROJECT_ID="PVT_proj"
    _WF_STATUS_FIELD_ID="PVTSSF_field"
    _WF_OPTION_IDS[Planning]="opt_planning"
    save_project_cache
    [ -f "$(project_cache_file_path)" ]

    cat > "${STUB_BIN}/gh" << 'STUBEOF'
#!/usr/bin/env bash
if [[ "$*" == *"addProjectV2ItemById"* ]]; then
    printf 'GraphQL error: project not found\n' >&2
    exit 1
fi
printf 'NODE_abc\n'
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    run update_workflow_status "Issue" "42" "Planning"
    [ "${status}" -eq 0 ]
    [ ! -f "$(project_cache_file_path)" ]
}

# --- update_workflow_status writes only the built-in Status (#1519) -----------------------

# A board whose built-in Status field carries the ten workflow states (ids wf_1 to wf_10, in board
# order), and a gh stand-in that logs every call. A file named fail_update in TEST_TMP makes the
# field update fail.
setup_status_board() {
    _WF_PROJECT_ID="PVT_proj"
    _WF_STATUS_FIELD_ID="PVTSSF_status"
    unset _WF_OPTION_IDS
    declare -gA _WF_OPTION_IDS
    local n=0 name
    while IFS= read -r name; do
        n=$((n + 1))
        _WF_OPTION_IDS["${name}"]="wf_${n}"
    done < <(project_status_names)
    GH_CALLS="${TEST_TMP}/gh_calls"
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${GH_CALLS}"
if [[ "\$*" == *"node_id"* ]]; then
    printf 'NODE_abc\n'
    exit 0
fi
if [[ "\$*" == *"addProjectV2ItemById"* ]]; then
    printf 'PVTI_item1\n'
    exit 0
fi
if [ -f "${TEST_TMP}/fail_update" ] && [[ "\$*" == *"updateProjectV2ItemFieldValue"* ]]; then
    exit 1
fi
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/gh"
}

@test "update_workflow_status sets each of the ten states on the built-in Status field, with one field write (#1519)" {
    setup_status_board
    local name n=0
    while IFS= read -r name; do
        n=$((n + 1))
        : > "${GH_CALLS}"
        update_workflow_status "Issue" 42 "${name}" > /dev/null 2>&1
        [ "$(grep -c 'updateProjectV2ItemFieldValue' "${GH_CALLS}")" -eq 1 ]
        grep -q -- "-f f=PVTSSF_status -f v=wf_${n}" "${GH_CALLS}"
    done < <(project_status_names)
}

@test "update_workflow_status only warns when the Status write fails (#1519)" {
    setup_status_board
    touch "${TEST_TMP}/fail_update"
    run update_workflow_status "Issue" 42 "Development"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"failed to set status 'Development' for Issue #42"* ]]
}

# --- report_missing_workflow_project --------------------------------------

@test "report_missing_workflow_project files an issue when none is open" {
    export WF_CREATE_LOG="${TEST_TMP}/wf_create.log"
    : > "${WF_CREATE_LOG}"
    # shellcheck disable=SC2016  # stub body: $1/$2/$* must stay literal and expand at stub runtime
    make_stub gh '
case "$1 $2" in
    "issue list")   printf "" ;;
    "issue create") printf "%s\n" "$*" >> "${WF_CREATE_LOG}" ;;
    *)              ;;
esac'

    run report_missing_workflow_project
    [ "${status}" -eq 0 ]

    run cat "${WF_CREATE_LOG}"
    [[ "${output}" == *"--title ${WF_SETUP_ISSUE_TITLE}"* ]]
    [[ "${output}" == *"--label AI-Work"* ]]
    [[ "${output}" == *"create-project --repo ${REPO_FULL}"* ]]
}

@test "report_missing_workflow_project does not file when an open issue already exists" {
    export WF_CREATE_LOG="${TEST_TMP}/wf_create.log"
    : > "${WF_CREATE_LOG}"
    # shellcheck disable=SC2016  # stub body: $1/$2/$* must stay literal and expand at stub runtime
    make_stub gh '
case "$1 $2" in
    "issue list")   printf "7\n" ;;
    "issue create") printf "%s\n" "$*" >> "${WF_CREATE_LOG}" ;;
    *)              ;;
esac'

    run report_missing_workflow_project
    [ "${status}" -eq 0 ]

    run cat "${WF_CREATE_LOG}"
    [ -z "${output}" ]
}

@test "report_missing_workflow_project files at most once per repo within a run" {
    export WF_CREATE_LOG="${TEST_TMP}/wf_create.log"
    : > "${WF_CREATE_LOG}"
    # shellcheck disable=SC2016  # stub body: $1/$2/$* must stay literal and expand at stub runtime
    make_stub gh '
case "$1 $2" in
    "issue list")   printf "" ;;
    "issue create") printf "created\n" >> "${WF_CREATE_LOG}" ;;
    *)              ;;
esac'

    report_missing_workflow_project
    report_missing_workflow_project

    run grep -c created "${WF_CREATE_LOG}"
    [ "${output}" -eq 1 ]
}

@test "report_missing_workflow_project skips filing when gh issue list fails" {
    export WF_CREATE_LOG="${TEST_TMP}/wf_create.log"
    : > "${WF_CREATE_LOG}"
    # shellcheck disable=SC2016  # stub body: $1/$2/$* must stay literal and expand at stub runtime
    make_stub gh '
case "$1 $2" in
    "issue list")   exit 1 ;;
    "issue create") printf "%s\n" "$*" >> "${WF_CREATE_LOG}" ;;
    *)              ;;
esac'

    run report_missing_workflow_project
    [ "${status}" -eq 0 ]

    run cat "${WF_CREATE_LOG}"
    [ -z "${output}" ]
}

@test "report_missing_workflow_project retries filing when previous issue creation failed" {
    export WF_CREATE_LOG="${TEST_TMP}/wf_create.log"
    : > "${WF_CREATE_LOG}"
    # shellcheck disable=SC2016  # stub body: $1/$2/$* must stay literal and expand at stub runtime
    make_stub gh '
case "$1 $2" in
    "issue list")   printf "" ;;
    "issue create") printf "attempted\n" >> "${WF_CREATE_LOG}"; exit 1 ;;
    *)              ;;
esac'

    report_missing_workflow_project
    report_missing_workflow_project

    run grep -c attempted "${WF_CREATE_LOG}"
    [ "${output}" -eq 2 ]
}

@test "report_missing_workflow_project marks repo as reported when existing issue is found" {
    # shellcheck disable=SC2016  # stub body: $1/$2/$* must stay literal and expand at stub runtime
    make_stub gh '
case "$1 $2" in
    "issue list")   printf "7\n" ;;
    "issue create") exit 1 ;;
    *)              ;;
esac'

    _WF_REPORTED_REPOS=""
    report_missing_workflow_project
    [[ " ${_WF_REPORTED_REPOS} " == *" ${REPO_FULL} "* ]]
}

@test "discover_or_create_workflow_project sets _WF_CREATION_FAILED when project creation fails" {
    cat > "${STUB_BIN}/gh" << 'STUBEOF'
#!/usr/bin/env bash
if [[ "$*" == *"projectsV2"* ]]; then
    printf '{"nodes":[],"pageInfo":{"endCursor":null,"hasNextPage":false}}\n'
    exit 0
fi
if [[ "$*" == *"organization"* ]]; then
    exit 1
fi
if [[ "$*" == *"user(login"* ]]; then
    printf 'U_abc\n'
    exit 0
fi
if [[ "$*" == *"createProjectV2"* ]]; then
    printf 'Only users can create projects\n' >&2
    exit 1
fi
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    _WF_CREATION_FAILED=""
    discover_or_create_workflow_project
    [ -z "${_WF_PROJECT_ID}" ]
    [ -n "${_WF_CREATION_FAILED}" ]
}
