#!/usr/bin/env bats
# shellcheck disable=SC2329  # functions in @test bodies are invoked indirectly via 'run'
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are used inside run() subshells where shellcheck cannot trace them

bats_require_minimum_version 1.5.0

load test_helper
load oneshot_helper

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
    invoke_claude "test prompt" "Issue" "42" "# per-item instructions" 2>/dev/null
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
    local discord_log="${TEST_TMP}/discord.log"
    notify_discord_host_health() { printf '%s\n' "$*" >> "${discord_log}"; }
    run preload_ssh_keys
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"no SSH keys could be loaded"* ]]
    grep -q "ssh_agent_no_keys" "${discord_log}"
}

@test "preload_ssh_keys dies rather than silently passing when ssh-add cannot connect to the agent (exit 2, #1103)" {
    local ssh_sock="${TEST_TMP}/ssh-agent.sock"
    python3 -c "import socket,os; s=socket.socket(socket.AF_UNIX); s.bind('${ssh_sock}')"
    export SSH_AUTH_SOCK="${ssh_sock}"
    # Exit 2 = "cannot connect to the agent" — a dead/stale socket. This must not be treated
    # like exit 0 (already loaded); it must fail fast on the host instead of letting a dead
    # socket get mounted into every agent container.
    cat > "${STUB_BIN}/ssh-add" << 'STUBEOF'
#!/usr/bin/env bash
exit 2
STUBEOF
    chmod +x "${STUB_BIN}/ssh-add"
    local discord_log="${TEST_TMP}/discord.log"
    notify_discord_host_health() { printf '%s\n' "$*" >> "${discord_log}"; }
    run preload_ssh_keys
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"cannot connect to the agent"* ]]
    grep -q "ssh_agent_down" "${discord_log}"
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

@test "stop_ssh_agent calls pkill scoped to its own user and socket when SSH_AUTH_SOCK is set (#1122)" {
    export SSH_AUTH_SOCK="${TEST_TMP}/ssh-agent.sock"
    local pkill_log="${TEST_TMP}/pkill.log"
    make_stub pkill "printf '%s\n' \"\$*\" >> \"${pkill_log}\"; exit 0"
    stop_ssh_agent
    grep -qxe "-u $(id -un) -f ssh-agent -a ${SSH_AUTH_SOCK}" "${pkill_log}"
}

@test "stop_ssh_agent succeeds even when pkill finds no process" {
    export SSH_AUTH_SOCK="${TEST_TMP}/ssh-agent.sock"
    make_stub pkill 'exit 1'
    run stop_ssh_agent
    [ "${status}" -eq 0 ]
}

@test "stop_ssh_agent does not kill an unrelated ssh-agent bound to a different socket (#1122)" {
    local required_tool
    for required_tool in ssh-agent pgrep pkill; do
        if ! command -v "${required_tool}" > /dev/null 2>&1; then
            echo "${required_tool} is required by this test but is not installed" >&2
            return 1
        fi
    done

    local decoy_sock="${TEST_TMP}/decoy-agent.sock"
    # The pid comes from ssh-agent's own output rather than pgrep: ssh-agent is not visible to
    # user-scoped ps/pgrep on every host (#1487). fd 3 is closed so a leaked decoy can never
    # hold bats' output pipe open and hang the run. SHELL pins sh-style output without adding
    # a flag, so the decoy's argv stays exactly what stop_ssh_agent's pkill pattern matches.
    local decoy_pid
    decoy_pid=$(SHELL=/bin/sh ssh-agent -a "${decoy_sock}" 3>&- | sed -n 's/^SSH_AGENT_PID=\([0-9][0-9]*\);.*/\1/p')
    if [ -z "${decoy_pid}" ]; then
        echo "ssh-agent did not report a pid for the decoy agent" >&2
        return 1
    fi

    if ! pgrep -u "$(id -un)" -f "ssh-agent -a ${decoy_sock}" | grep -qx "${decoy_pid}"; then
        kill "${decoy_pid}" 2> /dev/null || true
        skip "the decoy ssh-agent (pid ${decoy_pid}) is not visible to a user-scoped pgrep -f on this host, so this test cannot tell whether stop_ssh_agent's pkill would have found it"
    fi

    export SSH_AUTH_SOCK="${TEST_TMP}/this-run-agent.sock"
    stop_ssh_agent

    # pkill only sends SIGTERM and returns, so give a wrongly-killed decoy a moment to actually exit.
    local survived=1 attempt
    for attempt in 1 2 3 4 5; do
        if ! kill -0 "${decoy_pid}" 2> /dev/null; then
            survived=0
            break
        fi
        sleep 0.1
    done
    kill "${decoy_pid}" 2> /dev/null || true
    [ "${survived}" -eq 1 ]
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

@test "invoke_claude falls back to the cached image when podman pull fails but the image exists locally (#1090)" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "inspect" ] && exit 1
[ "$1" = "pull" ] && exit 1
[ "$1" = "image" ] && [ "$2" = "exists" ] && exit 0
[ "$1" = "image" ] && exit 0
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"falling back to the cached local image"* ]]
}

