#!/usr/bin/env bats
# shellcheck disable=SC2329  # functions in @test bodies are invoked indirectly via 'run'
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are used inside run() subshells where shellcheck cannot trace them
#
# The agent container's memory limit (#2089): resolve_agent_container_memory and its use for
# --memory and --memory-swap in prepare_claude_container_args (lib/podman), and the two .env keys
# load_env_config (lib/core) reads. The pre-check plus agent launch case is in precheck.bats.

bats_require_minimum_version 1.5.0

load test_helper
load oneshot_helper

# Writes a fake meminfo with the given MemTotal in kB and points HOST_MEMINFO_PATH at it.
fake_meminfo() {
    HOST_MEMINFO_PATH="${TEST_TMP}/meminfo"
    printf 'MemTotal:       %s kB\nMemFree:         1024000 kB\nMemAvailable:    2048000 kB\n' "$1" > "${HOST_MEMINFO_PATH}"
}

# A podman stub that accepts every call, for prepare_claude_container_args' secret calls.
stub_accepting_podman() {
    printf '#!/usr/bin/env bash\nexit 0\n' > "${STUB_BIN}/podman"
    chmod +x "${STUB_BIN}/podman"
}

# Prints the PODMAN_RUN_ARGS prepare_claude_container_args builds, one per line, in a subshell
# so its EXIT trap cleans up there. An optional argument is passed on as the mode (precheck).
container_args() {
    (
        prepare_claude_container_args "# mock CLAUDE.md" "" "orchestrator-${OWNER}" "Issue" "42" "$@" 2> /dev/null
        printf '%s\n' "${PODMAN_RUN_ARGS[@]}"
    )
}

@test "a 7.6 GiB host gets MemTotal less the fixed 1536 MiB reserve (#2089)" {
    # 7.6 GiB = 7969178 kB = 7782 MiB; 10% is 778 MiB, below the 1536 MiB reserve.
    fake_meminfo 7969178
    resolve_agent_container_memory 2> /dev/null
    [ "${AGENT_CONTAINER_MEMORY}" = "6246m" ]
}

@test "a large host reserves 10% of MemTotal when that is more than the fixed reserve (#2089)" {
    # 32 GiB = 32768 MiB; 10% is 3276 MiB, above 1536.
    fake_meminfo 33554432
    resolve_agent_container_memory 2> /dev/null
    [ "${AGENT_CONTAINER_MEMORY}" = "29492m" ]
}

@test "ORCHESTRATOR_CONTAINER_MEMORY_RESERVE_MB sets the fixed reserve (#2089)" {
    # 16 GiB = 16384 MiB; 4096 is above 10% (1638).
    fake_meminfo 16777216
    ORCHESTRATOR_CONTAINER_MEMORY_RESERVE_MB=4096
    resolve_agent_container_memory 2> /dev/null
    [ "${AGENT_CONTAINER_MEMORY}" = "12288m" ]
}

@test "an invalid ORCHESTRATOR_CONTAINER_MEMORY_RESERVE_MB warns and uses 1536 (#2089)" {
    fake_meminfo 7969178
    ORCHESTRATOR_CONTAINER_MEMORY_RESERVE_MB="1.5g"
    run --separate-stderr resolve_agent_container_memory
    [ "${status}" -eq 0 ]
    [[ "${stderr}" == *"ORCHESTRATOR_CONTAINER_MEMORY_RESERVE_MB must be a whole number of MiB; ignoring '1.5g' and using 1536"* ]]
    [[ "${stderr}" == *"Agent container memory limit: 6246m"* ]]
}

@test "a small host never gets less than the 2048 MiB floor (#2089)" {
    # 3 GiB = 3072 MiB; 3072 - 1536 = 1536, below the floor.
    fake_meminfo 3145728
    resolve_agent_container_memory 2> /dev/null
    [ "${AGENT_CONTAINER_MEMORY}" = "2048m" ]
}

@test "ORCHESTRATOR_CONTAINER_MEMORY overrides the calculation and is used as given (#2089)" {
    fake_meminfo 7969178
    ORCHESTRATOR_CONTAINER_MEMORY="4g"
    run --separate-stderr resolve_agent_container_memory
    [ "${status}" -eq 0 ]
    [[ "${stderr}" == *"Agent container memory limit: 4g (set by ORCHESTRATOR_CONTAINER_MEMORY)"* ]]
    resolve_agent_container_memory 2> /dev/null
    [ "${AGENT_CONTAINER_MEMORY}" = "4g" ]
}

@test "the override needs no readable meminfo (#2089)" {
    HOST_MEMINFO_PATH="${TEST_TMP}/no-such-meminfo"
    ORCHESTRATOR_CONTAINER_MEMORY="6144m"
    run --separate-stderr resolve_agent_container_memory
    [ "${status}" -eq 0 ]
    [[ "${stderr}" != *"Could not read MemTotal"* ]]
    resolve_agent_container_memory 2> /dev/null
    [ "${AGENT_CONTAINER_MEMORY}" = "6144m" ]
}

