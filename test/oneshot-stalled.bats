#!/usr/bin/env bats
# shellcheck disable=SC2329  # functions in @test bodies are invoked indirectly via 'run'
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are used inside run() subshells where shellcheck cannot trace them

bats_require_minimum_version 1.5.0

load test_helper
load oneshot_helper

# --- stalled-session outcome, alert, per-day record and daily digest -----------

@test "claude_result_indicates_tool_denied_quit matches a session that stopped because Bash is now denied" {
    claude_result_indicates_tool_denied_quit "Bash is now denied (don't ask mode), so I couldn't run the build. Stopping here."
}

@test "claude_result_indicates_tool_denied_quit matches don't ask mode with a session-level stop" {
    claude_result_indicates_tool_denied_quit "Because of don't ask mode I couldn't run git fetch, so I have stopped."
    claude_result_indicates_tool_denied_quit "I stopped work after a denial in don't ask mode."
}

@test "claude_result_indicates_tool_denied_quit has no length cap" {
    local long_text
    long_text="$(printf 'Implemented the change and updated the docs. %.0s' $(seq 1 20))The Bash tool was disabled for the rest of the session."
    [ "${#long_text}" -gt 500 ]
    claude_result_indicates_tool_denied_quit "${long_text}"
}

@test "claude_result_indicates_tool_denied_quit does not match a session that retried a denied command successfully" {
    run claude_result_indicates_tool_denied_quit "The first git fetch was denied in don't ask mode, so I reran it as git -C /workspace/repo fetch and it succeeded. All checks pass."
    [ "${status}" -ne 0 ]
}

@test "claude_result_indicates_tool_denied_quit does not match a session that worked round one denied Bash call" {
    run claude_result_indicates_tool_denied_quit "Note: Bash was denied for one gh api call, so I used gh pr view instead and finished."
    [ "${status}" -ne 0 ]
}

@test "claude_result_indicates_tool_denied_quit does not match a can't that is not about continuing when a workaround follows" {
    run claude_result_indicates_tool_denied_quit "don't ask mode blocked rm, so I can't delete it that way; used git clean instead and pushed."
    [ "${status}" -ne 0 ]
}

@test "claude_result_indicates_tool_denied_quit does not match a session that stopped short of one step and worked round it" {
    run claude_result_indicates_tool_denied_quit "In don't ask mode, the gh pr merge call was blocked, so I stopped short of merging and left a comment instead"
    [ "${status}" -ne 0 ]
    run claude_result_indicates_tool_denied_quit "In don't ask mode, the gh pr merge call was blocked, so I stopped short of merging."
    [ "${status}" -ne 0 ]
}

@test "claude_result_indicates_tool_denied_quit does not match a session that could not continue one step but completed the rest" {
    run claude_result_indicates_tool_denied_quit "Bash was denied for rm, and I could not continue with cleanup, but the rest of the work is complete"
    [ "${status}" -ne 0 ]
}

@test "claude_result_indicates_tool_denied_quit does not match a give-up phrase with no denial mention" {
    run claude_result_indicates_tool_denied_quit "The build failed twice, so I cannot continue."
    [ "${status}" -ne 0 ]
}

@test "claude_result_indicates_tool_denied_quit matches session-ending phrasing" {
    claude_result_indicates_tool_denied_quit "Bash is no longer available, so the rest of the work is left for a human."
    claude_result_indicates_tool_denied_quit "The Bash tool was denied, so I cannot continue."
    claude_result_indicates_tool_denied_quit "In don't ask mode I am unable to proceed with the build."
    claude_result_indicates_tool_denied_quit "Giving up: don't ask mode refused the push."
}

@test "claude_result_indicates_tool_denied_quit matches a give-up phrase in a different clause or sentence from the denial" {
    claude_result_indicates_tool_denied_quit "Bash tool was denied for git push; I cannot proceed"
    claude_result_indicates_tool_denied_quit "All Bash commands are being denied. I cannot continue."
}

@test "claude_result_indicates_tool_denied_quit treats workaround terms as whole words only" {
    claude_result_indicates_tool_denied_quit "The branch is unpushed: Bash was denied, so I cannot proceed."
    claude_result_indicates_tool_denied_quit "The work is unfinished because Bash is denied; I cannot continue."
    claude_result_indicates_tool_denied_quit "Bash is completely denied now. I cannot continue."
}

@test "claude_result_indicates_tool_denied_quit matches session-level denial wording" {
    claude_result_indicates_tool_denied_quit "I couldn't post the plan: Bash is now denied (\"don't ask mode\"), so nothing below has been done."
    claude_result_indicates_tool_denied_quit "Bash was denied partway through the session (\"don't ask mode\"). Earlier Bash calls worked."
    claude_result_indicates_tool_denied_quit "I couldn't make any progress on #1042, because the Bash tool is denied in this session"
}

@test "claude_result_indicates_tool_denied_quit matches the quoted don't ask mode wording agents write" {
    claude_result_indicates_tool_denied_quit "Claude Code is in \"don't ask\" mode and denied my first Bash call. To continue, either allow Bash, then re-invoke me."
    claude_result_indicates_tool_denied_quit "Claude Code is in \"don't ask\" mode, so I couldn't do anything on this PR."
    claude_result_indicates_tool_denied_quit "Bash is denied (\"don't ask\" mode). To continue, allow Bash for this repository."
    claude_result_indicates_tool_denied_quit "Claude Code is in \"don't ask\" mode; nothing has been done."
}

@test "claude_result_indicates_tool_denied_quit matches a session that stopped before starting or was stopped by a denial" {
    claude_result_indicates_tool_denied_quit "I stopped before doing any phase work because Bash is denied"
    claude_result_indicates_tool_denied_quit "A permission denial stopped me from running the build in \"don't ask\" mode"
}

@test "claude_result_indicates_tool_denied_quit does not match a denial that stopped one step when a workaround follows" {
    run claude_result_indicates_tool_denied_quit "A permission denial stopped me from running rm in \"don't ask\" mode, so I used git clean instead"
    [ "${status}" -ne 0 ]
}

@test "claude_result_indicates_tool_denied_quit matches a quit that says nothing was pushed or completed" {
    claude_result_indicates_tool_denied_quit "Bash is denied. I cannot proceed. Nothing was pushed."
    claude_result_indicates_tool_denied_quit "All Bash commands are being denied. I cannot continue; the task was not completed."
    claude_result_indicates_tool_denied_quit "Bash is denied; nothing else has been completed. Stopping here."
    claude_result_indicates_tool_denied_quit "Bash is denied; no commits were pushed. Giving up."
}