@test "invoke_claude dies when podman pull fails and no cached image exists locally (#1090)" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "inspect" ] && exit 1
[ "$1" = "pull" ] && exit 1
[ "$1" = "image" ] && [ "$2" = "exists" ] && exit 1
[ "$1" = "image" ] && exit 0
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"no cached local image is available"* ]]
}

@test "invoke_claude notifies Discord before dying when podman pull fails and no cached image exists locally (#1103, #1400)" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "inspect" ] && exit 1
[ "$1" = "pull" ] && exit 1
[ "$1" = "image" ] && [ "$2" = "exists" ] && exit 1
[ "$1" = "image" ] && exit 0
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    local notify_log="${TEST_TMP}/notify.log"
    # #1400: the hard pull-failure branch now calls the purpose-named
    # notify_discord_pull_failed instead of the misleadingly-titled
    # notify_discord_claude_error - stubbing the old function to detect a regression.
    notify_discord_pull_failed() { printf '%s\n' "$*" >> "${notify_log}"; }
    notify_discord_claude_error() { printf 'WRONG_FUNCTION_CALLED %s\n' "$*" >> "${notify_log}"; }

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -ne 0 ]
    grep -q "no cached local image is available" "${notify_log}"
    [ "$(grep -c "WRONG_FUNCTION_CALLED" "${notify_log}")" -eq 0 ]
}

@test "invoke_claude records the pull duration on a successful pull (#1400)" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    OWNER="owner"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "pull" ] && exit 0
[ "$1" = "image" ] && exit 0
[ "$1" = "inspect" ] && exit 1
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    invoke_claude "test prompt" "Issue" "1" "# mock CLAUDE.md" 2>/dev/null

    [ -f "${ORCHESTRATOR_STATE_DIR}/owner/pull-durations" ]
}

@test "invoke_claude fires notify_discord_slow_pull when pull_duration_exceeds_baseline trips (#1400)" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    OWNER="owner"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "pull" ] && exit 0
[ "$1" = "image" ] && exit 0
[ "$1" = "inspect" ] && exit 1
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    local notify_log="${TEST_TMP}/notify.log"
    # Stubs the predicate itself rather than controlling real wall-clock timing - this test is
    # about invoke_claude's wiring (does it call notify_discord_slow_pull with the right
    # arguments when told the pull was slow?), not about pull_duration_exceeds_baseline's own
    # threshold arithmetic, which has its own direct tests above.
    pull_duration_exceeds_baseline() { printf '10\n'; }
    notify_discord_slow_pull() { printf '%s\n' "$*" >> "${notify_log}"; }

    invoke_claude "test prompt" "Issue" "1" "# mock CLAUDE.md" 2>/dev/null

    [ -f "${notify_log}" ]
    grep -q "^owner " "${notify_log}"
    grep -q " 10$" "${notify_log}"
}

