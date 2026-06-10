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

@test "build_issue_prompt references AI instructions for CLI and label rules" {
    run build_issue_prompt 42 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"mandatory rules from the AI instructions"* ]]
    [[ "${output}" == *"GitHub CLI comment bodies"* ]]
    [[ "${output}" == *"label management"* ]]
}

@test "build_pr_prompt includes PR number, repo, work dir and Blocked instruction" {
    run build_pr_prompt 7 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"pull request #7"* ]]
    [[ "${output}" == *"${REPO_FULL}"* ]]
    [[ "${output}" == *"${REPO_WORK_DIR}"* ]]
    [[ "${output}" == *"gh pr edit 7 --repo ${REPO_FULL} --add-label Blocked"* ]]
    [[ "${output}" == *"Read AI instructions from /resolved/.ai-instructions"* ]]
    [[ "${output}" == *"gh pr ready 7 --repo ${REPO_FULL}"* ]]
}

@test "build_pr_prompt references AI instructions for CLI, label, and CI rules" {
    run build_pr_prompt 7 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"mandatory rules from the AI instructions"* ]]
    [[ "${output}" == *"GitHub CLI comment bodies"* ]]
    [[ "${output}" == *"label management"* ]]
    [[ "${output}" == *"CI checks"* ]]
}

@test "build_pr_prompt with BEHIND merge state includes rebase notice with branch name and force-with-lease" {
    run build_pr_prompt 7 "/resolved/.ai-instructions" "BEHIND" "feat/my-branch"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"BEHIND"* ]]
    [[ "${output}" == *"feat/my-branch"* ]]
    [[ "${output}" == *"force-with-lease"* ]]
    [[ "${output}" == *"rebase"* ]]
}

@test "build_pr_prompt with CLEAN merge state does not include rebase notice" {
    run build_pr_prompt 7 "/resolved/.ai-instructions" "CLEAN" ""
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"force-with-lease"* ]]
    [[ "${output}" != *"BEHIND"* ]]
}

@test "build_pr_prompt with DIRTY merge state includes rebase notice with branch name and force-with-lease" {
    run build_pr_prompt 7 "/resolved/.ai-instructions" "DIRTY" "feat/my-branch"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"DIRTY"* ]]
    [[ "${output}" == *"feat/my-branch"* ]]
    [[ "${output}" == *"force-with-lease"* ]]
    [[ "${output}" == *"rebase"* ]]
}

@test "build_issue_prompt uses provided repo_path instead of REPO_WORK_DIR" {
    run build_issue_prompt 42 "/workspace/rules/.ai-instructions" "/workspace/repo"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"/workspace/repo"* ]]
    [[ "${output}" != *"${REPO_WORK_DIR}"* ]]
}

@test "build_pr_prompt uses provided repo_path in rebase notice" {
    run build_pr_prompt 7 "/workspace/rules/.ai-instructions" "BEHIND" "feat/my-branch" "/workspace/repo"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"/workspace/repo"* ]]
    [[ "${output}" != *"${REPO_WORK_DIR}"* ]]
    [[ "${output}" == *"feat/my-branch"* ]]
    [[ "${output}" == *"force-with-lease"* ]]
}

@test "main passes DIRTY merge state and branch name to build_pr_prompt" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json()           { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[],"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY"}\n'; }
    fingerprint_pr_json()     { printf 'fp-new\n'; }
    load_pr_fingerprint()     { printf 'fp-old\n'; }
    local _prompt_log="${TEST_TMP}/prompt_log"
    build_pr_prompt() { printf 'merge_state=%s branch=%s\n' "$3" "$4" > "${_prompt_log}"; printf 'mock-pr-prompt\n'; }

    run main
    [ "${status}" -eq 0 ]
    grep -q 'merge_state=DIRTY' "${_prompt_log}"
    grep -q 'branch=feat/test' "${_prompt_log}"
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
    local _claude_log="${TEST_TMP}/claude_log"
    invoke_claude() { printf 'called\n' >> "${_claude_log}"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"rebased non-agentically"* ]]
    [ ! -f "${_claude_log}" ]
}

