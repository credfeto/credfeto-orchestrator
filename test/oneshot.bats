#!/usr/bin/env bats
# shellcheck disable=SC2329  # functions in @test bodies are invoked indirectly via 'run'
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are used inside run() subshells where shellcheck cannot trace them

load test_helper

setup() {
    setup_isolated_env
    source_oneshot
}

teardown() {
    cleanup_stubs
}

# --- prompt building (minimal bootstrap prompts) ---------------------------

@test "build_issue_prompt includes issue number, repo, and work dir" {
    run build_issue_prompt 42 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"issue #42"* ]]
    [[ "${output}" == *"${REPO_FULL}"* ]]
    [[ "${output}" == *"${REPO_WORK_DIR}"* ]]
}

@test "build_issue_prompt does not include detailed instructions (those are in CLAUDE.md)" {
    run build_issue_prompt 42 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"--add-label Blocked"* ]]
    [[ "${output}" != *"Read AI instructions"* ]]
    [[ "${output}" != *"mandatory rules"* ]]
}

@test "build_pr_prompt includes PR number, repo, and work dir" {
    run build_pr_prompt 7 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"pull request #7"* ]]
    [[ "${output}" == *"${REPO_FULL}"* ]]
    [[ "${output}" == *"${REPO_WORK_DIR}"* ]]
}

@test "build_pr_prompt does not include detailed instructions (those are in CLAUDE.md)" {
    run build_pr_prompt 7 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"--add-label Blocked"* ]]
    [[ "${output}" != *"Read AI instructions"* ]]
    [[ "${output}" != *"mandatory rules"* ]]
}

@test "build_pr_prompt with BEHIND merge state does not include rebase notice (moved to CLAUDE.md)" {
    run build_pr_prompt 7 "/resolved/.ai-instructions" "BEHIND" "feat/my-branch"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"force-with-lease"* ]]
    [[ "${output}" != *"BEHIND"* ]]
}

@test "build_pr_prompt with CLEAN merge state does not include rebase notice" {
    run build_pr_prompt 7 "/resolved/.ai-instructions" "CLEAN" ""
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"force-with-lease"* ]]
    [[ "${output}" != *"BEHIND"* ]]
}

@test "build_pr_prompt with DIRTY merge state does not include rebase notice (moved to CLAUDE.md)" {
    run build_pr_prompt 7 "/resolved/.ai-instructions" "DIRTY" "feat/my-branch"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"force-with-lease"* ]]
    [[ "${output}" != *"DIRTY"* ]]
}

@test "build_issue_prompt uses provided repo_path instead of REPO_WORK_DIR" {
    run build_issue_prompt 42 "/workspace/rules/.ai-instructions" "/workspace/repo"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"/workspace/repo"* ]]
    [[ "${output}" != *"${REPO_WORK_DIR}"* ]]
}

@test "build_pr_prompt uses provided repo_path" {
    run build_pr_prompt 7 "/workspace/rules/.ai-instructions" "BEHIND" "feat/my-branch" "/workspace/repo"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"/workspace/repo"* ]]
    [[ "${output}" != *"${REPO_WORK_DIR}"* ]]
}

# --- CLAUDE.md content building -------------------------------------------

@test "build_issue_claude_md includes role, ai instructions, issue number, repo, work dir and steps" {
    run build_issue_claude_md 42 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Orchestrator agent"* ]]
    [[ "${output}" == *"issue #42"* ]]
    [[ "${output}" == *"${REPO_FULL}"* ]]
    [[ "${output}" == *"${REPO_WORK_DIR}"* ]]
    [[ "${output}" == *"--add-label Blocked"* ]]
    [[ "${output}" == *"gh issue edit 42 --repo ${REPO_FULL} --add-label Blocked"* ]]
    [[ "${output}" == *"Read AI instructions from /resolved/.ai-instructions"* ]]
}

@test "build_issue_claude_md references AI instructions for CLI and label rules" {
    run build_issue_claude_md 42 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"mandatory rules from the AI instructions"* ]]
    [[ "${output}" == *"GitHub CLI comment bodies"* ]]
    [[ "${output}" == *"label management"* ]]
}

@test "build_issue_claude_md uses provided repo_path instead of REPO_WORK_DIR" {
    run build_issue_claude_md 42 "/workspace/rules/.ai-instructions" "/workspace/repo"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"/workspace/repo"* ]]
    [[ "${output}" != *"${REPO_WORK_DIR}"* ]]
}

@test "build_issue_claude_md warns against branch-name poll patterns in Monitor loops" {
    run build_issue_claude_md 42 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"branch names contain slashes"* ]]
    [[ "${output}" == *"foreground"* ]]
}

@test "build_issue_claude_md omits trusted-commenters section when logins list is empty" {
    run build_issue_claude_md 42 "/resolved/.ai-instructions" "" ""
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"Trusted commenters"* ]]
}

@test "build_issue_claude_md includes trusted-commenters section listing supplied logins" {
    run build_issue_claude_md 42 "/resolved/.ai-instructions" "" "false" '["alice","bob"]'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Trusted commenters"* ]]
    [[ "${output}" == *"- alice"* ]]
    [[ "${output}" == *"- bob"* ]]
}

@test "build_pr_claude_md omits trusted-commenters section when logins list is empty" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false" ""
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"Trusted commenters"* ]]
}

@test "build_pr_claude_md includes trusted-commenters section listing supplied logins" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false" '["alice","bob"]'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Trusted commenters"* ]]
    [[ "${output}" == *"- alice"* ]]
    [[ "${output}" == *"- bob"* ]]
}

@test "build_pr_claude_md includes role, ai instructions, PR number, repo, work dir and steps" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Orchestrator agent"* ]]
    [[ "${output}" == *"pull request #7"* ]]
    [[ "${output}" == *"${REPO_FULL}"* ]]
    [[ "${output}" == *"${REPO_WORK_DIR}"* ]]
    [[ "${output}" == *"gh pr edit 7 --repo ${REPO_FULL} --add-label Blocked"* ]]
    [[ "${output}" == *"Read AI instructions from /resolved/.ai-instructions"* ]]
    [[ "${output}" == *"gh pr ready 7 --repo ${REPO_FULL}"* ]]
}

@test "build_pr_claude_md references AI instructions for CLI, label, and CI rules" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"mandatory rules from the AI instructions"* ]]
    [[ "${output}" == *"GitHub CLI comment bodies"* ]]
    [[ "${output}" == *"label management"* ]]
    [[ "${output}" == *"CI checks"* ]]
}

@test "build_pr_claude_md warns against branch-name poll patterns in Monitor loops" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"branch names contain slashes"* ]]
    [[ "${output}" == *"foreground"* ]]
}

@test "build_pr_claude_md with BEHIND merge state includes rebase notice with branch name and force-with-lease" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "BEHIND" "feat/my-branch"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"BEHIND"* ]]
    [[ "${output}" == *"feat/my-branch"* ]]
    [[ "${output}" == *"force-with-lease"* ]]
    [[ "${output}" == *"rebase origin/main"* ]]
}

@test "build_pr_claude_md with CLEAN merge state does not include rebase notice" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" ""
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"force-with-lease"* ]]
    [[ "${output}" != *"BEHIND"* ]]
    [[ "${output}" != *"rebase origin/main"* ]]
}

@test "build_pr_claude_md with DIRTY merge state includes rebase notice with branch name and force-with-lease" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "DIRTY" "feat/my-branch"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"DIRTY"* ]]
    [[ "${output}" == *"feat/my-branch"* ]]
    [[ "${output}" == *"force-with-lease"* ]]
    [[ "${output}" == *"rebase origin/main"* ]]
}

@test "build_pr_claude_md uses provided repo_path in rebase notice" {
    run build_pr_claude_md 7 "/workspace/rules/.ai-instructions" "BEHIND" "feat/my-branch" "/workspace/repo"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"/workspace/repo"* ]]
    [[ "${output}" != *"${REPO_WORK_DIR}"* ]]
    [[ "${output}" == *"feat/my-branch"* ]]
    [[ "${output}" == *"force-with-lease"* ]]
}

@test "build_pr_claude_md includes auto-merge step for regular PRs" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"gh pr merge --auto --merge 7 --repo ${REPO_FULL}"* ]]
    [[ "${output}" == *"gh pr ready 7 --repo ${REPO_FULL}"* ]]
}

@test "build_pr_claude_md for dependency PR generates compact instructions without code-work steps" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "true"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"dependency update PR"* ]]
    [[ "${output}" == *"Do NOT make any code changes"* ]]
    [[ "${output}" == *"gh pr merge --auto --merge 7 --repo ${REPO_FULL}"* ]]
    [[ "${output}" == *"gh pr edit 7 --repo ${REPO_FULL} --add-label Blocked"* ]]
    [[ "${output}" != *"mandatory rules from the AI instructions"* ]]
    [[ "${output}" != *"force-with-lease"* ]]
}

@test "build_pr_claude_md for dependency PR instructs agent to stop if CI is still pending" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "true"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PENDING"* ]]
    [[ "${output}" == *"stop without taking action"* ]]
}

@test "build_pr_claude_md for dependency PR skips rebase steps even when merge state is BEHIND" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "BEHIND" "feat/my-branch" "" "" "true"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"force-with-lease"* ]]
    [[ "${output}" != *"rebase origin/main"* ]]
}

@test "main passes DIRTY merge state and branch name to build_pr_claude_md" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json()           { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[],"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY"}\n'; }
    fingerprint_pr_json()     { printf 'fp-new\n'; }
    load_pr_fingerprint()     { printf 'fp-old\n'; }
    # Use TEST_TMP directly (exported) to avoid local-variable subprocess isolation issue.
    build_pr_claude_md() { printf 'merge_state=%s branch=%s\n' "$3" "$4" > "${TEST_TMP}/claude_md_log"; printf 'mock-pr-claude-md\n'; }

    run main
    [ "${status}" -eq 0 ]
    grep -q 'merge_state=DIRTY' "${TEST_TMP}/claude_md_log"
    grep -q 'branch=feat/test' "${TEST_TMP}/claude_md_log"
}

@test "main performs non-agentic rebase for BEHIND PR, saves fingerprint, and continues without invoking agent" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false},{"id":10,"itemType":"Issue","repository":"other/repo","priority":2,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json()        { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[],"mergeable":"MERGEABLE","mergeStateStatus":"BEHIND"}\n'; }
    fingerprint_pr_json()  { printf 'fp-new\n'; }
    load_pr_fingerprint()  { printf 'fp-old\n'; }
    try_nonagentic_rebase() { return 0; }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[{"name":"Blocked"}],"comments":[],"assignees":[],"milestone":null}\n'; }
    issue_json_has_blocked_label() { return 0; }
    # Use TEST_TMP directly (exported) to avoid local-variable subprocess isolation issue.
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"rebased non-agentically"* ]]
    [ ! -f "${TEST_TMP}/claude_log" ]
}

@test "main passes BEHIND merge state and branch name to build_pr_claude_md" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json()           { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[],"mergeable":"MERGEABLE","mergeStateStatus":"BEHIND"}\n'; }
    fingerprint_pr_json()     { printf 'fp-new\n'; }
    load_pr_fingerprint()     { printf 'fp-old\n'; }
    # Use TEST_TMP directly (exported) to avoid local-variable subprocess isolation issue.
    build_pr_claude_md() { printf 'merge_state=%s branch=%s\n' "$3" "$4" > "${TEST_TMP}/claude_md_log"; printf 'mock-pr-claude-md\n'; }

    run main
    [ "${status}" -eq 0 ]
    grep -q 'merge_state=BEHIND' "${TEST_TMP}/claude_md_log"
    grep -q 'branch=feat/test' "${TEST_TMP}/claude_md_log"
}

# --- --owner argument ---------------------------------------------------------

@test "main --owner filters priorities to only items from that owner" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":1,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false},{"id":2,"itemType":"Issue","repository":"other/repo2","priority":2,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[{"name":"Blocked"}],"comments":[],"assignees":[],"milestone":null}\n'; }

    run main --owner org
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"org/repo"* ]]
    [[ "${output}" != *"other/repo2"* ]]
    [[ "${output}" == *"No actionable work items found"* ]]
}

@test "main --owner with no value dies" {
    setup_main_mocks
    run main --owner
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"--owner requires a value"* ]]
}

@test "main with an unknown argument dies" {
    setup_main_mocks
    run main --unknown-flag
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Unknown argument"* ]]
}

@test "main --owner with invalid characters dies" {
    setup_main_mocks
    run main --owner "evil;rm"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"invalid characters"* ]]
}

@test "main exits cleanly when another instance holds the lock" {
    setup_main_mocks
    # Hold the lock in a background process so main's flock --nonblock fails.
    local lock_dir="${HOME}/.orchestrator/locks"
    mkdir -p "${lock_dir}"
    # Use a subshell holding fd 9 for the duration of the test.
    exec 9>"${lock_dir}/_global.lock"
    flock --exclusive 9
    # Remove the flock stub so the real flock binary is used.
    rm -f "${STUB_BIN}/flock"

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"already running"* ]]

    # Release lock.
    exec 9>&-
}

@test "main without --owner processes items from all owners" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":1,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false},{"id":2,"itemType":"Issue","repository":"other/repo2","priority":2,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[{"name":"Blocked"}],"comments":[],"assignees":[],"milestone":null}\n'; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"org/repo"* ]]
    [[ "${output}" == *"other/repo2"* ]]
    [[ "${output}" == *"No actionable work items found"* ]]
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

# --- host_to_container_path ---------------------------------------------------

@test "host_to_container_path maps REPO_WORK_DIR to CONTAINER_REPO_PATH" {
    run host_to_container_path "${REPO_WORK_DIR}/.ai-instructions"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${CONTAINER_REPO_PATH}/.ai-instructions" ]
}

@test "host_to_container_path maps REPO_WORK_DIR exactly to CONTAINER_REPO_PATH" {
    run host_to_container_path "${REPO_WORK_DIR}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${CONTAINER_REPO_PATH}" ]
}

@test "host_to_container_path maps RULES_DIR to CONTAINER_RULES_PATH" {
    run host_to_container_path "${RULES_DIR}/.ai-instructions"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${CONTAINER_RULES_PATH}/.ai-instructions" ]
}

@test "host_to_container_path returns path unchanged when not matching a known dir" {
    run host_to_container_path "/some/other/path"
    [ "${status}" -eq 0 ]
    [ "${output}" = "/some/other/path" ]
}

@test "host_to_container_path prefers REPO_WORK_DIR over RULES_DIR when path starts with both" {
    # Construct a path that starts with REPO_WORK_DIR (which is a prefix match test).
    # Since REPO_WORK_DIR is checked first, it wins.
    run host_to_container_path "${REPO_WORK_DIR}/subdir"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${CONTAINER_REPO_PATH}/subdir" ]
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
        if [ "$1" = "-v" ] && [ "$2" = "podman" ]; then
            return 1
        fi
        builtin command "$@"
    }
    run check_required_tools
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Required tool not found: podman"* ]]
}

@test "check_required_tools dies when timeout is missing" {
    make_stub curl 'exit 0'
    make_stub jq 'exit 0'
    make_stub podman 'exit 0'
    make_stub gh 'exit 0'
    make_stub git 'exit 0'
    make_stub awk 'exit 0'
    make_stub grep 'exit 0'
    make_stub flock 'exit 0'
    # shellcheck disable=SC2329
    command() {
        if [ "$1" = "-v" ] && [ "$2" = "timeout" ]; then
            return 1
        fi
        builtin command "$@"
    }
    export -f command
    run check_required_tools
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Required tool not found: timeout"* ]]
}

