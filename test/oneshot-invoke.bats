#!/usr/bin/env bats
# shellcheck disable=SC2329  # functions in @test bodies are invoked indirectly via 'run'
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are used inside run() subshells where shellcheck cannot trace them

bats_require_minimum_version 1.5.0

load test_helper
load oneshot_helper

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

    invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md" 2>/dev/null
    grep -qx -- '--model' "${args_log}"
    grep -qx 'opusplan' "${args_log}"
}

@test "invoke_claude passes the prompt as a trailing positional argument to claude, not via stdin (#1062)" {
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

    invoke_claude "unique-prompt-marker-xyz" "Issue" "42" "# mock CLAUDE.md" 2>/dev/null
    # The prompt text must appear as its own argv element (the CLAUDE_PROMPT
    # trailing entry in PODMAN_CLAUDE_ARGS), not be piped in via stdin.
    grep -qx -- 'unique-prompt-marker-xyz' "${args_log}"
}

@test "invoke_claude terminates option parsing with -- immediately before the prompt so --add-dir cannot swallow it (#1062 recurrence)" {
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

    invoke_claude "unique-prompt-marker-xyz" "Issue" "42" "# mock CLAUDE.md" 2>/dev/null
    # --add-dir takes <directories...> (variadic) — without a "--" separator right
    # before the prompt, the CLI parser swallows the prompt as an extra --add-dir
    # value instead of the positional [prompt] argument. Assert "--" is the line
    # immediately preceding the prompt marker in the logged argv.
    local prompt_line
    prompt_line=$(grep -nx -- 'unique-prompt-marker-xyz' "${args_log}" | cut -d: -f1)
    [ -n "${prompt_line}" ]
    local separator_line=$((prompt_line - 1))
    [ "$(sed -n "${separator_line}p" "${args_log}")" = "--" ]
}

@test "invoke_claude registers CONTAINER_REPO_PATH, CONTAINER_RULES_PATH, and CONTAINER_SCRATCH_PATH as --add-dir args in that order (#1351, #1377)" {
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

    invoke_claude "unique-prompt-marker-xyz" "Issue" "42" "# mock CLAUDE.md" 2>/dev/null
    local add_dir_line
    add_dir_line=$(grep -nx -- '--add-dir' "${args_log}" | cut -d: -f1)
    [ -n "${add_dir_line}" ]
    [ "$(sed -n "$((add_dir_line + 1))p" "${args_log}")" = "${CONTAINER_REPO_PATH}" ]
    [ "$(sed -n "$((add_dir_line + 2))p" "${args_log}")" = "${CONTAINER_RULES_PATH}" ]
    [ "$(sed -n "$((add_dir_line + 3))p" "${args_log}")" = "${CONTAINER_SCRATCH_PATH}" ]
}

@test "invoke_claude bind-mounts a fresh host scratch dir at CONTAINER_SCRATCH_PATH read-write (#1351)" {
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

    invoke_claude "unique-prompt-marker-xyz" "Issue" "42" "# mock CLAUDE.md" 2>/dev/null
    grep -qE -- ":${CONTAINER_SCRATCH_PATH}:rw\$" "${args_log}"
}

@test "invoke_claude removes the host scratch dir on successful completion, leaving no orphan (#1351)" {
    local args_log="${TEST_TMP}/podman_args"
    local scratch_dir_log="${TEST_TMP}/scratch_dir_seen"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    invoke_claude "unique-prompt-marker-xyz" "Issue" "42" "# mock CLAUDE.md" 2>/dev/null
    # The --volume argv element is HOST:CONTAINER:rw as a single token; strip the
    # container-side suffix to recover the host-side scratch dir invoke_claude created.
    local scratch_dir
    scratch_dir=$(grep -E -- ":${CONTAINER_SCRATCH_PATH}:rw\$" "${args_log}" | sed -E "s#:${CONTAINER_SCRATCH_PATH}:rw\$##")
    # invoke_claude resets CLAUDE_SCRATCH_TMPDIR to "" on its own cleanup path once removed —
    # the directory it captured in argv above must no longer exist on disk.
    [ -n "${scratch_dir}" ]
    [ ! -d "${scratch_dir}" ]
    [ -z "${CLAUDE_SCRATCH_TMPDIR}" ]
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

    invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md" 2>/dev/null
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
    run invoke_claude "${long_prompt}" "Issue" "1"
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
    run invoke_claude "${long_prompt}" "Issue" "42"
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

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"API Error"* ]]
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

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -ne 0 ]
    grep -q "https://discord.example.com/hook" "${args_log}"
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
    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
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

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -ne 0 ]
    grep -q "https://discord.example.com/hook" "${args_log}"
}

# --- cleanup_claude_invocation_tmpfiles (#1133 review, Copilot) ----------------

