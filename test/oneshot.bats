#!/usr/bin/env bats
# shellcheck disable=SC2329  # functions in @test bodies are invoked indirectly via 'run'

load test_helper

setup() {
    setup_isolated_env
    source_oneshot
}

teardown() {
    cleanup_stubs
}

# --- prompt building -------------------------------------------------------

@test "build_issue_prompt includes issue number, repo, work dir and key instructions" {
    run build_issue_prompt 42 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"issue #42"* ]]
    [[ "${output}" == *"${REPO_FULL}"* ]]
    [[ "${output}" == *"${REPO_WORK_DIR}"* ]]
    [[ "${output}" == *"--add-label Blocked"* ]]
    [[ "${output}" == *"gh issue edit 42 --repo ${REPO_FULL} --add-label Blocked"* ]]
    [[ "${output}" == *"Read AI instructions from /resolved/.ai-instructions"* ]]
}

@test "build_pr_prompt includes PR number, repo, work dir and Blocked instruction" {
    run build_pr_prompt 7 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"pull request #7"* ]]
    [[ "${output}" == *"${REPO_FULL}"* ]]
    [[ "${output}" == *"${REPO_WORK_DIR}"* ]]
    [[ "${output}" == *"gh pr edit 7 --repo ${REPO_FULL} --add-label Blocked"* ]]
    [[ "${output}" == *"Read AI instructions from /resolved/.ai-instructions"* ]]
}

@test "find_ai_instructions returns repo work dir path when .ai-instructions exists there" {
    mkdir -p "${REPO_WORK_DIR}"
    printf 'instructions\n' > "${REPO_WORK_DIR}/.ai-instructions"
    run find_ai_instructions
    [ "${status}" -eq 0 ]
    [ "${output}" = "${REPO_WORK_DIR}/.ai-instructions" ]
}

@test "find_ai_instructions falls back to rules dir when repo work dir has no .ai-instructions" {
    mkdir -p "${RULES_DIR}"
    printf 'instructions\n' > "${RULES_DIR}/.ai-instructions"
    run find_ai_instructions
    [ "${status}" -eq 0 ]
    [ "${output}" = "${RULES_DIR}/.ai-instructions" ]
}

@test "find_ai_instructions prefers repo work dir over rules dir when both exist" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    printf 'repo\n' > "${REPO_WORK_DIR}/.ai-instructions"
    printf 'rules\n' > "${RULES_DIR}/.ai-instructions"
    run find_ai_instructions
    [ "${status}" -eq 0 ]
    [ "${output}" = "${REPO_WORK_DIR}/.ai-instructions" ]
}

@test "find_ai_instructions dies when neither path has .ai-instructions" {
    run find_ai_instructions
    [ "${status}" -ne 0 ]
    [[ "${output}" == *".ai-instructions"* ]]
}

# --- input validation / security ------------------------------------------

@test "load_token_for_owner rejects owners with invalid characters" {
    local bad
    # shellcheck disable=SC2016  # 'owner$x' is a deliberate literal — testing that a '$' in the owner is rejected
    for bad in 'owner;rm' 'owner space' 'owner/slash' 'owner$x' 'owner.dot'; do
        run load_token_for_owner "${bad}"
        [ "${status}" -eq 0 ]
        [ -z "${output}" ]
    done
}

@test "load_token_for_owner reads a token for a valid owner with safe perms" {
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator/tokens"
    printf 'secret-token\n' > "${XDG_CONFIG_HOME}/orchestrator/tokens/credfeto"
    chmod 600 "${XDG_CONFIG_HOME}/orchestrator/tokens/credfeto"
    run load_token_for_owner credfeto
    [ "${status}" -eq 0 ]
    [ "${output}" = "secret-token" ]
}

@test "read_token_if_safe outputs token for safe perms and skips unsafe perms" {
    local tf="${TEST_TMP}/token"
    printf '  my-token  \n' > "${tf}"

    local perm
    for perm in 600 400; do
        chmod "${perm}" "${tf}"
        run read_token_if_safe "${tf}"
        [ "${status}" -eq 0 ]
        [ "${output}" = "my-token" ]
    done

    for perm in 644 664 666 755; do
        chmod "${perm}" "${tf}"
        run read_token_if_safe "${tf}"
        [ "${status}" -eq 0 ]
        # Unsafe perms: token is skipped, only the warning (on stderr) is produced.
        [[ "${output}" != *"my-token"* ]]
    done
}

