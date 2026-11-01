#!/usr/bin/env bats
# shellcheck disable=SC2329  # functions in @test bodies are invoked indirectly via 'run'
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are used inside run() subshells where shellcheck cannot trace them

bats_require_minimum_version 1.5.0

load test_helper
load oneshot_helper

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

# --- notify_discord_permission_denials (#1328) ----------------------------------

@test "notify_discord_permission_denials does not call curl when DISCORD_WEBHOOK_URL is empty" {
    DISCORD_WEBHOOK_URL=""
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_permission_denials "Issue" "42" "- Bash: git status"
    [ "${status}" -eq 0 ]
    [ ! -f "${args_log}" ]
}

@test "notify_discord_permission_denials posts to DISCORD_WEBHOOK_URL_PERMISSIONS when set, not DISCORD_WEBHOOK_URL (#1456)" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/general"
    DISCORD_WEBHOOK_URL_PERMISSIONS="https://discord.example.com/permissions"
    set_repo_context "org/repo-perm-1"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_permission_denials "Issue" "42" "- Bash: git status" "1"
    [ "${status}" -eq 0 ]
    grep -q "https://discord.example.com/permissions" "${args_log}"
    run ! grep -q "https://discord.example.com/general" "${args_log}"
}

@test "notify_discord_permission_denials falls back to DISCORD_WEBHOOK_URL when DISCORD_WEBHOOK_URL_PERMISSIONS is unset (#1456)" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/general"
    unset DISCORD_WEBHOOK_URL_PERMISSIONS
    set_repo_context "org/repo-perm-2"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_permission_denials "Issue" "42" "- Bash: git status" "1"
    [ "${status}" -eq 0 ]
    grep -q "https://discord.example.com/general" "${args_log}"
}

@test "notify_discord_permission_denials is silent when both DISCORD_WEBHOOK_URL_PERMISSIONS and DISCORD_WEBHOOK_URL are empty (#1456)" {
    DISCORD_WEBHOOK_URL=""
    DISCORD_WEBHOOK_URL_PERMISSIONS=""
    set_repo_context "org/repo-perm-3"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_permission_denials "Issue" "42" "- Bash: git status" "1"
    [ "${status}" -eq 0 ]
    [ ! -f "${args_log}" ]
}

@test "_discord_webhook_for falls back to DISCORD_WEBHOOK_URL for an unrecognised category (#1456)" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/general"
    DISCORD_WEBHOOK_URL_PERMISSIONS="https://discord.example.com/permissions"
    _discord_webhook_for "not_a_real_category"
    [ "${DISCORD_RESOLVED_WEBHOOK_URL}" = "https://discord.example.com/general" ]
}

@test "notify_discord_permission_denials calls curl with embed payload including issue URL, count, and summary" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_permission_denials "Issue" "42" "- Bash: git status" "1"
    [ "${status}" -eq 0 ]
    grep -q "https://discord.example.com/hook" "${args_log}"
    grep -q "https://github.com/org/repo/issues/42" "${args_log}"
    grep -q "Bash: git status" "${args_log}"
    grep -q "Permission Denials (1)" "${args_log}"
}

@test "notify_discord_permission_denials appends a truncation marker when the summary exceeds the field limit" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    local long_summary
    long_summary=$(printf -- '- Bash: git status %.0s' $(seq 1 100))
    run notify_discord_permission_denials "Issue" "42" "${long_summary}" "100"
    [ "${status}" -eq 0 ]
    grep -q "truncated; see the run log for the full list" "${args_log}"
    grep -q "Permission Denials (100)" "${args_log}"
}

@test "notify_discord_permission_denials does not append a truncation marker for a short summary" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_permission_denials "Issue" "42" "- Bash: git status" "1"
    [ "${status}" -eq 0 ]
    [ "$(grep -c "truncated; see the run log" "${args_log}")" -eq 0 ]
}

@test "notify_discord_permission_denials uses repo URL when item type is unknown" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_permission_denials "" "" "- Bash: git status" "1"
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

    invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md" 2>/dev/null
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

    invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md" 2>/dev/null
    grep -qx "${REPO_WORK_DIR}:${CONTAINER_REPO_PATH}:rw" "${args_log}"
    grep -qx "${RULES_DIR}:${CONTAINER_RULES_PATH}:ro" "${args_log}"
}

@test "invoke_claude mounts CLAUDE.md read-only as a single file when claude_md_content is provided" {
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

    invoke_claude "test prompt" "Issue" "42" "# per-item instructions" 2>/dev/null
    grep -q ':/home/developer/.claude/CLAUDE.md:ro' "${args_log}"
}

@test "invoke_claude mounts the five persistent Claude state subdirectories read-write" {
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

    invoke_claude "test prompt" "Issue" "42" "# per-item instructions" 2>/dev/null
    for d in sessions session-env plans cache backups; do
        grep -qx "${CLAUDE_STATE_DIR}/${d}:/home/developer/.claude/${d}:rw" "${args_log}"
        [ -d "${CLAUDE_STATE_DIR}/${d}" ]
    done
}

@test "invoke_claude mounts the persistent orchestrator cache global directory read-write (#1380)" {
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

    invoke_claude "test prompt" "Issue" "42" "# per-item instructions" 2>/dev/null
    grep -qx "${ORCHESTRATOR_CACHE_DIR}/global:/home/developer/.cache/orchestrator/global:rw" "${args_log}"
    [ -d "${ORCHESTRATOR_CACHE_DIR}/global" ]
    # Only "global" is mounted - "local" is created by entrypoint.sh itself and stays
    # container-ephemeral, so invoke_claude must not create or mount it.
    [ ! -e "${ORCHESTRATOR_CACHE_DIR}/local" ]
    [ "$(grep -c "${ORCHESTRATOR_CACHE_DIR}/local:" "${args_log}")" -eq 0 ]
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
    run invoke_claude "test prompt" "Issue" "42" ""
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"claude_md_content is required"* ]]
}

@test "invoke_claude notifies Discord before dying when claude_md_content is empty (#1103)" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "inspect" ] && exit 1
[ "$1" = "pull" ] && exit 0
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    local notify_log="${TEST_TMP}/notify.log"
    notify_discord_claude_error() { printf '%s\n' "$*" >> "${notify_log}"; }

    run invoke_claude "test prompt" "Issue" "42" ""
    [ "${status}" -ne 0 ]
    grep -q "claude_md_content is required" "${notify_log}"
}

@test "invoke_claude surfaces permission_denials via Discord even when the run also errors (#1328)" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "inspect" ] && exit 1
[ "$1" = "pull" ] && exit 0
printf '{"is_error":true,"api_error_status":"500","result":"internal error","permission_denials":[{"tool_name":"Bash","tool_input":{"command":"git status"}}]}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    notify_discord_claude_error() { return 0; }
    local notify_log="${TEST_TMP}/denial_notify.log"
    notify_discord_permission_denials() { printf '%s\n' "$*" >> "${notify_log}"; }

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    # Overall run still fails: handle_claude_is_error always dies - but the denial must have
    # been surfaced before tmpfile was deleted on that path (#1328).
    [ "${status}" -ne 0 ]
    grep -q "git status" "${notify_log}"
}