@test "cleanup_claude_invocation_tmpfiles is safe to call twice in a row" {
    # Mirrors the real EXIT-trap backstop calling it again after the explicit call on every
    # normal path already cleared these globals to empty — must not error the second time.
    local tmpfile gpgdir
    tmpfile=$(mktemp)
    gpgdir=$(mktemp -d)
    CLAUDE_MD_TMPFILE="${tmpfile}"
    GPG_PUBKEY_TMPDIR="${gpgdir}"

    cleanup_claude_invocation_tmpfiles
    [ -z "${CLAUDE_MD_TMPFILE}" ]
    [ -z "${GPG_PUBKEY_TMPDIR}" ]
    [ ! -e "${tmpfile}" ]
    [ ! -e "${gpgdir}" ]

    run cleanup_claude_invocation_tmpfiles
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "invoke_claude does not leak CLAUDE_MD_TMPFILE when the state-dir mkdir loop fails (#1103)" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    export XDG_RUNTIME_DIR="${TEST_TMP}/runtime"
    mkdir -p "${XDG_RUNTIME_DIR}"
    local claude_md_path="${XDG_RUNTIME_DIR}/fixed.claude-md"
    cat > "${STUB_BIN}/mktemp" << STUBEOF
#!/usr/bin/env bash
touch "${claude_md_path}"
printf '%s\n' "${claude_md_path}"
STUBEOF
    chmod +x "${STUB_BIN}/mktemp"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "inspect" ] && exit 1
[ "$1" = "pull" ] && exit 0
STUBEOF
    chmod +x "${STUB_BIN}/podman"
    # A FILE (not a directory) at the first state-dir path forces "mkdir -p" to fail there,
    # between CLAUDE_MD_TMPFILE being populated and the container ever starting.
    mkdir -p "${CLAUDE_STATE_DIR}"
    touch "${CLAUDE_STATE_DIR}/sessions"

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Failed to create persistent Claude state directory"* ]]
    [ ! -e "${claude_md_path}" ]
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
    invoke_claude "test prompt" "Issue" "42" "# per-item instructions" 2>/dev/null
    [ -z "${CLAUDE_MD_TMPFILE}" ]
}

@test "invoke_claude marks the background-stall marker when the session result matches the pattern (#1326/#1335)" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/jq" << 'JQEOF'
#!/usr/bin/env bash
case "$2" in
    '.is_error // false')    printf 'false\n' ;;
    '.result // ""')         printf "I'll pause here and wait for the Monitor notification when it completes.\n" ;;
    '.session_id // empty')  printf '12345678-1234-1234-1234-123456789abc\n' ;;
esac
JQEOF
    chmod +x "${STUB_BIN}/jq"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "pull" ] && exit 0
[ "$1" = "inspect" ] && exit 1
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"..."}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    invoke_claude "test prompt" "Issue" "215" "# per-item instructions" 2>/dev/null
    [ -f "${SESSION_BASE_DIR}/Issue_215.background-stall" ]
}

@test "invoke_claude clears the background-stall marker when the session result does not match the pattern" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}" "${SESSION_BASE_DIR}"
    touch "${SESSION_BASE_DIR}/Issue_215.background-stall"
    cat > "${STUB_BIN}/jq" << 'JQEOF'
#!/usr/bin/env bash
case "$2" in
    '.is_error // false')    printf 'false\n' ;;
    '.result // ""')         printf 'Opened draft PR #284 and moved the board to Development.\n' ;;
    '.session_id // empty')  printf '12345678-1234-1234-1234-123456789abc\n' ;;
esac
JQEOF
    chmod +x "${STUB_BIN}/jq"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "pull" ] && exit 0
[ "$1" = "inspect" ] && exit 1
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"..."}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    invoke_claude "test prompt" "Issue" "215" "# per-item instructions" 2>/dev/null
    [ ! -f "${SESSION_BASE_DIR}/Issue_215.background-stall" ]
}

@test "invoke_claude creates CLAUDE_MD_TMPFILE as a regular file (not a directory) from XDG_RUNTIME_DIR when set" {
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
    invoke_claude "test prompt" "Issue" "42" "# per-item instructions" 2>/dev/null
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

    invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md" 2>/dev/null
    # Secret was created with the container-scoped name (orchestrator-<owner>)
    grep -q "create" "${secret_log}"
    grep -qx "claude-oauth-orchestrator-credfeto" "${secret_log}"
    # Token is NOT passed via --env
    run grep -q 'CLAUDE_CODE_OAUTH_TOKEN=' "${args_log}"
    [ "${status}" -ne 0 ]
    # --secret flag IS present in the podman run args
    grep -qx 'claude-oauth-orchestrator-credfeto,type=env,target=CLAUDE_CODE_OAUTH_TOKEN' "${args_log}"
    # Secrets left under the pre-rename names by a crashed earlier run are swept too
    local legacy_rm
    legacy_rm=$(printf '%s\n' secret rm claude-oauth-credfeto gh-enterprise-token)
    [ "$(grep -A3 -x 'secret' "${secret_log}" | grep -B1 -A2 -x 'rm' | head -4)" = "${legacy_rm}" ]
}

@test "invoke_claude notifies Discord before dying when creating the Claude OAuth Podman secret fails (#1103)" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator/tokens"
    printf 'my-claude-token\n' > "${XDG_CONFIG_HOME}/orchestrator/tokens/credfeto"
    chmod 600 "${XDG_CONFIG_HOME}/orchestrator/tokens/credfeto"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "secret" ] && [ "$2" = "create" ] && exit 1
