#!/usr/bin/env bats
# Asserts containers/base/development-full/claude-hooks/command-allowlist and
# containers/base/development-full/claude-settings.json's permissions.allow stay
# in sync, per the MANDATORY rule in ai/local/claude-hooks.instructions.md
# ("Keep command-allowlist and claude-settings.json in sync"). Without this,
# permissions.allow is free to silently drift behind command-allowlist - as it
# already had, by the time this test was added (#1313) - with nothing catching
# it until the day --dangerously-skip-permissions is removed and Claude Code
# starts blocking on the missing entries.

load test_helper

ALLOWLIST="${REPO_ROOT}/containers/base/development-full/claude-hooks/command-allowlist"
BLOCKLIST="${REPO_ROOT}/containers/base/development-full/claude-hooks/command-blocklist"
SETTINGS="${REPO_ROOT}/containers/base/development-full/claude-settings.json"

setup() {
    setup_isolated_env
}

teardown() {
    cleanup_stubs
}

@test "every command-allowlist entry has a matching claude-settings.json permissions.allow entry, unless blocklisted or explicitly denied" {
    local allow_names blocklist_names deny_names settings_allow_names expected missing

    allow_names=$(grep -vE '^(#|$)' "${ALLOWLIST}" | sort -u)
    blocklist_names=$(grep -vE '^(#|$)' "${BLOCKLIST}" | cut -f1 | sort -u)
    deny_names=$(jq -r '.permissions.deny[]' "${SETTINGS}" | sed -nE 's/^Bash\(([^ )]+).*/\1/p' | sort -u)
    settings_allow_names=$(jq -r '.permissions.allow[]' "${SETTINGS}" | sed -nE 's/^Bash\(([^ )]+).*/\1/p' | sort -u)

    # A name genuinely needs a permissions.allow entry only if command-allowlist
    # permits it AND command-blocklist doesn't shadow it into a no-op (blocklist
    # wins - e.g. xargs) AND it isn't explicitly denied on purpose (e.g. sqlcmd).
    expected=$(comm -23 <(printf '%s\n' "${allow_names}") <(printf '%s\n' "${blocklist_names}"))
    expected=$(comm -23 <(printf '%s\n' "${expected}") <(printf '%s\n' "${deny_names}"))

    missing=$(comm -23 <(printf '%s\n' "${expected}") <(printf '%s\n' "${settings_allow_names}"))

    if [ -n "${missing}" ]; then
        echo "command-allowlist name(s) with no matching claude-settings.json permissions.allow entry - add Bash(<name> *) there (or, if deliberately excluded, add it to command-blocklist/permissions.deny and document why in ai/local/claude-hooks.instructions.md):" >&2
        echo "${missing}" >&2
        return 1
    fi
}