@test "read_token_if_safe outputs nothing for a missing file" {
    run read_token_if_safe "${TEST_TMP}/does-not-exist"
    [ -z "${output}" ]
}

@test "session_id UUID validation accepts a well-formed UUID" {
    run is_valid_session_id "12345678-1234-1234-1234-123456789abc"
    [ "${status}" -eq 0 ]
}

@test "session_id UUID validation rejects non-UUID values" {
    local bad
    for bad in "" "not-a-uuid" "12345678-1234-1234-1234-123456789abc; rm -rf /" \
               "1234567-1234-1234-1234-123456789abc" "gggggggg-1234-1234-1234-123456789abc"; do
        run is_valid_session_id "${bad}"
        [ "${status}" -ne 0 ]
    done
}

# --- tool checks -----------------------------------------------------------

@test "check_required_tools dies when a required tool is missing" {
    # Override the shell builtin used for presence checks so that a chosen tool
    # reports as absent, deterministically and without altering the real system.
    command() {
        if [ "$1" = "-v" ] && [ "$2" = "claude" ]; then
            return 1
        fi
        builtin command "$@"
    }
    run check_required_tools
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Required tool not found: claude"* ]]
}

@test "check_required_tools succeeds when all tools are present" {
    # All required tools are available in the environment.
    run check_required_tools
    [ "${status}" -eq 0 ]
}

# --- session handling ------------------------------------------------------

@test "session_file_path produces the expected path format" {
    run session_file_path Issue 99
    [ "${status}" -eq 0 ]
    [ "${output}" = "${SESSION_BASE_DIR}/Issue_99.env" ]

    run session_file_path PullRequest 12
    [ "${status}" -eq 0 ]
    [ "${output}" = "${SESSION_BASE_DIR}/PullRequest_12.env" ]
}

@test "save_session and load_session round-trip via SESSION_BASE_DIR" {
    local uuid="abcdabcd-1234-5678-9abc-def012345678"
    save_session Issue 5 "${uuid}"
    [ -f "${SESSION_BASE_DIR}/Issue_5.env" ]

    SESSION_ID="sentinel"
    load_session Issue 5
    [ "${SESSION_ID}" = "${uuid}" ]
}

@test "load_session for a PR with no session falls back to linked issue session" {
    # Linked issue 5 already has a saved session.
    local issue_uuid="11112222-3333-4444-5555-666677778888"
    save_session Issue 5 "${issue_uuid}"

    # gh pr view returns issue 5 as the linked closing issue.
    make_stub gh 'printf "5\n"'

    SESSION_ID="sentinel"
    load_session PullRequest 77
    [ "${SESSION_ID}" = "${issue_uuid}" ]
}

@test "load_session for a PR with no session and no linked issue leaves SESSION_ID empty" {
    make_stub gh 'printf "\n"'
    SESSION_ID="sentinel"
    load_session PullRequest 77
    [ -z "${SESSION_ID}" ]
}

# --- fingerprinting --------------------------------------------------------