@test "invoke_claude does not fire notify_discord_slow_pull when pull_duration_exceeds_baseline says the pull wasn't slow (#1400)" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    OWNER="owner"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "pull" ] && exit 0
[ "$1" = "image" ] && exit 0
[ "$1" = "inspect" ] && exit 1
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    local notify_log="${TEST_TMP}/notify.log"
    pull_duration_exceeds_baseline() { return 1; }
    notify_discord_slow_pull() { printf '%s\n' "$*" >> "${notify_log}"; }

    invoke_claude "test prompt" "Issue" "1" "# mock CLAUDE.md" 2>/dev/null

    [ ! -f "${notify_log}" ]
}

@test "invoke_claude pulls the image only once across multiple invocations in the same run (#1401)" {
    local call_log="${TEST_TMP}/podman_calls"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "pull" ]    && printf 'pull\n' >> "${call_log}" && exit 0
[ "\$1" = "image" ]   && exit 0
[ "\$1" = "inspect" ] && exit 1
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    invoke_claude "test prompt" "Issue" "1" "# mock CLAUDE.md" 2>/dev/null
    invoke_claude "test prompt" "Issue" "2" "# mock CLAUDE.md" 2>/dev/null

    [ "$(grep -c '^pull$' "${call_log}")" -eq 1 ]
}

@test "invoke_claude retries the pull on the next item after a fallback within the same run (#1401)" {
    # Deliberately does NOT use bats' "run" helper for the invoke_claude calls: "run" captures
    # output via command substitution, which forks a subshell — any mutation invoke_claude makes
    # to ORCHESTRATOR_IMAGE_PULLED_THIS_RUN inside that subshell would be lost on return, making
    # it impossible to observe whether the flag was really left clear across the two calls.
    local call_log="${TEST_TMP}/podman_calls"
    local first_output="${TEST_TMP}/first_output"
    local second_output="${TEST_TMP}/second_output"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "pull" ]    && printf 'pull\n' >> "${call_log}" && exit 1
[ "\$1" = "image" ] && [ "\$2" = "exists" ] && exit 0
[ "\$1" = "image" ]   && exit 0
[ "\$1" = "inspect" ] && exit 1
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    invoke_claude "test prompt" "Issue" "1" "# mock CLAUDE.md" > "${first_output}" 2>&1
    invoke_claude "test prompt" "Issue" "2" "# mock CLAUDE.md" > "${second_output}" 2>&1

    grep -q "falling back to the cached local image" "${first_output}"
    grep -q "falling back to the cached local image" "${second_output}"
    [ "$(grep -c '^pull$' "${call_log}")" -eq 2 ]
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
    invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md" 2>/dev/null
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
    invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md" 2>/dev/null
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
    # stop_ssh_agent runs as an EXIT trap inside invoke_claude — stub pkill so the
    # trap never reaches the real system binary (#1122).
    make_stub pkill 'exit 1'
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
    invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md" 2>/dev/null
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
    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"SSH_AUTH_SOCK is not set"* ]]
}

@test "invoke_claude warns and skips SSH mount when SSH_AUTH_SOCK path is not a socket" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    export SSH_AUTH_SOCK="${TEST_TMP}/nonexistent-sock"
    # stop_ssh_agent runs as an EXIT trap inside invoke_claude even though the
    # socket path is bogus — SSH_AUTH_SOCK is still non-empty. Stub pkill so the
    # trap never reaches the real system binary (#1122).
    make_stub pkill 'exit 1'
    make_gpg_stubs
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "pull" ] && exit 0
[ "$1" = "inspect" ] && exit 1
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"
    GIT_SIGNING_KEY=""
    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
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
    invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md" 2>/dev/null
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
    invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md" 2>/dev/null
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
    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *".database not found"* ]]
}

# --- verify_gpg_signing_ready unit tests --------------------------------------