@test "invoke_claude persists the permission-denials summary as the last-session diagnostic even when the run also errors (#1448)" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "inspect" ] && exit 1
[ "$1" = "pull" ] && exit 0
printf '{"is_error":true,"api_error_status":"500","result":"internal error","permission_denials":[{"tool_name":"Bash","tool_input":{"command":"git status"}}]}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    notify_discord_claude_error() { return 0; }
    notify_discord_permission_denials() { return 0; }

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -ne 0 ]
    run load_last_diagnostic "Issue" "42"
    [[ "${output}" == *"Bash: git status"* ]]
}

@test "invoke_claude surfaces permission_denials via Discord on a successful run (#1328)" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "inspect" ] && exit 1
[ "$1" = "pull" ] && exit 0
printf '{"is_error":false,"result":"done","permission_denials":[{"tool_name":"Bash","tool_input":{"command":"git status"}}]}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    local notify_log="${TEST_TMP}/denial_notify.log"
    notify_discord_permission_denials() { printf '%s\n' "$*" >> "${notify_log}"; }

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -eq 0 ]
    grep -q "git status" "${notify_log}"
}

@test "invoke_claude does not call notify_discord_permission_denials when permission_denials is absent (#1328)" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "inspect" ] && exit 1
[ "$1" = "pull" ] && exit 0
printf '{"is_error":false,"result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    local notify_log="${TEST_TMP}/denial_notify.log"
    notify_discord_permission_denials() { printf '%s\n' "$*" >> "${notify_log}"; }

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -eq 0 ]
    [ ! -f "${notify_log}" ]
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
    # No board configured and no labels passed — status/sub-status/priority fall back
    # gracefully (#1136) rather than the old meaningless New/Resume "session status".
    grep -q "Priority" "${args_log}"
    grep -q "Undefined" "${args_log}"
    grep -q "Sub-status" "${args_log}"
    grep -q "Unknown" "${args_log}"
}

@test "notify_discord_work_item calls curl with embed payload for PullRequest resume" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_work_item "resume" "PullRequest" "7" "Update deps"
    [ "${status}" -eq 0 ]
    grep -q "https://github.com/org/repo/pull/7" "${args_log}"
    grep -q "Update deps" "${args_log}"
}

@test "notify_discord_work_item includes the item's priority-rank name in the payload (#1375)" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_work_item "start" "Issue" "42" "Fix the bug" "3"
    [ "${status}" -eq 0 ]
    grep -q "Priority" "${args_log}"
    grep -q "High" "${args_log}"
}

@test "notify_discord_work_item maps priority rank 5 to Security and 0 to Default (#1375)" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_work_item "start" "Issue" "42" "Fix the bug" "5"
    [ "${status}" -eq 0 ]
    grep -q "Security" "${args_log}"

    : > "${args_log}"
    run notify_discord_work_item "start" "Issue" "43" "Fix another bug" "0"
    [ "${status}" -eq 0 ]
    grep -q "Default" "${args_log}"
}

@test "notify_discord_work_item falls back to Undefined for a missing or out-of-range priority rank (#1375)" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_work_item "start" "Issue" "42" "Fix the bug" "99"
    [ "${status}" -eq 0 ]
    grep -q "Undefined" "${args_log}"
}

@test "notify_discord_work_item enriches Sub-status with round progress and keeps Status derived from the raw substatus (#1375)" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    # Shadow board_substatus_for_item rather than standing up a full fake GraphQL board — proves
    # notify_discord_work_item feeds its raw output into enrich_substatus_with_round_progress for
    # display, while still deriving the coarse Status field from the raw (unenriched) name (a real
    # ordering bug caught during review: computing Status from the already-enriched text made
    # every round-tracked phase silently show "Unknown").
    board_substatus_for_item() { printf 'AI Review'; }
    make_stub gh 'printf "%s" "{\"comments\":[{\"body\":\"Code review round: fixed 1 finding\"}]}"'
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_work_item "start" "PullRequest" "42" "Fix the bug" "3" "feature/x"
    [ "${status}" -eq 0 ]
    grep -q "AI Review (round 1 of ${MAX_CODE_REVIEW_ITERATIONS})" "${args_log}"
    grep -q "In Progress" "${args_log}"
}

@test "notify_discord_work_item defaults Progress to Running and omits Overall when not given (#1375)" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_work_item "start" "Issue" "42" "Fix the bug"
    [ "${status}" -eq 0 ]
    grep -q "Progress" "${args_log}"
    grep -q "Running" "${args_log}"
    [ "$(grep -c "Overall" "${args_log}")" -eq 0 ]
}

@test "notify_discord_work_item includes Overall when given (#1375)" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_work_item "start" "Issue" "42" "Fix the bug" "" "" "Running" "3 / 57"
    [ "${status}" -eq 0 ]
    grep -q "Overall" "${args_log}"
    grep -q "3 / 57" "${args_log}"
}

@test "notify_discord_work_item waiting sends a Progress field describing why it's parked (#1375)" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_work_item "waiting" "PullRequest" "42" "Fix the bug" "" "" "Waiting on CI"
    [ "${status}" -eq 0 ]
    grep -q "Progress" "${args_log}"
    grep -q "Waiting on CI" "${args_log}"
}

@test "notify_discord_work_item waiting suppresses an identical repeat but re-sends on a real change (#1375)" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local call_log="${TEST_TMP}/curl_calls"
    make_stub curl "printf 'call\n' >> '${call_log}'"

    run notify_discord_work_item "waiting" "PullRequest" "42" "Fix the bug" "" "" "Waiting on CI"
    [ "${status}" -eq 0 ]
    [ "$(wc -l < "${call_log}")" -eq 1 ]

    # Identical content again — suppressed, no second curl call.
    run notify_discord_work_item "waiting" "PullRequest" "42" "Fix the bug" "" "" "Waiting on CI"
    [ "${status}" -eq 0 ]
    [ "$(wc -l < "${call_log}")" -eq 1 ]

    # Genuine state change (now waiting on human review instead) — sends again.
    run notify_discord_work_item "waiting" "PullRequest" "42" "Fix the bug" "" "" "Waiting on human review"
    [ "${status}" -eq 0 ]
    [ "$(wc -l < "${call_log}")" -eq 2 ]
}

@test "notify_discord_work_item start clears the waiting latch so a repeated later waiting episode re-sends (#1375)" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local call_log="${TEST_TMP}/curl_calls"
    make_stub curl "printf 'call\n' >> '${call_log}'"

    run notify_discord_work_item "waiting" "PullRequest" "42" "Fix the bug" "" "" "Waiting on CI"
    [ "${status}" -eq 0 ]
    [ "$(wc -l < "${call_log}")" -eq 1 ]

    # Item observed actively running again — closes the waiting episode.
    run notify_discord_work_item "start" "PullRequest" "42" "Fix the bug"
    [ "${status}" -eq 0 ]

    # A later waiting episode reproducing the exact same content hash must NOT be treated as a
    # stale repeat of the closed episode above (#1375 review).
    run notify_discord_work_item "waiting" "PullRequest" "42" "Fix the bug" "" "" "Waiting on CI"
    [ "${status}" -eq 0 ]
    [ "$(wc -l < "${call_log}")" -eq 3 ]
}

