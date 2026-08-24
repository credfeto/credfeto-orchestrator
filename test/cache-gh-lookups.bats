#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped

load test_helper

HOOK="${REPO_ROOT}/containers/base/development-full/claude-hooks/cache-gh-lookups"

setup() {
    setup_isolated_env
}

teardown() {
    cleanup_stubs
}

# The rewritten command this hook returns for a matching call - kept in one place so a
# future change to the hook's own rewrite only needs updating here too. Single-quoted
# deliberately: $HOME/$XDG_CACHE_HOME must stay unexpanded literal text, matching what the
# hook itself emits for the shell that eventually runs the rewritten command to expand.
# shellcheck disable=SC2016
expected_rewrite='mkdir -p "${XDG_CACHE_HOME:-$HOME/.cache}/orchestrator/global" && { [ -s "${XDG_CACHE_HOME:-$HOME/.cache}/orchestrator/global/user.json" ] || gh api user --jq '"'"'.login'"'"' > "${XDG_CACHE_HOME:-$HOME/.cache}/orchestrator/global/user.json"; } && cat "${XDG_CACHE_HOME:-$HOME/.cache}/orchestrator/global/user.json"'

assert_rewrite() {
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'"permissionDecision":"allow"'* ]] || [[ "${output}" == *'"permissionDecision": "allow"'* ]]
    local got_cmd
    got_cmd=$(printf '%s' "${output}" | jq -r '.hookSpecificOutput.updatedInput.command')
    [ "${got_cmd}" = "${expected_rewrite}" ]
}

assert_pass_through() {
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "exact single-quoted .login is rewritten" {
    run_hook "gh api user --jq '.login'"
    assert_rewrite
}

@test "exact double-quoted .login is rewritten" {
    run_hook 'gh api user --jq ".login"'
    assert_rewrite
}

@test "exact unquoted .login is rewritten" {
    run_hook "gh api user --jq .login"
    assert_rewrite
}

@test "path-qualified gh is rewritten" {
    run_hook "/usr/bin/gh api user --jq '.login'"
    assert_rewrite
}

@test "sibling tool_input fields survive the rewrite" {
    run_hook "gh api user --jq '.login'" true
    assert_rewrite
    local got_bg
    got_bg=$(printf '%s' "${output}" | jq -r '.hookSpecificOutput.updatedInput.run_in_background')
    [ "${got_bg}" = "true" ]
}

@test "an extra trailing argument does not match" {
    run_hook "gh api user --jq '.login' --hostname github.com"
    assert_pass_through
}

@test "a different jq filter does not match" {
    run_hook "gh api user --jq '.name'"
    assert_pass_through
}

@test "piped into another command does not match" {
    run_hook "gh api user --jq '.login' | cat"
    assert_pass_through
}

@test "redirected does not match" {
    run_hook "gh api user --jq '.login' > out.txt"
    assert_pass_through
}

@test "a second statement in the same command does not match" {
    run_hook "gh api user --jq '.login'; echo done"
    assert_pass_through
}

@test "backgrounded does not match" {
    run_hook "gh api user --jq '.login' &"
    assert_pass_through
}

@test "an unrelated gh subcommand does not match" {
    run_hook "gh pr list"
    assert_pass_through
}

@test "a bare git command does not match" {
    run_hook "git status"
    assert_pass_through
}

@test "empty command does not match" {
    run_hook ""
    assert_pass_through
}

@test "missing shfmt passes through instead of blocking" {
    mkdir -p "${STUB_BIN}/noshfmt"
    ln -s "$(command -v jq)" "${STUB_BIN}/noshfmt/jq"
    ln -s "$(command -v bash)" "${STUB_BIN}/noshfmt/bash"
    ln -s "$(command -v cat)" "${STUB_BIN}/noshfmt/cat"
    local payload
    payload=$(jq -n --arg cmd "gh api user --jq '.login'" '{tool_input: {command: $cmd}}')
    run bash -c 'printf "%s" "$1" | PATH="$2" "$3"' _ "$payload" "${STUB_BIN}/noshfmt" "$HOOK"
    assert_pass_through
}

@test "a command that does not parse as shell passes through instead of blocking" {
    run_hook "if true; then gh api user --jq '.login'"
    assert_pass_through
}