@test "hash_sha256 is deterministic and matches the known SHA-256 of 'hello'" {
    run bash -c 'source "'"${REPO_ROOT}"'/oneshot"; printf "hello" | hash_sha256'
    [ "${status}" -eq 0 ]
    [ "${output}" = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824" ]
}

@test "fingerprint_pr_json is deterministic and changes when input changes" {
    local pr_a='{"title":"T","body":"B","isDraft":false,"labels":[{"name":"bug"}],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}'
    local pr_b='{"title":"T2","body":"B","isDraft":false,"labels":[{"name":"bug"}],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}'

    local fp1 fp2 fp3
    fp1=$(fingerprint_pr_json "${pr_a}")
    fp2=$(fingerprint_pr_json "${pr_a}")
    fp3=$(fingerprint_pr_json "${pr_b}")
    [ -n "${fp1}" ]
    [ "${fp1}" = "${fp2}" ]
    [ "${fp1}" != "${fp3}" ]
}

@test "fingerprint_issue_json is deterministic and changes when input changes" {
    local issue_a='{"title":"T","body":"B","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}'
    local issue_b='{"title":"T","body":"CHANGED","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}'

    local fp1 fp2 fp3
    fp1=$(fingerprint_issue_json "${issue_a}")
    fp2=$(fingerprint_issue_json "${issue_a}")
    fp3=$(fingerprint_issue_json "${issue_b}")
    [ -n "${fp1}" ]
    [ "${fp1}" = "${fp2}" ]
    [ "${fp1}" != "${fp3}" ]
}

@test "pr_json_has_blocked_label detects 'blocked' case-insensitively and is false when absent" {
    run pr_json_has_blocked_label '{"labels":[{"name":"Blocked"}]}'
    [ "${status}" -eq 0 ]

    run pr_json_has_blocked_label '{"labels":[{"name":"BLOCKED"}]}'
    [ "${status}" -eq 0 ]

    run pr_json_has_blocked_label '{"labels":[{"name":"bug"},{"name":"enhancement"}]}'
    [ "${status}" -ne 0 ]
}

@test "issue_json_has_blocked_label detects 'blocked' case-insensitively and is false when absent" {
    run issue_json_has_blocked_label '{"labels":[{"name":"blocked"}]}'
    [ "${status}" -eq 0 ]

    run issue_json_has_blocked_label '{"labels":[{"name":"BlOcKeD"}]}'
    [ "${status}" -eq 0 ]

    run issue_json_has_blocked_label '{"labels":[{"name":"wontfix"}]}'
    [ "${status}" -ne 0 ]
}

# --- model selection -----------------------------------------------------------

@test "invoke_claude passes --model opusplan to claude for a new session" {
    local args_log="${TEST_TMP}/claude_args"
    make_stub_multiline claude \
        "$(printf 'printf "%%s\\n" "$@" >> "%s"' "${args_log}")" \
        'printf '"'"'{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'"'"

    invoke_claude "test prompt" "" 2>/dev/null
    grep -qx -- '--model' "${args_log}"
    grep -qx 'opusplan' "${args_log}"
}

@test "invoke_claude passes --model opusplan to claude when resuming a session" {
    local args_log="${TEST_TMP}/claude_args"
    make_stub_multiline claude \
        "$(printf 'printf "%%s\\n" "$@" >> "%s"' "${args_log}")" \
        'printf '"'"'{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'"'"

    invoke_claude "test prompt" "12345678-1234-1234-1234-123456789abc" 2>/dev/null
    grep -qx -- '--model' "${args_log}"
    grep -qx 'opusplan' "${args_log}"
}

# --- set_repo_context ---------------------------------------------------------

@test "set_repo_context sets OWNER REPO REPO_FULL RULES_DIR REPO_WORK_DIR SESSION_BASE_DIR" {
    set_repo_context "myorg/myrepo"
    [ "${OWNER}"    = "myorg" ]
    [ "${REPO}"     = "myrepo" ]
    [ "${REPO_FULL}" = "myorg/myrepo" ]
    [ "${RULES_DIR}"     = "${WORK}/myorg/myrepo/rules" ]
    [ "${REPO_WORK_DIR}" = "${WORK}/myorg/myrepo/repo" ]
    [ "${SESSION_BASE_DIR}" = "${HOME}/.orchestrator/myorg/myrepo" ]
}

@test "set_repo_context is idempotent when called twice with the same repo" {
    set_repo_context "orgA/repoA"
    set_repo_context "orgA/repoA"
    [ "${REPO_FULL}" = "orgA/repoA" ]
    [ "${OWNER}" = "orgA" ]
}

@test "set_repo_context correctly switches context between two different repos" {
    set_repo_context "orgA/repoA"
    [ "${REPO_FULL}" = "orgA/repoA" ]
    [ "${OWNER}" = "orgA" ]

    set_repo_context "orgB/repoB"
    [ "${REPO_FULL}" = "orgB/repoB" ]
    [ "${OWNER}" = "orgB" ]
    [ "${REPO_WORK_DIR}" = "${WORK}/orgB/repoB/repo" ]
}

# --- fetch_all_priorities -----------------------------------------------------

@test "fetch_all_priorities returns all open non-on-hold items sorted by priority" {
    make_stub curl 'printf '"'"'{"priorities":[
        {"id":3,"itemType":"Issue","repository":"org/repo","status":"Open","isOnHold":false,"priority":3},
        {"id":1,"itemType":"Issue","repository":"org/repo","status":"Open","isOnHold":false,"priority":1},
        {"id":2,"itemType":"PullRequest","repository":"org/repo","status":"Open","isOnHold":false,"priority":2},
        {"id":4,"itemType":"Issue","repository":"org/repo","status":"Closed","isOnHold":false,"priority":4},
        {"id":5,"itemType":"Issue","repository":"org/repo","status":"Open","isOnHold":true,"priority":0}
    ]}\n'"'"

    run fetch_all_priorities
    [ "${status}" -eq 0 ]
    # Only the 3 open non-on-hold items appear, in priority order
    local ids
    ids=$(printf '%s' "${output}" | jq -r '.[].id')
    [ "${ids}" = "$(printf '1\n2\n3')" ]
}

