#!/usr/bin/env bats
# shellcheck disable=SC2329  # functions in @test bodies are invoked indirectly via 'run'
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are used inside run() subshells where shellcheck cannot trace them

bats_require_minimum_version 1.5.0

load test_helper
load oneshot_helper

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

@test "main still cleans up ssh-agent when it dies on the earliest argument-parsing path (#1103)" {
    setup_main_mocks
    export SSH_AUTH_SOCK="${TEST_TMP}/ssh-agent.sock"
    local pkill_log="${TEST_TMP}/pkill.log"
    make_stub pkill "printf '%s\n' \"\$*\" >> \"${pkill_log}\"; exit 0"
    run main --unknown-flag
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Unknown argument"* ]]
    grep -qxe "-u $(id -un) -f ssh-agent -a ${SSH_AUTH_SOCK}" "${pkill_log}"
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
    local lock_dir="${ORCHESTRATOR_STATE_DIR}/locks"
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

# --- AGENT_TIMEOUT_MINUTES validation (#1103) -------------------------------

@test "AGENT_TIMEOUT_MINUTES falls back to 90 when unset" {
    run bash -c 'unset AGENT_TIMEOUT_MINUTES; source "'"${REPO_ROOT}"'/oneshot"; printf "%s" "${AGENT_TIMEOUT_MINUTES}"'
    [ "${status}" -eq 0 ]
    [ "${output}" = "90" ]
}

@test "AGENT_TIMEOUT_MINUTES falls back to 90 for a non-numeric value" {
    run bash -c 'export AGENT_TIMEOUT_MINUTES=abc; source "'"${REPO_ROOT}"'/oneshot"; printf "%s" "${AGENT_TIMEOUT_MINUTES}"'
    [ "${status}" -eq 0 ]
    [ "${output}" = "90" ]
}

@test "AGENT_TIMEOUT_MINUTES falls back to 90 for a value with a trailing non-digit" {
    run bash -c 'export AGENT_TIMEOUT_MINUTES=1x; source "'"${REPO_ROOT}"'/oneshot"; printf "%s" "${AGENT_TIMEOUT_MINUTES}"'
    [ "${status}" -eq 0 ]
    [ "${output}" = "90" ]
}

@test "AGENT_TIMEOUT_MINUTES falls back to 90 for zero" {
    run bash -c 'export AGENT_TIMEOUT_MINUTES=0; source "'"${REPO_ROOT}"'/oneshot"; printf "%s" "${AGENT_TIMEOUT_MINUTES}"'
    [ "${status}" -eq 0 ]
    [ "${output}" = "90" ]
}

@test "AGENT_TIMEOUT_MINUTES accepts a valid positive integer" {
    run bash -c 'export AGENT_TIMEOUT_MINUTES=45; source "'"${REPO_ROOT}"'/oneshot"; printf "%s" "${AGENT_TIMEOUT_MINUTES}"'
    [ "${status}" -eq 0 ]
    [ "${output}" = "45" ]
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

@test "fingerprint_pr_json changes when a legacy StatusContext check's .state changes, with no .conclusion/.status present (#1210)" {
    local pr_pending='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[{"name":"codecov/project","state":"PENDING"}]}'
    local pr_failed='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[{"name":"codecov/project","state":"FAILURE"}]}'

    local fp1 fp2
    fp1=$(fingerprint_pr_json "${pr_pending}")
    fp2=$(fingerprint_pr_json "${pr_failed}")
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

@test "pr_json_has_blocked_label and issue_json_has_blocked_label do not error when labels is absent (#1102)" {
    run pr_json_has_blocked_label '{}'
    [ "${status}" -ne 0 ]
    [[ "${output}" != *"jq: error"* ]]

    run issue_json_has_blocked_label '{}'
    [ "${status}" -ne 0 ]
    [[ "${output}" != *"jq: error"* ]]
}

# --- set_repo_context ---------------------------------------------------------

@test "set_repo_context sets OWNER REPO REPO_FULL RULES_DIR REPO_WORK_DIR SESSION_BASE_DIR" {
    set_repo_context "myorg/myrepo"
    [ "${OWNER}"    = "myorg" ]
    [ "${REPO}"     = "myrepo" ]
    [ "${REPO_FULL}" = "myorg/myrepo" ]
    [ "${RULES_DIR}"     = "${WORK}/myorg/myrepo/rules" ]
    [ "${REPO_WORK_DIR}" = "${WORK}/myorg/myrepo/repo" ]
    [ "${SESSION_BASE_DIR}" = "${ORCHESTRATOR_STATE_DIR}/myorg/myrepo" ]
    [ "${CLAUDE_STATE_DIR}" = "${SESSION_BASE_DIR}/claude" ]
    [ "${ORCHESTRATOR_CACHE_DIR}" = "${SESSION_BASE_DIR}/orchestrator-cache" ]
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

# --- migrate_legacy_orchestrator_state (#52) -----------------------------------

@test "migrate_legacy_orchestrator_state is a no-op when no legacy directory exists" {
    run migrate_legacy_orchestrator_state
    [ "${status}" -eq 0 ]
    [ ! -e "${HOME}/.orchestrator" ]
    [ ! -e "${ORCHESTRATOR_STATE_DIR}" ]
}

@test "migrate_legacy_orchestrator_state moves the legacy directory to ORCHESTRATOR_STATE_DIR" {
    seed_legacy_orchestrator_dir

    run migrate_legacy_orchestrator_state

    [ "${status}" -eq 0 ]
    [ ! -e "${HOME}/.orchestrator" ]
    [ "$(cat "${ORCHESTRATOR_STATE_DIR}/myorg/myrepo/Issue_1.fingerprint")" = "session-data" ]
    [[ "${output}" == *"Migrated legacy session state"* ]]
}

@test "migrate_legacy_orchestrator_state is a no-op that leaves the legacy directory alone when ORCHESTRATOR_STATE_DIR already exists" {
    seed_legacy_orchestrator_dir "legacy"
    mkdir -p "${ORCHESTRATOR_STATE_DIR}/myorg/myrepo"
    printf 'current' > "${ORCHESTRATOR_STATE_DIR}/myorg/myrepo/Issue_1.fingerprint"

    run migrate_legacy_orchestrator_state

    [ "${status}" -eq 0 ]
    [ "$(cat "${HOME}/.orchestrator/myorg/myrepo/Issue_1.fingerprint")" = "legacy" ]
    [ "$(cat "${ORCHESTRATOR_STATE_DIR}/myorg/myrepo/Issue_1.fingerprint")" = "current" ]
}

@test "migrate_legacy_orchestrator_state warns and leaves the legacy directory in place when mv fails" {
    seed_legacy_orchestrator_dir
    make_stub mv "exit 1"

    run migrate_legacy_orchestrator_state

    [ "${status}" -eq 0 ]
    [ -d "${HOME}/.orchestrator/myorg/myrepo" ]
    [[ "${output}" == *"Failed to migrate legacy session state"* ]]
}

# --- find_ai_instructions (updated behaviour) ---------------------------------

@test "find_ai_instructions returns non-zero (not die) when neither path has .ai-instructions" {
    # Function should return 1 and emit a warning, not call die/exit.
    run find_ai_instructions
    [ "${status}" -ne 0 ]
    [[ "${output}" == *".ai-instructions"* ]]
}

# --- repository name validation -----------------------------------------------

@test "main dies loudly (does not report success) when fetch_all_priorities ultimately fails (#1089)" {
    setup_main_mocks
    fetch_all_priorities() { return 1; }

    run main
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Failed to fetch priorities"* ]]
    [[ "${output}" != *"No actionable work items"* ]]
    [[ "${output}" != *"No open work items"* ]]
}

@test "main notifies Discord before dying when fetch_all_priorities ultimately fails (#1171)" {
    setup_main_mocks
    fetch_all_priorities() { return 1; }
    local discord_log="${TEST_TMP}/discord_log"
    notify_discord_priorities_unreachable() { printf 'notified\n' >> "${discord_log}"; }

    run main
    [ "${status}" -ne 0 ]
    [ -f "${discord_log}" ]
}

@test "main does NOT notify Discord when fetch_all_priorities fails to parse (rc 2, not unreachable) (#1171)" {
    setup_main_mocks
    fetch_all_priorities() { return 2; }
    local discord_log="${TEST_TMP}/discord_log"
    notify_discord_priorities_unreachable() { printf 'notified\n' >> "${discord_log}"; }

    run main
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Failed to fetch priorities"* ]]
    [ ! -f "${discord_log}" ]
}

@test "main resolves the GitHub login before fetching priorities so it stays cached for the run (#1570)" {
    setup_main_mocks
    unset _GH_ME
    resolve_gh_me() { _GH_ME="resolved-login"; return 0; }
    fetch_all_priorities() { printf 'me=%s\n' "${_GH_ME:-}" > "${TEST_TMP}/fetch_log"; printf '[]\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ "$(cat "${TEST_TMP}/fetch_log")" = "me=resolved-login" ]
}

@test "main still fetches priorities and does not fail when the GitHub login cannot be resolved (#1570)" {
    setup_main_mocks
    unset _GH_ME
    resolve_gh_me() { return 1; }
    fetch_all_priorities() { printf 'called\n' > "${TEST_TMP}/fetch_log"; printf '[]\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ -f "${TEST_TMP}/fetch_log" ]
    [[ "${output}" == *"Fetching priorities without the user parameter"* ]]
    [[ "${output}" == *"No open work items"* ]]
}

@test "main dies loudly when the priorities item count cannot be determined (#1089)" {
    setup_main_mocks
    fetch_all_priorities() { printf 'not valid json\n'; }

    run main
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Failed to determine item count from priorities JSON"* ]]
}

@test "main skips (does not die on) a malformed repository name from priorities API (path traversal) (#1090)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":1,"itemType":"Issue","repository":"../evil/path","priority":1,"status":"Open","isOnHold":false}]'
    }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"Malformed repository from priorities API"* ]]
    [[ "${output}" == *"errors: 1"* ]]
}