@test "notify_discord_work_item waiting does not record the dedup state on a failed send (#1375)" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    make_stub curl 'exit 1'
    run notify_discord_work_item "waiting" "PullRequest" "42" "Fix the bug" "" "" "Waiting on CI"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"webhook notification failed"* ]]

    local call_log="${TEST_TMP}/curl_calls"
    make_stub curl "printf 'call\n' >> '${call_log}'"
    run notify_discord_work_item "waiting" "PullRequest" "42" "Fix the bug" "" "" "Waiting on CI"
    [ "${status}" -eq 0 ]
    [ "$(wc -l < "${call_log}")" -eq 1 ]
}

# --- notify_discord_pr_waiting -------------------------------------------------

@test "notify_discord_pr_waiting derives title, branch_name and comments from pr_json and forwards to notify_discord_work_item (#1375)" {
    set_repo_context "org/repo"
    discover_or_create_workflow_project() { return 0; }
    local call_log="${TEST_TMP}/notify_calls"
    notify_discord_work_item() { printf '%s\n' "$*" >> "${call_log}"; }
    local pr_json='{"title":"Fix the bug","headRefName":"feature/x","comments":[{"body":"hi"}]}'

    run notify_discord_pr_waiting "42" "${pr_json}" "3" "Waiting on CI"
    [ "${status}" -eq 0 ]
    [ -f "${call_log}" ]
    grep -q '^waiting PullRequest 42 Fix the bug 3 feature/x Waiting on CI  \[{"body":"hi"}\]$' "${call_log}"
}

@test "notify_discord_pr_waiting calls discover_or_create_workflow_project before notifying (#1375)" {
    set_repo_context "org/repo"
    local call_log="${TEST_TMP}/discover_calls"
    discover_or_create_workflow_project() { printf 'called\n' >> "${call_log}"; }
    notify_discord_work_item() { return 0; }

    run notify_discord_pr_waiting "42" '{"title":"T","comments":[]}' "" "Waiting on CI"
    [ "${status}" -eq 0 ]
    [ -f "${call_log}" ]
}

@test "notify_discord_pr_waiting defaults comments to an empty array when pr_json has none (#1375)" {
    set_repo_context "org/repo"
    discover_or_create_workflow_project() { return 0; }
    local call_log="${TEST_TMP}/notify_calls"
    notify_discord_work_item() { printf '%s\n' "$*" >> "${call_log}"; }

    run notify_discord_pr_waiting "42" '{"title":"T"}' "" "Waiting on CI"
    [ "${status}" -eq 0 ]
    grep -q '\[\]$' "${call_log}"
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

@test "notify_discord_no_work resends same content after one hour has elapsed" {
    # Two sequential real calls with IDENTICAL args, so the second call's dedup_hash genuinely
    # matches the state file the first call wrote — this is what actually exercises the
    # elapsed-time branch (elapsed > 3600), rather than a placeholder hash that can never match
    # regardless of timing (#1291 review: the prior version of this test used a hand-seeded
    # placeholder hash and would still pass even if the elapsed-time check were broken).
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"

    make_stub date "echo 1700000000"
    local args_log1="${TEST_TMP}/curl_first"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log1}'"
    run notify_discord_no_work "" 0 0 0 0
    [ "${status}" -eq 0 ]
    [ -f "${args_log1}" ]

    make_stub date "echo 1700003601"   # 3601s later — just past the one-hour window
    local args_log2="${TEST_TMP}/curl_second"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log2}'"
    run notify_discord_no_work "" 0 0 0 0
    [ "${status}" -eq 0 ]
    [ -f "${args_log2}" ]
    grep -q "No actionable work items found" "${args_log2}"
}

@test "notify_discord_no_work sends different content immediately even within the last hour" {
    # Two sequential real calls with DIFFERENT args at the SAME timestamp, so the second call's
    # dedup_hash genuinely differs from the state file the first call wrote (#1291 review — see
    # rationale on the sibling elapsed-time test above).
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    make_stub date "echo 1700000000"

    local args_log1="${TEST_TMP}/curl_first"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log1}'"
    run notify_discord_no_work "" 0 0 0 0
    [ "${status}" -eq 0 ]
    [ -f "${args_log1}" ]

    local args_log2="${TEST_TMP}/curl_second"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log2}'"
    run notify_discord_no_work "" 0 5 0 0
    [ "${status}" -eq 0 ]
    [ -f "${args_log2}" ]
    grep -q "unchanged: 5" "${args_log2}"
}

@test "notify_discord_no_work saves a hash (not raw text) to disk after sending" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    make_stub curl "exit 0"
    make_stub date "echo 1700000000"

    run notify_discord_no_work "" 0 0 0 0
    [ "${status}" -eq 0 ]

    local state_file="${ORCHESTRATOR_STATE_DIR}/.no_work__global.state"
    [ -f "${state_file}" ]
    local stored_hash
    stored_hash=$(sed -n '1p' "${state_file}")
    # sha256 hex digest: 64 lowercase hex characters — the dedup key, not the message text
    # (#1291: the breakdown can now be multi-line and much larger than a single content string).
    [[ "${stored_hash}" =~ ^[0-9a-f]{64}$ ]]
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

# --- notify_discord_no_work: per-item breakdown (#1291) ------------------------

@test "notify_discord_no_work includes item breakdown lines with a working link" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    local items='[{"type":"Issue","id":"42","repo":"org/repo","reason":"blocked - skipping"}]'
    run notify_discord_no_work "" 1 0 0 0 0 0 "${items}"
    [ "${status}" -eq 0 ]
    grep -q "Issue #42 in org/repo" "${args_log}"
    grep -q "https://github.com/org/repo/issues/42" "${args_log}"
    grep -q "blocked - skipping" "${args_log}"
}

@test "notify_discord_no_work omits breakdown lines when items_json is empty" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_no_work
    [ "${status}" -eq 0 ]
    run grep -q ' in .*):' "${args_log}"
    [ "${status}" -ne 0 ]
}

@test "notify_discord_no_work defaults items_json to an empty breakdown when omitted" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_no_work "" 1 0 0 0 0 0
    [ "${status}" -eq 0 ]
    grep -q "blocked: 1" "${args_log}"
}

@test "notify_discord_no_work suppresses identical items within the last hour" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    make_stub date "echo 1700000000"
    local items='[{"type":"Issue","id":"1","repo":"org/repo","reason":"unchanged - skipping"}]'

    local args_log1="${TEST_TMP}/curl_first"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log1}'"
    run notify_discord_no_work "" 0 1 0 0 0 0 "${items}"
    [ "${status}" -eq 0 ]
    [ -f "${args_log1}" ]

    local args_log2="${TEST_TMP}/curl_second"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log2}'"
    run notify_discord_no_work "" 0 1 0 0 0 0 "${items}"
    [ "${status}" -eq 0 ]
    [ ! -f "${args_log2}" ]
}

@test "notify_discord_no_work resends immediately when a single item's reason changes" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    make_stub date "echo 1700000000"

    local args_log1="${TEST_TMP}/curl_first"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log1}'"
    run notify_discord_no_work "" 0 1 0 0 0 0 '[{"type":"Issue","id":"1","repo":"org/repo","reason":"unchanged - skipping"}]'
    [ "${status}" -eq 0 ]
    [ -f "${args_log1}" ]

    local args_log2="${TEST_TMP}/curl_second"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log2}'"
    run notify_discord_no_work "" 0 1 0 0 0 0 '[{"type":"Issue","id":"1","repo":"org/repo","reason":"blocked - skipping"}]'
    [ "${status}" -eq 0 ]
    [ -f "${args_log2}" ]
    grep -q "blocked - skipping" "${args_log2}"
}