[ "$1" = "secret" ] && exit 0
[ "$1" = "pull" ] && exit 0
[ "$1" = "inspect" ] && exit 1
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    local notify_log="${TEST_TMP}/notify.log"
    notify_discord_claude_error() { printf '%s\n' "$*" >> "${notify_log}"; }

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Failed to create Podman secret for Claude OAuth token"* ]]
    grep -q "Failed to create Podman secret for Claude OAuth token" "${notify_log}"
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

    invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md" 2>/dev/null
    # Secret was created with the container-scoped enterprise token secret name
    grep -q "create" "${secret_log}"
    grep -qx "gh-enterprise-token-orchestrator-credfeto" "${secret_log}"
    # Token is NOT passed via --env
    run grep -q 'GH_ENTERPRISE_TOKEN=my-gh-token' "${args_log}"
    [ "${status}" -ne 0 ]
    # --secret flag IS present in the podman run args
    grep -qx 'gh-enterprise-token-orchestrator-credfeto,type=env,target=GH_ENTERPRISE_TOKEN' "${args_log}"
}

@test "invoke_claude passes the gh token as GH_TOKEN when GH_HOST is github.com (unproxied .env)" {
    local args_log="${TEST_TMP}/podman_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    # shellcheck disable=SC2030
    GH_ENTERPRISE_TOKEN="my-gh-token"
    # Verbatim from a shell or .env; gh treats it as github.com and so must we.
    export GH_HOST="GitHub.com"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "secret" ] && exit 0
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md" 2>/dev/null
    grep -qx 'gh-enterprise-token-orchestrator-credfeto,type=env,target=GH_TOKEN' "${args_log}"
    grep -qx 'GH_HOST=github.com' "${args_log}"
    [ "$(grep -c 'target=GH_ENTERPRISE_TOKEN' "${args_log}")" -eq 0 ]
}

@test "invoke_claude notifies Discord before dying when creating the GH_ENTERPRISE_TOKEN Podman secret fails (#1103)" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    # shellcheck disable=SC2030
    GH_ENTERPRISE_TOKEN="my-gh-token"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "secret" ] && [ "$2" = "create" ] && exit 1
[ "$1" = "secret" ] && exit 0
[ "$1" = "pull" ] && exit 0
[ "$1" = "inspect" ] && exit 1
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    local notify_log="${TEST_TMP}/notify.log"
    notify_discord_claude_error() { printf '%s\n' "$*" >> "${notify_log}"; }

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Failed to create Podman secret for GH_ENTERPRISE_TOKEN"* ]]
    grep -q "Failed to create Podman secret for GH_ENTERPRISE_TOKEN" "${notify_log}"
}

@test "invoke_claude never passes --resume (every run is a fresh session)" {
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
    run grep -qx -- '--resume' "${args_log}"
    [ "${status}" -ne 0 ]
}

@test "invoke_claude dies if container already exists and is running" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "inspect" ] && [ "$2" = "--format" ] && { printf 'true\n'; exit 0; }
[ "$1" = "inspect" ] && exit 0
[ "$1" = "pull" ] && exit 0
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"already exists and is running"* ]]
}

@test "invoke_claude notifies Discord before dying when container already exists and is running (#1103)" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "inspect" ] && [ "$2" = "--format" ] && { printf 'true\n'; exit 0; }
[ "$1" = "inspect" ] && exit 0
[ "$1" = "pull" ] && exit 0
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    local notify_log="${TEST_TMP}/notify.log"
    notify_discord_claude_error() { printf '%s\n' "$*" >> "${notify_log}"; }

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -ne 0 ]
    grep -q "already exists and is running" "${notify_log}"
}

@test "invoke_claude notifies Discord before dying when a leftover container cannot be removed (#1103)" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "inspect" ] && [ "$2" = "--format" ] && { printf 'false\n'; exit 0; }
[ "$1" = "inspect" ] && exit 0
[ "$1" = "rm" ] && exit 1
[ "$1" = "pull" ] && exit 0
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    local notify_log="${TEST_TMP}/notify.log"
    notify_discord_claude_error() { printf '%s\n' "$*" >> "${notify_log}"; }

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Failed to remove leftover container"* ]]
    grep -q "Failed to remove leftover container" "${notify_log}"
}

@test "invoke_claude removes a leftover non-running container and proceeds (#1090)" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    local args_log="${TEST_TMP}/podman_args"
    # shellcheck disable=SC2016
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
printf "%s\n" "\$*" >> "${args_log}"
[ "\$1" = "inspect" ] && [ "\$2" = "--format" ] && { printf 'false\n'; exit 0; }
[ "\$1" = "inspect" ] && exit 0
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "rm" ] && exit 0
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -eq 0 ]
    grep -qx -- "rm -f orchestrator-credfeto" "${args_log}"
}

