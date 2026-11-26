#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are read by the sourced oneshot functions, where shellcheck cannot trace them

# Golden parity cases for stopping the run's ssh-agent in the .NET rewrite (#252). test/fixtures/agents-stop-parity.json
# holds, for each case, the socket SSH_AUTH_SOCK names and the argv[0] of a stand-in process (exec -a <argv0> sleep 30,
# so pkill -f sees "<argv0> 30"), both as printf %b text with @ROOT@ standing for a directory of the test's own, and
# whether stop_ssh_agent's pkill killed the stand-in ("killed"). This file checks the shell function against the
# fixture, and Credfeto.Orchestrator.Agents.Tests (src/) checks the tool's match rule against the same file. A case
# marked "refuses" is one the tool must refuse (a socket path it does not match as pkill's regular expression, or a
# command line whose match depends on how procps renders a byte outside printable ASCII or where it cuts a long one),
# so bash runs pkill. Where that answer depends on the procps version or the locale, "killed" is null and only the
# refusal is checked.
#
# Every pattern holds the test's own directory, so it can only match this test's stand-ins, never a real ssh-agent.
# To regenerate the recorded results after a change to the cases, run the last test with AGENTS_STOP_PARITY_REGENERATE
# set to the file to write; it keeps the fixture's cases and records what the shell function does for each one whose
# "killed" is not null.

bats_require_minimum_version 1.5.0

load test_helper
load oneshot_helper

AGENTS_STOP_FIXTURE="${BATS_TEST_DIRNAME}/fixtures/agents-stop-parity.json"

# The shared teardown, after killing any stand-in a failed test left running
teardown() {
    local pid_file
    for pid_file in "${BATS_TEST_TMPDIR}/stand-in.pid" "${BATS_TEST_TMPDIR}/real-agent.pid"; do
        if [ -f "${pid_file}" ]; then
            kill -9 "$(cat "${pid_file}")" 2> /dev/null || true
        fi
    done
    cleanup_stubs
    cleanup_repo_fixtures
}

# Prints field $2 (a jq path) of case $1
_stop_case() {
    jq -j --argjson i "$1" ".cases[\$i]$2" "${AGENTS_STOP_FIXTURE}"
}

# Prints case $1's field $2 as the bytes it stands for, with @ROOT@ replaced by $3, then a dot (so a trailing
# newline survives the command substitution)
_stop_case_text() {
    local text
    text=$(_stop_case "$1" ".$2")
    printf '%b.' "${text//@ROOT@/$3}"
}