# --- record_item_status / serialize_item_status_log unit tests -----------------
# record_item_status is a pure function (outputs JSON, does not mutate a caller array) and
# serialize_item_status_log takes its entries as positional arguments (#1291 review: makes the
# data flow explicit at every call site instead of relying on bash's dynamic scoping).

@test "record_item_status outputs a compact JSON object for the given fields" {
    local obj
    obj=$(record_item_status "Issue" "42" "org/repo" "blocked - skipping")
    [ "$(printf '%s' "${obj}" | jq -r '.type')" = "Issue" ]
    [ "$(printf '%s' "${obj}" | jq -r '.id')" = "42" ]
    [ "$(printf '%s' "${obj}" | jq -r '.repo')" = "org/repo" ]
    [ "$(printf '%s' "${obj}" | jq -r '.reason')" = "blocked - skipping" ]
}

@test "serialize_item_status_log returns an empty JSON array when given no arguments" {
    [ "$(serialize_item_status_log)" = "[]" ]
}

@test "serialize_item_status_log combines multiple entries into one JSON array, in order" {
    local -a item_status_log=()
    item_status_log+=("$(record_item_status "Issue" "1" "org/repo" "reason one")")
    item_status_log+=("$(record_item_status "PullRequest" "2" "org/repo2" "reason two")")
    local combined
    combined=$(serialize_item_status_log "${item_status_log[@]}")
    [ "$(printf '%s' "${combined}" | jq 'length')" -eq 2 ]
    [ "$(printf '%s' "${combined}" | jq -r '.[0].id')" = "1" ]
    [ "$(printf '%s' "${combined}" | jq -r '.[1].id')" = "2" ]
}

# --- _build_no_work_item_breakdown unit tests -----------------------------------

@test "_build_no_work_item_breakdown returns empty for an empty items array" {
    [ -z "$(_build_no_work_item_breakdown '[]')" ]
}

@test "_build_no_work_item_breakdown builds one markdown line per item with a working link" {
    local items='[{"type":"Issue","id":"42","repo":"org/repo","reason":"blocked - skipping"}]'
    run _build_no_work_item_breakdown "${items}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "- [Issue #42 in org/repo](https://github.com/org/repo/issues/42): blocked - skipping" ]
}

@test "_build_no_work_item_breakdown uses each item's own repo for its link" {
    local items='[{"type":"PullRequest","id":"7","repo":"owner/other-repo","reason":"CI checks pending"}]'
    run _build_no_work_item_breakdown "${items}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"https://github.com/owner/other-repo/pull/7"* ]]
}

@test "_build_no_work_item_breakdown truncates and appends a trailer when over budget" {
    local items
    items=$(jq -cn '[range(0;400) | {type:"Issue", id:(.|tostring), repo:"org/repo", reason:"unchanged - skipping"}]')
    run _build_no_work_item_breakdown "${items}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"more (see the journal for full detail)"* ]]
    [[ "${output}" != *"Issue #399"* ]]

    # Assert the trailer's stated count and kept-item count actually add up to 400, and that a
    # substantial number of items were kept (not just one) — an off-by-one in the trailer count,
    # or a budget/line-length regression that keeps far fewer items than expected, would both
    # still pass the substring-only assertions above (#1291 review).
    local kept_count trailer_count
    kept_count=$(printf '%s\n' "${output}" | grep -c '^- \[Issue #')
    trailer_count=$(printf '%s\n' "${output}" | sed -n 's/^\.\.\. and \([0-9]\+\) more.*/\1/p')
    [ -n "${trailer_count}" ]
    [ "$(( kept_count + trailer_count ))" -eq 400 ]
    [ "${kept_count}" -gt 30 ]
}

# --- build_item_url: repo override (#1291) --------------------------------------

@test "build_item_url uses the explicit repo argument over REPO_FULL when given" {
    [ "$(build_item_url "Issue" "42" "other/repo")" = "https://github.com/other/repo/issues/42" ]
}

@test "build_item_url falls back to REPO_FULL when no repo argument is given" {
    [ "$(build_item_url "PullRequest" "17")" = "https://github.com/${REPO_FULL}/pull/17" ]
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

@test "notify_discord_blocked_item posts to DISCORD_WEBHOOK_URL_BLOCKED when set, not DISCORD_WEBHOOK_URL (#1456)" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/general"
    DISCORD_WEBHOOK_URL_BLOCKED="https://discord.example.com/blocked"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    make_stub gh 'printf "{\"title\":\"T\",\"labels\":[],\"comments\":[]}"'
    run notify_discord_blocked_item "Issue" "42"
    [ "${status}" -eq 0 ]
    grep -q "https://discord.example.com/blocked" "${args_log}"
    run ! grep -q "https://discord.example.com/general" "${args_log}"
}

@test "notify_discord_blocked_item falls back to DISCORD_WEBHOOK_URL when DISCORD_WEBHOOK_URL_BLOCKED is unset (#1456)" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/general"
    unset DISCORD_WEBHOOK_URL_BLOCKED
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    make_stub gh 'printf "{\"title\":\"T\",\"labels\":[],\"comments\":[]}"'
    run notify_discord_blocked_item "Issue" "42"
    [ "${status}" -eq 0 ]
    grep -q "https://discord.example.com/general" "${args_log}"
}

@test "notify_discord_blocked_item is silent when both DISCORD_WEBHOOK_URL_BLOCKED and DISCORD_WEBHOOK_URL are empty (#1456)" {
    DISCORD_WEBHOOK_URL=""
    DISCORD_WEBHOOK_URL_BLOCKED=""
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
    make_stub gh 'printf "{\"title\":\"T\",\"labels\":[],\"comments\":[]}"'
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
    make_stub gh 'printf "{\"title\":\"T\",\"labels\":[],\"comments\":[]}"'
    run notify_discord_blocked_item "PullRequest" "7"
    [ "${status}" -eq 0 ]
    grep -q "https://github.com/org/repo/pull/7" "${args_log}"
    grep -q "Blocked" "${args_log}"
}

@test "notify_discord_blocked_item includes the item's priority label in the payload (#1136)" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    make_stub gh 'printf "{\"title\":\"T\",\"labels\":[{\"name\":\"Urgent\"}],\"comments\":[]}"'
    run notify_discord_blocked_item "Issue" "42"
    [ "${status}" -eq 0 ]
    grep -q "Priority" "${args_log}"
    grep -q "Urgent" "${args_log}"
}

@test "notify_discord_blocked_item defaults priority to Undefined when the label fetch fails (#1136)" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    make_stub gh 'exit 1'
    run notify_discord_blocked_item "Issue" "42"
    [ "${status}" -eq 0 ]
    grep -q "Priority" "${args_log}"
    grep -q "Undefined" "${args_log}"
}

@test "notify_discord_blocked_item uses the item's real title, not just type and number (#1140)" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    make_stub gh 'printf "{\"title\":\"Cache writes are not atomic\",\"labels\":[],\"comments\":[]}"'
    run notify_discord_blocked_item "Issue" "42"
    [ "${status}" -eq 0 ]
    grep -q "Blocked: Cache writes are not atomic" "${args_log}"
}