@test "main skips (does not die on) a repository name with no slash from priorities API (#1090)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":1,"itemType":"Issue","repository":"noslash","priority":1,"status":"Open","isOnHold":false}]'
    }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"Malformed repository from priorities API"* ]]
    [[ "${output}" == *"errors: 1"* ]]
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

@test "main skips an Issue and does not die when the PR lookup fails transiently (#1085)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":1,"itemType":"Issue","repository":"org/my-repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { return 1; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    # A transient PR-lookup failure must skip the item, not abort the run.
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"Failed to query open PRs for org/my-repo — skipping"* ]]
    [[ "${output}" == *"errors: 1"* ]]
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

@test "main skips (does not die on) a non-numeric id from priorities API (#1090)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":"not-a-number","itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"Non-numeric id from priorities API"* ]]
    [[ "${output}" == *"errors: 1"* ]]
}

@test "main skips (does not die on) an unexpected itemType from priorities API (#1090)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":1,"itemType":"Discussion","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"Unexpected itemType from priorities API"* ]]
    [[ "${output}" == *"errors: 1"* ]]
}

@test "main skips (does not die on) a non-numeric open PR number from GitHub (#1090)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":1,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf 'not-a-number\n'; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"Non-numeric open PR number from GitHub"* ]]
    [[ "${output}" == *"errors: 1"* ]]
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

