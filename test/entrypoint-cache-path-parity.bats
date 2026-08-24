#!/usr/bin/env bats
# Asserts entrypoint.sh's seed_orchestrator_cache and the cache-gh-lookups hook's rewritten
# command resolve the orchestrator cache directory from the exact same literal shell
# expression (#1380). Both files' own comments claim this is "kept byte-identical" - this test
# is what actually enforces that claim instead of leaving it to be caught by a human noticing
# a stale comment after one side is edited and the other isn't.

load test_helper

ENTRYPOINT="${REPO_ROOT}/containers/agent/entrypoint.sh"
HOOK="${REPO_ROOT}/containers/base/development-full/claude-hooks/cache-gh-lookups"

# The shell expression both files must resolve the same way. Deliberately hardcoded here
# rather than extracted from one file and compared to the other: a change that edits both
# files identically (e.g. widening the fallback) still needs this test's own expectation
# updated, which is the point - a silent drift between the two is what must fail, not an
# intentional, matching change to both.
# shellcheck disable=SC2016
expected_expr='${XDG_CACHE_HOME:-${HOME}/.cache}/orchestrator'

@test "entrypoint.sh's cache_root uses the expected XDG_CACHE_HOME/HOME fallback expression" {
    grep -qF "${expected_expr}" "${ENTRYPOINT}"
}

@test "cache-gh-lookups' rewritten command uses the same XDG_CACHE_HOME/HOME fallback expression" {
    grep -qF "${expected_expr}" "${HOOK}"
}