@test "invoke_claude returns 2 (not a hard die) when podman run fails due to container name in use (#1361)" {
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

    local notify_log="${TEST_TMP}/notify.log"
    notify_discord_claude_error() { printf '%s\n' "$*" >> "${notify_log}"; }

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    # Must be 2, not just any non-zero: main()'s MAX_CONSECUTIVE_INFRA_FAILURES escalation
    # (#1133) only ever triggers on exactly 2. This branch used to die, which bypassed that
    # escalation entirely and let a wedged container retry ~3,000 times unreported (#1361).
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"already in use"* ]]
    # Must NOT notify from here: returning 2 lets main() continue to the next item, so a
    # host-scoped fault would post one Discord message per item per 30s tick. Alerting for this
    # class belongs to the unit-level OnFailure= handler, which fires once per failed tick.
    [ ! -f "${notify_log}" ]
}


@test "invoke_claude passes --replace to podman run so a stale container name cannot wedge it (#1361)" {
    local args_log="${TEST_TMP}/podman_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
printf "%s\n" "\$@" >> "${args_log}"
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md" 2>/dev/null
    grep -qx -- '--replace' "${args_log}"
}

@test "invoke_claude still refuses to clobber a genuinely running container despite --replace (#1361)" {
    local args_log="${TEST_TMP}/podman_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
printf "%s\n" "\$*" >> "${args_log}"
[ "\$1" = "inspect" ] && [ "\$2" = "--format" ] && { printf 'true\n'; exit 0; }
[ "\$1" = "inspect" ] && exit 0
[ "\$1" = "pull" ] && exit 0
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    # --replace would happily destroy another invocation's in-flight work; the pre-flight guard
    # is what prevents that, so it must still fire before podman run is ever reached.
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"already exists and is running"* ]]
    [ "$(grep -c -- '--replace' "${args_log}")" -eq 0 ]
}

# --- pre-flight/infra container failure (#1133) --------------------------------

@test "invoke_claude returns 2 when the container fails before Claude produces any result" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "pull" ] && exit 0
[ "$1" = "inspect" ] && exit 1
if [ "$1" = "run" ]; then
    printf '✗ Repo checkout contains /workspace/repo/.claude/settings.json — refusing to grant workspace trust\n' >&2
    exit 1
fi
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -eq 2 ]
}

@test "invoke_claude removes the Claude OAuth podman secret when the container fails before Claude produces any result (#1133 review)" {
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
if [ "\$1" = "run" ]; then
    exit 1
fi
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -eq 2 ]
    # The stub logs one argument per line. The container-scoped secret name must appear three
    # times: the pre-create cleanup of any stale secret from a prior run, the create, and THIS
    # invocation's own post-failure cleanup (#1133 review) — previously only the pre-create rm
    # happened; the post-failure one was missing entirely. (The legacy-name sweep is a separate
    # rm and is not counted here.)
    local name_count
    name_count=$(grep -c '^claude-oauth-orchestrator-credfeto$' "${secret_log}" || true)
    [ "${name_count}" -eq 3 ]
    [ "$(grep -c '^create$' "${secret_log}")" -eq 1 ]
}

@test "invoke_claude cleans up CLAUDE_MD_TMPFILE when the container fails before Claude produces any result" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    export XDG_RUNTIME_DIR="${TEST_TMP}/runtime"
    mkdir -p "${XDG_RUNTIME_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "pull" ] && exit 0
[ "$1" = "inspect" ] && exit 1
if [ "$1" = "run" ]; then
    exit 1
fi
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -eq 2 ]
    # The CLAUDE.md tempfile (created under XDG_RUNTIME_DIR) must not survive the call.
    [ -z "$(find "${XDG_RUNTIME_DIR}" -name '*.claude-md' 2>/dev/null)" ]
}

@test "invoke_claude still dies (not returns 2) when podman exits nonzero but Claude produced a valid is_error result" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "pull" ] && exit 0
[ "$1" = "inspect" ] && exit 1
if [ "$1" = "run" ]; then
    printf '{"type":"result","is_error":true,"result":"boom"}\n'
    exit 1
fi
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -ne 2 ]
}

@test "invoke_claude does not return 2 when podman exits nonzero but Claude produced a genuinely successful result (#1133 review, Copilot)" {
    # A valid is_error:false result proves Claude actually ran, even if the container's own
    # exit code is nonzero for an unrelated reason (e.g. a kill racing a clean exit) — this
    # must be classified as a real (successful) invocation, not a pre-flight infra failure.
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "pull" ] && exit 0
[ "$1" = "inspect" ] && exit 1
if [ "$1" = "run" ]; then
    printf '{"type":"result","is_error":false,"result":"done"}\n'
    exit 1
fi
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -ne 2 ]
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

    invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md" 2>/dev/null
    run grep -q ".claude:/home/developer/.claude" "${args_log}"
    [ "${status}" -ne 0 ]
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

# --- handle_claude_permission_denials (#1328) -----------------------------------

