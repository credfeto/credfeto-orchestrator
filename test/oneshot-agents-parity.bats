#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are read by the sourced oneshot functions, where shellcheck cannot trace them

# Golden parity cases for the read-only ssh-agent query in the .NET rewrite (#252). test/fixtures/agents-parity.json
# holds, for each case, what SSH_AUTH_SOCK names ("agent": a "reply" agent that answers every connection with the
# bytes in "reply", hex, length header included; nothing there ("missing"); a regular "file"; a "directory"; a "stale"
# socket nobody listens on; or a "long-path" longer than a socket address holds) and the status ssh_agent_key_state
# returned in bash, which is ssh-add -l's. This file checks the shell function against the fixture, and
# Credfeto.Orchestrator.Agents.Tests (src/) serves the same replies to the tool and checks it against the same file. A
# case marked "refuses" is one the tool must refuse (a key it does not judge, or a path it leaves to ssh-add), so bash
# answers it. The replies only ever answer a key listing: no case signs anything or holds a private key.
#
# The fake agent is a few lines of python3, which the preload_ssh_keys tests already use for their sockets.
# To regenerate the recorded statuses after a change to the cases, run the last test with AGENTS_PARITY_REGENERATE set
# to the file to write; it keeps the fixture's cases and records what the shell function returns for each.

bats_require_minimum_version 1.5.0

load test_helper
load oneshot_helper

AGENTS_FIXTURE="${BATS_TEST_DIRNAME}/fixtures/agents-parity.json"

# The shared teardown, after stopping any agent a failed test left running
teardown() {
    if [ -f "${BATS_TEST_TMPDIR}/real-agent.pid" ]; then
        kill -9 "$(cat "${BATS_TEST_TMPDIR}/real-agent.pid")" 2> /dev/null || true
    fi
    _agents_parity_stop "${BATS_TEST_TMPDIR}/root/case"
    cleanup_stubs
    cleanup_repo_fixtures
}

# Reads one 5-byte request a connection, logs it as hex to the file in argv[3], answers with the bytes in argv[2] (hex)
# and closes, for every connection until it is killed
AGENTS_FAKE_AGENT='
import socket
import sys

path, reply, log = sys.argv[1], bytes.fromhex(sys.argv[2]), sys.argv[3]
server = socket.socket(socket.AF_UNIX)
server.bind(path)
server.listen(8)
while True:
    connection, _ = server.accept()
    request = b""
    while len(request) < 5:
        chunk = connection.recv(5 - len(request))
        if not chunk:
            break
        request += chunk
    with open(log, "a", encoding="ascii") as requests:
        requests.write(request.hex() + "\n")
    try:
        connection.sendall(reply)
    except OSError:
        pass
    connection.close()
'

# Prints field $2 (a jq path) of case $1
_agents_case() {
    jq -j --argjson i "$1" ".cases[\$i]$2" "${AGENTS_FIXTURE}"
}

# Puts case $2's agent in the empty directory $1 and prints the path SSH_AUTH_SOCK is to name. A reply agent runs in
# the background, its pid in $1/agent.pid, logging each request to $1/requests.
_agents_parity_agent() {
    local dir="$1" index="$2" socket kind attempt
    socket="${dir}/agent.sock"
    kind=$(_agents_case "${index}" '.agent')
    case "${kind}" in
        reply)
            python3 -c "${AGENTS_FAKE_AGENT}" "${socket}" "$(_agents_case "${index}" '.reply')" "${dir}/requests" \
                < /dev/null > /dev/null 2>&1 3>&- &
            printf '%s' "$!" > "${dir}/agent.pid"
            for ((attempt = 0; attempt < 200; attempt++)); do
                [ -S "${socket}" ] && break
                sleep 0.05
            done
            [ -S "${socket}" ] || return 1
            ;;
        missing) ;;
        file) : > "${socket}" ;;
        directory) mkdir "${socket}" ;;
        stale) python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "${socket}" ;;
        long-path) socket="${dir}/$(printf 'x%.0s' {1..120})" ;;
        *) return 1 ;;
    esac
    printf '%s' "${socket}"
}

# Stops the reply agent in directory $1, if there is one
_agents_parity_stop() {
    if [ -f "$1/agent.pid" ]; then
        kill "$(cat "$1/agent.pid")" 2> /dev/null || true
        rm -f "$1/agent.pid"
    fi
}

# Runs ssh_agent_key_state against case $2's agent, set up in directory $1 (emptied first), and prints what it printed,
# then a dot and its status; its stderr goes to $3, and the agent's requests are left in $1/requests
_agents_parity_call() {
    local dir="$1" index="$2" stderr_file="$3" socket
    rm -rf "${dir}"
    mkdir -p "${dir}"
    socket=$(_agents_parity_agent "${dir}" "${index}") || return 1
    (
        export SSH_AUTH_SOCK="${socket}"
        ssh_agent_key_state
        printf '.%s' "$?"
    ) 2> "${stderr_file}"
    _agents_parity_stop "${dir}"
}

