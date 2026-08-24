#!/usr/bin/env bats
# Asserts entrypoint.sh's seed_orchestrator_cache and the cache-gh-lookups hook's rewritten
# command resolve the orchestrator cache directory from the exact same literal shell
# expression (#1380). Both files' own comments claim this is "kept byte-identical" - this test
# is what actually enforces that claim instead of leaving it to be caught by a human noticing
# a stale comment after one side is edited and the other isn't.

load test_helper

ENTRYPOINT="${REPO_ROOT}/containers/agent/entrypoint.sh"
HOOK="${REPO_ROOT}/containers/base/development-full/claude-hooks/cache-gh-lookups"

# The exact code lines both files must contain, anchored on each side's own variable-
# assignment prefix (cache_root=/cache_dir=) rather than a bare substring - a plain substring
# search would also match this file's own comments and either hook's/entrypoint's *comment*
# text, which quotes the same expression in prose, letting a stale comment (with the real code
# line already changed) pass. Deliberately hardcoded here rather than extracted from one file
# and compared to the other: a change that edits both files identically (e.g. widening the
# fallback) still needs this test's own expectation updated, which is the point - a silent
# drift between the two is what must fail, not an intentional, matching change to both.
# shellcheck disable=SC2016
entrypoint_expr='cache_root="${XDG_CACHE_HOME:-${HOME}/.cache}/orchestrator"'
# shellcheck disable=SC2016
hook_expr='cache_dir="${XDG_CACHE_HOME:-${HOME}/.cache}/orchestrator/global"'

@test "entrypoint.sh's cache_root uses the expected XDG_CACHE_HOME/HOME fallback expression" {
    grep -qF "${entrypoint_expr}" "${ENTRYPOINT}"
}

@test "cache-gh-lookups' rewritten command uses the same XDG_CACHE_HOME/HOME fallback expression" {
    grep -qF "${hook_expr}" "${HOOK}"
}