@test "handle_claude_permission_denials is a no-op when permission_denials is absent" {
    local tmpfile
    tmpfile="$(mktemp "${TEST_TMP}/claude.XXXXXX.json")"
    printf '%s' '{"is_error":false,"result":"done"}' > "${tmpfile}"

    local notify_log="${TEST_TMP}/denial_notify.log"
    notify_discord_permission_denials() { printf '%s\n' "$*" >> "${notify_log}"; }

    run handle_claude_permission_denials "${tmpfile}" "Issue" "42"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    [ ! -f "${notify_log}" ]
}

@test "handle_claude_permission_denials is a no-op when permission_denials is an empty array" {
    local tmpfile
    tmpfile="$(mktemp "${TEST_TMP}/claude.XXXXXX.json")"
    printf '%s' '{"is_error":false,"result":"done","permission_denials":[]}' > "${tmpfile}"

    local notify_log="${TEST_TMP}/denial_notify.log"
    notify_discord_permission_denials() { printf '%s\n' "$*" >> "${notify_log}"; }

    run handle_claude_permission_denials "${tmpfile}" "Issue" "42"
    [ "${status}" -eq 0 ]
    [ ! -f "${notify_log}" ]
}

@test "handle_claude_permission_denials logs and notifies on a single Bash denial" {
    local tmpfile
    tmpfile="$(mktemp "${TEST_TMP}/claude.XXXXXX.json")"
    printf '%s' '{"is_error":false,"result":"done","permission_denials":[{"tool_name":"Bash","tool_input":{"command":"git status"}}]}' > "${tmpfile}"

    local notify_log="${TEST_TMP}/denial_notify.log"
    notify_discord_permission_denials() { printf '%s\n' "$*" >> "${notify_log}"; }

    run handle_claude_permission_denials "${tmpfile}" "Issue" "42"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"1 permission denial"* ]]
    [[ "${output}" == *"Bash: git status"* ]]
    grep -q "Bash: git status" "${notify_log}"
    # The count is passed through as a trailing argument so the Discord embed can show it
    # rather than the reviewer only being able to infer it by counting summary lines.
    grep -q " 1\$" "${notify_log}"
}

@test "handle_claude_permission_denials summarizes multiple denials across different tools" {
    local tmpfile
    tmpfile="$(mktemp "${TEST_TMP}/claude.XXXXXX.json")"
    printf '%s' '{"is_error":false,"result":"done","permission_denials":[{"tool_name":"Bash","tool_input":{"command":"git status"}},{"tool_name":"Edit","tool_input":{"file_path":"/workspace/repo/.database"}}]}' > "${tmpfile}"

    local notify_log="${TEST_TMP}/denial_notify.log"
    notify_discord_permission_denials() { printf '%s\n' "$*" >> "${notify_log}"; }

    run handle_claude_permission_denials "${tmpfile}" "PullRequest" "7"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"2 permission denial"* ]]
    [[ "${output}" == *"Bash: git status"* ]]
    [[ "${output}" == *"Edit: /workspace/repo/.database"* ]]
    grep -q "Bash: git status" "${notify_log}"
    grep -q "Edit: /workspace/repo/.database" "${notify_log}"
    grep -q " 2\$" "${notify_log}"
}

@test "handle_claude_permission_denials does not remove the tmpfile (caller owns cleanup)" {
    local tmpfile
    tmpfile="$(mktemp "${TEST_TMP}/claude.XXXXXX.json")"
    printf '%s' '{"is_error":false,"result":"done","permission_denials":[{"tool_name":"Bash","tool_input":{"command":"git status"}}]}' > "${tmpfile}"

    notify_discord_permission_denials() { return 0; }

    run handle_claude_permission_denials "${tmpfile}" "Issue" "42"
    [ "${status}" -eq 0 ]
    [ -f "${tmpfile}" ]
}

@test "handle_claude_permission_denials survives a non-object tool_input without losing the rest of the batch (code review, #1328)" {
    # A scalar tool_input makes jq's .tool_input.command indexing a runtime error, not a null -
    # without normalizing tool_input to an object first, jq aborts the whole $d[] iteration on
    # the first such entry, and only entries before it would ever reach the summary.
    local tmpfile
    tmpfile="$(mktemp "${TEST_TMP}/claude.XXXXXX.json")"
    printf '%s' '{"is_error":false,"result":"done","permission_denials":[{"tool_name":"Bash","tool_input":"not-an-object"},{"tool_name":"Bash","tool_input":{"command":"echo hi"}}]}' > "${tmpfile}"

    local notify_log="${TEST_TMP}/denial_notify.log"
    notify_discord_permission_denials() { printf '%s\n' "$*" >> "${notify_log}"; }

    run handle_claude_permission_denials "${tmpfile}" "Issue" "42"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"2 permission denial"* ]]
    [[ "${output}" == *"Bash: not-an-object"* ]]
    [[ "${output}" == *"Bash: echo hi"* ]]
    grep -q "Bash: echo hi" "${notify_log}"
    grep -q " 2\$" "${notify_log}"
}

