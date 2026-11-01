#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2329  # functions in @test bodies are invoked indirectly via 'run'
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are used inside run() subshells where shellcheck cannot trace them
#
# Shared setup/teardown and fixture helpers for the test/oneshot-*.bats files (split out of
# the former test/oneshot.bats, #1579). Each oneshot-*.bats file loads test_helper, then this.

setup() {
    setup_isolated_env
    source_oneshot
}

teardown() {
    cleanup_stubs
    cleanup_repo_fixtures
}

# Common overrides shared across main() integration tests.
# Call this inside each test after sourcing (i.e. after setup has run) to
# replace every function that performs real I/O.
setup_main_mocks() {
    # Deterministic baseline for the self-update staleness gate (#1298): never inherit a real
    # ORCHESTRATOR_SELF_UPDATE_MANAGED from whatever environment is actually running these tests.
    # Individual tests opt into the "systemd-managed self-update ran" path by exporting it
    # themselves.
    unset ORCHESTRATOR_SELF_UPDATE_MANAGED
    make_stub flock 'exit 0'
    check_required_tools()      { return 0; }
    set_repo_context()          { return 0; }
    ensure_rules_current()      { return 0; }
    ensure_repo_current()       { return 0; }
    recover_orphaned_branch()   { return 1; }
    resolve_resumable_issue_branch() { return 1; }
    try_nonagentic_rebase()     { return 1; }
    # Default: no human-driven PRs anywhere (#1131) — tests that exercise the
    # stand-off paths override these individually.
    find_human_taken_over_pr_for_issue() { return 1; }
    pr_is_human_driven()                 { return 1; }
    # Default: the auto-merge-unsupported board fallback never matches (#1479) — matches every
    # pre-existing test's expectation byte-for-byte, since pr_json_is_terminal's behaviour before
    # this fallback existed is exactly what "no fallback match" reproduces. Tests exercising the
    # fallback itself override this individually.
    pr_review_pipeline_finished_without_auto_merge() { return 1; }
    # Stub resolve_gh_me for the assignee standoff check (#1142) — no real gh call
    # in integration tests.  := preserves any _GH_ME set directly by unit tests.
    resolve_gh_me()                      { _GH_ME="${_GH_ME:-testuser}"; return 0; }
    find_ai_instructions()      { printf '/mock/.ai-instructions\n'; }
    host_to_container_path()    { printf '%s\n' "$1"; }
    build_issue_prompt()        { printf 'mock-issue-prompt\n'; }
    build_pr_prompt()           { printf 'mock-pr-prompt\n'; }
    build_issue_claude_md()     { printf 'mock-issue-claude-md\n'; }
    build_pr_claude_md()        { printf 'mock-pr-claude-md\n'; }
    invoke_claude()             { return 0; }
    # The pre-commit pre-check (#1785) is tested in test/precheck.bats; main() tests skip it.
    prepare_precheck_section() {
        PRECHECK_SECTION=""
        PRECHECK_SESSION_LOG=""
        return 0
    }
    compute_pr_fingerprint()    { printf 'new-fp\n'; }
    compute_issue_fingerprint() { printf 'new-fp\n'; }
    save_pr_fingerprint()       { return 0; }
    save_issue_fingerprint()    { return 0; }
    # Default: no unaddressed trusted comment recorded/observed (#1307) — tests exercising the
    # unaddressed-comment override (terminal-skip/non-agentic-rebase bypass, save timing) set
    # fetch_pr_json's "comments" and/or these individually.
    load_pr_last_agent_comment_seen()    { printf ''; }
    save_pr_last_agent_comment_seen()    { return 0; }
    fetch_pr_latest_trusted_comment_timestamp() { printf ''; }
    fingerprint_issue_json()    { printf 'issue-fp-default\n'; }
    load_issue_fingerprint()    { printf ''; }
    # No Workflow board by default (#1204) — tests exercising board-approval behaviour override
    # these individually, matching how fetch_board_approved_items itself is a no-op when
    # _WF_PROJECT_ID is empty.
    discover_or_create_workflow_project() { return 0; }
    fetch_board_approved_items()          { return 0; }
    tag_pr_closed_issue()       { return 0; }
    is_owner_rate_limited()       { return 1; }
    load_env_config()             { return 0; }
    validate_config()             { return 0; }
    get_trusted_logins()          { printf '["credfeto"]\n'; }
    fetch_pr_review_comments()    { printf '[]\n'; }
    fetch_pr_issue_comments()     { printf '[]\n'; }
    # Default: the required-check lookup fails, leaving each fixture's own isRequired values (or
    # their absence) exactly as written. Tests of the annotation path override this.
    fetch_pr_required_check_names() { return 1; }
    notify_discord_work_item()         { return 0; }
    notify_discord_pr_waiting()        { return 0; }
    notify_discord_no_work()           { return 0; }
    notify_discord_blocked_item()      { return 0; }
    notify_discord_pr_needs_approval() { return 0; }
    notify_discord_claude_error()      { return 0; }
    notify_discord_rate_limited()      { return 0; }
    notify_discord_low_disk_space()    { return 0; }
    notify_discord_priorities_unreachable() { return 0; }
    notify_discord_session_stalled()   { return 0; }
    run_daily_digest_rollover()        { return 0; }
    check_disk_space()                 { return 0; }
    sync_pr_labels_from_linked_issues() { return 0; }
}

# Stubs an Issue's plan-comment state as "posted, awaiting approval, but already self-heal-marked":
# the ONLY fingerprint-unchanged Issue state that still reaches the terminal "unchanged" fallback,
# since a plan-less Issue now re-pokes (a real invocation) instead. Call this in any test whose own
# subject is unrelated to plan/idle state (an orphaned/resumable-branch check, a no-work
# notification count) so it keeps landing on "unchanged" without being confused by the no-plan-yet
# path. Stubs issue_json_has_plan_comment directly rather than requiring every caller to also
# hand-craft a fetch_issue_json fixture with a real "## Implementation Plan" comment: safe because
# issue_plan_block_marked's stubbed "already marked" short-circuits oneshot's self-heal elif before
# issue_plan_awaiting_human_approval (which is what would otherwise care about the comment body) is
# ever called.
stub_plan_already_self_heal_marked() {
    issue_plan_block_marked() { return 0; }
    issue_json_has_plan_comment() { return 0; }
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

stub_podman_run_logging_args() {
    local args_log="$1"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    make_stub_multiline podman \
        "[ \"\$1\" = \"pull\" ] && exit 0" \
        "[ \"\$1\" = \"inspect\" ] && exit 1" \
        "printf '%s\\n' \"\$@\" >> \"${args_log}\"" \
        "printf '{\"session_id\":\"12345678-1234-1234-1234-123456789abc\",\"result\":\"done\"}\\n'"
}

# main mocks for Issue 10, open and not Blocked, pivoting to PR 99; the caller stubs the PR's state.
setup_main_pivot_mocks() {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf '99\n'; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    issue_json_has_blocked_label() { return 1; }
}