@test "fetch_all_priorities returns empty array when no open items exist" {
    make_stub curl 'printf '"'"'{"priorities":[]}\n'"'"
    run fetch_all_priorities
    [ "${status}" -eq 0 ]
    [ "${output}" = "[]" ]
}

@test "fetch_all_priorities includes items from multiple repositories" {
    make_stub curl 'printf '"'"'{"priorities":[
        {"id":10,"itemType":"Issue","repository":"org/repoA","status":"Open","isOnHold":false,"priority":1},
        {"id":20,"itemType":"Issue","repository":"org/repoB","status":"Open","isOnHold":false,"priority":2}
    ]}\n'"'"

    run fetch_all_priorities
    [ "${status}" -eq 0 ]
    local repos
    repos=$(printf '%s' "${output}" | jq -r '.[].repository')
    [[ "${repos}" == *"org/repoA"* ]]
    [[ "${repos}" == *"org/repoB"* ]]
}

# --- find_open_nonblocked_pr_for_repo -----------------------------------------

@test "find_open_nonblocked_pr_for_repo returns first non-blocked PR number" {
    make_stub gh 'printf '"'"'[{"number":42,"labels":[]},{"number":99,"labels":[{"name":"enhancement"}]}]\n'"'"
    run find_open_nonblocked_pr_for_repo "org/repo"
    [ "${status}" -eq 0 ]
    [ "${output}" = "42" ]
}

@test "find_open_nonblocked_pr_for_repo skips PRs with the Blocked label" {
    make_stub gh 'printf '"'"'[{"number":7,"labels":[{"name":"Blocked"}]},{"number":8,"labels":[]}]\n'"'"
    run find_open_nonblocked_pr_for_repo "org/repo"
    [ "${status}" -eq 0 ]
    [ "${output}" = "8" ]
}