@test "check_required_tools succeeds when all tools are present" {
    make_stub curl 'exit 0'
    make_stub jq 'exit 0'
    make_stub podman 'exit 0'
    make_stub gh 'exit 0'
    make_stub git 'exit 0'
    make_stub awk 'exit 0'
    make_stub grep 'exit 0'
    make_stub flock 'exit 0'
    make_stub sha256sum 'exit 0'
    make_stub timeout 'exit 0'
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

@test "load_session discards a corrupted session file and resets SESSION_ID to empty" {
    local session_file="${SESSION_BASE_DIR}/Issue_9.env"
    mkdir -p "${SESSION_BASE_DIR}"
    # Write a file whose content is NOT a valid UUID (simulates podman pull output contamination)
    printf 'latest: Pulling from some/image\nlayer1: Pull complete\ndeadbeef-0000-0000-0000-000000000000\n' \
        > "${session_file}"

    SESSION_ID="sentinel"
    load_session Issue 9
    [ -z "${SESSION_ID}" ]
    [ ! -f "${session_file}" ]
}

@test "load_session discards a corrupted linked-issue session file and leaves SESSION_ID empty" {
    local linked_file="${SESSION_BASE_DIR}/Issue_5.env"
    mkdir -p "${SESSION_BASE_DIR}"
    printf 'not-a-uuid\n' > "${linked_file}"

    make_stub gh 'printf "5\n"'
    SESSION_ID="sentinel"
    load_session PullRequest 77
    [ -z "${SESSION_ID}" ]
    [ ! -f "${linked_file}" ]
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

@test "fingerprint_pr_json changes when autoMergeRequest transitions from null to set" {
    local pr_no_automerge='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[],"autoMergeRequest":null}'
    local pr_with_automerge='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[],"autoMergeRequest":{"mergeMethod":"MERGE"}}'

    local fp1 fp2
    fp1=$(fingerprint_pr_json "${pr_no_automerge}")
    fp2=$(fingerprint_pr_json "${pr_with_automerge}")
    [ -n "${fp1}" ]
    [ "${fp1}" != "${fp2}" ]
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

@test "fingerprint_issue_json with trusted logins: trusted comment changes fingerprint" {
    local issue_base='{"title":"T","body":"B","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}'
    local issue_trusted='{"title":"T","body":"B","state":"OPEN","labels":[],"comments":[{"author":{"login":"owner"},"body":"hello","updatedAt":"2024-01-01T00:00:00Z"}],"assignees":[],"milestone":null}'
    local trusted='["owner"]'
    local fp_base fp_trusted
    fp_base=$(fingerprint_issue_json "${issue_base}" "${trusted}")
    fp_trusted=$(fingerprint_issue_json "${issue_trusted}" "${trusted}")
    [ "${fp_base}" != "${fp_trusted}" ]
}

@test "fingerprint_issue_json with trusted logins: untrusted comment does not change fingerprint" {
    local issue_base='{"title":"T","body":"B","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}'
    local issue_untrusted='{"title":"T","body":"B","state":"OPEN","labels":[],"comments":[{"author":{"login":"randomer"},"body":"hello","updatedAt":"2024-01-01T00:00:00Z"}],"assignees":[],"milestone":null}'
    local trusted='["owner"]'
    local fp_base fp_untrusted
    fp_base=$(fingerprint_issue_json "${issue_base}" "${trusted}")
    fp_untrusted=$(fingerprint_issue_json "${issue_untrusted}" "${trusted}")
    [ "${fp_base}" = "${fp_untrusted}" ]
}

@test "fingerprint_issue_json without trusted logins uses all comments" {
    local issue_base='{"title":"T","body":"B","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}'
    local issue_comment='{"title":"T","body":"B","state":"OPEN","labels":[],"comments":[{"author":{"login":"anyone"},"body":"hi","updatedAt":"2024-01-01T00:00:00Z"}],"assignees":[],"milestone":null}'
    local fp_base fp_with
    fp_base=$(fingerprint_issue_json "${issue_base}")
    fp_with=$(fingerprint_issue_json "${issue_comment}")
    [ "${fp_base}" != "${fp_with}" ]
}

@test "fingerprint_pr_json with trusted logins: trusted comment changes fingerprint" {
    local pr_base='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}'
    local pr_trusted='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[{"author":{"login":"owner"},"body":"lgtm","updatedAt":"2024-01-01T00:00:00Z"}],"reviews":[],"statusCheckRollup":[]}'
    local trusted='["owner"]'
    local fp_base fp_trusted
    fp_base=$(fingerprint_pr_json "${pr_base}" "${trusted}")
    fp_trusted=$(fingerprint_pr_json "${pr_trusted}" "${trusted}")
    [ "${fp_base}" != "${fp_trusted}" ]
}

@test "fingerprint_pr_json with trusted logins: untrusted comment does not change fingerprint" {
    local pr_base='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}'
    local pr_untrusted='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[{"author":{"login":"randomer"},"body":"spam","updatedAt":"2024-01-01T00:00:00Z"}],"reviews":[],"statusCheckRollup":[]}'
    local trusted='["owner"]'
    local fp_base fp_untrusted
    fp_base=$(fingerprint_pr_json "${pr_base}" "${trusted}")
    fp_untrusted=$(fingerprint_pr_json "${pr_untrusted}" "${trusted}")
    [ "${fp_base}" = "${fp_untrusted}" ]
}

@test "fingerprint_pr_json with trusted logins: trusted review changes fingerprint" {
    local pr_base='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}'
    local pr_review='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[{"author":{"login":"owner"},"state":"APPROVED","submittedAt":"2024-01-01T00:00:00Z"}],"statusCheckRollup":[]}'
    local trusted='["owner"]'
    local fp_base fp_review
    fp_base=$(fingerprint_pr_json "${pr_base}" "${trusted}")
    fp_review=$(fingerprint_pr_json "${pr_review}" "${trusted}")
    [ "${fp_base}" != "${fp_review}" ]
}

@test "fingerprint_pr_json with trusted logins: untrusted review does not change fingerprint" {
    local pr_base='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}'
    local pr_untrusted_review='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[{"author":{"login":"spammer"},"state":"CHANGES_REQUESTED","submittedAt":"2024-01-01T00:00:00Z"}],"statusCheckRollup":[]}'
    local trusted='["owner"]'
    local fp_base fp_untrusted
    fp_base=$(fingerprint_pr_json "${pr_base}" "${trusted}")
    fp_untrusted=$(fingerprint_pr_json "${pr_untrusted_review}" "${trusted}")
    [ "${fp_base}" = "${fp_untrusted}" ]
}

@test "fingerprint_pr_json without trusted logins uses all comments and reviews" {
    local pr_base='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}'
    local pr_review='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[{"author":{"login":"anyone"},"state":"APPROVED","submittedAt":"2024-01-01T00:00:00Z"}],"statusCheckRollup":[]}'
    local fp_base fp_review
    fp_base=$(fingerprint_pr_json "${pr_base}")
    fp_review=$(fingerprint_pr_json "${pr_review}")
    [ "${fp_base}" != "${fp_review}" ]
}

# --- get_trusted_logins --------------------------------------------------------

@test "get_trusted_logins includes OWNER" {
    set_repo_context "myorg/myrepo"
    WHITELISTED_USERS=""
    make_stub gh 'printf ""'
    local result
    result=$(get_trusted_logins)
    printf '%s' "${result}" | jq -e 'index("myorg") != null' > /dev/null
}

@test "get_trusted_logins includes repo collaborators from GitHub API" {
    set_repo_context "myorg/myrepo"
    WHITELISTED_USERS=""
    make_stub gh 'printf "collab1\ncollab2\n"'
    local result
    result=$(get_trusted_logins)
    printf '%s' "${result}" | jq -e 'index("collab1") != null' > /dev/null
    printf '%s' "${result}" | jq -e 'index("collab2") != null' > /dev/null
}

@test "get_trusted_logins includes copilot-pull-request-reviewer" {
    set_repo_context "myorg/myrepo"
    WHITELISTED_USERS=""
    make_stub gh 'printf ""'
    local result
    result=$(get_trusted_logins)
    printf '%s' "${result}" | jq -e 'index("copilot-pull-request-reviewer") != null' > /dev/null
}

@test "get_trusted_logins includes whitelisted users from WHITELISTED_USERS" {
    set_repo_context "myorg/myrepo"
    WHITELISTED_USERS="trusted1,trusted2"
    make_stub gh 'printf ""'
    local result
    result=$(get_trusted_logins)
    printf '%s' "${result}" | jq -e 'index("trusted1") != null' > /dev/null
    printf '%s' "${result}" | jq -e 'index("trusted2") != null' > /dev/null
}

@test "get_trusted_logins trims spaces from WHITELISTED_USERS entries" {
    set_repo_context "myorg/myrepo"
    WHITELISTED_USERS=" spaced1 , spaced2 "
    make_stub gh 'printf ""'
    local result
    result=$(get_trusted_logins)
    printf '%s' "${result}" | jq -e 'index("spaced1") != null' > /dev/null
    printf '%s' "${result}" | jq -e 'index("spaced2") != null' > /dev/null
}

@test "get_trusted_logins falls back gracefully when GitHub API fails" {
    set_repo_context "myorg/myrepo"
    WHITELISTED_USERS=""
    make_stub gh 'exit 1'
    local result
    result=$(get_trusted_logins)
    [ -n "${result}" ]
    printf '%s' "${result}" | jq -e 'index("myorg") != null' > /dev/null
}

@test "get_trusted_logins deduplicates logins when OWNER appears as a collaborator" {
    set_repo_context "myorg/myrepo"
    WHITELISTED_USERS=""
    make_stub gh 'printf "myorg\ncollab1\n"'
    local result
    result=$(get_trusted_logins)
    local count
    count=$(printf '%s' "${result}" | jq '[.[] | select(. == "myorg")] | length')
    [ "${count}" = "1" ]
}

@test "get_trusted_logins caches result so GitHub API is called only once per repo context" {
    set_repo_context "myorg/myrepo"
    WHITELISTED_USERS=""
    local call_log="${TEST_TMP}/gh_calls"
    make_stub gh "printf 'called\n' >> '${call_log}'; printf 'collab1\n'"

    _TRUSTED_LOGINS_JSON=""
    get_trusted_logins > /dev/null
    local first_calls
    first_calls=$(wc -l < "${call_log}" 2>/dev/null || printf '0')

    get_trusted_logins > /dev/null
    local second_calls
    second_calls=$(wc -l < "${call_log}" 2>/dev/null || printf '0')

    [ "${first_calls}" = "${second_calls}" ]
}

@test "compute_issue_fingerprint passes trusted logins from get_trusted_logins to fingerprint_issue_json" {
    local captured_trusted="none"
    fetch_issue_json() { printf '{"title":"T","body":"B","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    get_trusted_logins() { printf '["testowner"]\n'; }
    fingerprint_issue_json() { captured_trusted="${2:-missing}"; printf 'test-fp\n'; }
    compute_issue_fingerprint 42
    [ "${captured_trusted}" = '["testowner"]' ]
}

@test "compute_pr_fingerprint passes trusted logins from get_trusted_logins to fingerprint_pr_json" {
    local captured_trusted="none"
    fetch_pr_json() { printf '{"title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}\n'; }
    get_trusted_logins() { printf '["testowner"]\n'; }
    fingerprint_pr_json() { captured_trusted="${2:-missing}"; printf 'test-fp\n'; }
    compute_pr_fingerprint 5
    [ "${captured_trusted}" = '["testowner"]' ]
}

# --- model selection -----------------------------------------------------------

@test "invoke_claude passes --model opusplan to podman claude command for a new session" {
    local args_log="${TEST_TMP}/podman_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
[ "\$1" = "pull" ] && exit 0
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    invoke_claude "test prompt" "" "" "" "# mock CLAUDE.md" 2>/dev/null
    grep -qx -- '--model' "${args_log}"
    grep -qx 'opusplan' "${args_log}"
}

@test "invoke_claude passes --model opusplan to podman claude command when resuming a session" {
    local args_log="${TEST_TMP}/podman_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
[ "\$1" = "pull" ] && exit 0
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    invoke_claude "test prompt" "12345678-1234-1234-1234-123456789abc" "" "" "# mock CLAUDE.md" 2>/dev/null
    grep -qx -- '--model' "${args_log}"
    grep -qx 'opusplan' "${args_log}"
}

@test "invoke_claude passes resource limit flags to podman run" {
    local args_log="${TEST_TMP}/podman_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"
    # Stub jq to return canned values matching the podman stub's JSON output.
    # Needed in environments where jq is not installed.
    cat > "${STUB_BIN}/jq" << 'JQSTUB'
#!/usr/bin/env bash
# Minimal stub: reads the last argument (file path) and returns canned values
# for the specific queries invoke_claude makes in the happy path.
case "$*" in
    *".is_error"*)   printf 'false\n' ;;
    *".result"*)     printf 'done\n' ;;
    *".session_id"*) printf '12345678-1234-1234-1234-123456789abc\n' ;;
    *)               printf '\n' ;;
esac
JQSTUB
    chmod +x "${STUB_BIN}/jq"

    invoke_claude "test prompt" "" "" "" "# mock CLAUDE.md" 2>/dev/null
    [ -f "${args_log}" ]
    grep -qFx -- '--cpus=4' "${args_log}"
    grep -qFx -- '--memory=12g' "${args_log}"
    grep -qFx -- '--memory-swap=12g' "${args_log}"
    grep -qFx -- '--pids-limit=4096' "${args_log}"
    grep -qFx -- '--userns=keep-id:uid=1000,gid=1000' "${args_log}"
}

# --- invoke_claude error handling ---------------------------------------------

@test "invoke_claude fails fast before calling podman when prompt exceeds MAX_PROMPT_CHARS" {
    local args_log="${TEST_TMP}/podman_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
[ "\$1" = "pull" ] && exit 0
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    DISCORD_WEBHOOK_URL=""
    local long_prompt
    long_prompt=$(printf '%*s' $((MAX_PROMPT_CHARS + 1)) '' | tr ' ' 'x')
    run invoke_claude "${long_prompt}" "" "Issue" "1"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"too long"* ]]
    [ ! -f "${args_log}" ]
}

@test "invoke_claude sends Discord notification when prompt exceeds MAX_PROMPT_CHARS" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "pull" ] && exit 0
[ "$1" = "inspect" ] && exit 1
[ "$1" = "pull" ] && exit 0
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"

    local long_prompt
    long_prompt=$(printf '%*s' $((MAX_PROMPT_CHARS + 1)) '' | tr ' ' 'x')
    run invoke_claude "${long_prompt}" "" "Issue" "42"
    [ "${status}" -ne 0 ]
    grep -q "https://discord.example.com/hook" "${args_log}"
}

@test "invoke_claude dies and sends Discord notification when Claude returns is_error true" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "pull" ] && exit 0
[ "$1" = "inspect" ] && exit 1
[ "$1" = "pull" ] && exit 0
printf '{"is_error":true,"terminal_reason":"api_error","session_id":"12345678-1234-1234-1234-123456789abc","result":"API Error"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"

    run invoke_claude "test prompt" "" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"API Error"* ]]
    grep -q "https://discord.example.com/hook" "${args_log}"
}

@test "invoke_claude retries as new session when Claude returns blocking_limit on a resumed session" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "pull" ] && exit 0
[ "$1" = "inspect" ] && exit 1
[ "$1" = "pull" ] && exit 0
for arg; do
    [ "$arg" = "--resume" ] && { printf '{"is_error":true,"terminal_reason":"blocking_limit","session_id":"old-id","result":"Prompt is too long"}\n'; exit 0; }
done
printf '{"session_id":"aabbccdd-1122-3344-5566-778899aabbcc","result":"done","is_error":false}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    DISCORD_WEBHOOK_URL=""
    local result
    result=$(invoke_claude "test prompt" "11111111-1111-1111-1111-111111111111" "Issue" "42" "# mock CLAUDE.md" 2>/dev/null)
    [ "${result}" = "aabbccdd-1122-3344-5566-778899aabbcc" ]
}

@test "invoke_claude sends Discord notification when retrying after blocking_limit" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "pull" ] && exit 0
[ "$1" = "inspect" ] && exit 1
[ "$1" = "pull" ] && exit 0
for arg; do
    [ "$arg" = "--resume" ] && { printf '{"is_error":true,"terminal_reason":"blocking_limit","session_id":"old-id","result":"Prompt is too long"}\n'; exit 0; }
done
printf '{"session_id":"aabbccdd-1122-3344-5566-778899aabbcc","result":"done","is_error":false}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"

    invoke_claude "test prompt" "11111111-1111-1111-1111-111111111111" "Issue" "42" "# mock CLAUDE.md" 2>/dev/null
    grep -q "https://discord.example.com/hook" "${args_log}"
}

@test "invoke_claude dies with Discord notification on blocking_limit for a new session" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "pull" ] && exit 0
[ "$1" = "inspect" ] && exit 1
[ "$1" = "pull" ] && exit 0
printf '{"is_error":true,"terminal_reason":"blocking_limit","session_id":"12345678-1234-1234-1234-123456789abc","result":"Prompt is too long"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"

    run invoke_claude "test prompt" "" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -ne 0 ]
    grep -q "https://discord.example.com/hook" "${args_log}"
}

@test "invoke_claude dies if retry after blocking_limit also fails" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "pull" ] && exit 0
[ "$1" = "inspect" ] && exit 1
[ "$1" = "pull" ] && exit 0
printf '{"is_error":true,"terminal_reason":"blocking_limit","session_id":"12345678-1234-1234-1234-123456789abc","result":"Prompt is too long"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    DISCORD_WEBHOOK_URL=""
    run invoke_claude "test prompt" "11111111-1111-1111-1111-111111111111" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"failed after retry"* ]]
}

@test "invoke_claude retries as new session when Claude reports session no longer exists" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "pull" ] && exit 0
[ "$1" = "inspect" ] && exit 1
[ "$1" = "pull" ] && exit 0
for arg; do
    [ "$arg" = "--resume" ] && { printf 'No conversation found with session ID: 11111111-1111-1111-1111-111111111111\n' >&2; exit 1; }
done
printf '{"session_id":"aabbccdd-1122-3344-5566-778899aabbcc","result":"done","is_error":false}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    DISCORD_WEBHOOK_URL=""
    local result
    result=$(invoke_claude "test prompt" "11111111-1111-1111-1111-111111111111" "Issue" "42" "# mock CLAUDE.md" 2>/dev/null)
    [ "${result}" = "aabbccdd-1122-3344-5566-778899aabbcc" ]
}

@test "invoke_claude does not send Discord notification when retrying after invalid session" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "pull" ] && exit 0
[ "$1" = "inspect" ] && exit 1
[ "$1" = "pull" ] && exit 0
for arg; do
    [ "$arg" = "--resume" ] && { printf 'No conversation found with session ID: 11111111-1111-1111-1111-111111111111\n' >&2; exit 1; }
done
printf '{"session_id":"aabbccdd-1122-3344-5566-778899aabbcc","result":"done","is_error":false}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"

    invoke_claude "test prompt" "11111111-1111-1111-1111-111111111111" "Issue" "42" "# mock CLAUDE.md" 2>/dev/null
    run grep -q "https://discord.example.com/hook" "${args_log}"
    [ "${status}" -ne 0 ]
}

@test "invoke_claude dies with a timeout message when the container exceeds AGENT_TIMEOUT_MINUTES" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "pull" ] && exit 0
[ "$1" = "inspect" ] && exit 1
[ "$1" = "rm" ] && exit 0
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/podman"
    make_stub timeout 'exit 124'

    DISCORD_WEBHOOK_URL=""
    run invoke_claude "test prompt" "" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"timed out"* ]]
}

@test "invoke_claude sends Discord notification when the container times out" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "pull" ] && exit 0
[ "$1" = "inspect" ] && exit 1
[ "$1" = "rm" ] && exit 0
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/podman"
    make_stub timeout 'exit 124'

    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"

    run invoke_claude "test prompt" "" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -ne 0 ]
    grep -q "https://discord.example.com/hook" "${args_log}"
}

# --- notify_discord_claude_error -----------------------------------------------

@test "notify_discord_claude_error does not call curl when DISCORD_WEBHOOK_URL is empty" {
    DISCORD_WEBHOOK_URL=""
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_claude_error "Issue" "42" "Prompt is too long"
    [ "${status}" -eq 0 ]
    [ ! -f "${args_log}" ]
}

@test "notify_discord_claude_error calls curl with embed payload including issue URL and error message" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_claude_error "Issue" "42" "Prompt is too long"
    [ "${status}" -eq 0 ]
    grep -q "https://discord.example.com/hook" "${args_log}"
    grep -q "https://github.com/org/repo/issues/42" "${args_log}"
    grep -q "Prompt is too long" "${args_log}"
}

@test "notify_discord_claude_error calls curl with embed payload including PR URL" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_claude_error "PullRequest" "7" "API Error"
    [ "${status}" -eq 0 ]
    grep -q "https://github.com/org/repo/pull/7" "${args_log}"
    grep -q "API Error" "${args_log}"
}

@test "notify_discord_claude_error uses repo URL when item type is unknown" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_claude_error "" "" "Some error"
    [ "${status}" -eq 0 ]
    grep -q "https://github.com/org/repo" "${args_log}"
}

@test "invoke_claude uses container name orchestrator-OWNER" {
    local args_log="${TEST_TMP}/podman_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
[ "\$1" = "pull" ] && exit 0
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    invoke_claude "test prompt" "" "" "" "# mock CLAUDE.md" 2>/dev/null
    grep -qx 'orchestrator-credfeto' "${args_log}"
}

@test "invoke_claude mounts REPO_WORK_DIR read-write and RULES_DIR read-only" {
    local args_log="${TEST_TMP}/podman_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
[ "\$1" = "pull" ] && exit 0
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    invoke_claude "test prompt" "" "" "" "# mock CLAUDE.md" 2>/dev/null
    grep -qx "${REPO_WORK_DIR}:${CONTAINER_REPO_PATH}:rw" "${args_log}"
    grep -qx "${RULES_DIR}:${CONTAINER_RULES_PATH}:ro" "${args_log}"
}

@test "invoke_claude mounts .claude directory read-write when claude_md_content is provided" {
    local args_log="${TEST_TMP}/podman_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/jq" << 'JQEOF'
#!/usr/bin/env bash
case "$2" in
    '.is_error // false')    printf 'false\n' ;;
    '.result // ""')         printf '\n' ;;
    '.session_id // empty')  printf '12345678-1234-1234-1234-123456789abc\n' ;;
esac
JQEOF
    chmod +x "${STUB_BIN}/jq"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
[ "\$1" = "pull" ] && exit 0
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    invoke_claude "test prompt" "" "" "" "# per-item instructions" 2>/dev/null
    grep -q ':/home/developer/.claude:rw' "${args_log}"
}

@test "invoke_claude dies when claude_md_content is empty" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "inspect" ] && exit 1
[ "$1" = "pull" ] && exit 0
[ "$1" = "pull" ] && exit 0
STUBEOF
    chmod +x "${STUB_BIN}/podman"
    run invoke_claude "test prompt" "" "" "" ""
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"claude_md_content is required"* ]]
}

@test "invoke_claude cleans up CLAUDE_MD_TMPFILE after successful invocation" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/jq" << 'JQEOF'
#!/usr/bin/env bash
case "$2" in
    '.is_error // false')    printf 'false\n' ;;
    '.result // ""')         printf '\n' ;;
    '.session_id // empty')  printf '12345678-1234-1234-1234-123456789abc\n' ;;
esac
JQEOF
    chmod +x "${STUB_BIN}/jq"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "pull" ] && exit 0
[ "$1" = "inspect" ] && exit 1
[ "$1" = "pull" ] && exit 0
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    CLAUDE_MD_TMPFILE="sentinel"
    invoke_claude "test prompt" "" "" "" "# per-item instructions" 2>/dev/null
    [ -z "${CLAUDE_MD_TMPFILE}" ]
}

@test "invoke_claude mounts CLAUDE_MD_TMPFILE from XDG_RUNTIME_DIR when set" {
    local args_log="${TEST_TMP}/podman_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    export XDG_RUNTIME_DIR="${TEST_TMP}/runtime"
    mkdir -p "${XDG_RUNTIME_DIR}"
    cat > "${STUB_BIN}/jq" << 'JQEOF'
#!/usr/bin/env bash
case "$2" in
    '.is_error // false')    printf 'false\n' ;;
    '.result // ""')         printf '\n' ;;
    '.session_id // empty')  printf '12345678-1234-1234-1234-123456789abc\n' ;;
