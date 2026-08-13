#!/usr/bin/env bats
# Asserts containers/base/development-full/claude-hooks/command-allowlist and
# containers/base/development-full/claude-settings.json's permissions.allow stay
# in sync, per the MANDATORY rule in ai/local/claude-hooks.instructions.md
# ("Keep command-allowlist and claude-settings.json in sync"). Without this,
# permissions.allow is free to silently drift behind command-allowlist - as it
# already had, by the time this test was added (#1313) - with nothing catching
# it until the day --dangerously-skip-permissions is removed and Claude Code
# starts blocking on the missing entries.
#
# Reads static repo files only (no HOME/PATH/git interaction), so this
# intentionally skips the shared setup_isolated_env/cleanup_stubs sandbox
# other test/*.bats files use - REPO_ROOT is already set at source time by
# `load test_helper` below, independent of that sandbox.

load test_helper

ALLOWLIST="${REPO_ROOT}/containers/base/development-full/claude-hooks/command-allowlist"
BLOCKLIST="${REPO_ROOT}/containers/base/development-full/claude-hooks/command-blocklist"
SETTINGS="${REPO_ROOT}/containers/base/development-full/claude-settings.json"

@test "every command-allowlist entry has a matching claude-settings.json permissions.allow entry, and vice versa, unless blocklisted or explicitly denied" {
    local allow_names blocklist_names deny_names settings_allow_names expected missing extra

    # Fail loud, not open: a $(...) pipeline reports its LAST command's exit
    # status, not grep's, so a missing/mistyped path would otherwise make
    # grep silently produce nothing, every set below empty, and the test
    # pass vacuously instead of catching the drift it exists to catch.
    [ -s "${ALLOWLIST}" ] || { echo "ALLOWLIST not found or empty: ${ALLOWLIST}" >&2; return 1; }
    [ -s "${BLOCKLIST}" ] || { echo "BLOCKLIST not found or empty: ${BLOCKLIST}" >&2; return 1; }
    [ -s "${SETTINGS}" ] || { echo "SETTINGS not found or empty: ${SETTINGS}" >&2; return 1; }

    # Same comment-stripping convention as reject-obfuscated-commands itself
    # uses on these exact two files, so an indented comment is handled the
    # same way by both consumers.
    allow_names=$(grep -vE '^[[:space:]]*(#|$)' "${ALLOWLIST}" | sort -u)
    blocklist_names=$(grep -vE '^[[:space:]]*(#|$)' "${BLOCKLIST}" | cut -f1 | sort -u)
    # Whole-command denies only - Bash(name), Bash(name *), or the no-space
    # Bash(name*) style also used elsewhere in this same deny array. A
    # narrow, args-scoped deny like Bash(git config --add *) does NOT mean
    # "git" itself needs no allow entry (git still needs one for its other,
    # permitted invocations); only a deny that blocks the bare command
    # outright, e.g. Bash(sqlcmd *), does.
    #
    # NOTE for whoever implements #1315 (per-tool argument scoping for
    # high-risk denied/allowed tools): a future narrow allow override
    # alongside a whole-command deny for the same tool (e.g. a scoped
    # Bash(rm -v *) allow next to a Bash(rm *) deny) will trip the "extra"
    # check below, since a wholly-denied name is excluded from `expected`.
    # That is a deliberate exception this check cannot yet express - revisit
    # this logic together with whatever scoping design #1315 lands on.
    deny_names=$(jq -r '.permissions.deny[]' "${SETTINGS}" | sed -nE 's/^Bash\(([^ )*]+)( ?\*)?\)$/\1/p' | sort -u)
    # Extraction excludes '*' from the name (so a no-space Bash(name*) allow
    # entry isn't captured as "name*") and strips any leading path (so a
    # path-qualified entry like Bash(/usr/bin/git status) - a form
    # command-allowlist's own header documents as legitimate, matched by
    # basename - reduces to "git" instead of "/usr/bin/git").
    settings_allow_names=$(jq -r '.permissions.allow[]' "${SETTINGS}" | sed -nE 's/^Bash\(([^ )*]+).*/\1/p' | sed -E 's|.*/||' | sort -u)

    # A name genuinely needs a permissions.allow entry only if command-allowlist
    # permits it AND command-blocklist doesn't shadow it into a no-op (blocklist
    # wins - e.g. xargs) AND it isn't wholly denied on purpose (e.g. sqlcmd).
    expected=$(comm -23 <(printf '%s\n' "${allow_names}") <(printf '%s\n' "${blocklist_names}"))
    expected=$(comm -23 <(printf '%s\n' "${expected}") <(printf '%s\n' "${deny_names}"))

    missing=$(comm -23 <(printf '%s\n' "${expected}") <(printf '%s\n' "${settings_allow_names}"))
    # Reverse direction: an allow entry with no corresponding expected name
    # is either stale (its command-allowlist entry was removed but this
    # wasn't) or a contradiction (a blocklisted/denied name re-added to
    # permissions.allow) - both are drift this test exists to catch, not
    # just the missing-entry direction.
    extra=$(comm -13 <(printf '%s\n' "${expected}") <(printf '%s\n' "${settings_allow_names}"))

    # Report both directions in the same run - neither check short-circuits
    # the other, so simultaneous missing+extra drift is never masked behind
    # a single re-run.
    local failed=0

    if [ -n "${missing}" ]; then
        echo "command-allowlist name(s) with no matching claude-settings.json permissions.allow entry - add Bash(<name> ...) there (or, if deliberately excluded, add it to command-blocklist, or to permissions.deny as a whole-command Bash(<name> *) block, and document why in ai/local/claude-hooks.instructions.md):" >&2
        echo "${missing}" >&2
        failed=1
    fi

    if [ -n "${extra}" ]; then
        echo "claude-settings.json permissions.allow name(s) with no command-allowlist entry to justify them (stale after a command-allowlist removal, or a contradiction with command-blocklist/permissions.deny) - remove the entry, or add the name back to command-allowlist if it's still meant to be usable:" >&2
        echo "${extra}" >&2
        failed=1
    fi

    [ "${failed}" -eq 0 ]
}