@test "an invalid ORCHESTRATOR_CONTAINER_MEMORY warns and sizes the limit from the host (#2089)" {
    fake_meminfo 7969178
    ORCHESTRATOR_CONTAINER_MEMORY="lots"
    run --separate-stderr resolve_agent_container_memory
    [ "${status}" -eq 0 ]
    [[ "${stderr}" == *"ORCHESTRATOR_CONTAINER_MEMORY must be a podman memory size such as 4g or 6144m; ignoring 'lots'"* ]]
    resolve_agent_container_memory 2> /dev/null
    [ "${AGENT_CONTAINER_MEMORY}" = "6246m" ]
}

@test "a missing meminfo keeps the fixed 12g limit and warns (#2089)" {
    HOST_MEMINFO_PATH="${TEST_TMP}/no-such-meminfo"
    run --separate-stderr resolve_agent_container_memory
    [ "${status}" -eq 0 ]
    [[ "${stderr}" == *"Could not read MemTotal from ${TEST_TMP}/no-such-meminfo; using the fixed agent container memory limit 12g"* ]]
    resolve_agent_container_memory 2> /dev/null
    [ "${AGENT_CONTAINER_MEMORY}" = "12g" ]
}

@test "a meminfo without a usable MemTotal line keeps the fixed 12g limit and warns (#2089)" {
    HOST_MEMINFO_PATH="${TEST_TMP}/meminfo"
    printf 'MemFree:         1024000 kB\nMemTotal:       unknown kB\n' > "${HOST_MEMINFO_PATH}"
    run --separate-stderr resolve_agent_container_memory
    [ "${status}" -eq 0 ]
    [[ "${stderr}" == *"Could not read MemTotal from ${HOST_MEMINFO_PATH}"* ]]
    resolve_agent_container_memory 2> /dev/null
    [ "${AGENT_CONTAINER_MEMORY}" = "12g" ]
}

@test "the limit is logged once with how it was worked out, and kept for the rest of the run (#2089)" {
    fake_meminfo 7969178
    resolve_agent_container_memory 2> "${TEST_TMP}/log"
    # A later change to the host figure does not move the limit within one run.
    fake_meminfo 33554432
    resolve_agent_container_memory 2>> "${TEST_TMP}/log"
    [ "$(grep -c 'Agent container memory limit:' "${TEST_TMP}/log")" -eq 1 ]
    grep -qF 'Agent container memory limit: 6246m (host MemTotal 7782 MiB, reserve 1536 MiB, floor 2048 MiB)' "${TEST_TMP}/log"
    [ "${AGENT_CONTAINER_MEMORY}" = "6246m" ]
}

@test "the agent container gets the host-sized limit for both --memory and --memory-swap (#2089)" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    stub_accepting_podman
    fake_meminfo 7969178
    run container_args
    [ "${status}" -eq 0 ]
    [ "$(grep -cx -- '--memory=6246m' <<< "${output}")" -eq 1 ]
    [ "$(grep -cx -- '--memory-swap=6246m' <<< "${output}")" -eq 1 ]
    [ "$(grep -c -- '12g' <<< "${output}")" -eq 0 ]
}

@test "the pre-check container gets the same limit for both --memory and --memory-swap (#2089)" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    stub_accepting_podman
    fake_meminfo 7969178
    run container_args precheck
    [ "${status}" -eq 0 ]
    [ "$(grep -cx -- '--memory=6246m' <<< "${output}")" -eq 1 ]
    [ "$(grep -cx -- '--memory-swap=6246m' <<< "${output}")" -eq 1 ]
}

@test "the override and the fallback reach --memory and --memory-swap alike (#2089)" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    stub_accepting_podman
    ORCHESTRATOR_CONTAINER_MEMORY="4g"
    run container_args
    [ "$(grep -cx -- '--memory=4g' <<< "${output}")" -eq 1 ]
    [ "$(grep -cx -- '--memory-swap=4g' <<< "${output}")" -eq 1 ]

    ORCHESTRATOR_CONTAINER_MEMORY=""
    HOST_MEMINFO_PATH="${TEST_TMP}/no-such-meminfo"
    run container_args
    [ "$(grep -cx -- '--memory=12g' <<< "${output}")" -eq 1 ]
    [ "$(grep -cx -- '--memory-swap=12g' <<< "${output}")" -eq 1 ]
}

@test "load_env_config reads ORCHESTRATOR_CONTAINER_MEMORY and ORCHESTRATOR_CONTAINER_MEMORY_RESERVE_MB from .env (#2089)" {
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf 'ORCHESTRATOR_CONTAINER_MEMORY="5g"\nORCHESTRATOR_CONTAINER_MEMORY_RESERVE_MB=2048\n' \
        > "${XDG_CONFIG_HOME}/orchestrator/.env"
    load_env_config
    [ "${ORCHESTRATOR_CONTAINER_MEMORY}" = "5g" ]
    [ "${ORCHESTRATOR_CONTAINER_MEMORY_RESERVE_MB}" = "2048" ]
}