@test "notify_discord_blocked_item falls back to type and number when the title fetch fails (#1140)" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    make_stub gh 'exit 1'
    run notify_discord_blocked_item "Issue" "42"
    [ "${status}" -eq 0 ]
    grep -q "Blocked: Issue #42" "${args_log}"
}

@test "notify_discord_blocked_item uses an explicit reason when the caller provides one (#1140)" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    make_stub gh 'printf "{\"title\":\"T\",\"labels\":[],\"comments\":[{\"body\":\"unrelated latest comment\"}]}"'
    run notify_discord_blocked_item "Issue" "42" "CI checks have been pending for over 1440 minutes."
    [ "${status}" -eq 0 ]
    grep -q "CI checks have been pending for over 1440 minutes" "${args_log}"
    run grep -q "unrelated latest comment" "${args_log}"
    [ "${status}" -ne 0 ]
}

@test "notify_discord_blocked_item falls back to the item's most recent comment when no reason is given (#1140)" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    make_stub gh 'printf "{\"title\":\"T\",\"labels\":[],\"comments\":[{\"body\":\"first comment\"},{\"body\":\"most recent explanation\"}]}"'
    run notify_discord_blocked_item "Issue" "42"
    [ "${status}" -eq 0 ]
    grep -q "most recent explanation" "${args_log}"
    run grep -q "first comment" "${args_log}"
    [ "${status}" -ne 0 ]
}

@test "notify_discord_blocked_item shows a placeholder reason when there are no comments to fall back on (#1140)" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    make_stub gh 'printf "{\"title\":\"T\",\"labels\":[],\"comments\":[]}"'
    run notify_discord_blocked_item "Issue" "42"
    [ "${status}" -eq 0 ]
    grep -q "No reason found" "${args_log}"
}

@test "notify_discord_blocked_item truncates a very long reason to 900 characters (#1140)" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    make_stub gh 'printf "{\"title\":\"T\",\"labels\":[],\"comments\":[]}"'
    local long_reason
    long_reason=$(printf 'x%.0s' $(seq 1 2000))
    run notify_discord_blocked_item "Issue" "42" "${long_reason}"
    [ "${status}" -eq 0 ]
    run grep -q "$(printf 'x%.0s' $(seq 1 2000))" "${args_log}"
    [ "${status}" -ne 0 ]
    grep -q "$(printf 'x%.0s' $(seq 1 900))" "${args_log}"
}

@test "notify_discord_blocked_item truncates a very long title to stay under Discord's embed title limit (#1140 review)" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    local long_title
    long_title=$(printf 'y%.0s' $(seq 1 300))
    make_stub gh "printf '{\"title\":\"${long_title}\",\"labels\":[],\"comments\":[]}'"
    run notify_discord_blocked_item "Issue" "42"
    [ "${status}" -eq 0 ]
    run grep -q "$(printf 'y%.0s' $(seq 1 300))" "${args_log}"
    [ "${status}" -ne 0 ]
    grep -q "$(printf 'y%.0s' $(seq 1 240))" "${args_log}"
}

@test "notify_discord_blocked_item is silent on a repeat call while the item stays blocked" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    make_stub gh 'printf "{\"title\":\"T\",\"labels\":[],\"comments\":[]}"'

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
    make_stub gh 'printf "{\"title\":\"T\",\"labels\":[],\"comments\":[]}"'

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

# --- build_item_url unit tests --------------------------------------------------

@test "build_item_url builds an issues URL for an Issue" {
    [ "$(build_item_url "Issue" "42")" = "https://github.com/${REPO_FULL}/issues/42" ]
}

@test "build_item_url builds a pull URL for a PullRequest" {
    [ "$(build_item_url "PullRequest" "17")" = "https://github.com/${REPO_FULL}/pull/17" ]
}

@test "build_item_url falls back to the bare repo URL for an unrecognised item_type" {
    [ "$(build_item_url "" "")" = "https://github.com/${REPO_FULL}" ]
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
    mkdir -p "${ORCHESTRATOR_STATE_DIR}"
    printf '%s\n' "$(( $(date +%s) - 1800 ))" > "${ORCHESTRATOR_STATE_DIR}/.low_disk_space__global.state"

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
    mkdir -p "${ORCHESTRATOR_STATE_DIR}"
    printf '%s\n' "$(( $(date +%s) - 5400 ))" > "${ORCHESTRATOR_STATE_DIR}/.low_disk_space__global.state"

    run notify_discord_low_disk_space
    [ "${status}" -eq 0 ]
    [ -f "${curl_log}" ]
}

@test "notify_discord_low_disk_space does not record dedup state when the curl POST fails (#1171 review)" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    disk_space_available_kb() { printf '5242880\n'; }
    make_stub curl 'exit 1'
    hash curl

    run notify_discord_low_disk_space
    [ "${status}" -eq 0 ]
    [ ! -f "${ORCHESTRATOR_STATE_DIR}/.low_disk_space__global.state" ]
}

@test "notify_discord_low_disk_space uses owner-scoped state file" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    disk_space_available_kb() { printf '5242880\n'; }
    local curl_log="${TEST_TMP}/curl_log"
    make_stub curl "printf 'called\n' >> ${curl_log}"
    hash curl

    # Write a state file for a different owner — should not suppress this call.
    mkdir -p "${ORCHESTRATOR_STATE_DIR}"
    printf '%s\n' "$(( $(date +%s) - 1800 ))" > "${ORCHESTRATOR_STATE_DIR}/.low_disk_space_other_owner.state"

    run notify_discord_low_disk_space "myowner"
    [ "${status}" -eq 0 ]
    [ -f "${curl_log}" ]
}

# --- notify_discord_host_health (#1101) ---------------------------------------

@test "notify_discord_host_health does nothing when DISCORD_WEBHOOK_URL is unset" {
    DISCORD_WEBHOOK_URL=""
    local curl_log="${TEST_TMP}/curl_log"
    make_stub curl "printf 'called\n' >> ${curl_log}"
    hash curl
    run notify_discord_host_health gpg_agent_down "gpg-agent is not running"
    [ "${status}" -eq 0 ]
    [ ! -f "${curl_log}" ]
}

@test "notify_discord_host_health sends embed when webhook is set" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    local curl_log="${TEST_TMP}/curl_log"
    make_stub curl "printf '%s\n' \"\$*\" >> ${curl_log}"
    hash curl
    run notify_discord_host_health gpg_agent_down "gpg-agent is not running"
    [ "${status}" -eq 0 ]
    [ -f "${curl_log}" ]
    grep -q "discord.example.com" "${curl_log}"
}

@test "notify_discord_host_health includes the failure key and message in the payload" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    local curl_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> ${curl_log}"
    hash curl
    run notify_discord_host_health gpg_agent_down "gpg-agent is not running on the host"
    [ "${status}" -eq 0 ]
    [ -f "${curl_log}" ]
    grep -q "gpg_agent_down" "${curl_log}"
    grep -q "gpg-agent is not running on the host" "${curl_log}"
}

@test "notify_discord_host_health suppresses duplicate notification for the same failure key within 1 hour" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    local curl_log="${TEST_TMP}/curl_log"
    make_stub curl "printf 'called\n' >> ${curl_log}"
    hash curl

    mkdir -p "${ORCHESTRATOR_STATE_DIR}"
    printf '%s\n' "$(( $(date +%s) - 1800 ))" > "${ORCHESTRATOR_STATE_DIR}/.host_health_gpg_agent_down__global.state"

    run notify_discord_host_health gpg_agent_down "gpg-agent is not running"
    [ "${status}" -eq 0 ]
    [ ! -f "${curl_log}" ]
}