esac
JQEOF
    chmod +x "${STUB_BIN}/jq"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "${args_log}"
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"
    invoke_claude "test prompt" "" "" "" "# per-item instructions" 2>/dev/null
    grep -q "${XDG_RUNTIME_DIR}" "${args_log}"
}

@test "invoke_claude creates Podman secret and uses --secret for owner token instead of --env" {
    local args_log="${TEST_TMP}/podman_args"
    local secret_log="${TEST_TMP}/podman_secret"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator/tokens"
    printf 'my-claude-token\n' > "${XDG_CONFIG_HOME}/orchestrator/tokens/credfeto"
    chmod 600 "${XDG_CONFIG_HOME}/orchestrator/tokens/credfeto"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
if [ "\$1" = "secret" ]; then
    printf "%s\n" "\$@" >> "${secret_log}"
    exit 0
fi
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    invoke_claude "test prompt" "" "" "" "# mock CLAUDE.md" 2>/dev/null
    # Secret was created with the owner-scoped name
    grep -q "create" "${secret_log}"
    grep -q "claude-oauth-credfeto" "${secret_log}"
    # Token is NOT passed via --env
    run grep -q 'CLAUDE_CODE_OAUTH_TOKEN=' "${args_log}"
    [ "${status}" -ne 0 ]
    # --secret flag IS present in the podman run args
    grep -q 'claude-oauth-credfeto' "${args_log}"
}

@test "invoke_claude passes GH_ENTERPRISE_TOKEN via Podman secret instead of --env" {
    local args_log="${TEST_TMP}/podman_args"
    local secret_log="${TEST_TMP}/podman_secret"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    # shellcheck disable=SC2030
    GH_ENTERPRISE_TOKEN="my-gh-token"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
if [ "\$1" = "secret" ]; then
    printf "%s\n" "\$@" >> "${secret_log}"
    exit 0
fi
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    invoke_claude "test prompt" "" "" "" "# mock CLAUDE.md" 2>/dev/null
    # Secret was created with the enterprise token secret name
    grep -q "create" "${secret_log}"
    grep -q "gh-enterprise-token" "${secret_log}"
    # Token is NOT passed via --env
    run grep -q 'GH_ENTERPRISE_TOKEN=my-gh-token' "${args_log}"
    [ "${status}" -ne 0 ]
    # --secret flag IS present in the podman run args
    grep -q 'gh-enterprise-token' "${args_log}"
}

@test "invoke_claude passes --resume flag when session id is provided" {
    local args_log="${TEST_TMP}/podman_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
[ "\$1" = "pull" ] && exit 0
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    invoke_claude "test prompt" "12345678-1234-1234-1234-123456789abc" "" "" "# mock CLAUDE.md" 2>/dev/null
    grep -qx -- '--resume' "${args_log}"
    grep -qx '12345678-1234-1234-1234-123456789abc' "${args_log}"
}

@test "invoke_claude dies if container already exists" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "inspect" ] && exit 0
[ "$1" = "pull" ] && exit 0
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    run invoke_claude "test prompt" "" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"already exists"* ]]
}

@test "invoke_claude dies with specific message when podman run fails due to container name in use" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "pull" ] && exit 0
[ "$1" = "inspect" ] && exit 1
[ "$1" = "pull" ] && exit 0
printf 'Error: container name "orchestrator-credfeto" is already in use by container abc123def456\n' >&2
exit 1
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    run invoke_claude "test prompt" "" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"already in use"* ]]
}

@test "invoke_claude does not mount host .claude directory" {
    local args_log="${TEST_TMP}/podman_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}" "${HOME}/.claude"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
[ "\$1" = "pull" ] && exit 0
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    invoke_claude "test prompt" "" "" "" "# mock CLAUDE.md" 2>/dev/null
    run grep -q ".claude:/home/developer/.claude" "${args_log}"
    [ "${status}" -ne 0 ]
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

@test "set_repo_context resets _TRUSTED_LOGINS_JSON so get_trusted_logins refetches for each repo" {
    _TRUSTED_LOGINS_JSON='["stale-value"]'
    set_repo_context "neworg/newrepo"
    [ -z "${_TRUSTED_LOGINS_JSON}" ]
}

# --- fetch_all_priorities -----------------------------------------------------

@test "fetch_all_priorities returns all open and draft non-on-hold items in API order" {
    make_stub curl 'printf '"'"'{"priorities":[
        {"id":3,"itemType":"Issue","repository":"org/repo","status":"Open","isOnHold":false,"priority":3},
        {"id":1,"itemType":"Issue","repository":"org/repo","status":"Open","isOnHold":false,"priority":1},
        {"id":2,"itemType":"PullRequest","repository":"org/repo","status":"Draft","isOnHold":false,"priority":2},
        {"id":4,"itemType":"Issue","repository":"org/repo","status":"Closed","isOnHold":false,"priority":4},
        {"id":5,"itemType":"Issue","repository":"org/repo","status":"Open","isOnHold":true,"priority":0}
    ]}\n'"'"

    run fetch_all_priorities
    [ "${status}" -eq 0 ]
    # The 3 open/draft non-on-hold items appear in API order; Closed and on-hold are excluded
    local ids
    ids=$(printf '%s' "${output}" | jq -r '.[].id')
    [ "${ids}" = "$(printf '3\n1\n2')" ]
}

@test "fetch_all_priorities includes Draft items" {
    make_stub curl 'printf '"'"'{"priorities":[
        {"id":1,"itemType":"PullRequest","repository":"org/repo","status":"Draft","isOnHold":false,"priority":1},
        {"id":2,"itemType":"PullRequest","repository":"org/repo","status":"Open","isOnHold":false,"priority":2}
    ]}\n'"'"

    run fetch_all_priorities
    [ "${status}" -eq 0 ]
    local ids
    ids=$(printf '%s' "${output}" | jq -r '.[].id')
    [ "${ids}" = "$(printf '1\n2')" ]
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
    _GH_ME="testuser"
    make_stub gh 'printf '"'"'[{"number":42,"labels":[],"author":{"login":"testuser"}},{"number":99,"labels":[{"name":"enhancement"}],"author":{"login":"testuser"}}]\n'"'"
    run find_open_nonblocked_pr_for_repo "org/repo"
    [ "${status}" -eq 0 ]
    [ "${output}" = "42" ]
}

@test "find_open_nonblocked_pr_for_repo skips PRs with the Blocked label" {
    _GH_ME="testuser"
    make_stub gh 'printf '"'"'[{"number":7,"labels":[{"name":"Blocked"}],"author":{"login":"testuser"}},{"number":8,"labels":[],"author":{"login":"testuser"}}]\n'"'"
    run find_open_nonblocked_pr_for_repo "org/repo"
    [ "${status}" -eq 0 ]
    [ "${output}" = "8" ]
}

@test "find_open_nonblocked_pr_for_repo returns empty when all PRs are blocked" {
    _GH_ME="testuser"
    make_stub gh 'printf '"'"'[{"number":7,"labels":[{"name":"blocked"}],"author":{"login":"testuser"}}]\n'"'"
    run find_open_nonblocked_pr_for_repo "org/repo"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "find_open_nonblocked_pr_for_repo returns empty when no PRs exist" {
    _GH_ME="testuser"
    make_stub gh 'printf '"'"'[]\n'"'"
    run find_open_nonblocked_pr_for_repo "org/repo"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "find_open_nonblocked_pr_for_repo returns empty when all open PRs are by other authors" {
    _GH_ME="testuser"
    make_stub gh 'printf '"'"'[{"number":7,"labels":[],"author":{"login":"dependabot"}},{"number":8,"labels":[],"author":{"login":"github-actions"}}]\n'"'"
    run find_open_nonblocked_pr_for_repo "org/repo"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "find_open_nonblocked_pr_for_repo returns 1 when gh fails" {
    _GH_ME="testuser"
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
    make_stub flock 'exit 0'
    check_required_tools()      { return 0; }
    set_repo_context()          { return 0; }
    ensure_rules_current()      { return 0; }
    ensure_repo_current()       { return 0; }
    recover_orphaned_branch()   { return 1; }
    try_nonagentic_rebase()     { return 1; }
    find_ai_instructions()      { printf '/mock/.ai-instructions\n'; }
    host_to_container_path()    { printf '%s\n' "$1"; }
    load_session()              { SESSION_ID=""; }
    build_issue_prompt()        { printf 'mock-issue-prompt\n'; }
    build_pr_prompt()           { printf 'mock-pr-prompt\n'; }
    build_issue_claude_md()     { printf 'mock-issue-claude-md\n'; }
    build_pr_claude_md()        { printf 'mock-pr-claude-md\n'; }
    invoke_claude()             { printf '12345678-1234-1234-1234-123456789abc\n'; }
    save_session()              { return 0; }
    compute_pr_fingerprint()    { printf 'new-fp\n'; }
    compute_issue_fingerprint() { printf 'new-fp\n'; }
    save_pr_fingerprint()       { return 0; }
    save_issue_fingerprint()    { return 0; }
    fingerprint_issue_json()    { printf 'issue-fp-default\n'; }
    load_issue_fingerprint()    { printf ''; }
    tag_pr_closed_issue()       { return 0; }
    is_owner_rate_limited()       { return 1; }
    load_env_config()             { return 0; }
    validate_config()             { return 0; }
    get_trusted_logins()          { printf '["credfeto"]\n'; }
    notify_discord_work_item()         { return 0; }
    notify_discord_no_work()           { return 0; }
    notify_discord_blocked_item()      { return 0; }
    notify_discord_claude_error()      { return 0; }
    notify_discord_rate_limited()      { return 0; }
    notify_discord_low_disk_space()    { return 0; }
    check_disk_space()                 { return 0; }
    sync_pr_labels_from_linked_issues() { return 0; }
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

@test "main evaluates second PR in same repo when first PR is unchanged" {
    # Item 1 (PR #5, org/repo): open, non-blocked, unchanged → skip_repos += org/repo, continue
    # Item 2 (PR #17, org/repo): same repo — PRs bypass the skip_repos guard → evaluated
    #   PR #17 fingerprint differs from saved → actionable → Claude invoked → exit 0
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false},{"id":17,"itemType":"PullRequest","repository":"org/repo","priority":2,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json()             { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefName":"branch-17"}\n'; }
    pr_json_has_blocked_label() { return 1; }
    fingerprint_pr_json()       {
        # First call (PR #5): return saved fingerprint so it is unchanged.
        # Second call (PR #17): return a different fingerprint so it is actionable.
        local _fp_call_file="${TEST_TMP}/_fp_call"
        [ -f "${_fp_call_file}" ] || printf '0' > "${_fp_call_file}"
        local _count
        _count=$(cat "${_fp_call_file}")
        _count=$((_count + 1))
        printf '%d' "${_count}" > "${_fp_call_file}"
        [ "${_count}" -eq 1 ] && printf 'fp-same\n' || printf 'fp-new\n'
    }
    load_pr_fingerprint()       {
        # PR #5 has a saved fingerprint; PR #17 has none.
        [ "$1" = "5" ] && printf 'fp-same\n' || printf ''
    }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PR #5 in org/repo unchanged"* ]]
    [[ "${output}" != *"Skipping PullRequest #17 in org/repo — repo already has active work"* ]]
    [[ "${output}" == *"Found actionable PullRequest #17 in org/repo"* ]]
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
    #   Issue is open and unblocked; PR is open, non-blocked, fingerprint matches saved;
    #   issue fingerprint also matches saved → "unchanged — skipping repo".
    #   org/repo is added to skip_repos.
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
    fingerprint_issue_json()    { printf 'issue-fp-same\n'; }
    load_issue_fingerprint()    { printf 'issue-fp-same\n'; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PR #99 in org/repo unchanged — skipping repo"* ]]
    [[ "${output}" == *"Skipping Issue #20 in org/repo — repo already has active work"* ]]
    [[ "${output}" == *"No actionable work items found"* ]]
}

@test "main re-runs via pivot PR when PR unchanged but issue has new comment" {
    # Issue #10 has linked PR #99. PR fingerprint unchanged, but issue fingerprint changed
    # (user added a comment). Expect agent to be invoked.
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf '99\n'; }
    fetch_issue_json()          { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[{"body":"how to fix","updatedAt":"2024-01-01"}],"assignees":[],"milestone":null}\n'; }
    fetch_pr_json()             { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}\n'; }
    pr_json_has_blocked_label() { return 1; }
    fingerprint_pr_json()       { printf 'fp-same\n'; }
    load_pr_fingerprint()       { printf 'fp-same\n'; }
    fingerprint_issue_json()    { printf 'issue-fp-new\n'; }
    load_issue_fingerprint()    { printf 'issue-fp-old\n'; }
    local _invoke_log="${TEST_TMP}/invoke_log"
    invoke_claude() { printf 'invoked\n' >> "${_invoke_log}"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Issue #10 in org/repo changed — re-running against PR #99"* ]]
    [ -f "${_invoke_log}" ]
}

@test "main re-runs via pivot PR when PR unchanged and issue has no saved fingerprint" {
    # Issue #10 has linked PR #99. PR fingerprint unchanged, but there is no saved issue
    # fingerprint yet (first run after the fix was deployed). Expect agent to be invoked
    # so the issue fingerprint is initialised.
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf '99\n'; }
    fetch_issue_json()          { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    fetch_pr_json()             { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}\n'; }
    pr_json_has_blocked_label() { return 1; }
    fingerprint_pr_json()       { printf 'fp-same\n'; }
    load_pr_fingerprint()       { printf 'fp-same\n'; }
    fingerprint_issue_json()    { printf 'issue-fp-new\n'; }
    load_issue_fingerprint()    { printf ''; }
    local _invoke_log="${TEST_TMP}/invoke_log"
    invoke_claude() { printf 'invoked\n' >> "${_invoke_log}"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ -f "${_invoke_log}" ]
}

@test "main saves issue fingerprint after running agent on PR via issue pivot" {
    # Issue #10 has linked PR #99. Issue fingerprint changed → agent runs on PR #99.
    # Expect save_issue_fingerprint called with original issue ID (10), not PR ID (99).
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf '99\n'; }
    fetch_issue_json()          { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    fetch_pr_json()             { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}\n'; }
    pr_json_has_blocked_label() { return 1; }
    fingerprint_pr_json()       { printf 'fp-same\n'; }
    load_pr_fingerprint()       { printf 'fp-same\n'; }
    fingerprint_issue_json()    { printf 'issue-fp-new\n'; }
    load_issue_fingerprint()    { printf 'issue-fp-old\n'; }
    local _save_issue_log="${TEST_TMP}/save_issue_log"
    save_issue_fingerprint() { printf 'id=%s fp=%s\n' "$1" "$2" >> "${_save_issue_log}"; }

    run main
    [ "${status}" -eq 0 ]
    grep -q 'id=10' "${_save_issue_log}"
}

# --- main() git clean after session -------------------------------------------

@test "main runs git clean -fdX after invoke_claude succeeds for an Issue" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    local git_log="${TEST_TMP}/git_calls"
    cat > "${STUB_BIN}/git" << STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${git_log}"
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/git"
    hash git

    run main
    [ "${status}" -eq 0 ]
    grep -q "clean -fdX" "${git_log}"
}

@test "main runs git clean -fdX even when invoke_claude fails for an Issue" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    invoke_claude() { return 1; }
    local git_log="${TEST_TMP}/git_calls"
    cat > "${STUB_BIN}/git" << STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${git_log}"
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/git"
    hash git

    run main
    [ "${status}" -ne 0 ]
    grep -q "clean -fdX" "${git_log}"
    [[ "${output}" == *"Failed to invoke Claude"* ]]
}

@test "main runs git clean -fdX after invoke_claude succeeds for a PullRequest" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fingerprint_pr_json() { printf 'fp-new\n'; }
    load_pr_fingerprint() { printf 'fp-old\n'; }
    local git_log="${TEST_TMP}/git_calls"
    cat > "${STUB_BIN}/git" << STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${git_log}"
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/git"
    hash git

    run main
    [ "${status}" -eq 0 ]
    grep -q "clean -fdX" "${git_log}"
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

# --- load_env_config ------------------------------------------------------

@test "load_env_config sets DISCORD_WEBHOOK_URL from env file" {
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf 'DISCORD_WEBHOOK=https://discord.example.com/webhook/123\n' \
        > "${XDG_CONFIG_HOME}/orchestrator/.env"
    DISCORD_WEBHOOK_URL=""
    load_env_config
    [ "${DISCORD_WEBHOOK_URL}" = "https://discord.example.com/webhook/123" ]
}

@test "load_env_config strips double quotes from value" {
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf 'DISCORD_WEBHOOK="https://discord.example.com/webhook/456"\n' \
        > "${XDG_CONFIG_HOME}/orchestrator/.env"
    DISCORD_WEBHOOK_URL=""
    load_env_config
    [ "${DISCORD_WEBHOOK_URL}" = "https://discord.example.com/webhook/456" ]
}

@test "load_env_config strips single quotes from value" {
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf "DISCORD_WEBHOOK='https://discord.example.com/webhook/789'\n" \
        > "${XDG_CONFIG_HOME}/orchestrator/.env"
    DISCORD_WEBHOOK_URL=""
    load_env_config
    [ "${DISCORD_WEBHOOK_URL}" = "https://discord.example.com/webhook/789" ]
}

@test "load_env_config leaves DISCORD_WEBHOOK_URL empty when file is absent" {
    DISCORD_WEBHOOK_URL="should-be-cleared"
    load_env_config
    [ -z "${DISCORD_WEBHOOK_URL}" ]
}

@test "load_env_config leaves DISCORD_WEBHOOK_URL empty when key is absent from file" {
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf 'OTHER_KEY=some-value\n' > "${XDG_CONFIG_HOME}/orchestrator/.env"
    DISCORD_WEBHOOK_URL="should-be-cleared"
    load_env_config
    [ -z "${DISCORD_WEBHOOK_URL}" ]
}

@test "load_env_config strips trailing CR from CRLF env files" {
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf 'DISCORD_WEBHOOK=https://discord.example.com/hook\r\n' \
        > "${XDG_CONFIG_HOME}/orchestrator/.env"
    DISCORD_WEBHOOK_URL=""
    load_env_config
    [ "${DISCORD_WEBHOOK_URL}" = "https://discord.example.com/hook" ]
}

@test "load_env_config does not strip unmatched leading quote" {
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf 'DISCORD_WEBHOOK="https://discord.example.com/hook\n' \
        > "${XDG_CONFIG_HOME}/orchestrator/.env"
    DISCORD_WEBHOOK_URL=""
    load_env_config
    [ "${DISCORD_WEBHOOK_URL}" = '"https://discord.example.com/hook' ]
}

@test "load_env_config reads GH_TOKEN and GH_HOST and exports them" {
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf 'GH_TOKEN=ghp_testtoken\nGH_HOST=github-api.example.com\n' \
        > "${XDG_CONFIG_HOME}/orchestrator/.env"
    load_env_config
    [ "${GH_HOST}" = "github-api.example.com" ]
    # shellcheck disable=SC2031
    [ "${GH_ENTERPRISE_TOKEN}" = "ghp_testtoken" ]
}

@test "load_env_config does not export GH vars when GH_HOST is absent" {
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf 'GH_TOKEN=ghp_testtoken\n' > "${XDG_CONFIG_HOME}/orchestrator/.env"
    unset GH_HOST GH_ENTERPRISE_TOKEN || true
    load_env_config
    # shellcheck disable=SC2031
    [ -z "${GH_ENTERPRISE_TOKEN:-}" ]
}

@test "load_env_config reads all three keys from the same env file" {
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf 'DISCORD_WEBHOOK=https://hook.example.com/1\nGH_TOKEN=ghp_abc\nGH_HOST=proxy.example.com\n' \
        > "${XDG_CONFIG_HOME}/orchestrator/.env"
    DISCORD_WEBHOOK_URL=""
    load_env_config
    [ "${DISCORD_WEBHOOK_URL}" = "https://hook.example.com/1" ]
    # shellcheck disable=SC2031
    [ "${GH_ENTERPRISE_TOKEN}" = "ghp_abc" ]
    [ "${GH_HOST}" = "proxy.example.com" ]
}

@test "load_env_config reads WHITELISTED_USERS from env file" {
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf 'WHITELISTED_USERS=alice,bob\n' > "${XDG_CONFIG_HOME}/orchestrator/.env"
    WHITELISTED_USERS=""
    load_env_config
    [ "${WHITELISTED_USERS}" = "alice,bob" ]
}

@test "load_env_config leaves WHITELISTED_USERS empty when key is absent from env file" {
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf 'DISCORD_WEBHOOK=https://hook.example.com/1\n' > "${XDG_CONFIG_HOME}/orchestrator/.env"
    WHITELISTED_USERS=""
    load_env_config
    [ -z "${WHITELISTED_USERS}" ]
}

@test "load_env_config reads CI_CHECK_TIMEOUT_MINUTES from env file" {
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf 'CI_CHECK_TIMEOUT_MINUTES=30\n' > "${XDG_CONFIG_HOME}/orchestrator/.env"
    CI_CHECK_TIMEOUT_MINUTES=60
    load_env_config
    [ "${CI_CHECK_TIMEOUT_MINUTES}" = "30" ]
}

@test "load_env_config ignores non-integer CI_CHECK_TIMEOUT_MINUTES and warns" {
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf 'CI_CHECK_TIMEOUT_MINUTES=abc\n' > "${XDG_CONFIG_HOME}/orchestrator/.env"
    CI_CHECK_TIMEOUT_MINUTES=60
    run load_env_config
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"CI_CHECK_TIMEOUT_MINUTES must be a positive integer"* ]]
    [ "${CI_CHECK_TIMEOUT_MINUTES}" = "60" ]
}

@test "load_env_config ignores zero CI_CHECK_TIMEOUT_MINUTES and warns" {
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf 'CI_CHECK_TIMEOUT_MINUTES=0\n' > "${XDG_CONFIG_HOME}/orchestrator/.env"
    CI_CHECK_TIMEOUT_MINUTES=60
    run load_env_config
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"CI_CHECK_TIMEOUT_MINUTES must be a positive integer"* ]]
    [ "${CI_CHECK_TIMEOUT_MINUTES}" = "60" ]
}