@test "find_open_nonblocked_pr_for_repo returns empty when all PRs are blocked" {
    make_stub gh 'printf '"'"'[{"number":7,"labels":[{"name":"blocked"}]}]\n'"'"
    run find_open_nonblocked_pr_for_repo "org/repo"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "find_open_nonblocked_pr_for_repo returns empty when no PRs exist" {
    make_stub gh 'printf '"'"'[]\n'"'"
    run find_open_nonblocked_pr_for_repo "org/repo"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "find_open_nonblocked_pr_for_repo returns 1 when gh fails" {
    make_stub gh 'exit 1'
    run find_open_nonblocked_pr_for_repo "org/repo"
    [ "${status}" -ne 0 ]
}

# --- find_ai_instructions (updated behaviour) ---------------------------------

@test "find_ai_instructions returns non-zero (not die) when neither path has .ai-instructions" {
    # Function should return 1 and emit a warning, not call die/exit.
    run find_ai_instructions
    [ "${status}" -ne 0 ]
    [[ "${output}" == *".ai-instructions"* ]]
}

# --- main() skip_repos integration tests -------------------------------------
# These tests exercise the multi-repo iteration logic in main() by overriding
# all external-call functions.  No PATH stubs are used — all overrides are
# function-level so no teardown stub cleanup is required beyond the common hook.

# Common overrides shared across main() integration tests.
# Call this inside each test after sourcing (i.e. after setup has run) to
# replace every function that performs real I/O.
setup_main_mocks() {
    check_required_tools()      { return 0; }
    set_repo_context()          { return 0; }
    ensure_rules_current()      { return 0; }
    ensure_repo_current()       { return 0; }
    find_ai_instructions()      { printf '/mock/.ai-instructions\n'; }
    load_session()              { SESSION_ID=""; }
    build_issue_prompt()        { printf 'mock-issue-prompt\n'; }
    build_pr_prompt()           { printf 'mock-pr-prompt\n'; }
    invoke_claude()             { printf '12345678-1234-1234-1234-123456789abc\n'; }
    save_session()              { return 0; }
    compute_pr_fingerprint()    { printf 'new-fp\n'; }
    compute_issue_fingerprint() { printf 'new-fp\n'; }
    save_pr_fingerprint()       { return 0; }
    save_issue_fingerprint()    { return 0; }
    tag_pr_closed_issue()       { return 0; }
    load_discord_config()       { return 0; }
    notify_discord_work_item()  { return 0; }
    notify_discord_no_work()    { return 0; }
}

@test "main is_skipped resets between iterations so different-repo items are not incorrectly skipped" {
    # Three-item scenario that exercises the is_skipped reset:
    # Item 1 (PR #5, org/repo): non-blocked, unchanged → skip_repos += org/repo (is_skipped stays false)
    # Item 2 (Issue #10, org/repo): for-loop matches skip_repos → is_skipped=true → "active work" skip
    # Item 3 (Issue #20, other/repo): is_skipped must be reset to false; without the reset it stays
    #   true from iteration 2 and incorrectly skips this different-repo item.
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false},{"id":10,"itemType":"Issue","repository":"org/repo","priority":2,"status":"Open","isOnHold":false},{"id":20,"itemType":"Issue","repository":"other/repo","priority":3,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json()             { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}\n'; }
    pr_json_has_blocked_label() { return 1; }
    fingerprint_pr_json()       { printf 'fp-same\n'; }
    load_pr_fingerprint()       { printf 'fp-same\n'; }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json()          { printf '{"title":"T","body":"","state":"OPEN","labels":[{"name":"Blocked"}],"comments":[],"assignees":[],"milestone":null}\n'; }
    issue_json_has_blocked_label() { return 0; }

    run main
    [ "${status}" -eq 0 ]
    # Item 1: PR unchanged → skip_repos += org/repo
    [[ "${output}" == *"PR #5 in org/repo unchanged"* ]]
    # Item 2: Issue #10 correctly skipped via skip_repos (is_skipped=true at end of this iteration)
    [[ "${output}" == *"Skipping Issue #10 in org/repo — repo already has active work"* ]]
    # Item 3: Issue #20 must be evaluated (is_skipped reset to false) and hit the "blocked" path
    [[ "${output}" == *"Issue #20 in other/repo is blocked — skipping"* ]]
    # Must NOT see "repo already has active work" for other/repo (that would be the stale-is_skipped bug)
    [[ "${output}" != *"Skipping Issue #20 in other/repo — repo already has active work"* ]]
    [[ "${output}" == *"No actionable work items found"* ]]
}

@test "main skips same-repo issue when repo has a non-blocked unchanged PR in priorities" {
    # Item 1 (PR #5, org/repo): open, non-blocked, unchanged → skip_repos += org/repo, continue
    # Item 2 (Issue #10, org/repo): same repo → skipped with "repo already has active work"
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false},{"id":10,"itemType":"Issue","repository":"org/repo","priority":2,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json()             { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}\n'; }
    pr_json_has_blocked_label() { return 1; }
    fingerprint_pr_json()       { printf 'fp-same\n'; }
    load_pr_fingerprint()       { printf 'fp-same\n'; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PR #5 in org/repo unchanged — skipping"* ]]
    [[ "${output}" == *"Skipping Issue #10 in org/repo — repo already has active work"* ]]
    [[ "${output}" == *"No actionable work items found"* ]]
}

@test "main does not add repo to skip_repos for a blocked PR in priorities so same-repo issue is still evaluated" {
    # Item 1 (PR #5, org/repo): blocked → skipped, NOT added to skip_repos
    # Item 2 (Issue #10, org/repo): must be evaluated; here it is also blocked → no work
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false},{"id":10,"itemType":"Issue","repository":"org/repo","priority":2,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json()             { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[{"name":"Blocked"}],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}\n'; }
    pr_json_has_blocked_label() { return 0; }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json()          { printf '{"title":"T","body":"","state":"OPEN","labels":[{"name":"Blocked"}],"comments":[],"assignees":[],"milestone":null}\n'; }
    issue_json_has_blocked_label() { return 0; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PR #5 in org/repo is blocked — skipping (not counting as active work)"* ]]
    # Issue #10 must be evaluated (not falsely skipped due to skip_repos from the blocked PR)
    [[ "${output}" == *"Issue #10 in org/repo is blocked — skipping"* ]]
    [[ "${output}" != *"Skipping Issue #10 in org/repo — repo already has active work"* ]]
    [[ "${output}" == *"No actionable work items found"* ]]
}

@test "main does not add repo to skip_repos when switched-to PR is no longer open" {
    # Item 1 (Issue #10, org/repo): issue is open+unblocked, finds PR #99 via list (open at
    #   list time), but fetch returns MERGED — race condition.  Repo must NOT be added to
    #   skip_repos.
    # Item 2 (Issue #20, org/repo): same repo must still be evaluated; second call to
    #   find_open_nonblocked_pr_for_repo returns empty (PR gone); issue is blocked → no work.
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false},{"id":20,"itemType":"Issue","repository":"org/repo","priority":2,"status":"Open","isOnHold":false}]'
    }
    # The function is called via $(...) substitution (subshell), so incrementing a variable
    # inside the function would not persist.  Use a temp file as a persistent call counter.
    local _pr_call_file="${TEST_TMP}/_pr_call"
    printf '0' > "${_pr_call_file}"
    find_open_nonblocked_pr_for_repo() {
        local _count
        _count=$(cat "${_pr_call_file}")
        _count=$((_count + 1))
        printf '%d' "${_count}" > "${_pr_call_file}"
        [ "${_count}" -eq 1 ] && printf '99\n' || printf ''
    }
    fetch_pr_json() { printf '{"state":"MERGED","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}\n'; }
    # Issue #10 (first call, pivot path): open, not blocked — allows the PR-state check to fire.
    # Issue #20 (second call, no-PR path): open, blocked.
    local _issue_call_file="${TEST_TMP}/_issue_call"
    printf '0' > "${_issue_call_file}"
    fetch_issue_json() {
        local _count
        _count=$(cat "${_issue_call_file}")
        _count=$((_count + 1))
        printf '%d' "${_count}" > "${_issue_call_file}"
        if [ "${_count}" -eq 1 ]; then
            printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'
        else
            printf '{"title":"T","body":"","state":"OPEN","labels":[{"name":"Blocked"}],"comments":[],"assignees":[],"milestone":null}\n'
        fi
    }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PR #99 in org/repo is no longer open — skipping"* ]]
    # Issue #20 must be evaluated (repo NOT in skip_repos)
    [[ "${output}" == *"Issue #20 in org/repo is blocked — skipping"* ]]
    [[ "${output}" != *"Skipping Issue #20 in org/repo — repo already has active work"* ]]
    [[ "${output}" == *"No actionable work items found"* ]]
}

@test "main skips same-repo issue when linked PR found via issue-to-PR pivot is unchanged" {
    # Item 1 (Issue #10, org/repo): find_open_nonblocked_pr_for_repo returns PR #99.
    #   Issue is open and unblocked; PR is open, non-blocked, fingerprint matches saved
    #   → "unchanged — skipping repo".  org/repo is added to skip_repos.
    # Item 2 (Issue #20, org/repo): same repo → "repo already has active work".
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false},{"id":20,"itemType":"Issue","repository":"org/repo","priority":2,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf '99\n'; }
    fetch_issue_json()          { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    fetch_pr_json()             { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}\n'; }
    pr_json_has_blocked_label() { return 1; }
    fingerprint_pr_json()       { printf 'fp-same\n'; }
    load_pr_fingerprint()       { printf 'fp-same\n'; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PR #99 in org/repo unchanged — skipping repo"* ]]
    [[ "${output}" == *"Skipping Issue #20 in org/repo — repo already has active work"* ]]
    [[ "${output}" == *"No actionable work items found"* ]]
}

# --- repository name validation -----------------------------------------------

@test "main dies on malformed repository name from priorities API (path traversal)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":1,"itemType":"Issue","repository":"../evil/path","priority":1,"status":"Open","isOnHold":false}]'
    }
    run main
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Malformed repository from priorities API"* ]]
}