@test "claude_result_indicates_tool_denied_quit matches a quit with not, never or n't right before the workaround word" {
    claude_result_indicates_tool_denied_quit "Bash is denied, so I have not finished. I cannot continue."
    claude_result_indicates_tool_denied_quit "Bash is denied; the PR has not yet been pushed. Stopping here."
    claude_result_indicates_tool_denied_quit "Bash is denied; I never pushed. Stopping here."
    claude_result_indicates_tool_denied_quit "Bash was denied; I haven't pushed anything and cannot proceed."
    claude_result_indicates_tool_denied_quit "Bash was denied; I haven’t pushed anything and cannot proceed."
    claude_result_indicates_tool_denied_quit "Bash is denied so I couldn't push. I cannot continue."
}

@test "claude_result_indicates_tool_denied_quit matches a quit with cannot or a negation before be and the workaround word" {
    claude_result_indicates_tool_denied_quit "Bash is denied, so I cannot continue; the merge could not be completed."
    claude_result_indicates_tool_denied_quit "Bash is denied; the branch cannot be pushed. Stopping here."
    claude_result_indicates_tool_denied_quit "Bash is denied; the branch can't be pushed. Giving up."
    claude_result_indicates_tool_denied_quit "Bash is denied; the fix won't be pushed. I cannot continue."
}

@test "claude_result_indicates_tool_denied_quit still sees a real workaround next to a negated one" {
    run claude_result_indicates_tool_denied_quit "Bash is denied in don't ask mode. The docs were not completed, but I pushed the code. I cannot continue with the docs."
    [ "${status}" -ne 0 ]
    run claude_result_indicates_tool_denied_quit "Bash was denied; nothing was pushed by the first attempt, so I could not continue that way and used gh instead."
    [ "${status}" -ne 0 ]
}

@test "claude_result_indicates_tool_denied_quit treats negation as whole words only" {
    # "piano" ends in "no" and "knot" ends in "not", but neither is a negation.
    run claude_result_indicates_tool_denied_quit "Bash is denied, so I cannot continue the piano pushed task; the knot finished."
    [ "${status}" -ne 0 ]
}

@test "claude_result_indicates_tool_denied_quit accepts a curly apostrophe" {
    claude_result_indicates_tool_denied_quit "Claude Code is in don’t ask mode, so I can’t continue."
    claude_result_indicates_tool_denied_quit "Bash is denied, so I couldn’t do anything."
}

@test "claude_result_indicates_tool_denied_quit does not treat a letter or space as an apostrophe" {
    run claude_result_indicates_tool_denied_quit "The Bash tool was denied once; can it continue after the retry?"
    [ "${status}" -ne 0 ]
}

@test "claude_result_indicates_tool_denied_quit does not match quoted don't ask mode wording that reports a workaround" {
    run claude_result_indicates_tool_denied_quit "Claude Code is in \"don't ask\" mode and denied one Bash call, so I used gh pr view instead and finished. Re-invoke me if the merge is still needed."
    [ "${status}" -ne 0 ]
}

@test "claude_result_denied_command_names gives Bash first words and other tool names, deduplicated, never arguments" {
    local result_file="${TEST_TMP}/result.json"
    printf '%s\n' '{"permission_denials":[{"tool_name":"Bash","tool_input":{"command":"git fetch origin --token=s3cret"}},{"tool_name":"Bash","tool_input":{"command":"  gh api user"}},{"tool_name":"Bash","tool_input":{"command":"git status"}},{"tool_name":"Read","tool_input":{"file_path":"/home/x/.ssh/id_rsa"}},"malformed"]}' > "${result_file}"
    run claude_result_denied_command_names "${result_file}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "Read,gh,git" ]
}

@test "claude_result_denied_command_names skips a leading env assignment and never prints its secret value" {
    local result_file="${TEST_TMP}/result.json"
    printf '%s\n' '{"permission_denials":[{"tool_name":"Bash","tool_input":{"command":"GH_TOKEN=ghp_abc123 FOO=bar gh pr merge 7"}},{"tool_name":"Bash","tool_input":{"command":"env GH_TOKEN=ghp_def456 sudo nohup dotnet build"}},{"tool_name":"Bash","tool_input":{"command":"GH_TOKEN=ghp_only"}}]}' > "${result_file}"
    run claude_result_denied_command_names "${result_file}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "(other),dotnet,gh" ]
    [[ "${output}" != *ghp_* ]]
    [[ "${output}" != *GH_TOKEN* ]]
}

@test "claude_result_denied_command_names keeps only the basename of an absolute path" {
    local result_file="${TEST_TMP}/result.json"
    printf '%s\n' '{"permission_denials":[{"tool_name":"Bash","tool_input":{"command":"/home/someone/private-project/bin/deploy.sh --prod"}}]}' > "${result_file}"
    run claude_result_denied_command_names "${result_file}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "deploy.sh" ]
    [[ "${output}" != */* ]]
}

@test "claude_result_denied_command_names strips a leading bracket or quote and never prints a path" {
    local result_file="${TEST_TMP}/result.json"
    # shellcheck disable=SC2016  # the JSON fixture deliberately holds literal $HOME and $(...) so the test can check they are never expanded or printed
    printf '%s\n' '{"permission_denials":[{"tool_name":"Bash","tool_input":{"command":"\"$HOME/secret-dir/tool\" --x"}},{"tool_name":"Bash","tool_input":{"command":"(cd /workspace/repo && make)"}},{"tool_name":"Bash","tool_input":{"command":"{ git status; }"}},{"tool_name":"Bash","tool_input":{"command":"$(cat /etc/passwd)"}}]}' > "${result_file}"
    run claude_result_denied_command_names "${result_file}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "(other),cd,git,tool" ]
    [[ "${output}" != */* ]]
    [[ "${output}" != *secret-dir* ]]
    [[ "${output}" != *HOME* ]]
}