# --- notify_discord_work_item -------------------------------------------------

@test "notify_discord_work_item warns and returns for unknown msg_type without calling curl" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_work_item "unknown_type" "Issue" "1" "Title"
    [ "${status}" -eq 0 ]
    [ ! -f "${args_log}" ]
    [[ "${output}" == *"unknown notification type"* ]]
}

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

@test "notify_discord_no_work prefixes message with owner when owner argument provided" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_no_work "credfeto"
    [ "${status}" -eq 0 ]
    grep -q "\[credfeto\] No actionable work items found" "${args_log}"
}

@test "notify_discord_no_work omits prefix when no owner argument provided" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_no_work
    [ "${status}" -eq 0 ]
    # Should NOT have bracket-prefixed owner
    run grep -q "\[.*\] No actionable" "${args_log}"
    [ "${status}" -ne 0 ]
    grep -q "No actionable work items found" "${args_log}"
}

@test "notify_discord_no_work appends blocked count when count_blocked is non-zero" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_no_work "" 3 0 0 0
    [ "${status}" -eq 0 ]
    grep -q "No actionable work items found" "${args_log}"
    grep -q "blocked: 3" "${args_log}"
}

@test "notify_discord_no_work appends unchanged count when count_unchanged is non-zero" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_no_work "" 0 5 0 0
    [ "${status}" -eq 0 ]
    grep -q "No actionable work items found" "${args_log}"
    grep -q "unchanged: 5" "${args_log}"
}

@test "notify_discord_no_work appends repo-active count when count_active_repo is non-zero" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_no_work "" 0 0 2 0
    [ "${status}" -eq 0 ]
    grep -q "No actionable work items found" "${args_log}"
    grep -q "repo-active: 2" "${args_log}"
}

@test "notify_discord_no_work appends not-open count when count_not_open is non-zero" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_no_work "" 0 0 0 1
    [ "${status}" -eq 0 ]
    grep -q "No actionable work items found" "${args_log}"
    grep -q "not-open: 1" "${args_log}"
}

@test "notify_discord_no_work omits detail suffix when all counts are zero" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_no_work "" 0 0 0 0
    [ "${status}" -eq 0 ]
    grep -q "No actionable work items found" "${args_log}"
    run grep -q "blocked:\|unchanged:\|repo-active:\|not-open:" "${args_log}"
    [ "${status}" -ne 0 ]
}

@test "notify_discord_no_work includes all non-zero counts in detail" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_no_work "myorg" 2 3 1 4
    [ "${status}" -eq 0 ]
    grep -q "\[myorg\] No actionable work items found" "${args_log}"
    grep -q "blocked: 2" "${args_log}"
    grep -q "unchanged: 3" "${args_log}"
    grep -q "repo-active: 1" "${args_log}"
    grep -q "not-open: 4" "${args_log}"
}

@test "notify_discord_no_work suppresses duplicate message sent within the last hour" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    make_stub date "echo 1700000000"

    local args_log1="${TEST_TMP}/curl_first"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log1}'"
    run notify_discord_no_work "" 0 5 0 0
    [ "${status}" -eq 0 ]
    [ -f "${args_log1}" ]

    local args_log2="${TEST_TMP}/curl_second"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log2}'"
    run notify_discord_no_work "" 0 5 0 0
    [ "${status}" -eq 0 ]
    [ ! -f "${args_log2}" ]
}

@test "notify_discord_no_work resends same message after one hour has elapsed" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    make_stub date "echo 1700003601"

    local state_file="${HOME}/.orchestrator/.no_work__global.state"
    mkdir -p "${HOME}/.orchestrator"
    printf 'No actionable work items found.\n1700000000\n' > "${state_file}"

    run notify_discord_no_work "" 0 0 0 0
    [ "${status}" -eq 0 ]
    grep -q "No actionable work items found" "${args_log}"
}

@test "notify_discord_no_work sends different message immediately even within the last hour" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    make_stub date "echo 1700000000"

    local state_file="${HOME}/.orchestrator/.no_work__global.state"
    mkdir -p "${HOME}/.orchestrator"
    printf 'No actionable work items found. (blocked: 1)\n1700000000\n' > "${state_file}"

    run notify_discord_no_work "" 0 5 0 0
    [ "${status}" -eq 0 ]
    grep -q "unchanged: 5" "${args_log}"
}

@test "notify_discord_no_work saves state to disk after sending" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    make_stub curl "exit 0"
    make_stub date "echo 1700000000"

    run notify_discord_no_work "" 0 0 0 0
    [ "${status}" -eq 0 ]

    local state_file="${HOME}/.orchestrator/.no_work__global.state"
    [ -f "${state_file}" ]
    grep -q "No actionable work items found" "${state_file}"
    grep -q "1700000000" "${state_file}"
}

@test "notify_discord_no_work uses owner-scoped state file" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    make_stub date "echo 1700000000"

    local args_log1="${TEST_TMP}/curl_first"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log1}'"
    run notify_discord_no_work "myorg" 0 5 0 0
    [ "${status}" -eq 0 ]
    [ -f "${args_log1}" ]

    # Same message, same owner — should be suppressed
    local args_log2="${TEST_TMP}/curl_second"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log2}'"
    run notify_discord_no_work "myorg" 0 5 0 0
    [ "${status}" -eq 0 ]
    [ ! -f "${args_log2}" ]

    # Same message, different owner — should still send (different state file)
    local args_log3="${TEST_TMP}/curl_third"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log3}'"
    run notify_discord_no_work "otherorg" 0 5 0 0
    [ "${status}" -eq 0 ]
    grep -q "otherorg" "${args_log3}"
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
    notify_discord_no_work() { printf 'no_work owner=%s\n' "${1:-}" >> "${_notif_log}"; }

    run main
    [ "${status}" -eq 0 ]
    grep -q 'no_work' "${_notif_log}"
}

@test "main passes owner to no-work notification when --owner flag is set" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[{"name":"Blocked"}],"comments":[],"assignees":[],"milestone":null}\n'; }
    local _notif_log="${TEST_TMP}/notif_log"
    notify_discord_no_work() { printf 'no_work owner=%s\n' "${1:-}" >> "${_notif_log}"; }

    run main --owner org
    [ "${status}" -eq 0 ]
    grep -q 'no_work owner=org' "${_notif_log}"
}

@test "main passes blocked count of 1 to no-work notification when a single issue is blocked" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[{"name":"Blocked"}],"comments":[],"assignees":[],"milestone":null}\n'; }
    local _notif_log="${TEST_TMP}/notif_log"
    notify_discord_no_work() { printf 'blocked=%s\n' "${2:-0}" >> "${_notif_log}"; }

    run main
    [ "${status}" -eq 0 ]
    grep -q 'blocked=1' "${_notif_log}"
}

@test "main passes unchanged count of 1 to no-work notification when a single issue fingerprint is unchanged" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json()          { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    issue_json_has_blocked_label() { return 1; }
    fingerprint_issue_json()    { printf 'fp-same\n'; }
    load_issue_fingerprint()    { printf 'fp-same\n'; }
    local _notif_log="${TEST_TMP}/notif_log"
    notify_discord_no_work() { printf 'unchanged=%s\n' "${3:-0}" >> "${_notif_log}"; }

    run main
    [ "${status}" -eq 0 ]
    grep -q 'unchanged=1' "${_notif_log}"
}

@test "main passes repo-active count to no-work notification when items are skipped for active repo" {
    # PR #5 (org/repo): unchanged → adds org/repo to skip_repos, count_unchanged=1
    # Issue #10 (org/repo): skipped because org/repo already in skip_repos, count_active_repo=1
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false},{"id":10,"itemType":"Issue","repository":"org/repo","priority":2,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json()             { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}\n'; }
    pr_json_has_blocked_label() { return 1; }
    fingerprint_pr_json()       { printf 'fp-same\n'; }
    load_pr_fingerprint()       { printf 'fp-same\n'; }
    local _notif_log="${TEST_TMP}/notif_log"
    notify_discord_no_work() { printf 'unchanged=%s active=%s\n' "${3:-0}" "${4:-0}" >> "${_notif_log}"; }

    run main
    [ "${status}" -eq 0 ]
    grep -q 'unchanged=1' "${_notif_log}"
    grep -q 'active=1' "${_notif_log}"
}

# --- notify_discord_blocked_item -----------------------------------------------

@test "notify_discord_blocked_item does not call curl when DISCORD_WEBHOOK_URL is empty" {
    DISCORD_WEBHOOK_URL=""
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_blocked_item "Issue" "42"
    [ "${status}" -eq 0 ]
    [ ! -f "${args_log}" ]
}

@test "notify_discord_blocked_item calls curl with embed payload for a blocked Issue" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_blocked_item "Issue" "42"
    [ "${status}" -eq 0 ]
    grep -q "https://discord.example.com/hook" "${args_log}"
    grep -q "https://github.com/org/repo/issues/42" "${args_log}"
    grep -q "Blocked" "${args_log}"
}

@test "notify_discord_blocked_item calls curl with embed payload for a blocked PullRequest" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_blocked_item "PullRequest" "7"
    [ "${status}" -eq 0 ]
    grep -q "https://github.com/org/repo/pull/7" "${args_log}"
    grep -q "Blocked" "${args_log}"
}

@test "notify_discord_blocked_item is silent on a repeat call while the item stays blocked" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"

    notify_discord_blocked_item "Issue" "42"
    notify_discord_blocked_item "Issue" "42"

    # The webhook URL appears once per curl invocation; only the first call notifies.
    [ "$(grep -c 'https://discord.example.com/hook' "${args_log}")" -eq 1 ]
    [ -f "$(blocked_marker_file_path Issue 42)" ]
}

@test "notify_discord_blocked_item notifies again after clear_blocked_marker re-arms it" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"

    notify_discord_blocked_item "Issue" "42"
    clear_blocked_marker "Issue" "42"
    [ ! -f "$(blocked_marker_file_path Issue 42)" ]
    notify_discord_blocked_item "Issue" "42"

    # Two distinct blocked spells — two notifications.
    [ "$(grep -c 'https://discord.example.com/hook' "${args_log}")" -eq 2 ]
}

@test "clear_blocked_marker on a missing marker is a silent no-op" {
    set_repo_context "org/repo"
    run clear_blocked_marker "PullRequest" "7"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

# --- main() blocked Discord notification integration --------------------------

@test "main sends blocked notification when a PR in priorities is blocked" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json()             { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[{"name":"Blocked"}],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}\n'; }
    pr_json_has_blocked_label() { return 0; }
    local _notif_log="${TEST_TMP}/notif_log"
    notify_discord_blocked_item() { printf 'type=%s id=%s\n' "$1" "$2" >> "${_notif_log}"; }

    run main
    [ "${status}" -eq 0 ]
    grep -q 'type=PullRequest id=5' "${_notif_log}"
}

@test "main sends blocked notification when a direct Issue is blocked" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[{"name":"Blocked"}],"comments":[],"assignees":[],"milestone":null}\n'; }
    issue_json_has_blocked_label() { return 0; }
    local _notif_log="${TEST_TMP}/notif_log"
    notify_discord_blocked_item() { printf 'type=%s id=%s\n' "$1" "$2" >> "${_notif_log}"; }

    run main
    [ "${status}" -eq 0 ]
    grep -q 'type=Issue id=10' "${_notif_log}"
}

@test "main sends blocked notification for Issue when the Issue has a linked PR that is blocked" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf '99\n'; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    issue_json_has_blocked_label() { return 1; }
    fetch_pr_json()             { printf '{"state":"OPEN","title":"PR title","body":"","isDraft":false,"labels":[{"name":"Blocked"}],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}\n'; }
    pr_json_has_blocked_label() { return 0; }
    local _notif_log="${TEST_TMP}/notif_log"
    notify_discord_blocked_item() { printf 'type=%s id=%s\n' "$1" "$2" >> "${_notif_log}"; }

    run main
    [ "${status}" -eq 0 ]
    grep -q 'type=PullRequest id=99' "${_notif_log}"
}

@test "main sends blocked notification for Issue with linked PR when the Issue itself is blocked" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf '99\n'; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[{"name":"Blocked"}],"comments":[],"assignees":[],"milestone":null}\n'; }
    issue_json_has_blocked_label() { return 0; }
    local _notif_log="${TEST_TMP}/notif_log"
    notify_discord_blocked_item() { printf 'type=%s id=%s\n' "$1" "$2" >> "${_notif_log}"; }

    run main
    [ "${status}" -eq 0 ]
    grep -q 'type=Issue id=10' "${_notif_log}"
}

# --- parse_reset_time ---------------------------------------------------------