@test "main dies on repository name with no slash from priorities API" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":1,"itemType":"Issue","repository":"noslash","priority":1,"status":"Open","isOnHold":false}]'
    }
    run main
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Malformed repository from priorities API"* ]]
}

@test "main accepts a well-formed owner/repo name from priorities API" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":1,"itemType":"Issue","repository":"org/my-repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[{"name":"Blocked"}],"comments":[],"assignees":[],"milestone":null}\n'; }
    issue_json_has_blocked_label() { return 0; }

    run main
    [ "${status}" -eq 0 ]
    # Valid repo name accepted — issue processed (then skipped as blocked)
    [[ "${output}" == *"Issue #1 in org/my-repo is blocked"* ]]
}

@test "main accepts a repo name starting with underscore from priorities API" {
    # GitHub allows repo names like _git_ignore_patterns — must not die with "Malformed"
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":1,"itemType":"Issue","repository":"isaacs/_git_ignore_patterns","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[{"name":"Blocked"}],"comments":[],"assignees":[],"milestone":null}\n'; }
    issue_json_has_blocked_label() { return 0; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"Malformed repository from priorities API"* ]]
    [[ "${output}" == *"Issue #1 in isaacs/_git_ignore_patterns is blocked"* ]]
}

# --- issue-to-PR pivot: issue state/blocked checks ----------------------------