# Prints the state letter of process $1 (R, S, Z ...), or nothing when it has gone (bash reaps its children itself)
_stop_process_state() {
    local stat
    stat=$(cat "/proc/$1/stat" 2> /dev/null) || return 0
    stat=${stat##*) }
    printf '%s' "${stat%% *}"
}

# Starts case $2's stand-in, runs stop_ssh_agent against case $2's socket with $1 as @ROOT@, and prints what
# stop_ssh_agent printed and its status after a dot, then "killed" when the stand-in died of SIGTERM or "alive" (it is
# killed with SIGKILL then);
# stop_ssh_agent's stderr goes to $3
_stop_parity_call() {
    local root="$1" index="$2" stderr_file="$3" socket argv0 pid attempt sleep_binary result state wait_status=0
    socket=$(_stop_case_text "${index}" socket "${root}")
    socket=${socket%.}
    argv0=$(_stop_case_text "${index}" argv0 "${root}")
    argv0=${argv0%.}
    sleep_binary=$(readlink -f "$(command -v sleep)")
    (exec -a "${argv0}" sleep 30) < /dev/null > /dev/null 2>&1 3>&- &
    pid=$!
    printf '%s' "${pid}" > "${BATS_TEST_TMPDIR}/stand-in.pid"
    for ((attempt = 0; attempt < 200; attempt++)); do
        [ "$(readlink "/proc/${pid}/exe" 2> /dev/null)" = "${sleep_binary}" ] && break
        sleep 0.01
    done
    result=$(
        export SSH_AUTH_SOCK="${socket}"
        stop_ssh_agent 2> "${stderr_file}"
        printf '.%s' "$?"
    )
    for ((attempt = 0; attempt < 30; attempt++)); do
        state=$(_stop_process_state "${pid}")
        [ -z "${state}" ] || [ "${state}" = Z ] && break
        sleep 0.01
    done
    kill -9 "${pid}" 2> /dev/null || true
    wait "${pid}" 2> /dev/null || wait_status=$?
    rm -f "${BATS_TEST_TMPDIR}/stand-in.pid"
    if [ "${wait_status}" -eq 143 ]; then
        printf '%s killed' "${result}"
    else
        printf '%s alive' "${result}"
    fi
}

# Runs every case, as the caller has set ORCHESTRATOR_DOTNET_AGENTS, and prints one line for each where
# stop_ssh_agent printed something, did not return 0, or killed or spared the stand-in other than as the fixture
# records. Switched on, it also checks that the tool answered exactly the "answers" cases (lib/podman warns when
# pkill runs instead) and that an answered case's stderr is empty, as bash's is.
_check_agents_stop_parity_cases() {
    local root="$1" count index name tool killed result failures=0 warned
    count=$(jq '.cases | length' "${AGENTS_STOP_FIXTURE}")
    [ "${count}" -gt 0 ] || return 1
    for ((index = 0; index < count; index++)); do
        name=$(_stop_case "${index}" '.name')
        tool=$(_stop_case "${index}" '.tool')
        killed=$(_stop_case "${index}" '.killed')
        result=$(_stop_parity_call "${root}" "${index}" "${root}.stderr")
        if [ "${result%% *}" != ".0" ]; then
            printf 'case %d (%s): printed and returned [%s], expected [.0]\n' "${index}" "${name}" "${result%% *}"
            failures=$((failures + 1))
        fi
        if [ "${killed}" != null ] && [ "${result#* }" != "$([ "${killed}" = true ] && echo killed || echo alive)" ]; then
            printf 'case %d (%s): the stand-in was %s, expected killed %s\n' "${index}" "${name}" "${result#* }" \
                "${killed}"
            failures=$((failures + 1))
        fi
        warned=answers
        if [ "${ORCHESTRATOR_DOTNET_AGENTS}" = 1 ]; then
            if grep -q 'running pkill in bash instead' "${root}.stderr"; then
                warned=refuses
            fi
            if [ "${warned}" != "${tool}" ]; then
                printf 'case %d (%s): the tool %s it, not %s\n' "${index}" "${name}" "${warned}" "${tool}"
                failures=$((failures + 1))
            fi
        fi
        if [ "${warned}" = answers ] && [ -s "${root}.stderr" ]; then
            printf 'case %d (%s): wrote to stderr: %s\n' "${index}" "${name}" "$(cat "${root}.stderr")"
            failures=$((failures + 1))
        fi
    done
    [ "${failures}" -eq 0 ]
}

# The locales the cases run in: C.UTF-8, and en_GB.UTF-8 as well where the host has it
_agents_stop_parity_locales() {
    printf 'C.UTF-8\n'
    if locale -a 2> /dev/null | grep -qix 'en_GB.utf-\?8'; then
        printf 'en_GB.UTF-8\n'
    fi
}

# The directory standing for @ROOT@: the test's own, which must hold only characters the patterns take literally
_agents_stop_root() {
    local root="${BATS_TEST_TMPDIR}/root"
    [[ "${root}" =~ ^[A-Za-z0-9/_.-]+$ ]] || return 1
    mkdir -p "${root}"
    printf '%s' "${root}"
}

@test "stop_ssh_agent kills what the fixture records for every agents stop parity case (#252)" {
    command -v pkill > /dev/null || skip "pkill is not installed"
    local root locale
    root=$(_agents_stop_root)
    ORCHESTRATOR_DOTNET_AGENTS=0
    while IFS= read -r locale; do
        LC_ALL="${locale}" run _check_agents_stop_parity_cases "${root}"
        if [ "${status}" -ne 0 ]; then
            printf '%s: %s\n' "${locale}" "${output}"
        fi
        [ "${status}" -eq 0 ]
    done < <(_agents_stop_parity_locales)
}

# The end-to-end check the plan asks for before each phase's PR: the same cases through the freshly built tool, given
# as ORCHESTRATOR_PARITY_CMD (a wrapper with an absolute path, since these tests replace HOME). Skipped when it is not
# set, as in CI, which has no tool on PATH.
@test "every agents stop parity case kills the same through ORCHESTRATOR_CMD when switched on (#252)" {
    [ -n "${ORCHESTRATOR_PARITY_CMD:-}" ] || skip "ORCHESTRATOR_PARITY_CMD is not set"
    command -v pkill > /dev/null || skip "pkill is not installed"
    local root locale
    root=$(_agents_stop_root)
    ORCHESTRATOR_DOTNET_AGENTS=1
    ORCHESTRATOR_CMD="${ORCHESTRATOR_PARITY_CMD}"
    while IFS= read -r locale; do
        LC_ALL="${locale}" run _check_agents_stop_parity_cases "${root}"
        if [ "${status}" -ne 0 ]; then
            printf '%s: %s\n' "${locale}" "${output}"
        fi
        [ "${status}" -eq 0 ]
    done < <(_agents_stop_parity_locales)
}

# A real ssh-agent bound to a socket in the test directory, and a decoy bound to another: switched on, the tool stops
# the run's agent with SIGTERM, so it removes its socket as it does for pkill, and leaves the decoy running
@test "a real ssh-agent is stopped through ORCHESTRATOR_CMD as pkill stops it, and a decoy is left (#252)" {
    [ -n "${ORCHESTRATOR_PARITY_CMD:-}" ] || skip "ORCHESTRATOR_PARITY_CMD is not set"
    command -v ssh-agent > /dev/null || skip "ssh-agent is not installed"
    local root mode env pid decoy_pid stopped
    root=$(_agents_stop_root)
    env=$(ssh-agent -a "${root}/decoy.sock" 3>&- 2> /dev/null)
    env=${env#*SSH_AGENT_PID=}
    decoy_pid=${env%%;*}
    printf '%s' "${decoy_pid}" > "${BATS_TEST_TMPDIR}/stand-in.pid"
    # ssh-agent makes itself non-dumpable, so a /proc mounted with hidepid hides it from its own user (#1487): neither
    # pkill nor the tool can find it there
    if ! pgrep -u "$(id -un)" -f "ssh-agent -a ${root}/decoy.sock" | grep -qx "${decoy_pid}"; then
        skip "ssh-agent (pid ${decoy_pid}) is not visible to a user-scoped pgrep -f on this host"
    fi
    ORCHESTRATOR_CMD="${ORCHESTRATOR_PARITY_CMD}"
    for mode in 0 1; do
        export SSH_AUTH_SOCK="${root}/agent.sock"
        env=$(ssh-agent -a "${SSH_AUTH_SOCK}" 3>&- 2> /dev/null)
        env=${env#*SSH_AGENT_PID=}
        pid=${env%%;*}
        printf '%s' "${pid}" > "${BATS_TEST_TMPDIR}/real-agent.pid"
        [ -S "${SSH_AUTH_SOCK}" ]
        ORCHESTRATOR_DOTNET_AGENTS="${mode}" stop_ssh_agent 2> "${root}.stderr"
        stopped=no
        for _ in {1..100}; do
            if ! kill -0 "${pid}" 2> /dev/null && [ ! -e "${SSH_AUTH_SOCK}" ]; then
                stopped=yes
                break
            fi
            sleep 0.02
        done
        printf 'mode %s: stopped %s, stderr [%s]\n' "${mode}" "${stopped}" "$(cat "${root}.stderr")"
        [ "${stopped}" = yes ]
        [ ! -s "${root}.stderr" ]
        kill -0 "${decoy_pid}"
        [ -S "${root}/decoy.sock" ]
    done
    kill "${decoy_pid}"
}

@test "the agents stop parity fixture covers answered and refused cases, killed and spared (#252)" {
    [ "$(jq '[.cases[] | select(.tool == "answers")] | length' "${AGENTS_STOP_FIXTURE}")" -gt 0 ]
    [ "$(jq '[.cases[] | select(.tool == "refuses")] | length' "${AGENTS_STOP_FIXTURE}")" -gt 0 ]
    [ "$(jq '[.cases[] | select(.tool != "answers" and .tool != "refuses")] | length' "${AGENTS_STOP_FIXTURE}")" -eq 0 ]
    [ "$(jq '[.cases[] | select(.tool == "answers") | .killed] | unique' -c "${AGENTS_STOP_FIXTURE}")" = '[false,true]' ]
    [ "$(jq '[.cases[] | select(.tool == "refuses") | .killed] | unique' -c "${AGENTS_STOP_FIXTURE}")" = '[null,false,true]' ]
    [ "$(jq '[.cases[] | select((.socket | contains("@ROOT@")) | not)] | length' "${AGENTS_STOP_FIXTURE}")" -eq 0 ]
}

# Rewrites the fixture's recorded results from the shell function: AGENTS_STOP_PARITY_REGENERATE names the file to
# write. A case whose "killed" is null stays null.
@test "regenerate the agents stop parity fixture when AGENTS_STOP_PARITY_REGENERATE is set (#252)" {
    [ -n "${AGENTS_STOP_PARITY_REGENERATE:-}" ] || skip "AGENTS_STOP_PARITY_REGENERATE is not set"
    local root count index result results="${BATS_TEST_TMPDIR}/results"
    root=$(_agents_stop_root)
    ORCHESTRATOR_DOTNET_AGENTS=0
    count=$(jq '.cases | length' "${AGENTS_STOP_FIXTURE}")
    : > "${results}"
    for ((index = 0; index < count; index++)); do
        result=$(LC_ALL=C.UTF-8 _stop_parity_call "${root}" "${index}" /dev/null)
        [ "${result%% *}" = ".0" ]
        jq -n -c --arg r "${result#* }" '{killed: ($r == "killed")}' >> "${results}"
    done
    jq --slurpfile r "${results}" \
        '.cases |= [to_entries[] | .value + (if .value.killed == null then {} else $r[.key] end)]' \
        "${AGENTS_STOP_FIXTURE}" > "${AGENTS_STOP_PARITY_REGENERATE}"
}