@test "parse_reset_time returns empty for non-matching input" {
    run parse_reset_time "Some unrelated error message"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "parse_reset_time converts 3pm UTC to correct unix timestamp" {
    # Use UTC so the test is timezone-independent.
    local result
    result=$(parse_reset_time "You've hit your limit · resets 3pm (UTC)")
    [ -n "${result}" ]
    [[ "${result}" =~ ^[0-9]+$ ]]
    # The result must be in the future (either today at 15:00 UTC or tomorrow).
    local now_unix
    now_unix=$(date +%s)
    [ "${result}" -gt "${now_unix}" ]
}

@test "parse_reset_time converts 7:10pm UTC to correct unix timestamp" {
    result=$(parse_reset_time "You've hit your limit · resets 7:10pm (UTC)")
    [ -n "${result}" ]

    now_unix=$(date +%s)
    # Expected: today or tomorrow at 19:10:00 UTC
    expected_unix=$(date -u -d "today 19:10:00" +%s)
    if [ "${expected_unix}" -le "${now_unix}" ]; then
        expected_unix=$(date -u -d "tomorrow 19:10:00" +%s)
    fi
    [ "${result}" -eq "${expected_unix}" ]
}

@test "parse_reset_time converts 12am UTC to hour 0 and returns future timestamp" {
    local result
    result=$(parse_reset_time "hit your limit · resets 12am (UTC)")
    [ -n "${result}" ]
    [[ "${result}" =~ ^[0-9]+$ ]]
    local now_unix
    now_unix=$(date +%s)
    [ "${result}" -gt "${now_unix}" ]
}

@test "parse_reset_time converts 12pm UTC to hour 12 and returns future timestamp" {
    local result
    result=$(parse_reset_time "hit your limit · resets 12pm (UTC)")
    [ -n "${result}" ]
    [[ "${result}" =~ ^[0-9]+$ ]]
    local now_unix
    now_unix=$(date +%s)
    [ "${result}" -gt "${now_unix}" ]
}

@test "parse_reset_time converts 'Jul 3, 10pm (UTC)' to correct unix timestamp" {
    result=$(parse_reset_time "You've hit your limit · resets Jul 3, 10pm (UTC)")
    [ -n "${result}" ]
    expected_unix=$(date -u -d "Jul 3 22:00:00" +%s)
    [ "${result}" -eq "${expected_unix}" ]
}

@test "parse_reset_time converts 'Jul 3, 10:30am (UTC)' to correct unix timestamp" {
    result=$(parse_reset_time "You've hit your limit · resets Jul 3, 10:30am (UTC)")
    [ -n "${result}" ]
    expected_unix=$(date -u -d "Jul 3 10:30:00" +%s)
    [ "${result}" -eq "${expected_unix}" ]
}

@test "parse_reset_time rejects timezone strings with dangerous characters" {
    run parse_reset_time "resets 3pm (UTC;rm -rf /)"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

# --- handle_claude_is_error tmpfile cleanup -----------------------------------

@test "handle_claude_is_error removes tmpfile before dying on rate-limit (429)" {
    notify_discord_rate_limited()      { return 0; }
    save_rate_limit()                  { return 0; }
    report_unparseable_rate_limit()    { return 0; }

    local tmpfile
    tmpfile="$(mktemp "${TEST_TMP}/claude.XXXXXX.json")"
    printf '%s' '{"api_error_status":"429","result":"Claude AI usage limit reached"}' > "${tmpfile}"

    run handle_claude_is_error "${tmpfile}" "" "Issue" "1"
    # die exits non-zero.
    [ "${status}" -ne 0 ]
    # The temp file must not be leaked on the rate-limit path.
    [ ! -f "${tmpfile}" ]
}

@test "handle_claude_is_error removes tmpfile before dying on generic error" {
    notify_discord_claude_error() { return 0; }

    local tmpfile
    tmpfile="$(mktemp "${TEST_TMP}/claude.XXXXXX.json")"
    printf '%s' '{"api_error_status":"500","result":"internal error"}' > "${tmpfile}"

    run handle_claude_is_error "${tmpfile}" "" "PullRequest" "2"
    # die exits non-zero.
    [ "${status}" -ne 0 ]
    # The temp file must not be leaked on the generic-error path.
    [ ! -f "${tmpfile}" ]
}

# --- report_unparseable_rate_limit --------------------------------------------

@test "handle_claude_is_error does not call report_unparseable_rate_limit when parse_reset_time succeeds" {
    # A parseable 429 message (resets 3pm UTC) → save_rate_limit is called, no GH issue raised.
    save_rate_limit()               { return 0; }
    notify_discord_rate_limited()   { return 0; }

    local gh_log="${TEST_TMP}/gh_calls"
    make_stub gh "printf '%s\n' \"\$@\" >> '${gh_log}'"

    local tmpfile
    tmpfile="$(mktemp "${TEST_TMP}/claude.XXXXXX.json")"
    printf '%s' '{"api_error_status":"429","result":"You'"'"'ve hit your Sonnet limit · resets 3pm (UTC)"}' > "${tmpfile}"

    run handle_claude_is_error "${tmpfile}" "" "Issue" "42"
    # Still fails (rate-limited).
    [ "${status}" -ne 0 ]
    # gh must NOT have been called — no tracking issue created.
    [ ! -f "${gh_log}" ] || [ ! -s "${gh_log}" ]
}

@test "report_unparseable_rate_limit creates a new issue when no open tracking issue exists" {
    local gh_log="${TEST_TMP}/gh_args"
    # Stub: gh issue list outputs nothing (no open tracker found after jq filtering).
    # All other gh calls (issue create) have their args logged.
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
if [ "\$1" = "issue" ] && [ "\$2" = "list" ]; then
    exit 0
fi
printf '%s\n' "\$@" >> '${gh_log}'
STUBEOF
    chmod +x "${STUB_BIN}/gh"

    local raw_msg="Rate limit reached — unknown format with no reset time"
    report_unparseable_rate_limit "Issue" "7" "${raw_msg}"

    [ -f "${gh_log}" ]
    # gh issue create must have been called with the expected flags.
    grep -q "^create$" "${gh_log}"
    grep -q "^${RATE_LIMIT_ISSUE_TITLE}$" "${gh_log}"
    grep -q "^AI-Work$" "${gh_log}"
    grep -q "^${RATE_LIMIT_ISSUE_REPO}$" "${gh_log}"
    # The verbatim raw message must appear in the body.
    grep -q "${raw_msg}" "${gh_log}"
    # gh issue comment must NOT have been called.
    run grep -q "^comment$" "${gh_log}"
    [ "${status}" -ne 0 ]
}

@test "report_unparseable_rate_limit appends to existing open tracking issue" {
    local tracker_number=99
    local gh_log="${TEST_TMP}/gh_args"
    # Stub: gh issue list outputs just the issue number (simulating jq-filtered output from gh).
    # All other gh calls (issue comment) have their args logged.
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
if [ "\$1" = "issue" ] && [ "\$2" = "list" ]; then
    printf '%s\n' '${tracker_number}'
    exit 0
fi
printf '%s\n' "\$@" >> '${gh_log}'
STUBEOF
    chmod +x "${STUB_BIN}/gh"

    local raw_msg="Some brand-new unparseable Claude 429 message"
    report_unparseable_rate_limit "PullRequest" "15" "${raw_msg}"

    [ -f "${gh_log}" ]
    # gh issue comment must have been called with the existing issue number.
    grep -q "^comment$" "${gh_log}"
    grep -q "^${tracker_number}$" "${gh_log}"
    # The verbatim raw message must appear in the body.
    grep -q "${raw_msg}" "${gh_log}"
    # gh issue create must NOT have been called.
    run grep -q "^create$" "${gh_log}"
    [ "${status}" -ne 0 ]
}

# --- rate-limit file management -----------------------------------------------

@test "is_owner_rate_limited returns false when no rate-limit file exists" {
    run is_owner_rate_limited
    [ "${status}" -ne 0 ]
}

@test "is_owner_rate_limited returns true when file has a future timestamp" {
    local future_unix
    future_unix=$(( $(date +%s) + 3600 ))
    mkdir -p "${HOME}/.orchestrator/${OWNER}"
    printf '%s\n' "${future_unix}" > "${HOME}/.orchestrator/${OWNER}/rate-limit"
    run is_owner_rate_limited
    [ "${status}" -eq 0 ]
}

@test "is_owner_rate_limited returns false and removes file when timestamp is in the past" {
    local past_unix
    past_unix=$(( $(date +%s) - 60 ))
    mkdir -p "${HOME}/.orchestrator/${OWNER}"
    local rate_file="${HOME}/.orchestrator/${OWNER}/rate-limit"
    printf '%s\n' "${past_unix}" > "${rate_file}"
    run is_owner_rate_limited
    [ "${status}" -ne 0 ]
    [ ! -f "${rate_file}" ]
}

@test "is_owner_rate_limited returns false and removes file when content is non-numeric" {
    mkdir -p "${HOME}/.orchestrator/${OWNER}"
    local rate_file="${HOME}/.orchestrator/${OWNER}/rate-limit"
    printf 'not-a-number\n' > "${rate_file}"
    run is_owner_rate_limited
    [ "${status}" -ne 0 ]
    [ ! -f "${rate_file}" ]
}

# --- notify_discord_rate_limited -----------------------------------------------

@test "notify_discord_rate_limited does not call curl when DISCORD_WEBHOOK_URL is empty" {
    DISCORD_WEBHOOK_URL=""
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_rate_limited "Issue" "42" "You've hit your Sonnet limit" ""
    [ "${status}" -eq 0 ]
    [ ! -f "${args_log}" ]
}

@test "notify_discord_rate_limited calls curl with embed including issue URL and error" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_rate_limited "Issue" "42" "You've hit your Sonnet limit" ""
    [ "${status}" -eq 0 ]
    grep -q "https://discord.example.com/hook" "${args_log}"
    grep -q "https://github.com/org/repo/issues/42" "${args_log}"
    grep -q "Sonnet limit" "${args_log}"
}

@test "notify_discord_rate_limited includes Discord timestamp markup when reset_unix is provided" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_rate_limited "Issue" "42" "Sonnet limit" "1700000000"
    [ "${status}" -eq 0 ]
    grep -q '<t:1700000000:t>' "${args_log}"
    grep -q '<t:1700000000:R>' "${args_log}"
}

# --- invoke_claude 429 handling ------------------------------------------------

@test "invoke_claude saves rate-limit file and sends Discord notification on HTTP 429" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "pull" ] && exit 0
[ "$1" = "inspect" ] && exit 1
[ "$1" = "pull" ] && exit 0
printf '%s\n' '{"is_error":true,"api_error_status":429,"terminal_reason":"completed","session_id":"12345678-1234-1234-1234-123456789abc","result":"You'\''ve hit your Sonnet limit \u00b7 resets 3pm (UTC)"}'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"

    run invoke_claude "test prompt" "" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"rate limited"* ]]
    grep -q "https://discord.example.com/hook" "${args_log}"
}

@test "invoke_claude persists rate-limit file on HTTP 429 so subsequent runs skip the owner" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "pull" ] && exit 0
[ "$1" = "inspect" ] && exit 1
[ "$1" = "pull" ] && exit 0
printf '%s\n' '{"is_error":true,"api_error_status":429,"terminal_reason":"completed","session_id":"12345678-1234-1234-1234-123456789abc","result":"You'\''ve hit your Sonnet limit \u00b7 resets 3pm (UTC)"}'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    DISCORD_WEBHOOK_URL=""
    run invoke_claude "test prompt" "" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -ne 0 ]
    # Rate-limit file must exist and contain reset_time + 1hr buffer, both in the future.
    local rate_file="${HOME}/.orchestrator/${OWNER}/rate-limit"
    [ -f "${rate_file}" ]
    local saved_unix
    saved_unix=$(cat "${rate_file}")
    [[ "${saved_unix}" =~ ^[0-9]+$ ]]
    local now_unix
    now_unix=$(date +%s)
    [ "${saved_unix}" -gt "${now_unix}" ]
    # Buffer must be at least RATE_LIMIT_RESUME_BUFFER_SECS (3600) seconds from now.
    [ "${saved_unix}" -ge "$((now_unix + RATE_LIMIT_RESUME_BUFFER_SECS))" ]
}

@test "invoke_claude saves rate-limit file when Claude CLI exits non-zero with 429 JSON on new session" {
    # Reproduces the production failure: Claude writes valid is_error JSON but exits 1.
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "pull" ] && exit 0
[ "$1" = "inspect" ] && exit 1
printf '%s\n' '{"type":"result","is_error":true,"api_error_status":429,"terminal_reason":"completed","session_id":"12345678-1234-1234-1234-123456789abc","result":"You'\''ve hit your Sonnet limit · resets 3pm (UTC)"}'
exit 1
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    DISCORD_WEBHOOK_URL=""
    run invoke_claude "test prompt" "" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -ne 0 ]
    local rate_file="${HOME}/.orchestrator/${OWNER}/rate-limit"
    [ -f "${rate_file}" ]
    local saved_unix
    saved_unix=$(cat "${rate_file}")
    [[ "${saved_unix}" =~ ^[0-9]+$ ]]
    local now_unix
    now_unix=$(date +%s)
    [ "${saved_unix}" -gt "${now_unix}" ]
}

@test "invoke_claude saves rate-limit file when Claude CLI exits non-zero with 429 JSON on resumed session" {
    # Reproduces the production failure: resumed session hits 429 and CLI exits 1.
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "pull" ] && exit 0
[ "$1" = "inspect" ] && exit 1
printf '%s\n' '{"type":"result","is_error":true,"api_error_status":429,"terminal_reason":"completed","session_id":"12345678-1234-1234-1234-123456789abc","result":"You'\''ve hit your Sonnet limit · resets 3pm (UTC)"}'
exit 1
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    DISCORD_WEBHOOK_URL=""
    run invoke_claude "test prompt" "11111111-1111-1111-1111-111111111111" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -ne 0 ]
    local rate_file="${HOME}/.orchestrator/${OWNER}/rate-limit"
    [ -f "${rate_file}" ]
    local saved_unix
    saved_unix=$(cat "${rate_file}")
    [[ "${saved_unix}" =~ ^[0-9]+$ ]]
    local now_unix
    now_unix=$(date +%s)
    [ "${saved_unix}" -gt "${now_unix}" ]
}

@test "invoke_claude sends Discord notification when Claude CLI exits non-zero with 429 JSON" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "pull" ] && exit 0
[ "$1" = "inspect" ] && exit 1
printf '%s\n' '{"type":"result","is_error":true,"api_error_status":429,"terminal_reason":"completed","session_id":"12345678-1234-1234-1234-123456789abc","result":"You'\''ve hit your Sonnet limit · resets 3pm (UTC)"}'
exit 1
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"

    run invoke_claude "test prompt" "11111111-1111-1111-1111-111111111111" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -ne 0 ]
    grep -q "https://discord.example.com/hook" "${args_log}"
}

# --- main() rate-limit integration --------------------------------------------

@test "main skips items for a rate-limited owner and continues to other owners" {
    setup_main_mocks
    # Let set_repo_context set OWNER so is_owner_rate_limited can check it.
    set_repo_context() { OWNER="${1%%/*}"; REPO_FULL="$1"; REPO_WORK_DIR="/work/$1"; }
    fetch_all_priorities() {
        printf '%s\n' '[{"id":1,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false},{"id":2,"itemType":"Issue","repository":"other/repo","priority":2,"status":"Open","isOnHold":false}]'
    }
    is_owner_rate_limited() {
        [ "${OWNER}" = "org" ] && return 0
        return 1
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    # Issues are open and non-blocked so they reach the rate-limit check (which now fires after ensure_repo_current).
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    issue_json_has_blocked_label() { return 1; }
    fingerprint_issue_json() { printf 'fp-new\n'; }
    load_issue_fingerprint()  { printf ''; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"rate-limited"* ]]
    # org/repo rate-limited before ensure_rules_current; other/repo must still be invoked
    [[ "${output}" == *"Issue #2 in other/repo"* ]]
}

# --- recover_orphaned_branch unit tests ----------------------------------------

# Sets up a local bare "remote" and clones it into REPO_WORK_DIR so that
# recover_orphaned_branch can perform real git operations without network calls.
setup_local_git_remote() {
    local remote_dir="${TEST_TMP}/remote.git"
    git init --bare "${remote_dir}" >/dev/null 2>&1
    git -C "${remote_dir}" symbolic-ref HEAD refs/heads/main >/dev/null 2>&1

    mkdir -p "$(dirname "${REPO_WORK_DIR}")"
    git clone "${remote_dir}" "${REPO_WORK_DIR}" >/dev/null 2>&1
    git -C "${REPO_WORK_DIR}" config user.email "test@example.com"
    git -C "${REPO_WORK_DIR}" config user.name "Test"
    git -C "${REPO_WORK_DIR}" config core.hooksPath /dev/null
    git -C "${REPO_WORK_DIR}" -c commit.gpgsign=false commit --allow-empty -m "init" >/dev/null 2>&1
    git -C "${REPO_WORK_DIR}" push origin main >/dev/null 2>&1

    printf '%s\n' "${remote_dir}"
}

@test "recover_orphaned_branch returns 1 when repo directory does not exist" {
    REPO_WORK_DIR="${TEST_TMP}/nonexistent/repo"
    run recover_orphaned_branch
    [ "${status}" -eq 1 ]
}

@test "recover_orphaned_branch returns 1 when repo is on main" {
    setup_local_git_remote >/dev/null
    run recover_orphaned_branch
    [ "${status}" -eq 1 ]
}

@test "recover_orphaned_branch returns 1 when branch still exists on remote" {
    local remote_dir
    remote_dir=$(setup_local_git_remote)
    git -C "${REPO_WORK_DIR}" checkout -b feature/active >/dev/null 2>&1
    git -C "${REPO_WORK_DIR}" -c commit.gpgsign=false commit --allow-empty -m "work" >/dev/null 2>&1
    git -C "${REPO_WORK_DIR}" push origin feature/active >/dev/null 2>&1

    run recover_orphaned_branch
    [ "${status}" -eq 1 ]

    local current_branch
    current_branch=$(git -C "${REPO_WORK_DIR}" branch --show-current)
    [ "${current_branch}" = "feature/active" ]
}

@test "recover_orphaned_branch returns 0 and resets to main when branch is gone from remote" {
    local remote_dir
    remote_dir=$(setup_local_git_remote)
    git -C "${REPO_WORK_DIR}" checkout -b feature/merged >/dev/null 2>&1
    git -C "${REPO_WORK_DIR}" -c commit.gpgsign=false commit --allow-empty -m "work" >/dev/null 2>&1
    git -C "${REPO_WORK_DIR}" push origin feature/merged >/dev/null 2>&1
    git -C "${remote_dir}" branch -D feature/merged >/dev/null 2>&1

    run recover_orphaned_branch
    [ "${status}" -eq 0 ]

    local current_branch
    current_branch=$(git -C "${REPO_WORK_DIR}" branch --show-current)
    [ "${current_branch}" = "main" ]
}

@test "recover_orphaned_branch output warns about the orphaned branch name" {
    local remote_dir
    remote_dir=$(setup_local_git_remote)
    git -C "${REPO_WORK_DIR}" checkout -b feature/gone >/dev/null 2>&1
    git -C "${REPO_WORK_DIR}" -c commit.gpgsign=false commit --allow-empty -m "work" >/dev/null 2>&1
    git -C "${REPO_WORK_DIR}" push origin feature/gone >/dev/null 2>&1
    git -C "${remote_dir}" branch -D feature/gone >/dev/null 2>&1

    run recover_orphaned_branch
    [[ "${output}" == *"feature/gone"* ]]
    [[ "${output}" == *"no longer exists on origin"* ]]
}

@test "recover_orphaned_branch returns 0 and resets to main when branch is gone from remote and working tree has unstaged changes" {
    local remote_dir
    remote_dir=$(setup_local_git_remote)
    git -C "${REPO_WORK_DIR}" checkout -b feature/dirty >/dev/null 2>&1
    git -C "${REPO_WORK_DIR}" -c commit.gpgsign=false commit --allow-empty -m "work" >/dev/null 2>&1
    git -C "${REPO_WORK_DIR}" push origin feature/dirty >/dev/null 2>&1
    git -C "${remote_dir}" branch -D feature/dirty >/dev/null 2>&1
    printf 'unstaged change\n' >> "${REPO_WORK_DIR}/CHANGELOG.md"

    run recover_orphaned_branch
    [ "${status}" -eq 0 ]

    local current_branch
    current_branch=$(git -C "${REPO_WORK_DIR}" branch --show-current)
    [ "${current_branch}" = "main" ]
}

# --- main() integration: orphaned-branch fingerprint bypass --------------------

@test "main re-runs issue with matching fingerprint when recover_orphaned_branch detects orphaned branch" {
    setup_main_mocks
    recover_orphaned_branch() { return 0; }

    fetch_all_priorities() {
        printf '[{"id":42,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]\n'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() {
        printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'
    }
    issue_json_has_blocked_label() { return 1; }
    fingerprint_issue_json()      { printf 'same-fp\n'; }
    load_issue_fingerprint()      { printf 'same-fp\n'; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"orphaned branch"* ]]
    [[ "${output}" == *"Found actionable Issue #42"* ]]
}

@test "main still skips issue with matching fingerprint when branch is not orphaned" {
    setup_main_mocks
    recover_orphaned_branch() { return 1; }

    fetch_all_priorities() {
        printf '[{"id":42,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]\n'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() {
        printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'
    }
    issue_json_has_blocked_label() { return 1; }
    fingerprint_issue_json()      { printf 'same-fp\n'; }
    load_issue_fingerprint()      { printf 'same-fp\n'; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Issue #42 in org/repo unchanged — skipping"* ]]
    [[ "${output}" != *"Found actionable Issue #42"* ]]
}

# --- load_env_config git identity tests ----------------------------------------

@test "load_env_config reads GIT_USER_NAME from .env" {
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf 'GIT_USER_NAME=Alice\n' > "${XDG_CONFIG_HOME}/orchestrator/.env"
    load_env_config
    [ "${GIT_USER_NAME}" = "Alice" ]
}

@test "load_env_config reads GIT_USER_EMAIL from .env" {
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf 'GIT_USER_EMAIL=alice@example.com\n' > "${XDG_CONFIG_HOME}/orchestrator/.env"
    load_env_config
    [ "${GIT_USER_EMAIL}" = "alice@example.com" ]
}

@test "load_env_config reads GIT_SIGNING_KEY from .env" {
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf 'GIT_SIGNING_KEY=ABCD1234\n' > "${XDG_CONFIG_HOME}/orchestrator/.env"
    load_env_config
    [ "${GIT_SIGNING_KEY}" = "ABCD1234" ]
}

@test "load_env_config leaves git identity vars empty when absent from .env" {
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf 'DISCORD_WEBHOOK=https://example.com/hook\n' > "${XDG_CONFIG_HOME}/orchestrator/.env"
    load_env_config
    [ -z "${GIT_USER_NAME}" ]
    [ -z "${GIT_USER_EMAIL}" ]
    [ -z "${GIT_SIGNING_KEY}" ]
}

# --- main startup GPG key check -----------------------------------------------

@test "main dies at startup when GIT_SIGNING_KEY is set but absent from the keyring" {
    check_required_tools() { return 0; }
    make_stub gpg 'exit 1'
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator" "${XDG_CONFIG_HOME}/gh"
    printf 'GIT_USER_NAME=Test User\nGIT_USER_EMAIL=test@example.com\nGIT_SIGNING_KEY=ABCD1234\n' \
        > "${XDG_CONFIG_HOME}/orchestrator/.env"
    printf 'github.com:\n' > "${XDG_CONFIG_HOME}/gh/hosts.yml"
    run main
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"not found in the GPG keyring"* ]]
}

@test "main does not check the keyring when GIT_SIGNING_KEY is absent from .env" {
    make_stub gpg 'exit 1'
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf 'DISCORD_WEBHOOK=https://example.com/hook\n' > "${XDG_CONFIG_HOME}/orchestrator/.env"
    # Should not reach the gpg check — verify it doesn't die due to gpg failure
    make_stub gh 'printf "{\"items\":[]}\n"'
    make_stub curl 'exit 0'
    make_stub flock 'shift; shift; exec "$@"'
    run main 2>/dev/null
    # As long as it doesn't die with a GPG error message, the check was skipped
    [[ "${output}" != *"not found in the GPG keyring"* ]]
}