@test "handle_claude_permission_denials survives a non-object denial ARRAY ELEMENT without losing the rest of the batch (code review, #1328)" {
    # A bare string (or number, etc.) sitting directly in the permission_denials array - not
    # inside tool_input, the array element itself - makes jq's .tool_name/.tool_input indexing a
    # runtime error, not a null: without coercing every $d[] element to an object first, jq
    # aborts the whole iteration on the first such entry and every denial after it is silently
    # dropped from the summary with no indication anything went wrong.
    local tmpfile
    tmpfile="$(mktemp "${TEST_TMP}/claude.XXXXXX.json")"
    printf '%s' '{"is_error":false,"result":"done","permission_denials":["a bare string entry",{"tool_name":"Bash","tool_input":{"command":"echo hi"}}]}' > "${tmpfile}"

    local notify_log="${TEST_TMP}/denial_notify.log"
    notify_discord_permission_denials() { printf '%s\n' "$*" >> "${notify_log}"; }

    run handle_claude_permission_denials "${tmpfile}" "Issue" "42"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"2 permission denial"* ]]
    [[ "${output}" == *"malformed-denial-entry"* ]]
    [[ "${output}" == *"Bash: echo hi"* ]]
    grep -q "Bash: echo hi" "${notify_log}"
    grep -q " 2\$" "${notify_log}"
}

@test "handle_claude_permission_denials collapses an embedded newline in a denied command to a single summary line" {
    # Without collapsing embedded newlines, a multi-line denied command (or a malformed entry's
    # raw JSON dump) would break the "one denial = one summary line" invariant the bash-side
    # line-count derivation of denials_count depends on.
    local tmpfile
    tmpfile="$(mktemp "${TEST_TMP}/claude.XXXXXX.json")"
    printf '%s' '{"is_error":false,"result":"done","permission_denials":[{"tool_name":"Bash","tool_input":{"command":"echo one\necho two"}},{"tool_name":"Bash","tool_input":{"command":"echo three"}}]}' > "${tmpfile}"

    local notify_log="${TEST_TMP}/denial_notify.log"
    notify_discord_permission_denials() { printf '%s\n' "$*" >> "${notify_log}"; }

    run handle_claude_permission_denials "${tmpfile}" "Issue" "42"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"2 permission denial"* ]]
    [[ "${output}" == *"Bash: echo one echo two"* ]]
    grep -q " 2\$" "${notify_log}"
}

@test "handle_claude_permission_denials truncates an oversized tool_input dump instead of logging it unbounded" {
    local tmpfile long_value
    tmpfile="$(mktemp "${TEST_TMP}/claude.XXXXXX.json")"
    long_value=$(printf 'x%.0s' $(seq 1 500))
    printf '{"is_error":false,"result":"done","permission_denials":[{"tool_name":"WebFetch","tool_input":{"url":"%s"}}]}' "${long_value}" > "${tmpfile}"

    notify_discord_permission_denials() { return 0; }

    run handle_claude_permission_denials "${tmpfile}" "Issue" "42"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"...(truncated)"* ]]
    [[ "${output}" != *"${long_value}"* ]]
}

@test "handle_claude_permission_denials falls back to {} rendering for a null or absent tool_input" {
    local tmpfile
    tmpfile="$(mktemp "${TEST_TMP}/claude.XXXXXX.json")"
    printf '%s' '{"is_error":false,"result":"done","permission_denials":[{"tool_name":"Weird","tool_input":null},{"tool_name":"NoInput"}]}' > "${tmpfile}"

    notify_discord_permission_denials() { return 0; }

    run handle_claude_permission_denials "${tmpfile}" "Issue" "42"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"2 permission denial"* ]]
    [[ "${output}" == *"Weird: {}"* ]]
    [[ "${output}" == *"NoInput: {}"* ]]
}

@test "handle_claude_permission_denials prints the summary on stdout when denials are found" {
    local tmpfile
    tmpfile="$(mktemp "${TEST_TMP}/claude.XXXXXX.json")"
    printf '%s' '{"is_error":false,"result":"done","permission_denials":[{"tool_name":"Bash","tool_input":{"command":"git status"}}]}' > "${tmpfile}"

    notify_discord_permission_denials() { return 0; }

    local denials_summary
    denials_summary=$(handle_claude_permission_denials "${tmpfile}" "Issue" "42")
    [[ "${denials_summary}" == *"Bash: git status"* ]]
}

@test "handle_claude_permission_denials prints nothing when no denials are found" {
    local tmpfile
    tmpfile="$(mktemp "${TEST_TMP}/claude.XXXXXX.json")"
    printf '%s' '{"is_error":false,"result":"done"}' > "${tmpfile}"

    local denials_summary
    denials_summary=$(handle_claude_permission_denials "${tmpfile}" "Issue" "42")
    [ -z "${denials_summary}" ]
}

# --- claude_result_indicates_diagnostic_refusal (#1448) ------------------------

@test "claude_result_indicates_diagnostic_refusal matches confirmed #182 incident phrasing" {
    local texts=(
        "Every invocation of gh — in any form, with any arguments — is denied by the permission system in this session (\"don't ask mode\")."
        "I need you to either confirm gh should be allowlisted, or tell me an alternative way to interact with GitHub here."
        "git push is denied. I can't proceed without a working git remote."
    )
    local t
    for t in "${texts[@]}"; do
        run claude_result_indicates_diagnostic_refusal "${t}"
        [ "${status}" -eq 0 ]
    done
}