@test "main passes BEHIND merge state and branch name to build_pr_prompt" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json()           { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[],"mergeable":"MERGEABLE","mergeStateStatus":"BEHIND"}\n'; }
    fingerprint_pr_json()     { printf 'fp-new\n'; }
    load_pr_fingerprint()     { printf 'fp-old\n'; }
    local _prompt_log="${TEST_TMP}/prompt_log"
    build_pr_prompt() { printf 'merge_state=%s branch=%s\n' "$3" "$4" > "${_prompt_log}"; printf 'mock-pr-prompt\n'; }

    run main
    [ "${status}" -eq 0 ]
    grep -q 'merge_state=BEHIND' "${_prompt_log}"
    grep -q 'branch=feat/test' "${_prompt_log}"
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

@test "load_gh_token_for_owner rejects owners with invalid characters" {
    local bad
    # shellcheck disable=SC2016  # 'owner$x' is a deliberate literal — testing that a '$' in the owner is rejected
    for bad in 'owner;rm' 'owner space' 'owner/slash' 'owner$x' 'owner.dot'; do
        run load_gh_token_for_owner "${bad}"
        [ "${status}" -eq 0 ]
        [ -z "${output}" ]
    done
}

@test "load_gh_token_for_owner reads a gh token for a valid owner with safe perms" {
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator/gh-tokens"
    printf 'gh-secret-token\n' > "${XDG_CONFIG_HOME}/orchestrator/gh-tokens/credfeto"
    chmod 600 "${XDG_CONFIG_HOME}/orchestrator/gh-tokens/credfeto"
    run load_gh_token_for_owner credfeto
    [ "${status}" -eq 0 ]
    [ "${output}" = "gh-secret-token" ]
}

@test "load_gh_token_for_owner returns empty when no gh token file exists" {
    run load_gh_token_for_owner credfeto
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "load_gh_token_for_owner falls back to GH_TOKEN in .env when no per-owner file exists" {
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf 'GH_TOKEN=env-gh-token\n' > "${XDG_CONFIG_HOME}/orchestrator/.env"
    run load_gh_token_for_owner credfeto
    [ "${status}" -eq 0 ]
    [ "${output}" = "env-gh-token" ]
}

@test "load_gh_token_for_owner prefers per-owner file over .env fallback" {
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator/gh-tokens"
    printf 'per-owner-token\n' > "${XDG_CONFIG_HOME}/orchestrator/gh-tokens/credfeto"
    chmod 600 "${XDG_CONFIG_HOME}/orchestrator/gh-tokens/credfeto"
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf 'GH_TOKEN=env-gh-token\n' > "${XDG_CONFIG_HOME}/orchestrator/.env"
    run load_gh_token_for_owner credfeto
    [ "${status}" -eq 0 ]
    [ "${output}" = "per-owner-token" ]
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
        if [ "$1" = "-v" ] && [ "$2" = "docker" ]; then
            return 1
        fi
        builtin command "$@"
    }
    run check_required_tools
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Required tool not found: docker"* ]]
}

@test "check_required_tools succeeds when all tools are present" {
    make_stub curl 'exit 0'
    make_stub jq 'exit 0'
    make_stub docker 'exit 0'
    make_stub gh 'exit 0'
    make_stub git 'exit 0'
    make_stub awk 'exit 0'
    make_stub grep 'exit 0'
    make_stub flock 'exit 0'
    make_stub sha256sum 'exit 0'
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

@test "invoke_claude passes --model opusplan to docker claude command for a new session" {
    local args_log="${TEST_TMP}/docker_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    make_stub sudo '"$@"'
    cat > "${STUB_BIN}/docker" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "inspect" ] && exit 1
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/docker"

    invoke_claude "test prompt" "" 2>/dev/null
    grep -qx -- '--model' "${args_log}"
    grep -qx 'opusplan' "${args_log}"
}

@test "invoke_claude passes --model opusplan to docker claude command when resuming a session" {
    local args_log="${TEST_TMP}/docker_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    make_stub sudo '"$@"'
    cat > "${STUB_BIN}/docker" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "inspect" ] && exit 1
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/docker"

    invoke_claude "test prompt" "12345678-1234-1234-1234-123456789abc" 2>/dev/null
    grep -qx -- '--model' "${args_log}"
    grep -qx 'opusplan' "${args_log}"
}