make_gpg_stubs() {
    local extra_socket="${TEST_TMP}/S.gpg-agent.extra"
    # Create a real socket file so [ -S ] passes.
    python3 -c "import socket,os; s=socket.socket(socket.AF_UNIX); s.bind('${extra_socket}')"
    cat > "${STUB_BIN}/gpgconf" << STUBEOF
#!/usr/bin/env bash
printf '%s\n' "${extra_socket}"
STUBEOF
    chmod +x "${STUB_BIN}/gpgconf"
    cat > "${STUB_BIN}/gpg" << 'STUBEOF'
#!/usr/bin/env bash
# Simulate export producing real bytes, import succeeding, and key listing succeeding.
if [[ "$*" == *"--export"* ]]; then
    printf 'FAKEPUBKEYDATA\n'
    exit 0
fi
if [[ "$*" == *"--import"* ]]; then
    exit 0
fi
if [[ "$*" == *"--list-secret-keys"* ]]; then
    exit 0
fi
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/gpg"
    make_stub gpg-connect-agent 'exit 0'
}

# --- invoke_claude git identity env var passing --------------------------------

@test "invoke_claude passes GIT_USER_NAME as container env var when set" {
    local args_log="${TEST_TMP}/podman_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    GIT_USER_NAME="Alice"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
[ "\$1" = "pull" ] && exit 0
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    invoke_claude "test prompt" "" "" "" "# mock CLAUDE.md" 2>/dev/null
    grep -qx 'GIT_USER_NAME=Alice' "${args_log}"
}

@test "invoke_claude passes GIT_USER_EMAIL as container env var when set" {
    local args_log="${TEST_TMP}/podman_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    GIT_USER_EMAIL="alice@example.com"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
[ "\$1" = "pull" ] && exit 0
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    invoke_claude "test prompt" "" "" "" "# mock CLAUDE.md" 2>/dev/null
    grep -qx 'GIT_USER_EMAIL=alice@example.com' "${args_log}"
}

@test "invoke_claude passes GIT_SIGNING_KEY as container env var when set" {
    local args_log="${TEST_TMP}/podman_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    GIT_SIGNING_KEY="ABCD1234"
    make_gpg_stubs
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "secret" ] && exit 0
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    invoke_claude "test prompt" "" "" "" "# mock CLAUDE.md" 2>/dev/null
    grep -qx 'GIT_SIGNING_KEY=ABCD1234' "${args_log}"
}

@test "invoke_claude does not pass GIT_USER_NAME when not set" {
    local args_log="${TEST_TMP}/podman_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    GIT_USER_NAME=""
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
[ "\$1" = "pull" ] && exit 0
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    invoke_claude "test prompt" "" "" "" "# mock CLAUDE.md" 2>/dev/null
    run grep -qx 'GIT_USER_NAME=' "${args_log}"
    [ "${status}" -ne 0 ]
}

@test "invoke_claude does not mount the host HOME gitconfig" {
    local args_log="${TEST_TMP}/podman_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
[ "\$1" = "pull" ] && exit 0
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    invoke_claude "test prompt" "" "" "" "# mock CLAUDE.md" 2>/dev/null
    run grep -qF ".gitconfig" "${args_log}"
    [ "${status}" -ne 0 ]
}

# --- add_gpg_podman_args unit tests --------------------------------------------

@test "add_gpg_podman_args uses socket forwarding when extra socket and signing key are available" {
    make_gpg_stubs
    PODMAN_RUN_ARGS=()
    GIT_SIGNING_KEY="ABCD1234"
    add_gpg_podman_args
    # Should contain at least one --volume arg referencing /home/developer/.gnupg
    local found=0
    for arg in "${PODMAN_RUN_ARGS[@]}"; do
        [[ "${arg}" == *":/home/developer/.gnupg"* ]] && found=1
    done
    [ "${found}" -eq 1 ]
}

@test "add_gpg_podman_args mounts extra socket at /home/developer/.gnupg/S.gpg-agent:ro" {
    make_gpg_stubs
    PODMAN_RUN_ARGS=()
    GIT_SIGNING_KEY="ABCD1234"
    add_gpg_podman_args
    local found=0
    for arg in "${PODMAN_RUN_ARGS[@]}"; do
        [[ "${arg}" == *":/home/developer/.gnupg/S.gpg-agent:ro"* ]] && found=1
    done
    [ "${found}" -eq 1 ]
}

@test "add_gpg_podman_args sets GPG_PUBKEY_TMPDIR when forwarding succeeds" {
    make_gpg_stubs
    PODMAN_RUN_ARGS=()
    GIT_SIGNING_KEY="ABCD1234"
    GPG_PUBKEY_TMPDIR=""
    add_gpg_podman_args
    [ -n "${GPG_PUBKEY_TMPDIR}" ]
    [ -d "${GPG_PUBKEY_TMPDIR}" ]
}

@test "add_gpg_podman_args creates GPG_PUBKEY_TMPDIR under XDG_RUNTIME_DIR when set" {
    make_gpg_stubs
    export XDG_RUNTIME_DIR="${TEST_TMP}/runtime"
    mkdir -p "${XDG_RUNTIME_DIR}"
    PODMAN_RUN_ARGS=()
    GIT_SIGNING_KEY="ABCD1234"
    GPG_PUBKEY_TMPDIR=""
    add_gpg_podman_args
    [ -n "${GPG_PUBKEY_TMPDIR}" ]
    [[ "${GPG_PUBKEY_TMPDIR}" == "${XDG_RUNTIME_DIR}/"* ]]
}

@test "add_gpg_podman_args dies when extra socket is absent and GIT_SIGNING_KEY is set" {
    # No gpgconf stub → gpgconf fails, extra_socket is empty, [ -S "" ] is false.
    make_stub gpgconf 'exit 1'
    mkdir -p "${HOME}/.gnupg"
    PODMAN_RUN_ARGS=()
    GIT_SIGNING_KEY="ABCD1234"
    run add_gpg_podman_args
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"GPG agent extra socket not available"* ]]
    # No ~/.gnupg mount should be added — there is no safe fallback
    local found=0
    for arg in "${PODMAN_RUN_ARGS[@]}"; do
        [[ "${arg}" == *".gnupg"* ]] && found=1
    done
    [ "${found}" -eq 0 ]
}

@test "add_gpg_podman_args dies when gpg export fails" {
    local extra_socket="${TEST_TMP}/S.gpg-agent.extra"
    python3 -c "import socket,os; s=socket.socket(socket.AF_UNIX); s.bind('${extra_socket}')"
    cat > "${STUB_BIN}/gpgconf" << STUBEOF
#!/usr/bin/env bash
printf '%s\n' "${extra_socket}"
STUBEOF
    chmod +x "${STUB_BIN}/gpgconf"
    # gpg export produces empty output → import fails
    cat > "${STUB_BIN}/gpg" << 'STUBEOF'
#!/usr/bin/env bash
if [[ "$*" == *"--export"* ]]; then printf ''; exit 0; fi
if [[ "$*" == *"--import"* ]]; then exit 1; fi
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/gpg"
    mkdir -p "${HOME}/.gnupg"
    PODMAN_RUN_ARGS=()
    GIT_SIGNING_KEY="ABCD1234"
    run add_gpg_podman_args
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"GPG public key export/import failed"* ]]
    # No ~/.gnupg mount should be added — there is no safe fallback
    local found=0
    for arg in "${PODMAN_RUN_ARGS[@]}"; do
        [[ "${arg}" == *".gnupg"* ]] && found=1
    done
    [ "${found}" -eq 0 ]
}

@test "add_gpg_podman_args skips all mounts when GIT_SIGNING_KEY is empty and ~/.gnupg absent" {
    make_stub gpgconf 'exit 1'
    PODMAN_RUN_ARGS=()
    GIT_SIGNING_KEY=""
    add_gpg_podman_args 2>/dev/null
    local found=0
    for arg in "${PODMAN_RUN_ARGS[@]}"; do
        [[ "${arg}" == *".gnupg"* ]] && found=1
    done
    [ "${found}" -eq 0 ]
}

@test "add_gpg_podman_args prefers XDG_RUNTIME_DIR socket over gpgconf path when available" {
    local runtime_socket="${TEST_TMP}/runtime/gnupg/S.gpg-agent.extra"
    mkdir -p "${TEST_TMP}/runtime/gnupg"
    python3 -c "import socket,os; s=socket.socket(socket.AF_UNIX); s.bind('${runtime_socket}')"
    # gpgconf returns a path with no actual socket; the XDG runtime path should win.
    make_stub gpgconf 'printf "/no/such/socket\n"'
    cat > "${STUB_BIN}/gpg" << 'STUBEOF'
#!/usr/bin/env bash
if [[ "$*" == *"--export"* ]]; then printf 'FAKEPUBKEYDATA\n'; exit 0; fi
if [[ "$*" == *"--import"* ]]; then exit 0; fi
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/gpg"
    export XDG_RUNTIME_DIR="${TEST_TMP}/runtime"
    PODMAN_RUN_ARGS=()
    GIT_SIGNING_KEY="ABCD1234"
    add_gpg_podman_args
    local found=0
    for arg in "${PODMAN_RUN_ARGS[@]}"; do
        [[ "${arg}" == "${runtime_socket}"* ]] && found=1
    done
    [ "${found}" -eq 1 ]
}

@test "add_gpg_podman_args GPG_PUBKEY_TMPDIR is cleaned up by invoke_claude on success" {
    make_gpg_stubs
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/jq" << 'JQEOF'
#!/usr/bin/env bash
case "$2" in
    '.is_error // false')    printf 'false\n' ;;
    '.result // ""')         printf '\n' ;;
    '.session_id // empty')  printf '12345678-1234-1234-1234-123456789abc\n' ;;
esac
JQEOF
    chmod +x "${STUB_BIN}/jq"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "inspect" ] && exit 1
[ "$1" = "pull" ] && exit 0
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    GIT_SIGNING_KEY="ABCD1234"
    GPG_PUBKEY_TMPDIR=""
    invoke_claude "test prompt" "" "" "" "# per-item instructions" 2>/dev/null
    [ -z "${GPG_PUBKEY_TMPDIR}" ]
}

# --- preload_ssh_keys unit tests ----------------------------------------------

@test "preload_ssh_keys is a no-op when SSH_AUTH_SOCK is unset" {
    unset SSH_AUTH_SOCK
    make_stub ssh-add 'exit 1'
    run preload_ssh_keys
    [ "${status}" -eq 0 ]
}

@test "preload_ssh_keys is a no-op when SSH_AUTH_SOCK is not a socket" {
    export SSH_AUTH_SOCK="${TEST_TMP}/not-a-socket"
    make_stub ssh-add 'exit 1'
    run preload_ssh_keys
    [ "${status}" -eq 0 ]
}

@test "preload_ssh_keys is a no-op when keys are already loaded (ssh-add -l exits 0)" {
    local ssh_sock="${TEST_TMP}/ssh-agent.sock"
    python3 -c "import socket,os; s=socket.socket(socket.AF_UNIX); s.bind('${ssh_sock}')"
    export SSH_AUTH_SOCK="${ssh_sock}"
    # ssh-add -l returns 0 = keys present; ssh-add (load) should never be called
    cat > "${STUB_BIN}/ssh-add" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "-l" ] && exit 0
exit 1
STUBEOF
    chmod +x "${STUB_BIN}/ssh-add"
    run preload_ssh_keys
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"could not load"* ]]
}

@test "preload_ssh_keys calls ssh-add when agent has no keys (ssh-add -l exits 1)" {
    local ssh_sock="${TEST_TMP}/ssh-agent.sock"
    python3 -c "import socket,os; s=socket.socket(socket.AF_UNIX); s.bind('${ssh_sock}')"
    export SSH_AUTH_SOCK="${ssh_sock}"
    local add_log="${TEST_TMP}/ssh-add.log"
    cat > "${STUB_BIN}/ssh-add" << STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${add_log}"
[ "\$1" = "-l" ] && exit 1
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/ssh-add"
    preload_ssh_keys
    grep -qx "\-q" "${add_log}"
}

@test "preload_ssh_keys dies when ssh-add fails to load keys" {
    local ssh_sock="${TEST_TMP}/ssh-agent.sock"
    python3 -c "import socket,os; s=socket.socket(socket.AF_UNIX); s.bind('${ssh_sock}')"
    export SSH_AUTH_SOCK="${ssh_sock}"
    cat > "${STUB_BIN}/ssh-add" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "-l" ] && exit 1
exit 1
STUBEOF
    chmod +x "${STUB_BIN}/ssh-add"
    run preload_ssh_keys
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"no SSH keys could be loaded"* ]]
}

# --- stop_ssh_agent unit tests ------------------------------------------------

@test "stop_ssh_agent is a no-op when SSH_AUTH_SOCK is unset" {
    unset SSH_AUTH_SOCK
    local pkill_log="${TEST_TMP}/pkill.log"
    make_stub pkill "printf '%s\n' \"\$*\" >> \"${pkill_log}\""
    run stop_ssh_agent
    [ "${status}" -eq 0 ]
    [ ! -f "${pkill_log}" ]
}

@test "stop_ssh_agent calls pkill ssh-agent when SSH_AUTH_SOCK is set" {
    export SSH_AUTH_SOCK="${TEST_TMP}/ssh-agent.sock"
    local pkill_log="${TEST_TMP}/pkill.log"
    make_stub pkill "printf '%s\n' \"\$*\" >> \"${pkill_log}\"; exit 0"
    stop_ssh_agent
    grep -qx "ssh-agent" "${pkill_log}"
}

@test "stop_ssh_agent succeeds even when pkill finds no process" {
    export SSH_AUTH_SOCK="${TEST_TMP}/ssh-agent.sock"
    make_stub pkill 'exit 1'
    run stop_ssh_agent
    [ "${status}" -eq 0 ]
}

# --- cleanup_dangling_images unit tests ---------------------------------------

@test "cleanup_dangling_images calls podman image prune --force" {
    local args_log="${TEST_TMP}/podman_args"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "image" ] && printf '%s\n' "\$@" >> "${args_log}" && exit 0
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/podman"
    cleanup_dangling_images
    [ -f "${args_log}" ]
    grep -qFx 'image' "${args_log}"
    grep -qFx 'prune' "${args_log}"
    grep -qFx -- '--force' "${args_log}"
}

@test "cleanup_dangling_images succeeds even when podman image prune fails" {
    make_stub podman 'exit 1'
    run cleanup_dangling_images
    [ "${status}" -eq 0 ]
}

@test "invoke_claude prunes dangling images before pulling the orchestrator image" {
    local call_log="${TEST_TMP}/podman_calls"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "image" ]   && printf 'image_prune\n'  >> "${call_log}" && exit 0
[ "\$1" = "pull" ]    && printf 'pull\n'         >> "${call_log}" && exit 0
[ "\$1" = "inspect" ] && exit 1
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"
    invoke_claude "test prompt" "" "" "" "# mock CLAUDE.md" 2>/dev/null
    [ -f "${call_log}" ]
    local prune_line pull_line
    prune_line=$(grep -n 'image_prune' "${call_log}" | head -1 | cut -d: -f1)
    pull_line=$(grep -n 'pull' "${call_log}" | head -1 | cut -d: -f1)
    [ -n "${prune_line}" ]
    [ -n "${pull_line}" ]
    [ "${prune_line}" -lt "${pull_line}" ]
}

@test "invoke_claude prunes dangling images twice per run (before pull and after container exits)" {
    local call_log="${TEST_TMP}/podman_calls"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "image" ]   && printf 'image_prune\n'  >> "${call_log}" && exit 0
[ "\$1" = "pull" ]    && exit 0
[ "\$1" = "inspect" ] && exit 1
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"
    invoke_claude "test prompt" "" "" "" "# mock CLAUDE.md" 2>/dev/null
    [ -f "${call_log}" ]
    local count
    count=$(grep -c 'image_prune' "${call_log}")
    [ "${count}" -eq 2 ]
}

# --- SSH agent socket forwarding unit tests -----------------------------------

@test "invoke_claude mounts SSH_AUTH_SOCK as /tmp/ssh-agent.sock and sets env var" {
    local args_log="${TEST_TMP}/podman_args"
    local ssh_sock="${TEST_TMP}/ssh-agent.sock"
    python3 -c "import socket,os; s=socket.socket(socket.AF_UNIX); s.bind('${ssh_sock}')"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    SSH_AUTH_SOCK="${ssh_sock}"
    make_gpg_stubs
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"
    GIT_SIGNING_KEY=""
    invoke_claude "test prompt" "" "" "" "# mock CLAUDE.md" 2>/dev/null
    grep -q "${ssh_sock}:/tmp/ssh-agent.sock:ro" "${args_log}"
    grep -qx "SSH_AUTH_SOCK=/tmp/ssh-agent.sock" "${args_log}"
}

@test "invoke_claude warns and skips SSH mount when SSH_AUTH_SOCK is unset" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    unset SSH_AUTH_SOCK
    make_gpg_stubs
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "pull" ] && exit 0
[ "$1" = "inspect" ] && exit 1
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"
    GIT_SIGNING_KEY=""
    run invoke_claude "test prompt" "" "" "" "# mock CLAUDE.md"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"SSH_AUTH_SOCK is not set"* ]]
}

@test "invoke_claude warns and skips SSH mount when SSH_AUTH_SOCK path is not a socket" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    export SSH_AUTH_SOCK="${TEST_TMP}/nonexistent-sock"
    make_gpg_stubs
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "pull" ] && exit 0
[ "$1" = "inspect" ] && exit 1
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"
    GIT_SIGNING_KEY=""
    run invoke_claude "test prompt" "" "" "" "# mock CLAUDE.md"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"SSH_AUTH_SOCK is not set or socket is absent"* ]]
}

@test "invoke_claude does not mount ~/.ssh directory" {
    local args_log="${TEST_TMP}/podman_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}" "${HOME}/.ssh"
    unset SSH_AUTH_SOCK
    make_gpg_stubs
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"
    GIT_SIGNING_KEY=""
    invoke_claude "test prompt" "" "" "" "# mock CLAUDE.md" 2>/dev/null
    run grep -q "\.ssh:/home/developer/.ssh" "${args_log}"
    [ "${status}" -ne 0 ]
}

# --- $HOME/.database mount tests ----------------------------------------------

@test "invoke_claude mounts \$HOME/.database read-only when file exists" {
    local args_log="${TEST_TMP}/podman_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    printf 'fake-db-credentials\n' > "${HOME}/.database"
    unset SSH_AUTH_SOCK
    make_gpg_stubs
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"
    GIT_SIGNING_KEY=""
    invoke_claude "test prompt" "" "" "" "# mock CLAUDE.md" 2>/dev/null
    grep -q "${HOME}/.database:/home/developer/.database:ro" "${args_log}"
}

@test "invoke_claude warns and skips .database mount when \$HOME/.database is absent" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    /bin/rm -f "${HOME}/.database"
    unset SSH_AUTH_SOCK
    make_gpg_stubs
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "pull" ] && exit 0
[ "$1" = "inspect" ] && exit 1
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"
    GIT_SIGNING_KEY=""
    run invoke_claude "test prompt" "" "" "" "# mock CLAUDE.md"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *".database not found"* ]]
}

# --- invoke_claude prompt-file and empty-prompt guards ------------------------

@test "invoke_claude dies before starting podman when prompt is empty" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    local podman_log="${TEST_TMP}/podman_calls"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "${podman_log}"
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"
    run invoke_claude "" "" "" "" "# mock CLAUDE.md"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Prompt is empty"* ]]
    run grep -qx "run" "${podman_log}"
    [ "${status}" -ne 0 ]
}

@test "invoke_claude sets CLAUDE_PROMPT to the prompt text before starting the container" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "pull" ]    && exit 0
[ "$1" = "inspect" ] && exit 1
[ "$1" = "secret" ]  && exit 0
[ "$1" = "image" ]   && exit 0
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"
    invoke_claude "hello from prompt" "" "" "" "# mock CLAUDE.md" 2>/dev/null
    [ "${CLAUDE_PROMPT}" = "hello from prompt" ]
}

# --- notify_github_blocked unit tests -----------------------------------------