@test "claude_result_indicates_diagnostic_refusal does not match ordinary long-form workflow narration" {
    local texts=(
        "Implemented the feature, ran the tests, and pushed the commit. CI is green and the PR is ready for review."
        "Fixed the failing test by correcting the assertion. The build passed and the change was denied entry to the cache once but retried successfully."
    )
    local t
    for t in "${texts[@]}"; do
        run claude_result_indicates_diagnostic_refusal "${t}"
        [ "${status}" -ne 0 ]
    done
}

@test "claude_result_indicates_diagnostic_refusal does not match a refusal-shaped result over the length cap" {
    local long_text
    long_text="is denied$(printf ' padding%.0s' $(seq 1 100))"
    run claude_result_indicates_diagnostic_refusal "${long_text}"
    [ "${status}" -ne 0 ]
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

# --- claude_result_indicates_background_stall (#1326/#1335) --------------------

@test "claude_result_indicates_background_stall matches every confirmed #215 incident phrasing" {
    local texts=(
        "The pre-commit baseline check (buildcheck + build) is still running in the background. I'll pause here and wait for the Monitor notification when it completes before proceeding to branch creation and the draft PR."
        "Waiting for the backgrounded pre-commit baseline check to finish; the Monitor will notify me when it completes."
        "I'll pause here and wait for the pre-commit Monitor task to notify me before continuing."
        "Still waiting on the background pre-commit/test run to complete."
        "I'll skip detailed task tracking overhead and just wait for the baseline check notification before proceeding."
        "I'm now waiting on the mandatory Pre-Work Baseline Check (pre-commit --all-files, running in background) to finish before creating the branch — I'll continue automatically once that completes."
    )
    local t
    for t in "${texts[@]}"; do
        run claude_result_indicates_background_stall "${t}"
        [ "${status}" -eq 0 ] || { echo "expected match for: ${t}"; false; }
    done
}

@test "claude_result_indicates_background_stall matches the #1374 recurrence phrasing that slipped past the #215 patterns" {
    local texts=(
        "Build and monitor are running in the background — I'll pick this up once the completion notification arrives."
        "I'll pick it up once the background test run finishes."
        "I'll resume once the background job completes."
        "I'll continue this once the background check finishes."
    )
    local t
    for t in "${texts[@]}"; do
        run claude_result_indicates_background_stall "${t}"
        [ "${status}" -eq 0 ] || { echo "expected match for: ${t}"; false; }
    done
}

@test "claude_result_indicates_background_stall matches when the background/monitor mention precedes the resume phrase, not just follows it" {
    # The four cases above all happen to satisfy the anchor-after alternative
    # (I.ll ...[^.]*(background|monitor|notification)) on its own - none of them isolate the
    # anchor-before alternative added alongside it. Confirmed by testing the anchor-after
    # pattern alone against all four: it matches every one, so this repo's own coverage never
    # actually exercised the anchor-before branch. This case only matches via anchor-before.
    run claude_result_indicates_background_stall "The build is running in the background; I'll resume when it finishes."
    [ "${status}" -eq 0 ]
}

@test "claude_result_indicates_background_stall does not match legitimate GitHub-side stop reasons" {
    local texts=(
        "PHASE H complete: PR #216 was still a draft, so it was moved out of draft and auto-merge was enabled, with a status comment posted. Stopping here per phase discipline — the next cycle will pick up once GitHub settles this state."
        "Auto-merge is already enabled and no other phase applies — the PR is ready and just waiting on the required human review/checks, which is expected branch-protection behavior."
        "Phase F (Security review) is complete: security review found no findings, board advanced from AI Security Review to AI Coverage. Per phase discipline, stopping here — the next cycle will pick up PHASE G (Coverage)."
        "Work on issue #177 is complete for this cycle. Opened draft PR #216, assigned myself. Updated Workflow board status to Development."
        "Issue #244 is blocked pending explicit human approval — done for this session."
        "Waiting for a human to review and approve the plan before proceeding."
        "PR #99 CI checks pending — deferring to the next cycle when GitHub settles."
        ""
    )
    local t
    for t in "${texts[@]}"; do
        run claude_result_indicates_background_stall "${t}"
        [ "${status}" -ne 0 ] || { echo "expected no match for: ${t}"; false; }
    done
}

@test "claude_result_indicates_background_stall does not match an ordinary 'I'll resume/continue ... once/when' sentence unrelated to backgrounding" {
    # Simplify-review finding on #1376: the first version of the #1374 fix added
    # `I.ll (pick (this|it) up|resume|continue this)[^.]*(once|when|after)` with no
    # background/monitor/notification anchor, so it matched any ordinary "I'll resume/continue
    # X once/when Y" sentence regardless of subject matter - the exact false-positive shape the
    # function's own header comment forbids. These three are all confirmed false positives of
    # that unanchored version.
    local texts=(
        "I'll resume the migration script once the schema review is done, then continue with the rollout."
        "I'll continue this work once code review comments land."
        "I'll resume tomorrow once I have more context."
    )
    local t
    for t in "${texts[@]}"; do
        run claude_result_indicates_background_stall "${t}"
        [ "${status}" -ne 0 ] || { echo "expected no match for: ${t}"; false; }
    done
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

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
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
    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -ne 0 ]
    # Rate-limit file must exist and contain reset_time + 1hr buffer, both in the future.
    local rate_file="${ORCHESTRATOR_STATE_DIR}/${OWNER}/rate-limit"
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
    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -ne 0 ]
    local rate_file="${ORCHESTRATOR_STATE_DIR}/${OWNER}/rate-limit"
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

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -ne 0 ]
    grep -q "https://discord.example.com/hook" "${args_log}"
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

    invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md" 2>/dev/null
    grep -qx 'GIT_USER_NAME=Alice' "${args_log}"
}