@test "notify_discord_host_health resends after 1 hour has elapsed" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    local curl_log="${TEST_TMP}/curl_log"
    make_stub curl "printf 'called\n' >> ${curl_log}"
    hash curl

    mkdir -p "${ORCHESTRATOR_STATE_DIR}"
    printf '%s\n' "$(( $(date +%s) - 5400 ))" > "${ORCHESTRATOR_STATE_DIR}/.host_health_gpg_agent_down__global.state"

    run notify_discord_host_health gpg_agent_down "gpg-agent is not running"
    [ "${status}" -eq 0 ]
    [ -f "${curl_log}" ]
}

@test "notify_discord_host_health does not record dedup state when the curl POST fails" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    make_stub curl 'exit 1'
    hash curl

    run notify_discord_host_health gpg_agent_down "gpg-agent is not running"
    [ "${status}" -eq 0 ]
    [ ! -f "${ORCHESTRATOR_STATE_DIR}/.host_health_gpg_agent_down__global.state" ]
}

@test "notify_discord_host_health treats independent failure keys as independently deduplicated" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    local curl_log="${TEST_TMP}/curl_log"
    make_stub curl "printf 'called\n' >> ${curl_log}"
    hash curl

    # A recent notification for a different failure key must not suppress this one.
    mkdir -p "${ORCHESTRATOR_STATE_DIR}"
    printf '%s\n' "$(( $(date +%s) - 1800 ))" > "${ORCHESTRATOR_STATE_DIR}/.host_health_ssh_agent_down__global.state"

    run notify_discord_host_health gpg_agent_down "gpg-agent is not running"
    [ "${status}" -eq 0 ]
    [ -f "${curl_log}" ]
}

# --- notify_discord_slow_pull (#1400) ------------------------------------------

@test "notify_discord_slow_pull does nothing when DISCORD_WEBHOOK_URL is unset" {
    DISCORD_WEBHOOK_URL=""
    local curl_log="${TEST_TMP}/curl_log"
    make_stub curl "printf 'called\n' >> ${curl_log}"
    hash curl
    run notify_discord_slow_pull "owner" 600 100
    [ "${status}" -eq 0 ]
    [ ! -f "${curl_log}" ]
}

@test "notify_discord_slow_pull posts to DISCORD_WEBHOOK_URL_SLOW_PULL when set, not DISCORD_WEBHOOK_URL (#1456)" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/general"
    DISCORD_WEBHOOK_URL_SLOW_PULL="https://discord.example.com/slow-pull"
    local curl_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> ${curl_log}"
    hash curl
    run notify_discord_slow_pull "owner-sp-1" 600 100
    [ "${status}" -eq 0 ]
    grep -q "https://discord.example.com/slow-pull" "${curl_log}"
    run ! grep -q "https://discord.example.com/general" "${curl_log}"
}

@test "notify_discord_slow_pull falls back to DISCORD_WEBHOOK_URL when DISCORD_WEBHOOK_URL_SLOW_PULL is unset (#1456)" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/general"
    unset DISCORD_WEBHOOK_URL_SLOW_PULL
    local curl_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> ${curl_log}"
    hash curl
    run notify_discord_slow_pull "owner-sp-2" 600 100
    [ "${status}" -eq 0 ]
    grep -q "https://discord.example.com/general" "${curl_log}"
}

@test "notify_discord_slow_pull is silent when both DISCORD_WEBHOOK_URL_SLOW_PULL and DISCORD_WEBHOOK_URL are empty (#1456)" {
    DISCORD_WEBHOOK_URL=""
    DISCORD_WEBHOOK_URL_SLOW_PULL=""
    local curl_log="${TEST_TMP}/curl_log"
    make_stub curl "printf 'called\n' >> ${curl_log}"
    hash curl
    run notify_discord_slow_pull "owner-sp-3" 600 100
    [ "${status}" -eq 0 ]
    [ ! -f "${curl_log}" ]
}

@test "notify_discord_slow_pull sends embed with duration and baseline" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    local curl_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> ${curl_log}"
    hash curl
    run notify_discord_slow_pull "owner" 600 100
    [ "${status}" -eq 0 ]
    [ -f "${curl_log}" ]
    grep -q "owner" "${curl_log}"
}

@test "notify_discord_slow_pull suppresses duplicate notification within 1 hour, per owner" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    local curl_log="${TEST_TMP}/curl_log"
    make_stub curl "printf 'called\n' >> ${curl_log}"
    hash curl

    mkdir -p "${ORCHESTRATOR_STATE_DIR}"
    printf '%s\n' "$(( $(date +%s) - 1800 ))" > "${ORCHESTRATOR_STATE_DIR}/.slow_pull_owner.state"

    run notify_discord_slow_pull "owner" 600 100
    [ "${status}" -eq 0 ]
    [ ! -f "${curl_log}" ]
}

# --- notify_discord_pull_failed (#1400) ----------------------------------------

@test "notify_discord_pull_failed does nothing when DISCORD_WEBHOOK_URL is unset" {
    DISCORD_WEBHOOK_URL=""
    local curl_log="${TEST_TMP}/curl_log"
    make_stub curl "printf 'called\n' >> ${curl_log}"
    hash curl
    run notify_discord_pull_failed "Issue" "42" "pull failed"
    [ "${status}" -eq 0 ]
    [ ! -f "${curl_log}" ]
}

@test "notify_discord_pull_failed sends an embed titled Image Pull Failed, not Claude Error, linking to the item" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    REPO_FULL="owner/repo"
    local curl_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> ${curl_log}"
    hash curl
    run notify_discord_pull_failed "Issue" "42" "no cached local image is available"
    [ "${status}" -eq 0 ]
    [ -f "${curl_log}" ]
    grep -q "Image Pull Failed" "${curl_log}"
    grep -q "owner/repo/issues/42" "${curl_log}"
    [ "$(grep -c "Claude Error" "${curl_log}")" -eq 0 ]
}

@test "notify_discord_pull_failed fires again immediately on a second call (no suppression)" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    local curl_log="${TEST_TMP}/curl_log"
    make_stub curl "printf 'called\n' >> ${curl_log}"
    hash curl
    notify_discord_pull_failed "Issue" "42" "first failure"
    notify_discord_pull_failed "Issue" "42" "second failure"
    [ "$(wc -l < "${curl_log}")" -eq 2 ]
}

# --- notify_discord_self_update_stale (#1298) ---------------------------------

@test "notify_discord_board_conversion_failed does nothing when DISCORD_WEBHOOK_URL is unset (#1519)" {
    DISCORD_WEBHOOK_URL=""
    local curl_log="${TEST_TMP}/curl_log"
    make_stub curl "printf 'called\n' >> ${curl_log}"
    hash curl
    run notify_discord_board_conversion_failed "owner/repo" "deleting the Workflow Status field"
    [ "${status}" -eq 0 ]
    [ ! -f "${curl_log}" ]
}