# --- invoke_claude error handling ---------------------------------------------

@test "invoke_claude fails fast before calling docker when prompt exceeds MAX_PROMPT_CHARS" {
    local args_log="${TEST_TMP}/docker_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/docker" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "inspect" ] && exit 1
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/docker"

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
    cat > "${STUB_BIN}/docker" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "inspect" ] && exit 1
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/docker"

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
    make_stub sudo '"$@"'
    cat > "${STUB_BIN}/docker" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "inspect" ] && exit 1
printf '{"is_error":true,"terminal_reason":"api_error","session_id":"12345678-1234-1234-1234-123456789abc","result":"API Error"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/docker"

    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"

    run invoke_claude "test prompt" "" "Issue" "42"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"API Error"* ]]
    grep -q "https://discord.example.com/hook" "${args_log}"
}

@test "invoke_claude retries as new session when Claude returns blocking_limit on a resumed session" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    make_stub sudo '"$@"'
    cat > "${STUB_BIN}/docker" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "inspect" ] && exit 1
for arg; do
    [ "$arg" = "--resume" ] && { printf '{"is_error":true,"terminal_reason":"blocking_limit","session_id":"old-id","result":"Prompt is too long"}\n'; exit 0; }
done
printf '{"session_id":"aabbccdd-1122-3344-5566-778899aabbcc","result":"done","is_error":false}\n'
STUBEOF
    chmod +x "${STUB_BIN}/docker"

    DISCORD_WEBHOOK_URL=""
    local result
    result=$(invoke_claude "test prompt" "11111111-1111-1111-1111-111111111111" "Issue" "42" 2>/dev/null)
    [ "${result}" = "aabbccdd-1122-3344-5566-778899aabbcc" ]
}

@test "invoke_claude sends Discord notification when retrying after blocking_limit" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    make_stub sudo '"$@"'
    cat > "${STUB_BIN}/docker" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "inspect" ] && exit 1
for arg; do
    [ "$arg" = "--resume" ] && { printf '{"is_error":true,"terminal_reason":"blocking_limit","session_id":"old-id","result":"Prompt is too long"}\n'; exit 0; }
done
printf '{"session_id":"aabbccdd-1122-3344-5566-778899aabbcc","result":"done","is_error":false}\n'
STUBEOF
    chmod +x "${STUB_BIN}/docker"

    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"

    invoke_claude "test prompt" "11111111-1111-1111-1111-111111111111" "Issue" "42" 2>/dev/null
    grep -q "https://discord.example.com/hook" "${args_log}"
}

@test "invoke_claude dies with Discord notification on blocking_limit for a new session" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    make_stub sudo '"$@"'
    cat > "${STUB_BIN}/docker" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "inspect" ] && exit 1
printf '{"is_error":true,"terminal_reason":"blocking_limit","session_id":"12345678-1234-1234-1234-123456789abc","result":"Prompt is too long"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/docker"

    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"

    run invoke_claude "test prompt" "" "Issue" "42"
    [ "${status}" -ne 0 ]
    grep -q "https://discord.example.com/hook" "${args_log}"
}

@test "invoke_claude dies if retry after blocking_limit also fails" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    make_stub sudo '"$@"'
    cat > "${STUB_BIN}/docker" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "inspect" ] && exit 1
printf '{"is_error":true,"terminal_reason":"blocking_limit","session_id":"12345678-1234-1234-1234-123456789abc","result":"Prompt is too long"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/docker"

    DISCORD_WEBHOOK_URL=""
    run invoke_claude "test prompt" "11111111-1111-1111-1111-111111111111" "Issue" "42"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"failed after retry"* ]]
}

@test "invoke_claude retries as new session when Claude reports session no longer exists" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    make_stub sudo '"$@"'
    cat > "${STUB_BIN}/docker" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "inspect" ] && exit 1
for arg; do
    [ "$arg" = "--resume" ] && { printf 'No conversation found with session ID: 11111111-1111-1111-1111-111111111111\n' >&2; exit 1; }