@test "invoke_claude passes CLAUDE_CODE_AUTO_COMPACT_WINDOW as container env var (#1070)" {
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
    grep -qx 'CLAUDE_CODE_AUTO_COMPACT_WINDOW=100000' "${args_log}"
}

@test "invoke_claude respects a CLAUDE_CODE_AUTO_COMPACT_WINDOW override from the environment (#1070)" {
    local args_log="${TEST_TMP}/podman_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    CLAUDE_CODE_AUTO_COMPACT_WINDOW=50000
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
    grep -qx 'CLAUDE_CODE_AUTO_COMPACT_WINDOW=50000' "${args_log}"
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

    invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md" 2>/dev/null
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

    invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md" 2>/dev/null
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

    invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md" 2>/dev/null
    run grep -qx 'GIT_USER_NAME=' "${args_log}"
    [ "${status}" -ne 0 ]
}

@test "invoke_claude passes WORK_ITEM_URL as container env var for an Issue" {
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

    invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md" 2>/dev/null
    grep -qx "WORK_ITEM_URL=https://github.com/${REPO_FULL}/issues/42" "${args_log}"
}

@test "invoke_claude passes WORK_ITEM_URL as container env var for a PullRequest" {
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

    invoke_claude "test prompt" "PullRequest" "17" "# mock CLAUDE.md" 2>/dev/null
    grep -qx "WORK_ITEM_URL=https://github.com/${REPO_FULL}/pull/17" "${args_log}"
}

@test "invoke_claude without an item dies before any podman call, creating no secret and no tmpfile" {
    local args_log="${TEST_TMP}/podman_args" mktemp_log="${TEST_TMP}/mktemp_calls" notify_log="${TEST_TMP}/notify"
    stub_podman_run_logging_args "${args_log}"
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator/tokens"
    printf 'my-claude-token\n' > "${XDG_CONFIG_HOME}/orchestrator/tokens/credfeto"
    chmod 600 "${XDG_CONFIG_HOME}/orchestrator/tokens/credfeto"
    export GH_ENTERPRISE_TOKEN="gh-token"
    mktemp() { printf '%s\n' "$*" >> "${mktemp_log}"; command mktemp "$@"; }
    notify_discord_claude_error() { printf '%s\n' "$*" >> "${notify_log}"; }
    local item
    # Each entry is "<item_type>|<item_id>".
    for item in "|" "Issue|" "|42"; do
        rm -f "${args_log}" "${mktemp_log}"
        run invoke_claude "test prompt" "${item%%|*}" "${item#*|}" "# mock CLAUDE.md"
        [ "${status}" -ne 0 ]
        [[ "${output}" == *"An agent container launch needs both an item type and an item id"* ]]
        # The stub logs every podman call but pull and inspect, so no log means the pre-flight
        # (image prune) never ran either.
        [ ! -e "${args_log}" ]
        [ ! -e "${mktemp_log}" ]
    done
    [ "$(grep -c 'An agent container launch needs both an item type and an item id' "${notify_log}")" -eq 3 ]
    [ ! -e "${SESSION_BASE_DIR}/transcripts" ]
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

    invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md" 2>/dev/null
    run grep -qF ".gitconfig" "${args_log}"
    [ "${status}" -ne 0 ]
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
    run invoke_claude "" "Issue" "42" "# mock CLAUDE.md"
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
    invoke_claude "hello from prompt" "Issue" "42" "# mock CLAUDE.md" 2>/dev/null
    [ "${CLAUDE_PROMPT}" = "hello from prompt" ]
}

# --- invoke_claude keeps its --print behaviour after the shared-builder split (#1409) ---------

@test "invoke_claude still passes --print, --output-format json and --permission-mode dontAsk" {
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
    invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md" 2>/dev/null
    grep -qx -- '--print' "${args_log}"
    grep -qx -- '--output-format' "${args_log}"
    grep -qx -- '--permission-mode' "${args_log}"
    grep -qx 'dontAsk' "${args_log}"
    [ "$(grep -c -- '^--tty$' "${args_log}")" -eq 0 ]
    grep -qx 'orchestrator-credfeto' "${args_log}"
}
