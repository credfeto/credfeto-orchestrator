#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped

load test_helper

HOOK="${REPO_ROOT}/containers/base/development-full/claude-hooks/block-config-skills"
MANAGED_SETTINGS="${REPO_ROOT}/containers/base/development-full/claude-managed-settings.json"

setup() {
    setup_isolated_env
    # The hook's own list, so the tests and the parity check below cannot drift from it.
    read -r -a CONFIG_SKILLS < <(sed -n 's/^CONFIG_SKILLS=(\(.*\))$/\1/p' "${HOOK}")
    [ "${#CONFIG_SKILLS[@]}" -gt 0 ] || { echo "could not read CONFIG_SKILLS from ${HOOK}" >&2; return 1; }
}

teardown() {
    cleanup_stubs
}

# Pipes a Claude Code PreToolUse payload for a Skill call into the hook under test.
# status 0 = allowed, 2 = blocked.
run_skill() {
    local payload
    payload=$(jq -n --arg skill "$1" '{tool_name: "Skill", tool_input: {skill: $skill}}')
    run bash -c 'printf "%s" "$1" | "$2"' _ "${payload}" "${HOOK}"
}

@test "each config-editing skill is blocked, naming it and stating it never ran" {
    local skill
    for skill in "${CONFIG_SKILLS[@]}"; do
        run_skill "${skill}"
        [ "${status}" -eq 2 ] || { echo "did not block ${skill}: ${output}" >&2; return 1; }
        [[ "${output}" == *"the ${skill} skill changes Claude Code configuration"* ]] || { echo "wrong message for ${skill}: ${output}" >&2; return 1; }
        [[ "${output}" == *'command did not run'* ]] || { echo "missing 'command did not run' for ${skill}: ${output}" >&2; return 1; }
    done
}

@test "a config-editing skill is blocked whatever plugin prefix it is invoked with" {
    local skill
    for skill in anthropic-skills:skill-creator other-plugin:update-config a:b:keybindings-help; do
        run_skill "${skill}"
        [ "${status}" -eq 2 ] || { echo "did not block ${skill}: ${output}" >&2; return 1; }
    done
}

@test "ordinary skills are allowed" {
    local skill
    for skill in credfeto-git-commit credfeto-code-style anthropic-skills:pdf update-configuration initialise; do
        run_skill "${skill}"
        [ "${status}" -eq 0 ] || { echo "did not allow ${skill}: ${output}" >&2; return 1; }
    done
}

@test "the hook blocks exactly the skills the managed settings deny with a Skill(...) rule" {
    # A deny may carry a plugin prefix (anthropic-skills:skill-creator); the hook matches the
    # part after the last ':', so that is what is compared, in both directions.
    run diff <(printf '%s\n' "${CONFIG_SKILLS[@]}" | sort) \
        <(jq -r '.permissions.deny[] | capture("^Skill\\((?<s>.*)\\)$").s | split(":") | last' "${MANAGED_SETTINGS}" | sort)
    [ "${status}" -eq 0 ] || { echo "hook list (<) and Skill(...) denies (>) differ: ${output}" >&2; return 1; }
    jq -r '.permissions.deny[]' "${MANAGED_SETTINGS}" | grep -qxF 'Agent(statusline-setup)'
}

@test "the managed settings register this hook against the Skill matcher" {
    run jq -r '.hooks.PreToolUse[] | select(.matcher == "Skill") | .hooks[] | .command' "${MANAGED_SETTINGS}"
    [ "${status}" -eq 0 ]
    [ "${output}" = '/etc/claude-code/hooks/block-config-skills' ]
}

@test "an empty skill name is blocked (fail closed)" {
    run_skill ""
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'no skill name'* ]]
}

@test "a payload with no skill field is blocked (fail closed)" {
    run bash -c 'printf "%s" "{}" | "$1"' _ "${HOOK}"
    [ "${status}" -eq 2 ]
}

@test "a payload that does not parse as JSON is blocked (fail closed)" {
    run bash -c 'printf "not json" | "$1"' _ "${HOOK}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'could not be parsed by jq'* ]]
}

@test "missing jq is blocked (fail closed)" {
    mkdir -p "${STUB_BIN}/nojq"
    run bash -c 'printf "%s" "{}" | PATH="$1" "$(command -v bash)" "$2"' _ "${STUB_BIN}/nojq" "${HOOK}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'jq is not available'* ]]
}