@test "main tags PR for investigation and skips when linked issue is no longer open" {
    # Issue #10 has a linked open PR #99, but the issue itself is CLOSED.
    # Expect: tag_pr_closed_issue called, no Claude invocation, repo not in skip_repos.
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf '99\n'; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"CLOSED","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    local _tag_log="${TEST_TMP}/tag_log"
    tag_pr_closed_issue() { printf 'pr=%s issue=%s\n' "$1" "$2" >> "${_tag_log}"; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Issue #10 in org/repo is no longer open"* ]]
    [[ "${output}" == *"PR #99"* ]]
    [[ "${output}" != *"Starting new Claude session"* ]]
    [[ "${output}" == *"No actionable work items found"* ]]
    grep -q 'pr=99 issue=10' "${_tag_log}"
}

@test "main skips issue-to-PR pivot without tagging PR when issue is blocked" {
    # Issue #10 has a linked open PR #99, but the issue is blocked.
    # Expect: blocked skip message, no tagging, no Claude invocation.
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf '99\n'; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[{"name":"Blocked"}],"comments":[],"assignees":[],"milestone":null}\n'; }
    local _tag_log="${TEST_TMP}/tag_log"
    tag_pr_closed_issue() { printf 'pr=%s issue=%s\n' "$1" "$2" >> "${_tag_log}"; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Issue #10 in org/repo is blocked — skipping"* ]]
    [[ "${output}" != *"switching to PR workflow"* ]]
    [[ "${output}" != *"Starting new Claude session"* ]]
    [[ "${output}" == *"No actionable work items found"* ]]
    [ ! -f "${_tag_log}" ] || [ ! -s "${_tag_log}" ]
}

# --- load_discord_config ------------------------------------------------------

@test "load_discord_config sets DISCORD_WEBHOOK_URL from env file" {
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf 'DISCORD_WEBHOOK=https://discord.example.com/webhook/123\n' \
        > "${XDG_CONFIG_HOME}/orchestrator/.env"
    DISCORD_WEBHOOK_URL=""
    load_discord_config
    [ "${DISCORD_WEBHOOK_URL}" = "https://discord.example.com/webhook/123" ]
}

@test "load_discord_config strips double quotes from value" {
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf 'DISCORD_WEBHOOK="https://discord.example.com/webhook/456"\n' \
        > "${XDG_CONFIG_HOME}/orchestrator/.env"
    DISCORD_WEBHOOK_URL=""
    load_discord_config
    [ "${DISCORD_WEBHOOK_URL}" = "https://discord.example.com/webhook/456" ]
}

@test "load_discord_config strips single quotes from value" {
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf "DISCORD_WEBHOOK='https://discord.example.com/webhook/789'\n" \
        > "${XDG_CONFIG_HOME}/orchestrator/.env"
    DISCORD_WEBHOOK_URL=""
    load_discord_config
    [ "${DISCORD_WEBHOOK_URL}" = "https://discord.example.com/webhook/789" ]
}

@test "load_discord_config leaves DISCORD_WEBHOOK_URL empty when file is absent" {
    DISCORD_WEBHOOK_URL="should-be-cleared"
    load_discord_config
    [ -z "${DISCORD_WEBHOOK_URL}" ]
}

@test "load_discord_config leaves DISCORD_WEBHOOK_URL empty when key is absent from file" {
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf 'OTHER_KEY=some-value\n' > "${XDG_CONFIG_HOME}/orchestrator/.env"
    DISCORD_WEBHOOK_URL="should-be-cleared"
    load_discord_config
    [ -z "${DISCORD_WEBHOOK_URL}" ]
}

# --- notify_discord_work_item -------------------------------------------------

@test "notify_discord_work_item does not call curl when DISCORD_WEBHOOK_URL is empty" {
    DISCORD_WEBHOOK_URL=""
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_work_item "start" "Issue" "42" "Fix the bug"
    [ "${status}" -eq 0 ]
    [ ! -f "${args_log}" ]
}

@test "notify_discord_work_item calls curl with embed payload for Issue start" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_work_item "start" "Issue" "42" "Fix the bug"
    [ "${status}" -eq 0 ]
    grep -q "https://discord.example.com/hook" "${args_log}"
    grep -q "Fix the bug" "${args_log}"
    grep -q "https://github.com/org/repo/issues/42" "${args_log}"
    grep -q "New" "${args_log}"
}