@test "notify_github_blocked posts issue comment and adds Blocked label for Issue" {
    cat > "${STUB_BIN}/gh" << 'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TEST_TMP}/gh.log"
GHEOF
    chmod +x "${STUB_BIN}/gh"
    REPO_FULL="owner/repo"
    notify_github_blocked "Issue" "42" "test message"
    grep -q "issue comment 42 --repo owner/repo" "${TEST_TMP}/gh.log"
    grep -q "issue edit 42 --repo owner/repo --add-label Blocked" "${TEST_TMP}/gh.log"
}

@test "notify_github_blocked posts pr comment and adds Blocked label for PullRequest" {
    cat > "${STUB_BIN}/gh" << 'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TEST_TMP}/gh.log"
GHEOF
    chmod +x "${STUB_BIN}/gh"
    REPO_FULL="owner/repo"
    notify_github_blocked "PullRequest" "7" "test message"
    grep -q "pr comment 7 --repo owner/repo" "${TEST_TMP}/gh.log"
    grep -q "pr edit 7 --repo owner/repo --add-label Blocked" "${TEST_TMP}/gh.log"
}

@test "notify_github_blocked is silent when item_type is empty" {
    cat > "${STUB_BIN}/gh" << 'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TEST_TMP}/gh.log"
GHEOF
    chmod +x "${STUB_BIN}/gh"
    REPO_FULL="owner/repo"
    notify_github_blocked "" "42" "test message"
    [ ! -f "${TEST_TMP}/gh.log" ]
}

# --- verify_gpg_signing_ready unit tests --------------------------------------

@test "verify_gpg_signing_ready passes when agent is running and key is present" {
    make_stub gpg-connect-agent 'exit 0'
    make_stub gpg 'exit 0'
    GIT_SIGNING_KEY="ABCD1234"
    run verify_gpg_signing_ready "" ""
    [ "${status}" -eq 0 ]
}

@test "verify_gpg_signing_ready is a no-op when GIT_SIGNING_KEY is empty" {
    make_stub gpg-connect-agent 'exit 1'
    GIT_SIGNING_KEY=""
    run verify_gpg_signing_ready "" ""
    [ "${status}" -eq 0 ]
}

@test "verify_gpg_signing_ready dies when gpg-agent is not running" {
    make_stub gpg-connect-agent 'exit 1'
    make_stub gh 'exit 0'
    GIT_SIGNING_KEY="ABCD1234"
    run verify_gpg_signing_ready "" ""
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"gpg-agent is not running"* ]]
}

@test "verify_gpg_signing_ready dies when signing key is absent from keyring" {
    make_stub gpg-connect-agent 'exit 0'
    cat > "${STUB_BIN}/gpg" << 'STUBEOF'
#!/usr/bin/env bash
if [[ "$*" == *"--list-secret-keys"* ]]; then exit 1; fi
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/gpg"
    make_stub gh 'exit 0'
    GIT_SIGNING_KEY="ABCD1234"
    run verify_gpg_signing_ready "" ""
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"not found in GPG keyring"* ]]
}

@test "verify_gpg_signing_ready notifies GitHub when gpg-agent is not running" {
    make_stub gpg-connect-agent 'exit 1'
    cat > "${STUB_BIN}/gh" << 'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TEST_TMP}/gh.log"
GHEOF
    chmod +x "${STUB_BIN}/gh"
    REPO_FULL="owner/repo"
    GIT_SIGNING_KEY="ABCD1234"
    run verify_gpg_signing_ready "Issue" "42"
    [ "${status}" -ne 0 ]
    [ -f "${TEST_TMP}/gh.log" ]
    grep -q "issue comment 42 --repo owner/repo" "${TEST_TMP}/gh.log"
}

@test "verify_gpg_signing_ready notifies GitHub when signing key is absent" {
    make_stub gpg-connect-agent 'exit 0'
    cat > "${STUB_BIN}/gpg" << 'STUBEOF'
#!/usr/bin/env bash
if [[ "$*" == *"--list-secret-keys"* ]]; then exit 1; fi
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/gpg"
    cat > "${STUB_BIN}/gh" << 'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TEST_TMP}/gh.log"
GHEOF
    chmod +x "${STUB_BIN}/gh"
    REPO_FULL="owner/repo"
    GIT_SIGNING_KEY="ABCD1234"
    run verify_gpg_signing_ready "Issue" "42"
    [ "${status}" -ne 0 ]
    [ -f "${TEST_TMP}/gh.log" ]
    grep -q "issue comment 42 --repo owner/repo" "${TEST_TMP}/gh.log"
}

# --- ensure_repo_current: SSH URL enforcement ---------------------------------

@test "ensure_repo_current resets HTTPS origin URL to SSH before fetching" {
    mkdir -p "${REPO_WORK_DIR}/.git"
    local git_log="${TEST_TMP}/git_calls"
    # PATH stub avoids shell function override (which triggers SC2218 on earlier
    # real git calls in the file) and avoids real git operations in temp dirs
    # that fail in CI due to GIT_CONFIG_GLOBAL safe.directory restrictions.
    cat > "${STUB_BIN}/git" << STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${git_log}"
for arg in "\$@"; do [ "\${arg}" = "--show-current" ] && { printf 'main\n'; exit 0; }; done
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/git"
    # Flush the bash hash table so PATH is re-searched for git; without this
    # the subshell created by `run` inherits the cached real-git path and
    # bypasses the stub.
    hash git

    run ensure_repo_current
    [ "${status}" -eq 0 ]
    grep -q "config remote.origin.url git@github.com:${OWNER}/${REPO}.git" "${git_log}"
}

@test "ensure_repo_current clears all fetch and push URL entries before setting the canonical SSH URL" {
    mkdir -p "${REPO_WORK_DIR}/.git"
    local git_log="${TEST_TMP}/git_calls"
    cat > "${STUB_BIN}/git" << STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${git_log}"
for arg in "\$@"; do [ "\${arg}" = "--show-current" ] && { printf 'main\n'; exit 0; }; done
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/git"
    # Flush the bash hash table so PATH is re-searched for git; without this
    # the subshell created by `run` inherits the cached real-git path and
    # bypasses the stub.
    hash git

    run ensure_repo_current
    [ "${status}" -eq 0 ]
    # All existing fetch URLs must be removed first (--unset-all handles multiple entries).
    grep -q "config --unset-all remote.origin.url" "${git_log}"
    # Exactly the canonical SSH URL must be written as the sole fetch URL.
    grep -q "config remote.origin.url git@github.com:${REPO_FULL}.git" "${git_log}"
    # All push-URL overrides must be removed (--unset-all handles multiple entries).
    grep -q "config --unset-all remote.origin.pushurl" "${git_log}"
}

@test "ensure_repo_current unsets url pushInsteadOf rules left in local git config by a previous agent session" {
    mkdir -p "${REPO_WORK_DIR}/.git"
    local git_log="${TEST_TMP}/git_calls"
    cat > "${STUB_BIN}/git" << STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${git_log}"
for arg in "\$@"; do [ "\${arg}" = "--show-current" ] && { printf 'main\n'; exit 0; }; done
case "\$*" in
    *"--local --name-only --list"*)
        printf 'url.https://x-oauth-basic:@github.com/.pushinsteadof\n'
        exit 0
        ;;
esac
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/git"
    hash git

    run ensure_repo_current
    [ "${status}" -eq 0 ]
    grep -q -- "--local --unset-all url.https://x-oauth-basic:@github.com/.pushinsteadof" "${git_log}"
}

# --- disk_space_available_kb --------------------------------------------------

@test "disk_space_available_kb outputs a numeric value" {
    make_stub df 'printf "Filesystem 1K-blocks Used Available Use%% Mounted on\ntmpfs 4096000 1024 4094976 1%% /\n"'
    hash df
    run disk_space_available_kb
    [ "${status}" -eq 0 ]
    [[ "${output}" =~ ^[0-9]+$ ]]
}

@test "disk_space_available_kb uses WORK path when it exists" {
    mkdir -p "${TEST_TMP}/work"
    WORK="${TEST_TMP}/work"
    local df_log="${TEST_TMP}/df_calls"
    make_stub df "printf '%s\n' \"\$*\" >> ${df_log}; printf 'Filesystem 1K-blocks Used Available Use%% Mounted on\ntmpfs 4096000 1024 20971520 1%% /\n'"
    hash df
    run disk_space_available_kb
    [ "${status}" -eq 0 ]
    grep -q "${TEST_TMP}/work" "${df_log}"
}

@test "disk_space_available_kb falls back to HOME when WORK does not exist" {
    WORK="${TEST_TMP}/nonexistent"
    local df_log="${TEST_TMP}/df_calls"
    make_stub df "printf '%s\n' \"\$*\" >> ${df_log}; printf 'Filesystem 1K-blocks Used Available Use%% Mounted on\ntmpfs 4096000 1024 20971520 1%% /\n'"
    hash df
    run disk_space_available_kb
    [ "${status}" -eq 0 ]
    grep -q "${HOME}" "${df_log}"
}

# --- check_disk_space ---------------------------------------------------------

@test "check_disk_space returns 0 when space is above threshold" {
    # 20 GB available; MIN_DISK_SPACE_KB = 10 * 1024 * 1024 = 10485760
    disk_space_available_kb() { printf '20971520\n'; }
    run check_disk_space
    [ "${status}" -eq 0 ]
}

@test "check_disk_space returns 1 when space is below threshold" {
    # 5 GB available
    disk_space_available_kb() { printf '5242880\n'; }
    run check_disk_space
    [ "${status}" -ne 0 ]
}

@test "check_disk_space returns 0 when space equals threshold" {
    # Exactly 10 GB available
    disk_space_available_kb() { printf '10485760\n'; }
    run check_disk_space
    [ "${status}" -eq 0 ]
}

@test "check_disk_space warns and returns 0 when df output is unparseable" {
    disk_space_available_kb() { printf 'not-a-number\n'; }
    run check_disk_space
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Could not determine available disk space"* ]]
}

@test "check_disk_space warns and returns 0 when df output is empty" {
    disk_space_available_kb() { printf ''; }
    run check_disk_space
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Could not determine available disk space"* ]]
}

# --- notify_discord_low_disk_space --------------------------------------------

@test "notify_discord_low_disk_space does nothing when DISCORD_WEBHOOK_URL is unset" {
    DISCORD_WEBHOOK_URL=""
    disk_space_available_kb() { printf '5242880\n'; }
    local curl_log="${TEST_TMP}/curl_log"
    make_stub curl "printf 'called\n' >> ${curl_log}"
    hash curl
    run notify_discord_low_disk_space
    [ "${status}" -eq 0 ]
    [ ! -f "${curl_log}" ]
}

@test "notify_discord_low_disk_space sends embed when webhook is set and space is low" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    disk_space_available_kb() { printf '5242880\n'; }
    local curl_log="${TEST_TMP}/curl_log"
    make_stub curl "printf '%s\n' \"\$*\" >> ${curl_log}"
    hash curl
    run notify_discord_low_disk_space
    [ "${status}" -eq 0 ]
    [ -f "${curl_log}" ]
    grep -q "discord.example.com" "${curl_log}"
}

@test "notify_discord_low_disk_space includes owner in title when owner is provided" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    disk_space_available_kb() { printf '5242880\n'; }
    local curl_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> ${curl_log}"
    hash curl
    run notify_discord_low_disk_space "myowner"
    [ "${status}" -eq 0 ]
    [ -f "${curl_log}" ]
    grep -q "myowner" "${curl_log}"
}

@test "notify_discord_low_disk_space suppresses duplicate notification within 1 hour" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    disk_space_available_kb() { printf '5242880\n'; }
    local curl_log="${TEST_TMP}/curl_log"
    make_stub curl "printf 'called\n' >> ${curl_log}"
    hash curl

    # Write a state file with a timestamp from 30 minutes ago.
    mkdir -p "${HOME}/.orchestrator"
    printf '%s\n' "$(( $(date +%s) - 1800 ))" > "${HOME}/.orchestrator/.low_disk_space__global.state"

    run notify_discord_low_disk_space
    [ "${status}" -eq 0 ]
    [ ! -f "${curl_log}" ]
}

@test "notify_discord_low_disk_space resends after 1 hour has elapsed" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    disk_space_available_kb() { printf '5242880\n'; }
    local curl_log="${TEST_TMP}/curl_log"
    make_stub curl "printf 'called\n' >> ${curl_log}"
    hash curl

    # Write a state file with a timestamp from 90 minutes ago.
    mkdir -p "${HOME}/.orchestrator"
    printf '%s\n' "$(( $(date +%s) - 5400 ))" > "${HOME}/.orchestrator/.low_disk_space__global.state"

    run notify_discord_low_disk_space
    [ "${status}" -eq 0 ]
    [ -f "${curl_log}" ]
}

@test "notify_discord_low_disk_space uses owner-scoped state file" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    disk_space_available_kb() { printf '5242880\n'; }
    local curl_log="${TEST_TMP}/curl_log"
    make_stub curl "printf 'called\n' >> ${curl_log}"
    hash curl

    # Write a state file for a different owner — should not suppress this call.
    mkdir -p "${HOME}/.orchestrator"
    printf '%s\n' "$(( $(date +%s) - 1800 ))" > "${HOME}/.orchestrator/.low_disk_space_other_owner.state"

    run notify_discord_low_disk_space "myowner"
    [ "${status}" -eq 0 ]
    [ -f "${curl_log}" ]
}

# --- main: disk space check ---------------------------------------------------

@test "main exits cleanly without launching work when disk space is low" {
    setup_main_mocks
    check_disk_space() { return 1; }
    fetch_all_priorities() {
        printf '%s\n' '[{"id":1,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    local claude_log="${TEST_TMP}/claude_log"
    invoke_claude() { printf 'called\n' >> "${claude_log}"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Insufficient disk space"* ]]
    [ ! -f "${claude_log}" ]
}

@test "main notifies Discord when disk space is low" {
    setup_main_mocks
    check_disk_space() { return 1; }
    fetch_all_priorities() {
        printf '%s\n' '[{"id":1,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    local discord_log="${TEST_TMP}/discord_log"
    notify_discord_low_disk_space() { printf 'notified\n' >> "${discord_log}"; }

    run main
    [ "${status}" -eq 0 ]
    [ -f "${discord_log}" ]
}

@test "main proceeds normally when disk space is sufficient" {
    setup_main_mocks
    check_disk_space() { return 0; }
    fetch_all_priorities() {
        printf '%s\n' '[{"id":1,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[{"name":"Blocked"}],"comments":[],"assignees":[],"milestone":null}\n'; }
    issue_json_has_blocked_label() { return 0; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"Insufficient disk space"* ]]
}

# --- MAX_REVIEW_ITERATIONS constant -------------------------------------------

@test "MAX_REVIEW_ITERATIONS defaults to 3" {
    [ "${MAX_REVIEW_ITERATIONS}" -eq 3 ]
}

@test "MAX_REVIEW_ITERATIONS can be overridden via environment variable" {
    MAX_REVIEW_ITERATIONS=5
    [ "${MAX_REVIEW_ITERATIONS}" -eq 5 ]
}

# --- build_issue_claude_md plan-first steps -----------------------------------

@test "build_issue_claude_md includes plan-check command" {
    run build_issue_claude_md 42 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Implementation Plan"* ]]
    [[ "${output}" == *'any(test("## Implementation Plan"'* ]]
}

@test "build_issue_claude_md instructs agent to post plan comment in correct format" {
    run build_issue_claude_md 42 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"### Files to change"* ]]
    [[ "${output}" == *"### Approach"* ]]
    [[ "${output}" == *"### Test strategy"* ]]
    [[ "${output}" == *"### Assumptions"* ]]
    [[ "${output}" == *"### Open questions"* ]]
}

@test "build_issue_claude_md describes plan mode and implementation mode" {
    run build_issue_claude_md 42 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Plan mode"* ]]
    [[ "${output}" == *"Implementation mode"* ]]
}

@test "build_issue_claude_md does not include WF section when _WF_PROJECT_ID is empty" {
    _WF_PROJECT_ID=""
    run build_issue_claude_md 42 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"WF_PROJECT_ID"* ]]
    [[ "${output}" != *"WF_PLANNING"* ]]
}

@test "build_issue_claude_md includes WF section when _WF_PROJECT_ID is set" {
    _WF_PROJECT_ID="PVT_test123"
    _WF_STATUS_FIELD_ID="PVTSSF_field456"
    _WF_OPTION_IDS[Planning]="opt_plan_id"
    _WF_OPTION_IDS[Development]="opt_dev_id"
    run build_issue_claude_md 42 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"WF_PROJECT_ID=PVT_test123"* ]]
    [[ "${output}" == *"WF_STATUS_FIELD_ID=PVTSSF_field456"* ]]
    [[ "${output}" == *"WF_PLANNING=opt_plan_id"* ]]
    [[ "${output}" == *"WF_DEVELOPMENT=opt_dev_id"* ]]
}

@test "build_issue_claude_md without board uses comment-based approval fallback" {
    _WF_PROJECT_ID=""
    run build_issue_claude_md 42 "/resolved/.ai-instructions" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"approved|go ahead|looks good|lgtm"* ]]
    [[ "${output}" != *"approved on the Workflow board"* ]]
}

@test "build_issue_claude_md with board and plan not approved shows board-pending text" {
    _WF_PROJECT_ID="PVT_test"
    run build_issue_claude_md 42 "/resolved/.ai-instructions" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Workflow board"* ]]
    [[ "${output}" != *"approved|go ahead"* ]]
}

@test "build_issue_claude_md with plan_approved=true shows board-approved text" {
    _WF_PROJECT_ID="PVT_test"
    run build_issue_claude_md 42 "/resolved/.ai-instructions" "" "true"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"approved on the Workflow board"* ]]
    [[ "${output}" == *"Implementation mode"* ]]
}

@test "build_issue_claude_md approval instruction mentions Workflow board when board is configured" {
    _WF_PROJECT_ID="PVT_test"
    run build_issue_claude_md 42 "/resolved/.ai-instructions" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'set the Workflow board status to "Approved"'* ]]
}

@test "build_issue_claude_md approval instruction mentions approval comment when no board" {
    _WF_PROJECT_ID=""
    run build_issue_claude_md 42 "/resolved/.ai-instructions" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"approval comment"* ]]
}

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
    _WF_APPROVED_CACHED_REPO=""
    local items_json='{"data":{"node":{"items":{"nodes":[{"content":{"number":42,"repository":{"nameWithOwner":"owner/repo"}},"fieldValues":{"nodes":[{"optionId":"opt_approved"}]}},{"content":{"number":99,"repository":{"nameWithOwner":"owner/repo"}},"fieldValues":{"nodes":[{"optionId":"opt_other"}]}}]}}}}'
    make_stub gh "printf '%s\n' '${items_json}'"
    fetch_board_approved_items
    [ "${_WF_APPROVED_ITEMS["owner/repo/42"]:-}" = "1" ]
    [ "${_WF_APPROVED_ITEMS["owner/repo/99"]:-}" != "1" ]
}

@test "fetch_board_approved_items caches per repo and does not re-call gh on second call" {
    _WF_PROJECT_ID="PVT_test"
    _WF_OPTION_IDS[Approved]="opt_approved"
    _WF_APPROVED_CACHED_REPO=""
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
    _WF_APPROVED_CACHED_REPO=""
    make_stub gh 'exit 1'
    fetch_board_approved_items
    [ -z "${_WF_APPROVED_ITEMS[*]:-}" ]
}