@test "verify_gpg_signing_ready passes when agent is running and key is present" {
    make_stub gpg-connect-agent 'exit 0'
    make_stub gpg 'exit 0'
    GIT_SIGNING_KEY="ABCD1234"
    run verify_gpg_signing_ready
    [ "${status}" -eq 0 ]
}

@test "verify_gpg_signing_ready is a no-op when GIT_SIGNING_KEY is empty" {
    make_stub gpg-connect-agent 'exit 1'
    GIT_SIGNING_KEY=""
    run verify_gpg_signing_ready
    [ "${status}" -eq 0 ]
}

@test "verify_gpg_signing_ready dies when gpg-agent is not running" {
    make_stub gpg-connect-agent 'exit 1'
    GIT_SIGNING_KEY="ABCD1234"
    run verify_gpg_signing_ready
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
    GIT_SIGNING_KEY="ABCD1234"
    run verify_gpg_signing_ready
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"not found in GPG keyring"* ]]
}

@test "verify_gpg_signing_ready notifies Discord host health and never touches GitHub when gpg-agent is not running" {
    make_stub gpg-connect-agent 'exit 1'
    cat > "${STUB_BIN}/gh" << 'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TEST_TMP}/gh.log"
GHEOF
    chmod +x "${STUB_BIN}/gh"
    local discord_log="${TEST_TMP}/discord.log"
    notify_discord_host_health() { printf '%s\n' "$*" >> "${discord_log}"; }
    REPO_FULL="owner/repo"
    GIT_SIGNING_KEY="ABCD1234"
    run verify_gpg_signing_ready
    [ "${status}" -ne 0 ]
    [ -f "${discord_log}" ]
    grep -q "gpg_agent_down" "${discord_log}"
    [ ! -f "${TEST_TMP}/gh.log" ]
}

@test "verify_gpg_signing_ready notifies Discord host health and never touches GitHub when signing key is absent" {
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
    local discord_log="${TEST_TMP}/discord.log"
    notify_discord_host_health() { printf '%s\n' "$*" >> "${discord_log}"; }
    REPO_FULL="owner/repo"
    GIT_SIGNING_KEY="ABCD1234"
    run verify_gpg_signing_ready
    [ "${status}" -ne 0 ]
    [ -f "${discord_log}" ]
    grep -q "gpg_key_missing" "${discord_log}"
    [ ! -f "${TEST_TMP}/gh.log" ]
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

@test "ensure_repo_current returns 2 (not dies) when git fetch fails transiently (#1090)" {
    mkdir -p "${REPO_WORK_DIR}/.git"
    cat > "${STUB_BIN}/git" << 'STUBEOF'
#!/usr/bin/env bash
for arg in "$@"; do [ "${arg}" = "fetch" ] && exit 1; done
for arg in "$@"; do [ "${arg}" = "--show-current" ] && { printf 'main\n'; exit 0; }; done
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/git"
    hash git

    run ensure_repo_current
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"Failed to fetch from origin"* ]]
}

# --- ensure_rules_current (#1090) ---------------------------------------------

@test "ensure_rules_current returns 1 (not dies) when the pull fails transiently" {
    mkdir -p "${RULES_DIR}/.git"
    cat > "${STUB_BIN}/git" << 'STUBEOF'
#!/usr/bin/env bash
for arg in "$@"; do [ "${arg}" = "pull" ] && exit 1; done
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/git"
    hash git

    run ensure_rules_current
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Failed to update cs-template"* ]]
}

@test "ensure_rules_current returns 1 (not dies) when the initial clone fails transiently" {
    make_stub git 'exit 1'

    run ensure_rules_current
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Failed to clone cs-template"* ]]
}

@test "ensure_rules_current succeeds when checkout and pull both succeed" {
    mkdir -p "${RULES_DIR}/.git"
    make_stub git 'exit 0'

    run ensure_rules_current
    [ "${status}" -eq 0 ]
}