@test "notify_discord_board_conversion_failed names the repository and the failed step (#1519)" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    local curl_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> ${curl_log}"
    hash curl
    run notify_discord_board_conversion_failed "owner/repo" "deleting the Workflow Status field"
    [ "${status}" -eq 0 ]
    grep -q "Workflow Board Conversion Failed: owner/repo" "${curl_log}"
    grep -q "deleting the Workflow Status field" "${curl_log}"
}

@test "notify_discord_board_conversion_failed alerts at most once an hour per repository, and separately for each repository (#1519)" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    local curl_log="${TEST_TMP}/curl_log"
    make_stub curl "printf 'called\n' >> ${curl_log}"
    hash curl
    notify_discord_board_conversion_failed "owner/repo-a" "step"
    notify_discord_board_conversion_failed "owner/repo-a" "step"
    [ "$(wc -l < "${curl_log}")" -eq 1 ]
    notify_discord_board_conversion_failed "owner/repo-b" "step"
    [ "$(wc -l < "${curl_log}")" -eq 2 ]
}

@test "notify_discord_self_update_stale does nothing when DISCORD_WEBHOOK_URL is unset" {
    DISCORD_WEBHOOK_URL=""
    local curl_log="${TEST_TMP}/curl_log"
    make_stub curl "printf 'called\n' >> ${curl_log}"
    hash curl
    run notify_discord_self_update_stale "" "abc1234" "3"
    [ "${status}" -eq 0 ]
    [ ! -f "${curl_log}" ]
}

@test "notify_discord_self_update_stale sends embed with the commit sha and behind count when webhook is set" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    local curl_log="${TEST_TMP}/curl_log"
    make_stub curl "printf '%s\n' \"\$*\" >> ${curl_log}"
    hash curl
    run notify_discord_self_update_stale "" "abc1234" "3"
    [ "${status}" -eq 0 ]
    [ -f "${curl_log}" ]
    grep -q "discord.example.com" "${curl_log}"
    grep -q "abc1234" "${curl_log}"
}

@test "notify_discord_self_update_stale includes owner in title when owner is provided" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    local curl_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> ${curl_log}"
    hash curl
    run notify_discord_self_update_stale "myowner" "abc1234" "3"
    [ "${status}" -eq 0 ]
    [ -f "${curl_log}" ]
    grep -q "myowner" "${curl_log}"
}

@test "notify_discord_self_update_stale suppresses duplicate notification within 1 hour" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    local curl_log="${TEST_TMP}/curl_log"
    make_stub curl "printf 'called\n' >> ${curl_log}"
    hash curl

    # Write a state file with a timestamp from 30 minutes ago.
    mkdir -p "${ORCHESTRATOR_STATE_DIR}"
    printf '%s\n' "$(( $(date +%s) - 1800 ))" > "${ORCHESTRATOR_STATE_DIR}/.self_update_stale__global.state"

    run notify_discord_self_update_stale "" "abc1234" "3"
    [ "${status}" -eq 0 ]
    [ ! -f "${curl_log}" ]
}

@test "notify_discord_self_update_stale resends after 1 hour has elapsed" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    local curl_log="${TEST_TMP}/curl_log"
    make_stub curl "printf 'called\n' >> ${curl_log}"
    hash curl

    # Write a state file with a timestamp from 90 minutes ago.
    mkdir -p "${ORCHESTRATOR_STATE_DIR}"
    printf '%s\n' "$(( $(date +%s) - 5400 ))" > "${ORCHESTRATOR_STATE_DIR}/.self_update_stale__global.state"

    run notify_discord_self_update_stale "" "abc1234" "3"
    [ "${status}" -eq 0 ]
    [ -f "${curl_log}" ]
}

@test "notify_discord_self_update_stale does not record dedup state when the curl POST fails" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    make_stub curl 'exit 1'
    hash curl

    run notify_discord_self_update_stale "" "abc1234" "3"
    [ "${status}" -eq 0 ]
    [ ! -f "${ORCHESTRATOR_STATE_DIR}/.self_update_stale__global.state" ]
}

@test "notify_discord_self_update_stale uses owner-scoped state file" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    local curl_log="${TEST_TMP}/curl_log"
    make_stub curl "printf 'called\n' >> ${curl_log}"
    hash curl

    # Write a state file for a different owner — should not suppress this call.
    mkdir -p "${ORCHESTRATOR_STATE_DIR}"
    printf '%s\n' "$(( $(date +%s) - 1800 ))" > "${ORCHESTRATOR_STATE_DIR}/.self_update_stale_other_owner.state"

    run notify_discord_self_update_stale "myowner" "abc1234" "3"
    [ "${status}" -eq 0 ]
    [ -f "${curl_log}" ]
}

# --- notify_discord_priorities_unreachable --------------------------------------------

@test "notify_discord_priorities_unreachable does nothing when DISCORD_WEBHOOK_URL is unset" {
    DISCORD_WEBHOOK_URL=""
    local curl_log="${TEST_TMP}/curl_log"
    make_stub curl "printf 'called\n' >> ${curl_log}"
    hash curl
    run notify_discord_priorities_unreachable
    [ "${status}" -eq 0 ]
    [ ! -f "${curl_log}" ]
}

@test "notify_discord_priorities_unreachable sends embed referencing PRIORITIES_URL when webhook is set" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    local curl_log="${TEST_TMP}/curl_log"
    make_stub curl "printf '%s\n' \"\$*\" >> ${curl_log}"
    hash curl
    run notify_discord_priorities_unreachable
    [ "${status}" -eq 0 ]
    [ -f "${curl_log}" ]
    grep -q "discord.example.com" "${curl_log}"
    grep -q "${PRIORITIES_URL}" "${curl_log}"
}

@test "notify_discord_priorities_unreachable includes owner in title when owner is provided" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    local curl_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> ${curl_log}"
    hash curl
    run notify_discord_priorities_unreachable "myowner"
    [ "${status}" -eq 0 ]
    [ -f "${curl_log}" ]
    grep -q "myowner" "${curl_log}"
}

@test "notify_discord_priorities_unreachable suppresses duplicate notification within 1 hour" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    local curl_log="${TEST_TMP}/curl_log"
    make_stub curl "printf 'called\n' >> ${curl_log}"
    hash curl

    # Write a state file with a timestamp from 30 minutes ago.
    mkdir -p "${ORCHESTRATOR_STATE_DIR}"
    printf '%s\n' "$(( $(date +%s) - 1800 ))" > "${ORCHESTRATOR_STATE_DIR}/.priorities_unreachable__global.state"

    run notify_discord_priorities_unreachable
    [ "${status}" -eq 0 ]
    [ ! -f "${curl_log}" ]
}

@test "notify_discord_priorities_unreachable resends after 1 hour has elapsed" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    local curl_log="${TEST_TMP}/curl_log"
    make_stub curl "printf 'called\n' >> ${curl_log}"
    hash curl

    # Write a state file with a timestamp from 90 minutes ago.
    mkdir -p "${ORCHESTRATOR_STATE_DIR}"
    printf '%s\n' "$(( $(date +%s) - 5400 ))" > "${ORCHESTRATOR_STATE_DIR}/.priorities_unreachable__global.state"

    run notify_discord_priorities_unreachable
    [ "${status}" -eq 0 ]
    [ -f "${curl_log}" ]
}