@test "claude_result_denied_command_names skips sudo's options and the value of sudo -u" {
    local result_file="${TEST_TMP}/result.json"
    printf '%s\n' '{"permission_denials":[{"tool_name":"Bash","tool_input":{"command":"sudo -u x /usr/bin/gh api user"}}]}' > "${result_file}"
    run claude_result_denied_command_names "${result_file}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "gh" ]
    [[ "${output}" != */* ]]
}

@test "claude_result_denied_command_names skips an xargs option with no value" {
    local result_file="${TEST_TMP}/result.json"
    printf '%s\n' '{"permission_denials":[{"tool_name":"Bash","tool_input":{"command":"xargs -0 rm"}}]}' > "${result_file}"
    run claude_result_denied_command_names "${result_file}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "rm" ]
}

@test "claude_result_denied_command_names skips the value of an xargs option that takes one" {
    local result_file="${TEST_TMP}/result.json"
    printf '%s\n' '{"permission_denials":[{"tool_name":"Bash","tool_input":{"command":"xargs -I {} -n 1 cp {} /x"}}]}' > "${result_file}"
    run claude_result_denied_command_names "${result_file}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "cp" ]
}

@test "claude_result_denied_command_names skips env's options" {
    local result_file="${TEST_TMP}/result.json"
    printf '%s\n' '{"permission_denials":[{"tool_name":"Bash","tool_input":{"command":"env -i foo"}}]}' > "${result_file}"
    run claude_result_denied_command_names "${result_file}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "foo" ]
}

@test "claude_result_denied_command_names skips the value of env -u and later assignments without printing them" {
    local result_file="${TEST_TMP}/result.json"
    printf '%s\n' '{"permission_denials":[{"tool_name":"Bash","tool_input":{"command":"env -u GH_TOKEN FOO=ghp_abc123 gh pr list"}}]}' > "${result_file}"
    run claude_result_denied_command_names "${result_file}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "gh" ]
    [[ "${output}" != *GH_TOKEN* ]]
    [[ "${output}" != *ghp_* ]]
}

@test "claude_result_denied_command_names skips time's options and the value of time -o" {
    local result_file="${TEST_TMP}/result.json"
    printf '%s\n' '{"permission_denials":[{"tool_name":"Bash","tool_input":{"command":"time -p cmd"}},{"tool_name":"Bash","tool_input":{"command":"time -o /home/someone/secret.log make"}}]}' > "${result_file}"
    run claude_result_denied_command_names "${result_file}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "cmd,make" ]
    [[ "${output}" != *secret* ]]
}

@test "claude_result_denied_command_names stops skipping wrapper options at --" {
    local result_file="${TEST_TMP}/result.json"
    printf '%s\n' '{"permission_denials":[{"tool_name":"Bash","tool_input":{"command":"nohup -- dotnet build"}}]}' > "${result_file}"
    run claude_result_denied_command_names "${result_file}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "dotnet" ]
}

@test "claude_result_denied_command_names skips long wrapper options and their values through nested wrappers" {
    local result_file="${TEST_TMP}/result.json"
    printf '%s\n' '{"permission_denials":[{"tool_name":"Bash","tool_input":{"command":"sudo --user root env -i FOO=bar nohup make"}}]}' > "${result_file}"
    run claude_result_denied_command_names "${result_file}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "make" ]
    [[ "${output}" != *root* ]]
}

@test "claude_result_denied_command_names gives (other) for a quoted option value that spans several words" {
    local result_file="${TEST_TMP}/result.json"
    printf '%s\n' '{"permission_denials":[{"tool_name":"Bash","tool_input":{"command":"sudo -p \"Enter s3cret\" gh"}},{"tool_name":"Bash","tool_input":{"command":"sudo -u"}}]}' > "${result_file}"
    run claude_result_denied_command_names "${result_file}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "(other)" ]
    [[ "${output}" != *s3cret* ]]
}

@test "claude_result_denied_command_names keeps cd as the program of a subshell that starts with cd" {
    local result_file="${TEST_TMP}/result.json"
    printf '%s\n' '{"permission_denials":[{"tool_name":"Bash","tool_input":{"command":"(cd /x && git status)"}}]}' > "${result_file}"
    run claude_result_denied_command_names "${result_file}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "cd" ]
}

@test "claude_result_denied_command_names prints nothing when there are no denials" {
    local result_file="${TEST_TMP}/result.json"
    printf '%s\n' '{"result":"done"}' > "${result_file}"
    run claude_result_denied_command_names "${result_file}"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "session_outcome_is_stalled is true on the quit flag alone, and on denials only with no PR progress" {
    session_outcome_is_stalled 1 0 0
    session_outcome_is_stalled 0 3 1
    run session_outcome_is_stalled 0 0 1
    [ "${status}" -ne 0 ]
    run session_outcome_is_stalled 0 3 0
    [ "${status}" -ne 0 ]
}

# Runs invoke_claude and prints the SESSION_* outcome it left, so a test can read the globals set
# inside run's subshell.
invoke_claude_and_print_outcome() {
    invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md" > /dev/null 2>&1
    printf '%s|%s|%s\n' "${SESSION_DENIAL_COUNT}" "${SESSION_DENIED_COMMANDS}" "${SESSION_TOOL_DENIED_QUIT}"
}

@test "invoke_claude sets the session outcome globals from the result" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "inspect" ] && exit 1
[ "$1" = "pull" ] && exit 0
printf '{"is_error":false,"result":"Bash is now denied (don'"'"'t ask mode), so I couldn'"'"'t continue.","permission_denials":[{"tool_name":"Bash","tool_input":{"command":"git fetch origin"}},{"tool_name":"Bash","tool_input":{"command":"dotnet build"}}]}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"
    notify_discord_permission_denials() { return 0; }

    run invoke_claude_and_print_outcome
    [ "${output}" = "2|dotnet,git|1" ]
}

@test "invoke_claude resets the session outcome globals left by an earlier session before any early exit" {
    # The prompt-length check dies before any container runs, so capture_session_outcome never
    # does: only the reset at the very top of invoke_claude can clear the earlier session's values.
    MAX_PROMPT_CHARS=5
    notify_discord_claude_error() { return 0; }
    die() { printf '%s|%s|%s|%s\n' "${SESSION_DENIAL_COUNT}" "${SESSION_DENIED_COMMANDS}" "${SESSION_TOOL_DENIED_QUIT}" "${SESSION_RESULT_TEXT}"; exit 1; }
    SESSION_DENIAL_COUNT=5
    SESSION_DENIED_COMMANDS="git"
    SESSION_TOOL_DENIED_QUIT=1
    SESSION_RESULT_TEXT="earlier session"

    run invoke_claude "a prompt longer than five characters" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -eq 1 ]
    [ "${output}" = "0||0|" ]
}

@test "invoke_claude records the session line and the stalled alert before dying on an errored run" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "inspect" ] && exit 1
[ "$1" = "pull" ] && exit 0
printf '{"is_error":true,"api_error_status":"500","result":"Bash is now denied, so I stopped.","permission_denials":[{"tool_name":"Bash","tool_input":{"command":"git status --short"}}]}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"
    orchestrator_today() { printf '2026-10-05'; }
    notify_discord_claude_error() { return 0; }
    notify_discord_permission_denials() { return 0; }
    local stalled_log="${TEST_TMP}/stalled.log"
    notify_discord_session_stalled() { printf '%s\n' "$*" >> "${stalled_log}"; }

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -ne 0 ]
    local state_file="${ORCHESTRATOR_STATE_DIR}/${OWNER}/session-denials.2026-10-05"
    [ "$(wc -l < "${state_file}")" -eq 1 ]
    [ "$(cut -f2- "${state_file}")" = "$(printf '%s\tIssue\t42\t1\t1\t1\tgit' "${REPO_FULL}")" ]
    grep -q "^Issue 42 1 git Bash is now denied" "${stalled_log}"
    [ "$(grep -c -- '--short' "${state_file}")" -eq 0 ]
    [ "$(grep -c -- '--short' "${stalled_log}")" -eq 0 ]
}

@test "invoke_claude records one session line with no denials before dying when the container times out" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "inspect" ] && exit 1
[ "$1" = "pull" ] && exit 0
[ "$1" = "rm" ] && exit 0
exit 124
STUBEOF
    chmod +x "${STUB_BIN}/podman"
    orchestrator_today() { printf '2026-10-05'; }
    notify_discord_claude_error() { return 0; }
    local stalled_log="${TEST_TMP}/stalled.log"
    notify_discord_session_stalled() { printf '%s\n' "$*" >> "${stalled_log}"; }
    SESSION_DENIAL_COUNT=4
    SESSION_DENIED_COMMANDS="git"
    SESSION_TOOL_DENIED_QUIT=1

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"timed out"* ]]
    local state_file="${ORCHESTRATOR_STATE_DIR}/${OWNER}/session-denials.2026-10-05"
    [ "$(wc -l < "${state_file}")" -eq 1 ]
    [ "$(cut -f3- "${state_file}")" = "$(printf 'Issue\t42\t0\t0\t0\t-')" ]
    [ ! -f "${stalled_log}" ]
}

@test "invoke_claude records one session line before dying when Claude returns no result object" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "inspect" ] && exit 1
[ "$1" = "pull" ] && exit 0
printf '"Bash is now denied, so I stopped."\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"
    orchestrator_today() { printf '2026-10-05'; }
    local stalled_log="${TEST_TMP}/stalled.log"
    notify_discord_session_stalled() { printf '%s\n' "$*" >> "${stalled_log}"; }

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Claude did not return a result object"* ]]
    local state_file="${ORCHESTRATOR_STATE_DIR}/${OWNER}/session-denials.2026-10-05"
    [ "$(wc -l < "${state_file}")" -eq 1 ]
    [ "$(cut -f3- "${state_file}")" = "$(printf 'Issue\t42\t0\t0\t0\t-')" ]
    [ ! -f "${stalled_log}" ]
}

@test "invoke_claude alerts on the no-result-object path when a stream fragment's final message says it quit" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "inspect" ] && exit 1
[ "$1" = "pull" ] && exit 0
printf '{"result":"Bash is now denied, so I stopped."}\n[1]\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"
    orchestrator_today() { printf '2026-10-05'; }
    local stalled_log="${TEST_TMP}/stalled.log"
    notify_discord_session_stalled() { printf '%s\n' "$*" >> "${stalled_log}"; }

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Claude did not return a result object"* ]]
    local state_file="${ORCHESTRATOR_STATE_DIR}/${OWNER}/session-denials.2026-10-05"
    [ "$(wc -l < "${state_file}")" -eq 1 ]
    [ "$(cut -f3- "${state_file}")" = "$(printf 'Issue\t42\t0\t1\t1\t-')" ]
    [ "$(wc -l < "${stalled_log}")" -eq 1 ]
    grep -q "^Issue 42 0  Bash is now denied, so I stopped.$" "${stalled_log}"
}

@test "invoke_claude leaves recording a successful session to its caller" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "inspect" ] && exit 1
[ "$1" = "pull" ] && exit 0
printf '{"is_error":false,"result":"done","permission_denials":[{"tool_name":"Bash","tool_input":{"command":"git status"}}]}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"
    orchestrator_today() { printf '2026-10-05'; }
    notify_discord_permission_denials() { return 0; }

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -eq 0 ]
    [ ! -f "${ORCHESTRATOR_STATE_DIR}/${OWNER}/session-denials.2026-10-05" ]
}

@test "record_session_outcome appends a line every time and alerts only when session_outcome_is_stalled says so" {
    orchestrator_today() { printf '2026-10-05'; }
    local stalled_log="${TEST_TMP}/stalled.log"
    notify_discord_session_stalled() { printf '%s\n' "$*" >> "${stalled_log}"; }
    SESSION_DENIAL_COUNT=0
    SESSION_DENIED_COMMANDS=""
    SESSION_TOOL_DENIED_QUIT=0

    record_session_outcome "PullRequest" "7" 0
    [ ! -f "${stalled_log}" ]
    SESSION_DENIAL_COUNT=2
    SESSION_DENIED_COMMANDS="gh,git"
    record_session_outcome "PullRequest" "7" 0
    [ ! -f "${stalled_log}" ]
    record_session_outcome "PullRequest" "7" 1
    [ "$(wc -l < "${stalled_log}")" -eq 1 ]
    SESSION_DENIAL_COUNT=0
    SESSION_DENIED_COMMANDS=""
    SESSION_TOOL_DENIED_QUIT=1
    record_session_outcome "Issue" "8" 0
    [ "$(wc -l < "${stalled_log}")" -eq 2 ]

    local state_file="${ORCHESTRATOR_STATE_DIR}/${OWNER}/session-denials.2026-10-05"
    [ "$(wc -l < "${state_file}")" -eq 4 ]
    [ "$(sed -n 1p "${state_file}" | cut -f3-)" = "$(printf 'PullRequest\t7\t0\t0\t0\t-')" ]
    [ "$(sed -n 2p "${state_file}" | cut -f3-)" = "$(printf 'PullRequest\t7\t2\t0\t0\tgh,git')" ]
    [ "$(sed -n 3p "${state_file}" | cut -f3-)" = "$(printf 'PullRequest\t7\t2\t1\t0\tgh,git')" ]
    [ "$(sed -n 4p "${state_file}" | cut -f3-)" = "$(printf 'Issue\t8\t0\t1\t1\t-')" ]
}

@test "prune_session_denials_files removes files older than the retention period and keeps the rest" {
    SESSION_DENIALS_RETENTION_DAYS=30
    local dir="${ORCHESTRATOR_STATE_DIR}/org"
    mkdir -p "${dir}"
    touch "${dir}/session-denials.2026-09-04" "${dir}/session-denials.2026-09-05" "${dir}/session-denials.2026-10-04" "${dir}/last-digest-sent"

    prune_session_denials_files "org" "2026-10-05"
    [ ! -f "${dir}/session-denials.2026-09-04" ]
    [ -f "${dir}/session-denials.2026-09-05" ]
    [ -f "${dir}/session-denials.2026-10-04" ]
    [ -f "${dir}/last-digest-sent" ]
}

@test "summarise_session_denials_day prints null for a missing file" {
    run summarise_session_denials_day "${TEST_TMP}/does-not-exist"
    [ "${status}" -eq 0 ]
    [ "${output}" = "null" ]
}

@test "summarise_session_denials_day totals sessions, denials, stalled and quits per repository and command" {
    local day_file="${TEST_TMP}/day"
    printf '%s\n' \
        "$(printf '2026-10-05T01:00:00+00:00\torg/a\tPullRequest\t1\t3\t1\t0\tgit,gh')" \
        "$(printf '2026-10-05T02:00:00+00:00\torg/a\tIssue\t2\t0\t0\t0\t-')" \
        "$(printf '2026-10-05T03:00:00+00:00\torg/b\tIssue\t3\t1\t1\t1\tgit')" \
        "not a valid line" > "${day_file}"

    run summarise_session_denials_day "${day_file}"
    [ "${status}" -eq 0 ]
    [ "$(printf '%s' "${output}" | jq -c '[.sessions, .denials, .stalled, .quits]')" = "[3,4,2,1]" ]
    [ "$(printf '%s' "${output}" | jq -c '.repos | map([.repo, .sessions, .denials, .stalled])')" = '[["org/a",2,3,1],["org/b",1,1,1]]' ]
    [ "$(printf '%s' "${output}" | jq -c '.top_commands')" = '[{"name":"git","count":2},{"name":"gh","count":1}]' ]
}

@test "send_daily_digest_if_due sends yesterday's digest once per day, not twice" {
    orchestrator_today() { printf '2026-10-05'; }
    local digest_log="${TEST_TMP}/digest.log"
    notify_discord_daily_digest() { printf '%s %s\n' "$1" "$2" >> "${digest_log}"; }
    mkdir -p "${ORCHESTRATOR_STATE_DIR}/org"
    touch "${ORCHESTRATOR_STATE_DIR}/org/session-denials.2026-10-04"

    send_daily_digest_if_due "org"
    send_daily_digest_if_due "org"
    [ "$(wc -l < "${digest_log}")" -eq 1 ]
    grep -q '^org 2026-10-04$' "${digest_log}"
    [ "$(cat "${ORCHESTRATOR_STATE_DIR}/org/last-digest-sent")" = "2026-10-05" ]

    orchestrator_today() { printf '2026-10-06'; }
    send_daily_digest_if_due "org"
    [ "$(wc -l < "${digest_log}")" -eq 2 ]
    grep -q '^org 2026-10-05$' "${digest_log}"
}

@test "send_daily_digest_if_due does not advance the marker when the digest fails to send, and still prunes" {
    orchestrator_today() { printf '2026-10-05'; }
    notify_discord_daily_digest() { return 1; }
    SESSION_DENIALS_RETENTION_DAYS=30
    mkdir -p "${ORCHESTRATOR_STATE_DIR}/org"
    touch "${ORCHESTRATOR_STATE_DIR}/org/session-denials.2026-10-04" "${ORCHESTRATOR_STATE_DIR}/org/session-denials.2026-01-01"

    run send_daily_digest_if_due "org"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Daily digest for org: sending the digest for 2026-10-04 failed"* ]]
    [ ! -f "${ORCHESTRATOR_STATE_DIR}/org/last-digest-sent" ]
    [ ! -f "${ORCHESTRATOR_STATE_DIR}/org/session-denials.2026-01-01" ]
    [ -f "${ORCHESTRATOR_STATE_DIR}/org/session-denials.2026-10-04" ]
}

@test "send_daily_digest_if_due catches up one digest per missed day, oldest first, after the host was down" {
    orchestrator_today() { printf '2026-10-05'; }
    local digest_log="${TEST_TMP}/digest.log"
    notify_discord_daily_digest() { printf '%s %s %s\n' "$1" "$2" "$(printf '%s' "$4" | jq -c '.sessions // null')" >> "${digest_log}"; }
    local dir="${ORCHESTRATOR_STATE_DIR}/org"
    mkdir -p "${dir}"
    printf '2026-10-02\n' > "${dir}/last-digest-sent"
    printf '2026-10-01T01:00:00+00:00\torg/a\tIssue\t1\t0\t0\t0\t-\n' > "${dir}/session-denials.2026-10-01"
    printf '2026-10-02T01:00:00+00:00\torg/a\tIssue\t2\t0\t0\t0\t-\n%s\n' "$(printf '2026-10-02T02:00:00+00:00\torg/a\tIssue\t3\t0\t0\t0\t-')" > "${dir}/session-denials.2026-10-02"

    send_daily_digest_if_due "org"
    # 10-02 against 10-01, then 10-03 (no file) against 10-02, then nothing for 10-04: neither
    # 10-04 nor 10-03 has a file.
    [ "$(cat "${digest_log}")" = "$(printf 'org 2026-10-02 1\norg 2026-10-03 2')" ]
    [ "$(cat "${dir}/last-digest-sent")" = "2026-10-05" ]
    [ ! -f "${dir}/last-digest-sent.tmp" ]
}

@test "send_daily_digest_if_due stops at a failed day during catch-up, keeps the marker there, and resumes from it" {
    orchestrator_today() { printf '2026-10-05'; }
    local digest_log="${TEST_TMP}/digest.log"
    notify_discord_daily_digest() {
        [ "$2" = "2026-10-03" ] && return 1
        printf '%s %s\n' "$1" "$2" >> "${digest_log}"
    }
    local dir="${ORCHESTRATOR_STATE_DIR}/org"
    mkdir -p "${dir}"
    printf '2026-10-02\n' > "${dir}/last-digest-sent"
    touch "${dir}/session-denials.2026-10-02" "${dir}/session-denials.2026-10-03" "${dir}/session-denials.2026-10-04"

    run send_daily_digest_if_due "org"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Daily digest for org: sending the digest for 2026-10-03 failed"* ]]
    [ "$(cat "${digest_log}")" = "org 2026-10-02" ]
    [ "$(cat "${dir}/last-digest-sent")" = "2026-10-03" ]

    notify_discord_daily_digest() { printf '%s %s\n' "$1" "$2" >> "${digest_log}"; }
    send_daily_digest_if_due "org"
    [ "$(cat "${digest_log}")" = "$(printf 'org 2026-10-02\norg 2026-10-03\norg 2026-10-04')" ]
    [ "$(cat "${dir}/last-digest-sent")" = "2026-10-05" ]
}

@test "send_daily_digest_if_due stops at a day whose day before cannot be worked out, keeps the marker there, and warns" {
    orchestrator_today() { printf '2026-10-05'; }
    local digest_log="${TEST_TMP}/digest.log"
    notify_discord_daily_digest() { printf '%s %s\n' "$1" "$2" >> "${digest_log}"; }
    date_days_before() {
        [ "$1" = "2026-10-03" ] && [ "$2" = "1" ] && return 1
        date -d "$1 -$2 day" +%Y-%m-%d
    }
    local dir="${ORCHESTRATOR_STATE_DIR}/org"
    mkdir -p "${dir}"
    printf '2026-10-02\n' > "${dir}/last-digest-sent"
    touch "${dir}/session-denials.2026-10-02" "${dir}/session-denials.2026-10-03" "${dir}/session-denials.2026-10-04"

    run send_daily_digest_if_due "org"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Daily digest for org: could not work out the day before 2026-10-03, will retry on the next tick"* ]]
    [ "$(cat "${digest_log}")" = "org 2026-10-02" ]
    [ "$(cat "${dir}/last-digest-sent")" = "2026-10-03" ]
}

@test "send_daily_digest_if_due stops at a day whose day after cannot be worked out, keeps the marker there, and warns" {
    orchestrator_today() { printf '2026-10-05'; }
    local digest_log="${TEST_TMP}/digest.log"
    notify_discord_daily_digest() { printf '%s %s\n' "$1" "$2" >> "${digest_log}"; }
    date_days_after() {
        [ "$1" = "2026-10-03" ] && return 1
        date -d "$1 +$2 day" +%Y-%m-%d
    }
    local dir="${ORCHESTRATOR_STATE_DIR}/org"
    mkdir -p "${dir}"
    printf '2026-10-02\n' > "${dir}/last-digest-sent"
    touch "${dir}/session-denials.2026-10-02" "${dir}/session-denials.2026-10-03" "${dir}/session-denials.2026-10-04"

    run send_daily_digest_if_due "org"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Daily digest for org: could not work out the day after 2026-10-03, will retry on the next tick"* ]]
    [ "$(cat "${digest_log}")" = "org 2026-10-02" ]
    [ "$(cat "${dir}/last-digest-sent")" = "2026-10-03" ]
}

@test "send_daily_digest_if_due warns when the marker cannot be written, leaves it unmoved, and carries on with the catch-up" {
    orchestrator_today() { printf '2026-10-05'; }
    local digest_log="${TEST_TMP}/digest.log"
    notify_discord_daily_digest() { printf '%s %s\n' "$1" "$2" >> "${digest_log}"; }
    local dir="${ORCHESTRATOR_STATE_DIR}/org"
    mkdir -p "${dir}"
    printf '2026-10-03\n' > "${dir}/last-digest-sent"
    touch "${dir}/session-denials.2026-10-03" "${dir}/session-denials.2026-10-04"
    # A directory in the way of the temporary file makes the marker write fail.
    mkdir "${dir}/last-digest-sent.tmp"

    run send_daily_digest_if_due "org"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Failed to write the daily digest marker ${dir}/last-digest-sent: the digest may be sent again"* ]]
    [ "$(cat "${digest_log}")" = "$(printf 'org 2026-10-03\norg 2026-10-04')" ]
    [ "$(cat "${dir}/last-digest-sent")" = "2026-10-03" ]
}

@test "send_daily_digest_if_due catches up no further back than SESSION_DENIALS_RETENTION_DAYS" {
    orchestrator_today() { printf '2026-10-05'; }
    SESSION_DENIALS_RETENTION_DAYS=3
    local days_log="${TEST_TMP}/days.log"
    local digest_log="${TEST_TMP}/digest.log"
    send_daily_digest_for_day() { printf '%s\n' "$3" >> "${days_log}"; }
    notify_discord_daily_digest() { printf '%s %s\n' "$1" "$2" >> "${digest_log}"; }
    local dir="${ORCHESTRATOR_STATE_DIR}/org"
    mkdir -p "${dir}"
    printf '2026-08-01\n' > "${dir}/last-digest-sent"

    run send_daily_digest_if_due "org"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"catching up from 2026-10-02 only"* ]]
    [ "$(cat "${days_log}")" = "$(printf '2026-10-02\n2026-10-03\n2026-10-04')" ]
}

@test "send_daily_digest_if_due with no marker sends only yesterday's digest, not older days" {
    orchestrator_today() { printf '2026-10-05'; }
    local digest_log="${TEST_TMP}/digest.log"
    notify_discord_daily_digest() { printf '%s %s\n' "$1" "$2" >> "${digest_log}"; }
    local dir="${ORCHESTRATOR_STATE_DIR}/org"
    mkdir -p "${dir}"
    touch "${dir}/session-denials.2026-10-01" "${dir}/session-denials.2026-10-02" "${dir}/session-denials.2026-10-04"

    send_daily_digest_if_due "org"
    [ "$(cat "${digest_log}")" = "org 2026-10-04" ]
    [ "$(cat "${dir}/last-digest-sent")" = "2026-10-05" ]
}

@test "send_daily_digest_if_due sends nothing when neither yesterday nor the day before has a record, but still advances the marker" {
    orchestrator_today() { printf '2026-10-05'; }
    local digest_log="${TEST_TMP}/digest.log"
    notify_discord_daily_digest() { printf '%s %s\n' "$1" "$2" >> "${digest_log}"; }
    mkdir -p "${ORCHESTRATOR_STATE_DIR}/org"
    touch "${ORCHESTRATOR_STATE_DIR}/org/session-denials.2026-10-01"

    send_daily_digest_if_due "org"
    [ ! -f "${digest_log}" ]
    [ "$(cat "${ORCHESTRATOR_STATE_DIR}/org/last-digest-sent")" = "2026-10-05" ]
}

@test "send_daily_digest_if_due skips the digest while another run holds the owner's digest lock" {
    orchestrator_today() { printf '2026-10-05'; }
    local digest_log="${TEST_TMP}/digest.log"
    notify_discord_daily_digest() { printf '%s %s\n' "$1" "$2" >> "${digest_log}"; }
    mkdir -p "${ORCHESTRATOR_STATE_DIR}/org"
    touch "${ORCHESTRATOR_STATE_DIR}/org/session-denials.2026-10-04"
    # A second open of the lock file is a separate open file description, so this flock
    # conflicts with the function's own even within one process.
    exec 8>"${ORCHESTRATOR_STATE_DIR}/org/.digest.lock"
    flock --exclusive 8

    send_daily_digest_if_due "org"
    [ ! -f "${digest_log}" ]
    [ ! -f "${ORCHESTRATOR_STATE_DIR}/org/last-digest-sent" ]

    exec 8>&-
    send_daily_digest_if_due "org"
    [ "$(cat "${digest_log}")" = "org 2026-10-04" ]
}

@test "send_daily_digest_if_due re-reads the marker once it holds the lock, so a digest just sent by another run is not sent again" {
    orchestrator_today() { printf '2026-10-05'; }
    local digest_log="${TEST_TMP}/digest.log"
    notify_discord_daily_digest() { printf '%s %s\n' "$1" "$2" >> "${digest_log}"; }
    mkdir -p "${ORCHESTRATOR_STATE_DIR}/org"
    touch "${ORCHESTRATOR_STATE_DIR}/org/session-denials.2026-10-04"
    # Stands in for a run that sent today's digest while this one waited for the lock.
    flock() { printf '2026-10-05\n' > "${ORCHESTRATOR_STATE_DIR}/org/last-digest-sent"; return 0; }

    send_daily_digest_if_due "org"
    [ ! -f "${digest_log}" ]
}

@test "send_daily_digest_if_due warns with the owner and the failing step instead of failing silently" {
    orchestrator_today() { return 1; }

    run send_daily_digest_if_due "org"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Daily digest for org: could not work out today's date"* ]]
}

@test "send_daily_digest_if_due reports no record for the day before when that file is missing" {
    orchestrator_today() { printf '2026-10-05'; }
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    mkdir -p "${ORCHESTRATOR_STATE_DIR}/org"
    printf '2026-10-04T01:00:00+00:00\torg/a\tPullRequest\t1\t3\t1\t0\tgit\n' > "${ORCHESTRATOR_STATE_DIR}/org/session-denials.2026-10-04"

    send_daily_digest_if_due "org"
    grep -q "Daily session digest: org, 2026-10-04" "${args_log}"
    grep -q "3 (no record for the day before)" "${args_log}"
    grep -q "org/a: 3 denial(s), 1 stalled, 1 session(s)" "${args_log}"
    grep -q "git (1)" "${args_log}"
}

@test "send_daily_digest_if_due reports the change against the day before" {
    orchestrator_today() { printf '2026-10-05'; }
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    mkdir -p "${ORCHESTRATOR_STATE_DIR}/org"
    printf '2026-10-04T01:00:00+00:00\torg/a\tPullRequest\t1\t3\t1\t0\tgit\n' > "${ORCHESTRATOR_STATE_DIR}/org/session-denials.2026-10-04"
    printf '2026-10-03T01:00:00+00:00\torg/a\tPullRequest\t1\t1\t1\t0\tgit\n' > "${ORCHESTRATOR_STATE_DIR}/org/session-denials.2026-10-03"

    send_daily_digest_if_due "org"
    grep -q "3 (+2 vs the day before)" "${args_log}"
    grep -q "1 (no change vs the day before)" "${args_log}"
}

# Replaces curl with a stub that writes the JSON body it was given with -d to the named file.
stub_curl_capturing_payload() {
    local payload_file="$1"
    cat > "${STUB_BIN}/curl" << STUBEOF
#!/usr/bin/env bash
while [ "\$#" -gt 0 ]; do
    if [ "\$1" = "-d" ]; then printf '%s' "\$2" > '${payload_file}'; fi
    shift
done
STUBEOF
    chmod +x "${STUB_BIN}/curl"
    hash -r
}

@test "send_daily_digest_if_due shows the change in sessions against the day before" {
    orchestrator_today() { printf '2026-10-05'; }
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    local payload_file="${TEST_TMP}/payload.json"
    stub_curl_capturing_payload "${payload_file}"
    mkdir -p "${ORCHESTRATOR_STATE_DIR}/org"
    printf '2026-10-04T01:00:00+00:00\torg/a\tPullRequest\t1\t3\t1\t0\tgit\n2026-10-04T02:00:00+00:00\torg/a\tIssue\t2\t0\t0\t0\t-\n' > "${ORCHESTRATOR_STATE_DIR}/org/session-denials.2026-10-04"
    printf '2026-10-03T01:00:00+00:00\torg/a\tPullRequest\t1\t1\t1\t0\tgit\n' > "${ORCHESTRATOR_STATE_DIR}/org/session-denials.2026-10-03"

    send_daily_digest_if_due "org"
    [ "$(jq -r '.embeds[0].fields[] | select(.name == "Sessions") | .value' "${payload_file}")" = "2 (+1 vs the day before)" ]
}

@test "notify_discord_daily_digest judges each delta by its own previous value, not by whether the day before has a record" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    local payload_file="${TEST_TMP}/payload.json"
    stub_curl_capturing_payload "${payload_file}"
    # A day-before summary that exists but lacks the denials total (as an older summary shape
    # might): that one field has no previous value, while the others compare normally.
    local summary='{"sessions":4,"denials":3,"stalled":1,"quits":0,"repos":[],"top_commands":[]}'
    local previous='{"sessions":2,"stalled":1,"quits":0,"repos":[],"top_commands":[]}'

    run notify_discord_daily_digest "org" "2026-10-04" "${summary}" "${previous}"
    [ "${status}" -eq 0 ]
    [ "$(jq -r '.embeds[0].fields[] | select(.name == "Sessions") | .value' "${payload_file}")" = "4 (+2 vs the day before)" ]
    [ "$(jq -r '.embeds[0].fields[] | select(.name == "Denials") | .value' "${payload_file}")" = "3 (no record for the day before)" ]
    [ "$(jq -r '.embeds[0].fields[] | select(.name == "Stalled sessions") | .value' "${payload_file}")" = "1 (no change vs the day before)" ]
}

@test "send_daily_digest_if_due prunes old per-day files on rollover" {
    orchestrator_today() { printf '2026-10-05'; }
    notify_discord_daily_digest() { return 0; }
    SESSION_DENIALS_RETENTION_DAYS=30
    mkdir -p "${ORCHESTRATOR_STATE_DIR}/org"
    touch "${ORCHESTRATOR_STATE_DIR}/org/session-denials.2026-01-01"

    send_daily_digest_if_due "org"
    [ ! -f "${ORCHESTRATOR_STATE_DIR}/org/session-denials.2026-01-01" ]
}

@test "notify_discord_daily_digest is silent and succeeds when no webhook is configured" {
    DISCORD_WEBHOOK_URL=""
    DISCORD_WEBHOOK_URL_PERMISSIONS=""
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"

    run notify_discord_daily_digest "org" "2026-10-04" "null" "null"
    [ "${status}" -eq 0 ]
    [ ! -f "${args_log}" ]
}

@test "notify_discord_daily_digest posts to DISCORD_WEBHOOK_URL_PERMISSIONS when set" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/general"
    DISCORD_WEBHOOK_URL_PERMISSIONS="https://discord.example.com/permissions"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"

    run notify_discord_daily_digest "org" "2026-10-04" "null" "null"
    [ "${status}" -eq 0 ]
    grep -q "https://discord.example.com/permissions" "${args_log}"
    grep -q "No sessions were recorded for this day." "${args_log}"
    [ "$(grep -c "https://discord.example.com/general" "${args_log}")" -eq 0 ]
}

@test "notify_discord_daily_digest returns 1 when the post fails" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    make_stub curl 'exit 22'

    run notify_discord_daily_digest "org" "2026-10-04" "null" "null"
    [ "${status}" -eq 1 ]
}

@test "run_daily_digest_rollover with no owner covers every owner that has recorded a session" {
    local digest_log="${TEST_TMP}/digest.log"
    send_daily_digest_if_due() { printf '%s\n' "$1" >> "${digest_log}"; }
    mkdir -p "${ORCHESTRATOR_STATE_DIR}/org-a" "${ORCHESTRATOR_STATE_DIR}/org-b" "${ORCHESTRATOR_STATE_DIR}/locks"
    touch "${ORCHESTRATOR_STATE_DIR}/org-a/session-denials.2026-10-04"

    run_daily_digest_rollover ""
    [ "$(cat "${digest_log}")" = "org-a" ]

    run_daily_digest_rollover "org-b"
    [ "$(sed -n 2p "${digest_log}")" = "org-b" ]
}

@test "notify_discord_session_stalled is silent when no webhook is configured" {
    DISCORD_WEBHOOK_URL=""
    DISCORD_WEBHOOK_URL_PERMISSIONS=""
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"

    run notify_discord_session_stalled "Issue" "42" "1" "git" "Bash is now denied"
    [ "${status}" -eq 0 ]
    [ ! -f "${args_log}" ]
}

@test "notify_discord_session_stalled posts the repo, item link, count, command names and the first 240 characters of the final message" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    DISCORD_WEBHOOK_URL_PERMISSIONS="https://discord.example.com/permissions"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    local final_message
    final_message="$(printf 'word %.0s' $(seq 1 48))TAILMARKER"

    run notify_discord_session_stalled "PullRequest" "7" "3" "gh,git" "${final_message}"
    [ "${status}" -eq 0 ]
    grep -q "https://discord.example.com/permissions" "${args_log}"
    grep -q "Session stalled: org/repo" "${args_log}"
    grep -q "https://github.com/org/repo/pull/7" "${args_log}"
    grep -Eq '"value": ?"3"' "${args_log}"
    grep -q "gh, git" "${args_log}"
    [ "$(grep -c "TAILMARKER" "${args_log}")" -eq 0 ]
}

@test "notify_discord_session_stalled masks tokens and path-like strings in the final message before cutting it" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local payload_file="${TEST_TMP}/payload.json"
    stub_curl_capturing_payload "${payload_file}"
    local final_message="Bash is now denied. Token ghp_AbC123secretXYZ, github_pat_11ABCDEF_secret, sha 0123456789abcdef0123456789abcdef01234567 and key QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVphYmNkZWZnaGlqa2xtbm9w; file /home/someone/private-repo/notes.txt and https://example.com/private/path."

    run notify_discord_session_stalled "Issue" "42" "1" "git" "${final_message}"
    [ "${status}" -eq 0 ]
    local excerpt
    excerpt=$(jq -r '.embeds[0].fields[] | select(.name == "Final message") | .value' "${payload_file}")
    [[ "${excerpt}" == "Bash is now denied. Token [REDACTED], [token], sha [token] and key [token]; file [path] and [path]"* ]]
    [[ "${excerpt}" != *ghp_* ]]
    [[ "${excerpt}" != *github_pat_* ]]
    [[ "${excerpt}" != *0123456789abcdef* ]]
    [[ "${excerpt}" != *QUJDREVG* ]]
    [[ "${excerpt}" != */* ]]
}