# Runs every case, as the caller has set ORCHESTRATOR_DOTNET_AGENTS, and prints one line for each whose output or
# status differs from the fixture, or where the agent did not get exactly one identities request. Switched on, it
# also checks that the tool answered exactly the "answers" cases (lib/podman warns when bash answers instead) and
# that an answered case's stderr is empty, as bash's is; a refused case's agent is asked twice, by the tool, then by
# ssh-add.
_check_agents_parity_cases() {
    local root="$1" count index name tool result expected_status failures=0 warned
    count=$(jq '.cases | length' "${AGENTS_FIXTURE}")
    [ "${count}" -gt 0 ] || return 1
    for ((index = 0; index < count; index++)); do
        name=$(_agents_case "${index}" '.name')
        tool=$(_agents_case "${index}" '.tool')
        expected_status=$(_agents_case "${index}" '.status')
        result=$(_agents_parity_call "${root}/case" "${index}" "${root}/stderr")
        if [ "${result}" != ".${expected_status}" ]; then
            printf 'case %d (%s): printed and returned [%s], expected [.%s]\n' "${index}" "${name}" "${result}" \
                "${expected_status}"
            failures=$((failures + 1))
        fi
        warned=answers
        if [ "${ORCHESTRATOR_DOTNET_AGENTS}" = 1 ]; then
            if grep -q 'asking ssh-add in bash instead' "${root}/stderr"; then
                warned=refuses
            fi
            if [ "${warned}" != "${tool}" ]; then
                printf 'case %d (%s): the tool %s it, not %s\n' "${index}" "${name}" "${warned}" "${tool}"
                failures=$((failures + 1))
            fi
        fi
        if [ "${warned}" = answers ] && [ -s "${root}/stderr" ]; then
            printf 'case %d (%s): wrote to stderr: %s\n' "${index}" "${name}" "$(cat "${root}/stderr")"
            failures=$((failures + 1))
        fi
        if [ "$(_agents_case "${index}" '.agent')" = reply ] && [ "${warned}" = answers ] \
            && [ "$(cat "${root}/case/requests")" != 000000010b ]; then
            printf 'case %d (%s): the agent was sent [%s]\n' "${index}" "${name}" "$(cat "${root}/case/requests")"
            failures=$((failures + 1))
        fi
    done
    [ "${failures}" -eq 0 ]
}

# The locales the cases run in: C.UTF-8, and en_GB.UTF-8 as well where the host has it
_agents_parity_locales() {
    printf 'C.UTF-8\n'
    if locale -a 2> /dev/null | grep -qix 'en_GB.utf-\?8'; then
        printf 'en_GB.UTF-8\n'
    fi
}