@test "notify_discord_work_item calls curl with embed payload for PullRequest resume" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_work_item "resume" "PullRequest" "7" "Update deps"
    [ "${status}" -eq 0 ]
    grep -q "https://github.com/org/repo/pull/7" "${args_log}"
    grep -q "Resume" "${args_log}"
    grep -q "Update deps" "${args_log}"
}

# --- notify_discord_no_work ---------------------------------------------------

@test "notify_discord_no_work does not call curl when DISCORD_WEBHOOK_URL is empty" {
    DISCORD_WEBHOOK_URL=""
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_no_work
    [ "${status}" -eq 0 ]
    [ ! -f "${args_log}" ]
}

@test "notify_discord_no_work calls curl with content payload" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_no_work
    [ "${status}" -eq 0 ]
    grep -q "https://discord.example.com/hook" "${args_log}"
    grep -q "No actionable work items found" "${args_log}"
}

# --- main() Discord notification integration ----------------------------------

@test "main sends start notification when starting new work on an issue" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"Do the thing","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    load_session() { SESSION_ID=""; }
    local _notif_log="${TEST_TMP}/notif_log"
    notify_discord_work_item() { printf 'type=%s item=%s id=%s\n' "$1" "$2" "$3" >> "${_notif_log}"; }

    run main
    [ "${status}" -eq 0 ]
    grep -q 'type=start item=Issue id=10' "${_notif_log}"
}

@test "main sends resume notification when resuming existing work on an issue" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"Do the thing","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    load_session() { SESSION_ID="aaaabbbb-cccc-dddd-eeee-ffffffffffff"; }
    local _notif_log="${TEST_TMP}/notif_log"
    notify_discord_work_item() { printf 'type=%s item=%s id=%s\n' "$1" "$2" "$3" >> "${_notif_log}"; }

    run main
    [ "${status}" -eq 0 ]
    grep -q 'type=resume item=Issue id=10' "${_notif_log}"
}

@test "main sends no-work notification when no actionable items found" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[{"name":"Blocked"}],"comments":[],"assignees":[],"milestone":null}\n'; }
    local _notif_log="${TEST_TMP}/notif_log"
    notify_discord_no_work() { printf 'no_work\n' >> "${_notif_log}"; }

    run main
    [ "${status}" -eq 0 ]
    grep -q 'no_work' "${_notif_log}"
}