@test "notify_discord_session_stalled masks a path that straddles the 240-character cut" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local payload_file="${TEST_TMP}/payload.json"
    stub_curl_capturing_payload "${payload_file}"
    local final_message
    final_message="$(printf 'word %.0s' $(seq 1 46))/home/someone/private-repo/very/long/path/notes.txt"

    run notify_discord_session_stalled "Issue" "42" "1" "git" "${final_message}"
    [ "${status}" -eq 0 ]
    local excerpt
    excerpt=$(jq -r '.embeds[0].fields[] | select(.name == "Final message") | .value' "${payload_file}")
    [[ "${excerpt}" == *"[path]" ]]
    [[ "${excerpt}" != *someone* ]]
}

# Each lib/secret-patterns form must be named by its own marker rather than collapsed into a
# generic "[path]" or "[token]", and the words either side of it must survive.
assert_session_stalled_form_redacted() {
    local secret="$1"
    local marker="$2"
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local payload_file="${TEST_TMP}/payload.json"
    stub_curl_capturing_payload "${payload_file}"

    run notify_discord_session_stalled "Issue" "42" "1" "git" "before ${secret} after"
    [ "${status}" -eq 0 ]
    local excerpt
    excerpt=$(jq -r '.embeds[0].fields[] | select(.name == "Final message") | .value' "${payload_file}")
    [ "${excerpt}" = "before ${marker} after" ]
}