@test "notify_discord_priorities_unreachable shares one dedup state file across owners (#1171 review)" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    local curl_log="${TEST_TMP}/curl_log"
    make_stub curl "printf 'called\n' >> ${curl_log}"
    hash curl

    # PRIORITIES_URL is one global endpoint, not per-owner — a recent alert for a different
    # owner must suppress this call too, rather than each owner getting its own hourly quota.
    mkdir -p "${ORCHESTRATOR_STATE_DIR}"
    printf '%s\n' "$(( $(date +%s) - 1800 ))" > "${ORCHESTRATOR_STATE_DIR}/.priorities_unreachable__global.state"

    run notify_discord_priorities_unreachable "myowner"
    [ "${status}" -eq 0 ]
    [ ! -f "${curl_log}" ]
}

# --- notify_discord_pr_needs_approval (#1278) ---------------------------------

@test "notify_discord_pr_needs_approval does nothing when DISCORD_WEBHOOK_URL is unset" {
    DISCORD_WEBHOOK_URL=""
    REPO_FULL="org/repo"
    local curl_log="${TEST_TMP}/curl_log"
    make_stub curl "printf 'called\n' >> ${curl_log}"
    hash curl
    run notify_discord_pr_needs_approval 397 '{"title":"Some PR title"}'
    [ "${status}" -eq 0 ]
    [ ! -f "${curl_log}" ]
}

@test "notify_discord_pr_needs_approval posts to DISCORD_WEBHOOK_URL_AWAITING_APPROVAL when set, not DISCORD_WEBHOOK_URL (#1456)" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/general"
    DISCORD_WEBHOOK_URL_AWAITING_APPROVAL="https://discord.example.com/awaiting-approval"
    REPO_FULL="org/repo"
    local curl_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> ${curl_log}"
    hash curl
    run notify_discord_pr_needs_approval 501 '{"title":"Some PR title"}'
    [ "${status}" -eq 0 ]
    grep -q "https://discord.example.com/awaiting-approval" "${curl_log}"
    run ! grep -q "https://discord.example.com/general" "${curl_log}"
}

@test "notify_discord_pr_needs_approval falls back to DISCORD_WEBHOOK_URL when DISCORD_WEBHOOK_URL_AWAITING_APPROVAL is unset (#1456)" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/general"
    unset DISCORD_WEBHOOK_URL_AWAITING_APPROVAL
    REPO_FULL="org/repo"
    local curl_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> ${curl_log}"
    hash curl
    run notify_discord_pr_needs_approval 502 '{"title":"Some PR title"}'
    [ "${status}" -eq 0 ]
    grep -q "https://discord.example.com/general" "${curl_log}"
}

@test "notify_discord_pr_needs_approval is silent when both DISCORD_WEBHOOK_URL_AWAITING_APPROVAL and DISCORD_WEBHOOK_URL are empty (#1456)" {
    DISCORD_WEBHOOK_URL=""
    DISCORD_WEBHOOK_URL_AWAITING_APPROVAL=""
    REPO_FULL="org/repo"
    local curl_log="${TEST_TMP}/curl_log"
    make_stub curl "printf 'called\n' >> ${curl_log}"
    hash curl
    run notify_discord_pr_needs_approval 503 '{"title":"Some PR title"}'
    [ "${status}" -eq 0 ]
    [ ! -f "${curl_log}" ]
}

@test "notify_discord_pr_needs_approval sends embed naming the PR and repo" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    REPO_FULL="org/repo"
    local curl_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> ${curl_log}"
    hash curl
    run notify_discord_pr_needs_approval 397 '{"title":"Some PR title"}'
    [ "${status}" -eq 0 ]
    [ -f "${curl_log}" ]
    grep -q "discord.example.com" "${curl_log}"
    grep -q "org/repo/pull/397" "${curl_log}"
    grep -q "Some PR title" "${curl_log}"
}

@test "notify_discord_pr_needs_approval suppresses duplicate notification within 1 hour" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    REPO_FULL="org/repo"
    local curl_log="${TEST_TMP}/curl_log"
    make_stub curl "printf 'called\n' >> ${curl_log}"
    hash curl

    mkdir -p "${ORCHESTRATOR_STATE_DIR}"
    printf '%s\n' "$(( $(date +%s) - 1800 ))" > "${ORCHESTRATOR_STATE_DIR}/.pr_needs_approval_org_repo_397.state"

    run notify_discord_pr_needs_approval 397 '{"title":"Some PR title"}'
    [ "${status}" -eq 0 ]
    [ ! -f "${curl_log}" ]
}

@test "notify_discord_pr_needs_approval resends after 1 hour has elapsed" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    REPO_FULL="org/repo"
    local curl_log="${TEST_TMP}/curl_log"
    make_stub curl "printf 'called\n' >> ${curl_log}"
    hash curl

    mkdir -p "${ORCHESTRATOR_STATE_DIR}"
    printf '%s\n' "$(( $(date +%s) - 5400 ))" > "${ORCHESTRATOR_STATE_DIR}/.pr_needs_approval_org_repo_397.state"

    run notify_discord_pr_needs_approval 397 '{"title":"Some PR title"}'
    [ "${status}" -eq 0 ]
    [ -f "${curl_log}" ]
}

@test "notify_discord_pr_needs_approval does not record dedup state when the curl POST fails" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    REPO_FULL="org/repo"
    make_stub curl 'exit 1'
    hash curl

    run notify_discord_pr_needs_approval 397 '{"title":"Some PR title"}'
    [ "${status}" -eq 0 ]
    [ ! -f "${ORCHESTRATOR_STATE_DIR}/.pr_needs_approval_org_repo_397.state" ]
}

@test "notify_discord_pr_needs_approval scopes its dedup state per repo-and-PR, not just PR number" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    REPO_FULL="org/repo"
    local curl_log="${TEST_TMP}/curl_log"
    make_stub curl "printf 'called\n' >> ${curl_log}"
    hash curl

    # A recent alert for PR #397 in a DIFFERENT repo must not suppress this call — same PR
    # number, different repo, is a different PR.
    mkdir -p "${ORCHESTRATOR_STATE_DIR}"
    printf '%s\n' "$(( $(date +%s) - 1800 ))" > "${ORCHESTRATOR_STATE_DIR}/.pr_needs_approval_other_repo_397.state"

    run notify_discord_pr_needs_approval 397 '{"title":"Some PR title"}'
    [ "${status}" -eq 0 ]
    [ -f "${curl_log}" ]
}

@test "notify_discord_pr_needs_approval falls back to a generic title when pr_json has none" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    REPO_FULL="org/repo"
    local curl_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> ${curl_log}"
    hash curl
    run notify_discord_pr_needs_approval 397 '{}'
    [ "${status}" -eq 0 ]
    grep -q "PullRequest #397" "${curl_log}"
}

@test "notify_discord_pr_needs_approval truncates an over-long title to stay under Discord's embed-title cap" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    REPO_FULL="org/repo"
    local curl_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> ${curl_log}"
    hash curl
    local long_title
    long_title=$(printf '%*s' 300 '' | tr ' ' 'x')
    run notify_discord_pr_needs_approval 397 "$(jq -n --arg t "${long_title}" '{title:$t}')"
    [ "${status}" -eq 0 ]
    # 240-char slice of the title, plus the "Needs Approval: " prefix, must appear; the raw
    # 300-char title must not (it would have been sliced down).
    grep -qE "x{240}" "${curl_log}"
    [ "$(grep -cE "x{300}" "${curl_log}")" -eq 0 ]
}