done
printf '{"session_id":"aabbccdd-1122-3344-5566-778899aabbcc","result":"done","is_error":false}\n'
STUBEOF
    chmod +x "${STUB_BIN}/docker"

    DISCORD_WEBHOOK_URL=""
    local result
    result=$(invoke_claude "test prompt" "11111111-1111-1111-1111-111111111111" "Issue" "42" 2>/dev/null)
    [ "${result}" = "aabbccdd-1122-3344-5566-778899aabbcc" ]
}

@test "invoke_claude does not send Discord notification when retrying after invalid session" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    make_stub sudo '"$@"'
    cat > "${STUB_BIN}/docker" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "inspect" ] && exit 1
for arg; do
    [ "$arg" = "--resume" ] && { printf 'No conversation found with session ID: 11111111-1111-1111-1111-111111111111\n' >&2; exit 1; }
done
printf '{"session_id":"aabbccdd-1122-3344-5566-778899aabbcc","result":"done","is_error":false}\n'
STUBEOF
    chmod +x "${STUB_BIN}/docker"

    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"

    invoke_claude "test prompt" "11111111-1111-1111-1111-111111111111" "Issue" "42" 2>/dev/null
    run ! grep -q "https://discord.example.com/hook" "${args_log}"
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
    local args_log="${TEST_TMP}/docker_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    make_stub sudo '"$@"'
    cat > "${STUB_BIN}/docker" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "inspect" ] && exit 1
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/docker"

    invoke_claude "test prompt" "" 2>/dev/null
    grep -qx 'orchestrator-credfeto' "${args_log}"
}

@test "invoke_claude mounts REPO_WORK_DIR read-write and RULES_DIR read-only" {
    local args_log="${TEST_TMP}/docker_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    make_stub sudo '"$@"'
    cat > "${STUB_BIN}/docker" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "inspect" ] && exit 1
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/docker"

    invoke_claude "test prompt" "" 2>/dev/null
    grep -qx "${REPO_WORK_DIR}:${CONTAINER_REPO_PATH}:rw" "${args_log}"
    grep -qx "${RULES_DIR}:${CONTAINER_RULES_PATH}:ro" "${args_log}"
}

@test "invoke_claude passes CLAUDE_CODE_OAUTH_TOKEN env var when owner token is configured" {
    local args_log="${TEST_TMP}/docker_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator/tokens"
    printf 'my-claude-token\n' > "${XDG_CONFIG_HOME}/orchestrator/tokens/credfeto"
    chmod 600 "${XDG_CONFIG_HOME}/orchestrator/tokens/credfeto"
    make_stub sudo '"$@"'
    cat > "${STUB_BIN}/docker" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "inspect" ] && exit 1
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/docker"

    invoke_claude "test prompt" "" 2>/dev/null
    grep -qx 'CLAUDE_CODE_OAUTH_TOKEN=my-claude-token' "${args_log}"
}

@test "invoke_claude passes GH_ENTERPRISE_TOKEN env var when gh token is configured" {
    local args_log="${TEST_TMP}/docker_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator/gh-tokens"
    printf 'my-gh-token\n' > "${XDG_CONFIG_HOME}/orchestrator/gh-tokens/credfeto"
    chmod 600 "${XDG_CONFIG_HOME}/orchestrator/gh-tokens/credfeto"
    make_stub sudo '"$@"'
    cat > "${STUB_BIN}/docker" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "inspect" ] && exit 1
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/docker"

    invoke_claude "test prompt" "" 2>/dev/null
    grep -qx 'GH_ENTERPRISE_TOKEN=my-gh-token' "${args_log}"
}

@test "invoke_claude passes --resume flag when session id is provided" {
    local args_log="${TEST_TMP}/docker_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    make_stub sudo '"$@"'
    cat > "${STUB_BIN}/docker" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "inspect" ] && exit 1
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/docker"

    invoke_claude "test prompt" "12345678-1234-1234-1234-123456789abc" 2>/dev/null
    grep -qx -- '--resume' "${args_log}"
    grep -qx '12345678-1234-1234-1234-123456789abc' "${args_log}"
}