@test "notify_discord_session_stalled names a discord.com webhook in the final message" {
    assert_session_stalled_form_redacted 'https://discord.com/api/webhooks/123456/abcDEF_-x' '[REDACTED-DISCORD-WEBHOOK]'
}

@test "notify_discord_session_stalled names a discordapp.com webhook in the final message" {
    assert_session_stalled_form_redacted 'https://discordapp.com/api/webhooks/123456/abcDEF_-x' '[REDACTED-DISCORD-WEBHOOK]'
}

@test "notify_discord_session_stalled names an OpenAI project key in the final message" {
    assert_session_stalled_form_redacted 'sk-proj-ABCDEFGHIJKLMNOPQRST' '[REDACTED-OPENAI-KEY]'
}

@test "notify_discord_session_stalled names a Bearer token in the final message" {
    assert_session_stalled_form_redacted 'Bearer abcdefghij0123456789klmn' 'Bearer [REDACTED]'
}

@test "notify_discord_session_stalled names an AWS access key ID in the final message" {
    assert_session_stalled_form_redacted 'AKIAIOSFODNN7EXAMPLE' '[REDACTED-AWS-KEY-ID]' # gitleaks:allow
}

@test "notify_discord_session_stalled names a GitHub token in the final message" {
    assert_session_stalled_form_redacted 'ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789' '[REDACTED-GH-TOKEN]'
}

@test "notify_discord_session_stalled deduplicates per item, apart from the per-repo permission-denials alert" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf 'post\n' >> '${args_log}'"

    notify_discord_permission_denials "PullRequest" "7" "- Bash: git status" "1"
    notify_discord_session_stalled "PullRequest" "7" "1" "git" "stopped"
    notify_discord_session_stalled "PullRequest" "7" "1" "git" "stopped"
    notify_discord_session_stalled "PullRequest" "8" "1" "git" "stopped"
    [ "$(grep -c post "${args_log}")" -eq 3 ]
}