# Starts a real ssh-agent at $1 and prints its pid
_agents_real_agent() {
    local env
    env=$(ssh-agent -a "$1" 3>&- 2> /dev/null) || return 1
    env=${env#*SSH_AGENT_PID=}
    printf '%s' "${env%%;*}"
}

@test "ssh_agent_key_state returns what the fixture records for every agents parity case (#252)" {
    command -v python3 > /dev/null || skip "python3 is not installed"
    command -v ssh-add > /dev/null || skip "ssh-add is not installed"
    local root="${BATS_TEST_TMPDIR}/root" locale
    mkdir -p "${root}"
    ORCHESTRATOR_DOTNET_AGENTS=0
    while IFS= read -r locale; do
        LC_ALL="${locale}" run _check_agents_parity_cases "${root}"
        if [ "${status}" -ne 0 ]; then
            printf '%s: %s\n' "${locale}" "${output}"
        fi
        [ "${status}" -eq 0 ]
    done < <(_agents_parity_locales)
}

# The end-to-end check the plan asks for before each phase's PR: the same cases through the freshly built tool, given
# as ORCHESTRATOR_PARITY_CMD (a wrapper with an absolute path, since these tests replace HOME). Skipped when it is not
# set, as in CI, which has no tool on PATH.
@test "every agents parity case returns the same through ORCHESTRATOR_CMD when switched on (#252)" {
    [ -n "${ORCHESTRATOR_PARITY_CMD:-}" ] || skip "ORCHESTRATOR_PARITY_CMD is not set"
    local root="${BATS_TEST_TMPDIR}/root" locale
    mkdir -p "${root}"
    ORCHESTRATOR_DOTNET_AGENTS=1
    ORCHESTRATOR_CMD="${ORCHESTRATOR_PARITY_CMD}"
    while IFS= read -r locale; do
        LC_ALL="${locale}" run _check_agents_parity_cases "${root}"
        if [ "${status}" -ne 0 ]; then
            printf '%s: %s\n' "${locale}" "${output}"
        fi
        [ "${status}" -eq 0 ]
    done < <(_agents_parity_locales)
}

# A real ssh-agent, empty, then holding keys ssh-keygen made in the test directory, then killed: switched on, the tool
# answers as ssh-add does, and leaves an agent holding only an ECDSA key to ssh-add
@test "a real ssh-agent gets the same answer through ORCHESTRATOR_CMD as from ssh-add (#252)" {
    [ -n "${ORCHESTRATOR_PARITY_CMD:-}" ] || skip "ORCHESTRATOR_PARITY_CMD is not set"
    command -v ssh-agent > /dev/null || skip "ssh-agent is not installed"
    local dir="${BATS_TEST_TMPDIR}/real" pid step off on
    mkdir -p "${dir}"
    export SSH_AUTH_SOCK="${dir}/agent.sock"
    pid=$(_agents_real_agent "${SSH_AUTH_SOCK}")
    printf '%s' "${pid}" > "${BATS_TEST_TMPDIR}/real-agent.pid"
    ssh-keygen -q -N '' -C parity -t ed25519 -f "${dir}/ed25519"
    ssh-keygen -q -N '' -C parity -t rsa -b 2048 -f "${dir}/rsa"
    ssh-keygen -q -N '' -C parity -t ecdsa -f "${dir}/ecdsa"
    ORCHESTRATOR_CMD="${ORCHESTRATOR_PARITY_CMD}"
    for step in empty ecdsa ed25519 rsa killed; do
        case "${step}" in
            ecdsa) ssh-add -q "${dir}/ecdsa" 2> /dev/null ;;
            ed25519)
                ssh-add -q -D 2> /dev/null
                ssh-add -q "${dir}/ed25519" 2> /dev/null
                ;;
            rsa) ssh-add -q "${dir}/rsa" 2> /dev/null ;;
            killed) kill -9 "${pid}" ;;
        esac
        off=0
        on=0
        ORCHESTRATOR_DOTNET_AGENTS=0 ssh_agent_key_state 2> "${dir}/off.err" || off=$?
        ORCHESTRATOR_DOTNET_AGENTS=1 ssh_agent_key_state 2> "${dir}/on.err" || on=$?
        printf '%s: off %s, on %s, stderr [%s]\n' "${step}" "${off}" "${on}" "$(cat "${dir}/on.err")"
        [ "${on}" -eq "${off}" ]
        if [ "${step}" = ecdsa ]; then
            grep -q 'asking ssh-add in bash instead' "${dir}/on.err"
        else
            [ ! -s "${dir}/on.err" ]
        fi
    done
    [ "${off}" -eq 2 ]
}

@test "the agents parity fixture covers every agent kind, answered and refused, each with a status (#252)" {
    local kind
    for kind in reply missing file directory stale long-path; do
        [ "$(jq --arg k "${kind}" '[.cases[] | select(.agent == $k)] | length' "${AGENTS_FIXTURE}")" -gt 0 ]
    done
    [ "$(jq '[.cases[] | select(.tool == "answers")] | length' "${AGENTS_FIXTURE}")" -gt 0 ]
    [ "$(jq '[.cases[] | select(.tool == "refuses")] | length' "${AGENTS_FIXTURE}")" -gt 0 ]
    [ "$(jq '[.cases[] | select(.tool != "answers" and .tool != "refuses")] | length' "${AGENTS_FIXTURE}")" -eq 0 ]
    [ "$(jq '[.cases[] | .status] | unique' -c "${AGENTS_FIXTURE}")" = '[0,1,2]' ]
}

# Rewrites the fixture's recorded statuses from the shell function: AGENTS_PARITY_REGENERATE names the file to write.
@test "regenerate the agents parity fixture when AGENTS_PARITY_REGENERATE is set (#252)" {
    [ -n "${AGENTS_PARITY_REGENERATE:-}" ] || skip "AGENTS_PARITY_REGENERATE is not set"
    local root="${BATS_TEST_TMPDIR}/root" count index result results="${BATS_TEST_TMPDIR}/results"
    mkdir -p "${root}"
    ORCHESTRATOR_DOTNET_AGENTS=0
    count=$(jq '.cases | length' "${AGENTS_FIXTURE}")
    : > "${results}"
    for ((index = 0; index < count; index++)); do
        result=$(LC_ALL=C.UTF-8 _agents_parity_call "${root}/case" "${index}" /dev/null)
        [ "${result%.*}" = "" ]
        jq -n -c --argjson status "${result##*.}" '{status: $status}' >> "${results}"
    done
    jq --slurpfile r "${results}" '.cases |= [to_entries[] | .value + $r[.key]]' "${AGENTS_FIXTURE}" \
        > "${AGENTS_PARITY_REGENERATE}"
}