@test "invoke_claude dies if container already exists" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    make_stub sudo '"$@"'
    cat > "${STUB_BIN}/docker" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "inspect" ] && exit 0
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/docker"

    run invoke_claude "test prompt" "" "Issue" "42"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"already exists"* ]]
}

@test "invoke_claude dies with specific message when docker run fails due to container name in use" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    make_stub sudo '"$@"'
    cat > "${STUB_BIN}/docker" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "inspect" ] && exit 1
printf 'docker: Error response from daemon: Conflict. The container name "/orchestrator-credfeto" is already in use\n' >&2
exit 1
STUBEOF
    chmod +x "${STUB_BIN}/docker"

    run invoke_claude "test prompt" "" "Issue" "42"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"already in use"* ]]
}

@test "invoke_claude does not mount host .claude directory" {
    local args_log="${TEST_TMP}/docker_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}" "${HOME}/.claude"
    make_stub sudo '"$@"'
    cat > "${STUB_BIN}/docker" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "inspect" ] && exit 1
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/docker"

    invoke_claude "test prompt" "" 2>/dev/null
    run ! grep -q ".claude:/home/developer/.claude" "${args_log}"
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
    try_nonagentic_rebase()     { return 1; }
    find_ai_instructions()      { printf '/mock/.ai-instructions\n'; }
    host_to_container_path()    { printf '%s\n' "$1"; }
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
    is_owner_rate_limited()       { return 1; }
    load_discord_config()             { return 0; }
    notify_discord_work_item()        { return 0; }
    notify_discord_no_work()          { return 0; }
    notify_discord_blocked_item()     { return 0; }
    notify_discord_claude_error()     { return 0; }
    notify_discord_rate_limited()     { return 0; }
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

@test "load_discord_config strips trailing CR from CRLF env files" {
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf 'DISCORD_WEBHOOK=https://discord.example.com/hook\r\n' \
        > "${XDG_CONFIG_HOME}/orchestrator/.env"
    DISCORD_WEBHOOK_URL=""
    load_discord_config
    [ "${DISCORD_WEBHOOK_URL}" = "https://discord.example.com/hook" ]
}

@test "load_discord_config does not strip unmatched leading quote" {
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf 'DISCORD_WEBHOOK="https://discord.example.com/hook\n' \
        > "${XDG_CONFIG_HOME}/orchestrator/.env"
    DISCORD_WEBHOOK_URL=""
    load_discord_config
    [ "${DISCORD_WEBHOOK_URL}" = '"https://discord.example.com/hook' ]
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
    run ! grep -q "\[.*\] No actionable" "${args_log}"
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
    run ! grep -q "blocked:\|unchanged:\|repo-active:\|not-open:" "${args_log}"
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

@test "parse_reset_time rejects timezone strings with dangerous characters" {
    run parse_reset_time "resets 3pm (UTC;rm -rf /)"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
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
    make_stub sudo '"$@"'
    cat > "${STUB_BIN}/docker" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "inspect" ] && exit 1
printf '%s\n' '{"is_error":true,"api_error_status":429,"terminal_reason":"completed","session_id":"12345678-1234-1234-1234-123456789abc","result":"You'\''ve hit your Sonnet limit \u00b7 resets 3pm (UTC)"}'
STUBEOF
    chmod +x "${STUB_BIN}/docker"

    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"

    run invoke_claude "test prompt" "" "Issue" "42"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"rate limited"* ]]
    grep -q "https://discord.example.com/hook" "${args_log}"
}

@test "invoke_claude persists rate-limit file on HTTP 429 so subsequent runs skip the owner" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    make_stub sudo '"$@"'
    cat > "${STUB_BIN}/docker" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "inspect" ] && exit 1
printf '%s\n' '{"is_error":true,"api_error_status":429,"terminal_reason":"completed","session_id":"12345678-1234-1234-1234-123456789abc","result":"You'\''ve hit your Sonnet limit \u00b7 resets 3pm (UTC)"}'
STUBEOF
    chmod +x "${STUB_BIN}/docker"

    DISCORD_WEBHOOK_URL=""
    run invoke_claude "test prompt" "" "Issue" "42"
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