@test "load_env_config reads the four per-category Discord webhook keys from env file (#1456)" {
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    cat > "${XDG_CONFIG_HOME}/orchestrator/.env" << 'ENVEOF'
DISCORD_WEBHOOK_BLOCKED=https://discord.example.com/blocked
DISCORD_WEBHOOK_AWAITING_APPROVAL=https://discord.example.com/awaiting-approval
DISCORD_WEBHOOK_PERMISSIONS=https://discord.example.com/permissions
DISCORD_WEBHOOK_SLOW_PULL=https://discord.example.com/slow-pull
ENVEOF
    load_env_config
    [ "${DISCORD_WEBHOOK_URL_BLOCKED}" = "https://discord.example.com/blocked" ]
    [ "${DISCORD_WEBHOOK_URL_AWAITING_APPROVAL}" = "https://discord.example.com/awaiting-approval" ]
    [ "${DISCORD_WEBHOOK_URL_PERMISSIONS}" = "https://discord.example.com/permissions" ]
    [ "${DISCORD_WEBHOOK_URL_SLOW_PULL}" = "https://discord.example.com/slow-pull" ]
}

@test "load_env_config leaves the four per-category Discord webhook vars empty when absent from env file (#1456)" {
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf 'DISCORD_WEBHOOK=https://discord.example.com/webhook\n' \
        > "${XDG_CONFIG_HOME}/orchestrator/.env"
    DISCORD_WEBHOOK_URL_BLOCKED="should-be-cleared"
    DISCORD_WEBHOOK_URL_AWAITING_APPROVAL="should-be-cleared"
    DISCORD_WEBHOOK_URL_PERMISSIONS="should-be-cleared"
    DISCORD_WEBHOOK_URL_SLOW_PULL="should-be-cleared"
    load_env_config
    [ -z "${DISCORD_WEBHOOK_URL_BLOCKED}" ]
    [ -z "${DISCORD_WEBHOOK_URL_AWAITING_APPROVAL}" ]
    [ -z "${DISCORD_WEBHOOK_URL_PERMISSIONS}" ]
    [ -z "${DISCORD_WEBHOOK_URL_SLOW_PULL}" ]
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

@test "load_env_config normalises GH_HOST and also exports GH_TOKEN for a direct github.com host" {
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf 'GH_TOKEN=ghp_direct\nGH_HOST=GitHub.com\n' > "${XDG_CONFIG_HOME}/orchestrator/.env"
    load_env_config
    [ "${GH_HOST}" = "github.com" ]
    # shellcheck disable=SC2031
    [ "${GH_ENTERPRISE_TOKEN}" = "ghp_direct" ]
    # shellcheck disable=SC2031
    [ "${GH_TOKEN}" = "ghp_direct" ]
    printf 'GH_TOKEN=ghp_direct\nGH_HOST=api.github.com\n' > "${XDG_CONFIG_HOME}/orchestrator/.env"
    unset GH_TOKEN
    load_env_config
    [ "${GH_HOST}" = "github.com" ]
    # shellcheck disable=SC2031
    [ "${GH_TOKEN}" = "ghp_direct" ]
    # A proxy host never gets GH_TOKEN: gh would send it to the proxy as a real PAT.
    printf 'GH_TOKEN=ghp_proxy\nGH_HOST=GitHub-API.example.com\n' > "${XDG_CONFIG_HOME}/orchestrator/.env"
    unset GH_TOKEN
    load_env_config
    [ "${GH_HOST}" = "github-api.example.com" ]
    # shellcheck disable=SC2031
    [ -z "${GH_TOKEN:-}" ]
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

@test "CI_CHECK_TIMEOUT_MINUTES defaults to 1440 minutes when it is not set (#1504)" {
    unset CI_CHECK_TIMEOUT_MINUTES
    source_oneshot
    [ "${CI_CHECK_TIMEOUT_MINUTES}" -eq 1440 ]
    [ "${CI_CHECK_TIMEOUT_DEFAULT_MINUTES}" -eq 1440 ]
}

@test "CI_CHECK_TIMEOUT_MINUTES keeps a valid override (#1504)" {
    CI_CHECK_TIMEOUT_MINUTES=30
    source_oneshot
    [ "${CI_CHECK_TIMEOUT_MINUTES}" -eq 30 ]
}

@test "CI_CHECK_TIMEOUT_MINUTES falls back to the default, not a different number, for an invalid override (#1504)" {
    local value
    for value in abc 0 -5 "" 1.5 " 30"; do
        CI_CHECK_TIMEOUT_MINUTES="${value}"
        source_oneshot
        [ "${CI_CHECK_TIMEOUT_MINUTES}" -eq "${CI_CHECK_TIMEOUT_DEFAULT_MINUTES}" ]
        [ "${CI_CHECK_TIMEOUT_MINUTES}" -eq 1440 ]
    done
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