@test "fetch_board_approved_items paginates and finds item on second page" {
    _WF_PROJECT_ID="PVT_test"
    _WF_OPTION_IDS[Approved]="opt_approved"
    _WF_APPROVED_CACHED_REPO=""
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
    _WF_APPROVED_CACHED_REPO=""
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
    _WF_APPROVED_CACHED_REPO=""
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
    _WF_APPROVED_CACHED_REPO=""
    local fv
    fv='[{"optionId":"x"},{"optionId":"x"},{"optionId":"x"},{"optionId":"x"},{"optionId":"x"},{"optionId":"x"},{"optionId":"x"},{"optionId":"x"},{"optionId":"x"},{"optionId":"x"},{"optionId":"x"},{"optionId":"x"},{"optionId":"x"},{"optionId":"x"},{"optionId":"opt_approved"}]'
    local items_json
    items_json='{"data":{"node":{"items":{"pageInfo":{"endCursor":null,"hasNextPage":false},"nodes":[{"content":{"number":5,"repository":{"nameWithOwner":"owner/repo"}},"fieldValues":{"nodes":'"${fv}"'}}]}}}}'
    make_stub gh "printf '%s\n' '${items_json}'"
    fetch_board_approved_items
    [ "${_WF_APPROVED_ITEMS["owner/repo/5"]:-}" = "1" ]
}

# --- build_pr_claude_md review-loop steps ------------------------------------

@test "build_pr_claude_md includes code-review loop instructions" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"/code-review --comment"* ]]
    [[ "${output}" == *"AI Review"* ]]
}

@test "build_pr_claude_md includes security-review loop instructions" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"/security-review"* ]]
    [[ "${output}" == *"AI Security Review"* ]]
}

@test "build_pr_claude_md embeds MAX_REVIEW_ITERATIONS value in review loop" {
    MAX_REVIEW_ITERATIONS=3
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"3 times total"* ]]
}

@test "build_pr_claude_md embeds custom MAX_REVIEW_ITERATIONS when overridden" {
    MAX_REVIEW_ITERATIONS=5
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"5 times total"* ]]
}

@test "build_pr_claude_md does not include WF section when _WF_PROJECT_ID is empty" {
    _WF_PROJECT_ID=""
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"WF_PROJECT_ID"* ]]
}

@test "build_pr_claude_md includes WF section when _WF_PROJECT_ID is set" {
    _WF_PROJECT_ID="PVT_pr_proj"
    _WF_STATUS_FIELD_ID="PVTSSF_pr_field"
    _WF_OPTION_IDS["AI Review"]="opt_air_id"
    _WF_OPTION_IDS["Human Review"]="opt_hr_id"
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"WF_PROJECT_ID=PVT_pr_proj"* ]]
    [[ "${output}" == *'WF_AI_REVIEW=opt_air_id'* ]]
    [[ "${output}" == *'WF_HUMAN_REVIEW=opt_hr_id'* ]]
}

# --- _build_wf_section unit tests ---------------------------------------------

@test "_build_wf_section outputs nothing when _WF_PROJECT_ID is empty" {
    _WF_PROJECT_ID=""
    run _build_wf_section
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "_build_wf_section outputs project ID and field ID when set" {
    _WF_PROJECT_ID="PVT_abc123"
    _WF_STATUS_FIELD_ID="PVTSSF_def456"
    run _build_wf_section
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"WF_PROJECT_ID=PVT_abc123"* ]]
    [[ "${output}" == *"WF_STATUS_FIELD_ID=PVTSSF_def456"* ]]
}

@test "_build_wf_section outputs all eight status option keys" {
    _WF_PROJECT_ID="PVT_test"
    _WF_STATUS_FIELD_ID="PVTSSF_test"
    _WF_OPTION_IDS["Not Started"]="opt1"
    _WF_OPTION_IDS[Planning]="opt2"
    _WF_OPTION_IDS[Approved]="opt3"
    _WF_OPTION_IDS[Development]="opt4"
    _WF_OPTION_IDS["AI Review"]="opt5"
    _WF_OPTION_IDS["AI Security Review"]="opt6"
    _WF_OPTION_IDS["Human Review"]="opt7"
    _WF_OPTION_IDS[Complete]="opt8"
    run _build_wf_section
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"WF_NOT_STARTED=opt1"* ]]
    [[ "${output}" == *"WF_PLANNING=opt2"* ]]
    [[ "${output}" == *"WF_APPROVED=opt3"* ]]
    [[ "${output}" == *"WF_DEVELOPMENT=opt4"* ]]
    [[ "${output}" == *"WF_AI_REVIEW=opt5"* ]]
    [[ "${output}" == *"WF_AI_SECURITY_REVIEW=opt6"* ]]
    [[ "${output}" == *"WF_HUMAN_REVIEW=opt7"* ]]
    [[ "${output}" == *"WF_COMPLETE=opt8"* ]]
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

@test "discover_or_create_workflow_project populates _WF_PROJECT_ID from existing project" {
    local project_json='[{"id":"PVT_found","title":"Workflow","fields":{"nodes":[{"id":"PVTSSF_f1","name":"Workflow Status","options":[{"id":"oid1","name":"Planning"},{"id":"oid2","name":"Development"}]}]}}]'
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
if [[ "\$*" == *"projectsV2"* ]]; then
    printf '%s\n' '${project_json}'
    exit 0
fi
exit 1
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    discover_or_create_workflow_project
    [ "${_WF_PROJECT_ID}" = "PVT_found" ]
    [ "${_WF_STATUS_FIELD_ID}" = "PVTSSF_f1" ]
    [ "${_WF_OPTION_IDS[Planning]}" = "oid1" ]
    [ "${_WF_OPTION_IDS[Development]}" = "oid2" ]
}

@test "discover_or_create_workflow_project returns immediately on second call for same repo when first succeeded" {
    local project_json='[{"id":"PVT_cache","title":"Workflow","fields":{"nodes":[{"id":"PVTSSF_c1","name":"Workflow Status","options":[{"id":"oid1","name":"Planning"}]}]}}]'
    local call_count_file="${TEST_TMP}/gh_calls"
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
printf 'called\n' >> "${call_count_file}"
if [[ "\$*" == *"projectsV2"* ]]; then
    printf '%s\n' '${project_json}'
    exit 0
fi
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    discover_or_create_workflow_project
    local count_after_first
    count_after_first=$(wc -l < "${call_count_file}" 2>/dev/null || printf '0\n')
    discover_or_create_workflow_project
    local count_after_second
    count_after_second=$(wc -l < "${call_count_file}" 2>/dev/null || printf '0\n')
    # Second call must not invoke gh at all (cache hit)
    [ "${count_after_second}" -eq "${count_after_first}" ]
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

@test "discover_or_create_workflow_project enables Projects when hasProjectsEnabled is false" {
    local project_json='[{"id":"PVT_found","title":"Workflow","fields":{"nodes":[{"id":"PVTSSF_f1","name":"Workflow Status","options":[{"id":"oid1","name":"Not Started"}]}]}}]'
    local gh_log="${TEST_TMP}/gh_calls"
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${gh_log}"
if [[ "\$*" == *"hasProjectsEnabled"* ]]; then printf 'false\n'; exit 0; fi
if [[ "\$*" == *"repo edit"* ]]; then exit 0; fi
if [[ "\$*" == *"projectsV2"* ]]; then printf '%s\n' '${project_json}'; exit 0; fi
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    discover_or_create_workflow_project
    grep -q 'enable-projects' "${gh_log}"
    [ "${_WF_PROJECT_ID}" = "PVT_found" ]
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
    printf '[]\n'
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

# --- CI pending gate ---------------------------------------------------------

@test "pr_json_has_pending_ci_checks returns true when a required check has status IN_PROGRESS" {
    run pr_json_has_pending_ci_checks '{"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null,"isRequired":true}]}'
    [ "${status}" -eq 0 ]
}

@test "pr_json_has_pending_ci_checks returns true when a required check has status QUEUED" {
    run pr_json_has_pending_ci_checks '{"statusCheckRollup":[{"name":"ci","status":"QUEUED","conclusion":null,"isRequired":true}]}'
    [ "${status}" -eq 0 ]
}

@test "pr_json_has_pending_ci_checks returns true when one of many required checks is not COMPLETED" {
    run pr_json_has_pending_ci_checks '{"statusCheckRollup":[{"name":"tests","status":"COMPLETED","conclusion":"SUCCESS","isRequired":true},{"name":"lint","status":"IN_PROGRESS","conclusion":null,"isRequired":true}]}'
    [ "${status}" -eq 0 ]
}

@test "pr_json_has_pending_ci_checks returns false when all checks are COMPLETED" {
    run pr_json_has_pending_ci_checks '{"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS","isRequired":true}]}'
    [ "${status}" -ne 0 ]
}

@test "pr_json_has_pending_ci_checks returns false when a non-required check is pending" {
    run pr_json_has_pending_ci_checks '{"statusCheckRollup":[{"name":"badge","status":"IN_PROGRESS","conclusion":null,"isRequired":false}]}'
    [ "${status}" -ne 0 ]
}

@test "pr_json_has_pending_ci_checks returns true when a pending check has no isRequired field" {
    run pr_json_has_pending_ci_checks '{"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null}]}'
    [ "${status}" -eq 0 ]
}

@test "pr_json_has_pending_ci_checks returns false when statusCheckRollup is empty" {
    run pr_json_has_pending_ci_checks '{"statusCheckRollup":[]}'
    [ "${status}" -ne 0 ]
}

@test "pr_json_has_pending_ci_checks returns false when statusCheckRollup is absent" {
    run pr_json_has_pending_ci_checks '{}'
    [ "${status}" -ne 0 ]
}

@test "clear_pr_ci_pending_state removes the state file when it exists" {
    save_pr_head_oid 42 "deadbeef" "1700000000"
    local state_file
    state_file=$(pr_head_oid_file_path 42)
    [ -f "${state_file}" ]
    clear_pr_ci_pending_state 42
    [ ! -f "${state_file}" ]
}

@test "clear_pr_ci_pending_state succeeds silently when no state file exists" {
    run clear_pr_ci_pending_state 99
    [ "${status}" -eq 0 ]
}

@test "load_pr_head_oid returns empty string when no state file exists" {
    run load_pr_head_oid 42
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "save_pr_head_oid and load_pr_head_oid round-trip the OID and timestamp" {
    save_pr_head_oid 42 "deadbeef" "1700000000"
    run load_pr_head_oid 42
    [ "${status}" -eq 0 ]
    [ "${output}" = "deadbeef 1700000000" ]
}

@test "ci_checks_timed_out returns false and writes state on first call for a new OID" {
    local pr_json='{"headRefOid":"abc123","statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null}]}'
    run ci_checks_timed_out 42 "${pr_json}"
    [ "${status}" -ne 0 ]
    local state_file
    state_file=$(pr_head_oid_file_path 42)
    [ -f "${state_file}" ]
    [[ "$(cat "${state_file}")" == "abc123 "* ]]
}

@test "ci_checks_timed_out returns false when elapsed time is below CI_CHECK_TIMEOUT_MINUTES" {
    local pr_json='{"headRefOid":"abc123","statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null}]}'
    local now
    now=$(date +%s)
    save_pr_head_oid 42 "abc123" "${now}"
    CI_CHECK_TIMEOUT_MINUTES=60
    run ci_checks_timed_out 42 "${pr_json}"
    [ "${status}" -ne 0 ]
}

@test "ci_checks_timed_out returns true when elapsed time exceeds CI_CHECK_TIMEOUT_MINUTES" {
    local pr_json='{"headRefOid":"abc123","statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null}]}'
    local old_time
    old_time=$(( $(date +%s) - 7200 ))
    save_pr_head_oid 42 "abc123" "${old_time}"
    CI_CHECK_TIMEOUT_MINUTES=60
    run ci_checks_timed_out 42 "${pr_json}"
    [ "${status}" -eq 0 ]
}

@test "ci_checks_timed_out resets the clock and returns false when the OID changes" {
    local pr_json='{"headRefOid":"new-oid","statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null}]}'
    local old_time
    old_time=$(( $(date +%s) - 7200 ))
    save_pr_head_oid 42 "old-oid" "${old_time}"
    CI_CHECK_TIMEOUT_MINUTES=60
    run ci_checks_timed_out 42 "${pr_json}"
    [ "${status}" -ne 0 ]
    local state_file
    state_file=$(pr_head_oid_file_path 42)
    [[ "$(cat "${state_file}")" == "new-oid "* ]]
}

@test "ci_checks_timed_out returns false and writes no state when headRefOid is absent" {
    local pr_json='{"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null}]}'
    run ci_checks_timed_out 42 "${pr_json}"
    [ "${status}" -ne 0 ]
    local state_file
    state_file=$(pr_head_oid_file_path 42)
    [ ! -f "${state_file}" ]
}

@test "ci_checks_timed_out returns false and resets state when state file has no space (corrupted)" {
    local pr_json='{"headRefOid":"abc123","statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null}]}'
    local state_file
    state_file=$(pr_head_oid_file_path 42)
    mkdir -p "${SESSION_BASE_DIR}"
    printf 'abc123' > "${state_file}"
    CI_CHECK_TIMEOUT_MINUTES=60
    run ci_checks_timed_out 42 "${pr_json}"
    [ "${status}" -ne 0 ]
    [[ "$(cat "${state_file}")" == "abc123 "* ]]
}

@test "main defers agent invocation when PR has pending CI checks within timeout" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null,"isRequired":true}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fingerprint_pr_json() { printf 'fp-new\n'; }
    load_pr_fingerprint()  { printf 'fp-old\n'; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }
    CI_CHECK_TIMEOUT_MINUTES=60

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"CI checks pending"* ]]
}

@test "main blocks PR and posts complaint when CI checks exceed timeout" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null,"isRequired":true}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fingerprint_pr_json() { printf 'fp-new\n'; }
    load_pr_fingerprint()  { printf 'fp-old\n'; }
    local old_time
    old_time=$(( $(date +%s) - 7200 ))
    save_pr_head_oid 5 "abc" "${old_time}"
    CI_CHECK_TIMEOUT_MINUTES=60
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"timeout"* ]]
    grep -q 'pr comment 5' "${GH_CALL_LOG}"
    grep -q 'Blocked' "${GH_CALL_LOG}"
}

@test "main invokes agent when PR CI checks are all COMPLETED" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fingerprint_pr_json() { printf 'fp-new\n'; }
    load_pr_fingerprint()  { printf 'fp-old\n'; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ -f "${TEST_TMP}/claude_log" ]
}

@test "main blocks unchanged PR when CI has been pending past timeout in direct-PR path" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null,"isRequired":true}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fingerprint_pr_json() { printf 'fp-same\n'; }
    load_pr_fingerprint()  { printf 'fp-same\n'; }
    local old_time
    old_time=$(( $(date +%s) - 7200 ))
    save_pr_head_oid 5 "abc" "${old_time}"
    CI_CHECK_TIMEOUT_MINUTES=60
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"timeout"* ]]
    grep -q 'pr comment 5' "${GH_CALL_LOG}"
    grep -q 'Blocked' "${GH_CALL_LOG}"
}

@test "main blocks PR and posts complaint when CI checks exceed timeout in Issue-to-PR pivot path" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf '7\n'; }
    fetch_issue_json()         { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    issue_json_has_blocked_label() { return 1; }
    fetch_pr_json()            { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null,"isRequired":true}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    pr_json_has_blocked_label() { return 1; }
    fingerprint_pr_json()      { printf 'fp-same\n'; }
    load_pr_fingerprint()      { printf 'fp-same\n'; }
    local old_time
    old_time=$(( $(date +%s) - 7200 ))
    save_pr_head_oid 7 "abc" "${old_time}"
    CI_CHECK_TIMEOUT_MINUTES=60
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"timeout"* ]]
    grep -q 'pr comment 7' "${GH_CALL_LOG}"
    grep -q 'Blocked' "${GH_CALL_LOG}"
}

@test "main clears CI pending state file when direct-PR CI timeout fires" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null,"isRequired":true}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fingerprint_pr_json() { printf 'fp-same\n'; }
    load_pr_fingerprint()  { printf 'fp-same\n'; }
    local old_time
    old_time=$(( $(date +%s) - 7200 ))
    save_pr_head_oid 5 "abc" "${old_time}"
    CI_CHECK_TIMEOUT_MINUTES=60
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    local state_file
    state_file=$(pr_head_oid_file_path 5)
    [ ! -f "${state_file}" ]
}

@test "main clears CI pending state file when Issue-to-PR CI timeout fires" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf '7\n'; }
    fetch_issue_json()         { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    issue_json_has_blocked_label() { return 1; }
    fetch_pr_json()            { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null,"isRequired":true}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    pr_json_has_blocked_label() { return 1; }
    fingerprint_pr_json()      { printf 'fp-same\n'; }
    load_pr_fingerprint()      { printf 'fp-same\n'; }
    local old_time
    old_time=$(( $(date +%s) - 7200 ))
    save_pr_head_oid 7 "abc" "${old_time}"
    CI_CHECK_TIMEOUT_MINUTES=60
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    local state_file
    state_file=$(pr_head_oid_file_path 7)
    [ ! -f "${state_file}" ]
}

@test "main clears CI pending state file when direct-PR CI completes and fingerprint is unchanged" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS","isRequired":true}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fingerprint_pr_json() { printf 'fp-same\n'; }
    load_pr_fingerprint()  { printf 'fp-same\n'; }
    local old_time
    old_time=$(( $(date +%s) - 30 ))
    save_pr_head_oid 5 "abc" "${old_time}"
    CI_CHECK_TIMEOUT_MINUTES=60
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    local state_file
    state_file=$(pr_head_oid_file_path 5)
    [ ! -f "${state_file}" ]
}

@test "main preserves CI pending state file when direct-PR is skipped while CI still pending" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null,"isRequired":true}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fingerprint_pr_json() { printf 'fp-same\n'; }
    load_pr_fingerprint()  { printf 'fp-same\n'; }
    CI_CHECK_TIMEOUT_MINUTES=60
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    local state_file
    state_file=$(pr_head_oid_file_path 5)
    [ -f "${state_file}" ]
}

@test "main preserves CI pending state file when Issue-to-PR pivot skips due to both FPs unchanged while CI still pending" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf '7\n'; }
    fetch_issue_json()         { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    issue_json_has_blocked_label() { return 1; }
    fetch_pr_json()            { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null,"isRequired":true}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    pr_json_has_blocked_label() { return 1; }
    fingerprint_pr_json()      { printf 'fp-same\n'; }
    load_pr_fingerprint()      { printf 'fp-same\n'; }
    fingerprint_issue_json()   { printf 'fp-same-issue\n'; }
    load_issue_fingerprint()   { printf 'fp-same-issue\n'; }
    CI_CHECK_TIMEOUT_MINUTES=60
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    local state_file
    state_file=$(pr_head_oid_file_path 7)
    [ -f "${state_file}" ]
}

@test "main clears CI pending state file when work-block CI timeout fires (fingerprint changed)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null,"isRequired":true}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fingerprint_pr_json() { printf 'fp-new\n'; }
    load_pr_fingerprint()  { printf 'fp-old\n'; }
    local old_time
    old_time=$(( $(date +%s) - 7200 ))
    save_pr_head_oid 5 "abc" "${old_time}"
    CI_CHECK_TIMEOUT_MINUTES=60
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    grep -q 'Blocked' "${GH_CALL_LOG}"
    local state_file
    state_file=$(pr_head_oid_file_path 5)
    [ ! -f "${state_file}" ]
}

@test "main defers unchanged BEHIND PR without invoking agent while CI is pending (direct-PR path)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null,"isRequired":true}],"mergeable":"MERGEABLE","mergeStateStatus":"BEHIND"}\n'; }
    fingerprint_pr_json() { printf 'fp-same\n'; }
    load_pr_fingerprint()  { printf 'fp-same\n'; }
    CI_CHECK_TIMEOUT_MINUTES=60
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"CI checks pending"* ]]
}

@test "main defers unchanged draft PR in Issue-to-PR path without invoking agent while CI is pending" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf '7\n'; }
    fetch_issue_json()         { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    issue_json_has_blocked_label() { return 1; }
    fetch_pr_json()            { printf '{"state":"OPEN","title":"T","body":"","isDraft":true,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null,"isRequired":true}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    pr_json_has_blocked_label() { return 1; }
    fingerprint_pr_json()      { printf 'fp-same\n'; }
    load_pr_fingerprint()      { printf 'fp-same\n'; }
    CI_CHECK_TIMEOUT_MINUTES=60
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"CI checks pending"* ]]
}
