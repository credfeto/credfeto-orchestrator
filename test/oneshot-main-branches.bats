#!/usr/bin/env bats
# shellcheck disable=SC2329  # functions in @test bodies are invoked indirectly via 'run'
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are used inside run() subshells where shellcheck cannot trace them

bats_require_minimum_version 1.5.0

load test_helper
load oneshot_helper

# --- recover_orphaned_branch unit tests ----------------------------------------

# Regression guard for the tests below (#1169 incident): they exercise real git
# plumbing (clone/commit/push/rebase) against a local bare "remote" fixture using the
# real git binary rather than a stub. If REPO_WORK_DIR or a remote URL were ever
# misresolved for any reason, the only acceptable failure mode is the git command
# failing fast — never a real network call reaching a real remote. Confirms
# setup_isolated_env's GIT_ALLOW_PROTOCOL=file guard actually blocks a non-file
# transport before any test below is trusted to run "push origin" for real.
@test "setup_isolated_env blocks git push over ssh/https (fail-closed network guard)" {
    local scratch_repo="${TEST_TMP}/scratch-repo"
    git init -q "${scratch_repo}"
    git -C "${scratch_repo}" config core.hooksPath /dev/null
    git -C "${scratch_repo}" remote add origin "git@github.com:credfeto/credfeto-orchestrator.git"
    printf 'x\n' > "${scratch_repo}/f"
    git -C "${scratch_repo}" add f
    git -C "${scratch_repo}" -c commit.gpgsign=false -c user.email=t@example.com -c user.name=Test commit -q -m init

    run git -C "${scratch_repo}" push origin HEAD:refs/heads/should-never-reach-a-real-remote
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"transport 'ssh' not allowed"* ]]
}

# Regression guard (#1185 incident): a git command run with -C (or cwd) pointed at a directory
# nested inside this real repo but WITHOUT its own .git (e.g. make_repo_fixture_dir's
# test/.fixture.XXXXXX) must never silently discover and operate on this repo's real .git by
# walking up parent directories — that let a stripped-down test session run real
# `git switch main` against the enclosing repo on every loop iteration for hours. Confirms
# setup_isolated_env's GIT_CEILING_DIRECTORIES=REPO_ROOT guard actually stops the walk.
@test "setup_isolated_env blocks git repo-discovery from escaping a fixture into the real repo" {
    local fixture_dir="${REPO_ROOT}/test/.fixture.ceiling-guard-$$"
    mkdir -p "${fixture_dir}"
    REPO_FIXTURE_DIRS+=("${fixture_dir}")

    run git -C "${fixture_dir}" rev-parse --show-toplevel
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"not a git repository"* ]]
}

# Sets up a local bare "remote" and clones it into REPO_WORK_DIR so that
# recover_orphaned_branch can perform real git operations without network calls.
@test "recover_orphaned_branch returns 1 when repo directory does not exist" {
    REPO_WORK_DIR="${TEST_TMP}/nonexistent/repo"
    run recover_orphaned_branch
    [ "${status}" -eq 1 ]
}

@test "recover_orphaned_branch returns 1 when repo is on main" {
    setup_local_git_remote >/dev/null
    run recover_orphaned_branch
    [ "${status}" -eq 1 ]
}

@test "recover_orphaned_branch returns 1 when branch still exists on remote" {
    local remote_dir
    remote_dir=$(setup_local_git_remote)
    git -C "${REPO_WORK_DIR}" checkout -b feature/active >/dev/null 2>&1
    git -C "${REPO_WORK_DIR}" -c commit.gpgsign=false commit --allow-empty -m "work" >/dev/null 2>&1
    git -C "${REPO_WORK_DIR}" push origin feature/active >/dev/null 2>&1

    run recover_orphaned_branch
    [ "${status}" -eq 1 ]

    local current_branch
    current_branch=$(git -C "${REPO_WORK_DIR}" branch --show-current)
    [ "${current_branch}" = "feature/active" ]
}

@test "recover_orphaned_branch returns 0 and resets to main when branch is gone from remote" {
    local remote_dir
    remote_dir=$(setup_local_git_remote)
    git -C "${REPO_WORK_DIR}" checkout -b feature/merged >/dev/null 2>&1
    git -C "${REPO_WORK_DIR}" -c commit.gpgsign=false commit --allow-empty -m "work" >/dev/null 2>&1
    git -C "${REPO_WORK_DIR}" push origin feature/merged >/dev/null 2>&1
    git -C "${remote_dir}" branch -D feature/merged >/dev/null 2>&1

    run recover_orphaned_branch
    [ "${status}" -eq 0 ]

    local current_branch
    current_branch=$(git -C "${REPO_WORK_DIR}" branch --show-current)
    [ "${current_branch}" = "main" ]
}

@test "recover_orphaned_branch does not warn about discarded work when the tree is clean (#1281)" {
    # Regression guard: the #1281 discard-visibility warning must only fire when there is
    # actually something about to be lost — the overwhelmingly common case (a branch merged and
    # deleted, working tree clean) must stay exactly as quiet as before.
    local remote_dir
    remote_dir=$(setup_local_git_remote)
    git -C "${REPO_WORK_DIR}" checkout -b feature/clean-merged >/dev/null 2>&1
    git -C "${REPO_WORK_DIR}" -c commit.gpgsign=false commit --allow-empty -m "work" >/dev/null 2>&1
    git -C "${REPO_WORK_DIR}" push origin feature/clean-merged >/dev/null 2>&1
    git -C "${remote_dir}" branch -D feature/clean-merged >/dev/null 2>&1

    run recover_orphaned_branch
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"uncommitted changes"* ]]
}

@test "recover_orphaned_branch output warns about the orphaned branch name" {
    local remote_dir
    remote_dir=$(setup_local_git_remote)
    git -C "${REPO_WORK_DIR}" checkout -b feature/gone >/dev/null 2>&1
    git -C "${REPO_WORK_DIR}" -c commit.gpgsign=false commit --allow-empty -m "work" >/dev/null 2>&1
    git -C "${REPO_WORK_DIR}" push origin feature/gone >/dev/null 2>&1
    git -C "${remote_dir}" branch -D feature/gone >/dev/null 2>&1

    run recover_orphaned_branch
    [[ "${output}" == *"feature/gone"* ]]
    [[ "${output}" == *"no longer exists on origin"* ]]
}

@test "recover_orphaned_branch returns 0 and resets to main when branch is gone from remote and working tree has unstaged changes" {
    local remote_dir
    remote_dir=$(setup_local_git_remote)
    git -C "${REPO_WORK_DIR}" checkout -b feature/dirty >/dev/null 2>&1
    git -C "${REPO_WORK_DIR}" -c commit.gpgsign=false commit --allow-empty -m "work" >/dev/null 2>&1
    git -C "${REPO_WORK_DIR}" push origin feature/dirty >/dev/null 2>&1
    git -C "${remote_dir}" branch -D feature/dirty >/dev/null 2>&1
    printf 'unstaged change\n' >> "${REPO_WORK_DIR}/CHANGELOG.md"

    run recover_orphaned_branch
    [ "${status}" -eq 0 ]

    local current_branch
    current_branch=$(git -C "${REPO_WORK_DIR}" branch --show-current)
    [ "${current_branch}" = "main" ]
}

@test "recover_orphaned_branch warns before discarding uncommitted changes on an orphaned branch (#1281)" {
    # The actual silent-discard mechanism #1281 documents: checkout -f below has no dirty-tree
    # check of its own, so a session whose commit never landed (e.g. its backgrounding attempt
    # was denied and misread as still running) loses real work with no trace. This asserts the
    # trace now exists — the branch name, the reason, and the affected file are all named.
    local remote_dir
    remote_dir=$(setup_local_git_remote)
    git -C "${REPO_WORK_DIR}" checkout -b feature/dirty-warned >/dev/null 2>&1
    git -C "${REPO_WORK_DIR}" -c commit.gpgsign=false commit --allow-empty -m "work" >/dev/null 2>&1
    git -C "${REPO_WORK_DIR}" push origin feature/dirty-warned >/dev/null 2>&1
    git -C "${remote_dir}" branch -D feature/dirty-warned >/dev/null 2>&1
    printf 'unstaged change\n' >> "${REPO_WORK_DIR}/CHANGELOG.md"

    run recover_orphaned_branch
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"feature/dirty-warned"* ]]
    [[ "${output}" == *"uncommitted changes"* ]]
    [[ "${output}" == *"CHANGELOG.md"* ]]
}

@test "recover_orphaned_branch warns before discarding an untracked (never-added) file on an orphaned branch (#1281)" {
    local remote_dir
    remote_dir=$(setup_local_git_remote)
    git -C "${REPO_WORK_DIR}" checkout -b feature/untracked-warned >/dev/null 2>&1
    git -C "${REPO_WORK_DIR}" -c commit.gpgsign=false commit --allow-empty -m "work" >/dev/null 2>&1
    git -C "${REPO_WORK_DIR}" push origin feature/untracked-warned >/dev/null 2>&1
    git -C "${remote_dir}" branch -D feature/untracked-warned >/dev/null 2>&1
    printf 'new file\n' > "${REPO_WORK_DIR}/new-untracked-file.txt"

    run recover_orphaned_branch
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"uncommitted changes"* ]]
    [[ "${output}" == *"new-untracked-file.txt"* ]]
}

# --- git_commits_behind unit tests (#1298) --------------------------------------

@test "git_commits_behind reports 0 when ref and upstream are the same commit" {
    # setup_local_git_remote's own push already updates REPO_WORK_DIR's origin/main tracking ref
    # locally — no separate fetch needed to observe it.
    setup_local_git_remote >/dev/null

    run git_commits_behind "${REPO_WORK_DIR}" HEAD origin/main
    [ "${status}" -eq 0 ]
    [ "${output}" = "0" ]
}

@test "git_commits_behind reports the count when origin/main has advanced" {
    local remote_dir
    remote_dir=$(setup_local_git_remote)

    # Advance the remote via a second, independent clone — REPO_WORK_DIR (the one under test)
    # must NOT itself merge these commits, only fetch, so its own HEAD stays behind.
    advance_remote_main "${remote_dir}" 2

    git -C "${REPO_WORK_DIR}" fetch -q origin

    run git_commits_behind "${REPO_WORK_DIR}" HEAD origin/main
    [ "${status}" -eq 0 ]
    [ "${output}" = "2" ]
}

@test "git_commits_behind returns 1 with no output when upstream does not exist (a fetch has never succeeded)" {
    local clone="${TEST_TMP}/behind-clone-no-remote"
    git init -q "${clone}"

    run git_commits_behind "${clone}" HEAD origin/main
    [ "${status}" -ne 0 ]
    [ -z "${output}" ]
}

@test "git_commits_behind returns 1 with no output when repo_dir does not exist" {
    run git_commits_behind "${TEST_TMP}/behind-nonexistent" HEAD origin/main
    [ "${status}" -ne 0 ]
    [ -z "${output}" ]
}

# --- find_stale_issue_branch unit tests (#1262) ---------------------------------

@test "find_stale_issue_branch returns 1 when repo directory does not exist" {
    REPO_WORK_DIR="${TEST_TMP}/nonexistent/repo"
    run find_stale_issue_branch 439
    [ "${status}" -eq 1 ]
}

@test "find_stale_issue_branch returns 1 when no branch matches the issue" {
    setup_local_git_remote >/dev/null
    run find_stale_issue_branch 439
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
}

@test "find_stale_issue_branch finds a <type>/<issue>-<slug> branch ahead of main" {
    setup_local_git_remote >/dev/null
    git -C "${REPO_WORK_DIR}" checkout -b chore/439-pin-actions >/dev/null 2>&1
    git -C "${REPO_WORK_DIR}" -c commit.gpgsign=false commit --allow-empty -m "placeholder changelog" >/dev/null 2>&1
    git -C "${REPO_WORK_DIR}" push origin chore/439-pin-actions >/dev/null 2>&1
    git -C "${REPO_WORK_DIR}" checkout main >/dev/null 2>&1
    git -C "${REPO_WORK_DIR}" fetch origin >/dev/null 2>&1

    run find_stale_issue_branch 439
    [ "${status}" -eq 0 ]
    [ "${output}" = "chore/439-pin-actions" ]
}

@test "find_stale_issue_branch does not match a branch whose issue number only shares a prefix (#1262)" {
    setup_local_git_remote >/dev/null
    git -C "${REPO_WORK_DIR}" checkout -b chore/4390-unrelated >/dev/null 2>&1
    git -C "${REPO_WORK_DIR}" -c commit.gpgsign=false commit --allow-empty -m "work" >/dev/null 2>&1
    git -C "${REPO_WORK_DIR}" push origin chore/4390-unrelated >/dev/null 2>&1
    git -C "${REPO_WORK_DIR}" checkout main >/dev/null 2>&1
    git -C "${REPO_WORK_DIR}" fetch origin >/dev/null 2>&1

    run find_stale_issue_branch 439
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
}

@test "find_stale_issue_branch ignores a matching branch with no commits ahead of main" {
    setup_local_git_remote >/dev/null
    git -C "${REPO_WORK_DIR}" checkout -b chore/439-noop >/dev/null 2>&1
    git -C "${REPO_WORK_DIR}" push origin chore/439-noop >/dev/null 2>&1
    git -C "${REPO_WORK_DIR}" checkout main >/dev/null 2>&1
    git -C "${REPO_WORK_DIR}" fetch origin >/dev/null 2>&1

    run find_stale_issue_branch 439
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
}

@test "find_stale_issue_branch matches a bare <type>/<issue> branch with no slug, per the shared issue_branch_regex convention (#1262 review)" {
    setup_local_git_remote >/dev/null
    git -C "${REPO_WORK_DIR}" checkout -b chore/439 >/dev/null 2>&1
    git -C "${REPO_WORK_DIR}" -c commit.gpgsign=false commit --allow-empty -m "work" >/dev/null 2>&1
    git -C "${REPO_WORK_DIR}" push origin chore/439 >/dev/null 2>&1
    git -C "${REPO_WORK_DIR}" checkout main >/dev/null 2>&1
    git -C "${REPO_WORK_DIR}" fetch origin >/dev/null 2>&1

    run find_stale_issue_branch 439
    [ "${status}" -eq 0 ]
    [ "${output}" = "chore/439" ]
}

# --- issue_branch_regex unit tests (#1262 review) -------------------------------

@test "issue_branch_regex matches <type>/<issue>-<slug> and a bare <type>/<issue>" {
    local pattern
    pattern=$(issue_branch_regex 439)
    [[ "chore/439-pin-actions" =~ ${pattern} ]]
    [[ "chore/439" =~ ${pattern} ]]
}

@test "issue_branch_regex does not match a longer issue number sharing a prefix" {
    local pattern
    pattern=$(issue_branch_regex 439)
    [[ ! "chore/4390-unrelated" =~ ${pattern} ]]
    [[ ! "chore/1439-unrelated" =~ ${pattern} ]]
}

# --- main() integration: orphaned-branch fingerprint bypass --------------------

@test "main re-runs issue with matching fingerprint when recover_orphaned_branch detects orphaned branch" {
    setup_main_mocks
    recover_orphaned_branch() { return 0; }

    fetch_all_priorities() {
        printf '[{"id":42,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]\n'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() {
        printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'
    }
    issue_json_has_blocked_label() { return 1; }
    fingerprint_issue_json()      { printf 'same-fp\n'; }
    load_issue_fingerprint()      { printf 'same-fp\n'; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"orphaned branch"* ]]
    [[ "${output}" == *"Found actionable Issue #42"* ]]
}

@test "main still skips issue with matching fingerprint when branch is not orphaned" {
    setup_main_mocks
    recover_orphaned_branch() { return 1; }
    stub_plan_already_self_heal_marked

    fetch_all_priorities() {
        printf '[{"id":42,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]\n'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() {
        printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'
    }
    issue_json_has_blocked_label() { return 1; }
    fingerprint_issue_json()      { printf 'same-fp\n'; }
    load_issue_fingerprint()      { printf 'same-fp\n'; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Issue #42 in org/repo unchanged — skipping"* ]]
    [[ "${output}" != *"Found actionable Issue #42"* ]]
}

# --- main() integration: stalled Issue branch bypass (#1262) -------------------

@test "main re-runs issue with matching fingerprint when resolve_resumable_issue_branch finds a resumable branch (#1262)" {
    setup_main_mocks
    recover_orphaned_branch() { return 1; }
    resolve_resumable_issue_branch() { printf 'chore/42-fix\n'; return 0; }

    fetch_all_priorities() {
        printf '[{"id":42,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]\n'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() {
        printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'
    }
    issue_json_has_blocked_label() { return 1; }
    fingerprint_issue_json()      { printf 'same-fp\n'; }
    load_issue_fingerprint()      { printf 'same-fp\n'; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"branch 'chore/42-fix' has commits ahead of main and no open PR — resuming stalled work"* ]]
    [[ "${output}" == *"Found actionable Issue #42"* ]]
}

@test "main still skips issue when resolve_resumable_issue_branch finds no resumable branch (already covered by a PR or no candidate) (#1262)" {
    setup_main_mocks
    recover_orphaned_branch() { return 1; }
    resolve_resumable_issue_branch() { return 1; }
    stub_plan_already_self_heal_marked

    fetch_all_priorities() {
        printf '[{"id":42,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]\n'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() {
        printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'
    }
    issue_json_has_blocked_label() { return 1; }
    fingerprint_issue_json()      { printf 'same-fp\n'; }
    load_issue_fingerprint()      { printf 'same-fp\n'; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Issue #42 in org/repo unchanged — skipping"* ]]
    [[ "${output}" != *"Found actionable Issue #42"* ]]
}

# --- main() integration: pre-plan Issue idle-retry (#1427) --------------------

@test "main re-invokes an Issue with no plan ever posted and matching fingerprint, within the idle budget (#1427)" {
    setup_main_mocks
    recover_orphaned_branch() { return 1; }
    resolve_resumable_issue_branch() { return 1; }

    fetch_all_priorities() {
        printf '[{"id":42,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]\n'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() {
        printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'
    }
    issue_json_has_blocked_label() { return 1; }
    fingerprint_issue_json()      { printf 'same-fp\n'; }
    load_issue_fingerprint()      { printf 'same-fp\n'; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"fingerprint unchanged with no plan ever posted, re-invoking to plan"* ]]
    [[ "${output}" == *"Found actionable Issue #42"* ]]
    # Idle counter bumped from 0 to 1 for this re-poke.
    [ "$(cat "${SESSION_BASE_DIR}/Issue_42.invocations")" = "1 1" ]
}

@test "main blocks an Issue once the idle budget is exhausted with no plan ever posted (#1427)" {
    setup_main_mocks
    recover_orphaned_branch() { return 1; }
    resolve_resumable_issue_branch() { return 1; }

    fetch_all_priorities() {
        printf '[{"id":42,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]\n'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() {
        printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'
    }
    issue_json_has_blocked_label() { return 1; }
    fingerprint_issue_json()      { printf 'same-fp\n'; }
    load_issue_fingerprint()      { printf 'same-fp\n'; }
    save_issue_invocation_counts 42 4 "${MAX_ISSUE_IDLE_INVOCATIONS}"
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; case "$*" in *"--json labels"*) printf "true\n" ;; *"--json number"*) printf "[]\n" ;; esac; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"idle budget exhausted with no plan ever posted, blocking"* ]]
    grep -q "issue comment 42 --repo org/repo --body This issue was re-invoked" "${GH_CALL_LOG}"
    grep -q 'Blocked' "${GH_CALL_LOG}"
}

# --- main() integration: plan-approved Issue idle-retry (#1264) ---------------

@test "main re-invokes a plan-approved Issue with matching fingerprint and no resumable branch, within the idle budget (#1264)" {
    setup_main_mocks
    recover_orphaned_branch() { return 1; }
    resolve_resumable_issue_branch() { return 1; }
    issue_plan_approved() { printf 'true'; }
    issue_plan_approved_or_later() { printf 'true'; }

    fetch_all_priorities() {
        printf '[{"id":42,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]\n'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() {
        printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'
    }
    issue_json_has_blocked_label() { return 1; }
    fingerprint_issue_json()      { printf 'same-fp\n'; }
    load_issue_fingerprint()      { printf 'same-fp\n'; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"fingerprint unchanged but plan approved — re-invoking to check progress"* ]]
    [[ "${output}" == *"Found actionable Issue #42"* ]]
    # Idle counter bumped from 0 to 1 for this re-poke.
    [ "$(cat "${SESSION_BASE_DIR}/Issue_42.invocations")" = "1 1" ]
}

@test "main blocks a plan-approved Issue once the idle budget is exhausted with no progress (#1264)" {
    setup_main_mocks
    recover_orphaned_branch() { return 1; }
    resolve_resumable_issue_branch() { return 1; }
    issue_plan_approved() { printf 'true'; }
    issue_plan_approved_or_later() { printf 'true'; }

    fetch_all_priorities() {
        printf '[{"id":42,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]\n'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() {
        printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'
    }
    issue_json_has_blocked_label() { return 1; }
    fingerprint_issue_json()      { printf 'same-fp\n'; }
    load_issue_fingerprint()      { printf 'same-fp\n'; }
    save_issue_invocation_counts 42 4 "${MAX_ISSUE_IDLE_INVOCATIONS}"
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; case "$*" in *"--json labels"*) printf "true\n" ;; *"--json number"*) printf "[]\n" ;; esac; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"idle budget exhausted with plan approved but no progress — blocking"* ]]
    grep -q "issue comment 42 --repo org/repo --body This issue's plan is approved" "${GH_CALL_LOG}"
    grep -q 'Blocked' "${GH_CALL_LOG}"
}

@test "main works an Issue that has no PR of its own, with no repo-wide slot deferral (#1517)" {
    # The one-active-branch-or-PR rule is per user, so there is no check that any open PR in the
    # repo defers the Issue: only the orchestrator's own PRs (find_open_nonblocked_pr_for_repo,
    # empty here) and a PR that owns this Issue and is human-driven (find_human_taken_over_pr_for_issue,
    # none here) stop it being worked. That an unrelated PR is ignored by those two is covered by
    # their own tests above.
    setup_main_mocks
    fetch_all_priorities() {
        printf '[{"id":1310,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]\n'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() {
        printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'
    }
    issue_json_has_blocked_label() { return 1; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Found actionable Issue #1310"* ]]
    [[ "${output}" != *"active-branch/PR slot occupied"* ]]
    [[ "${output}" != *"repo-active"* ]]
}

@test "main reports an Issue whose linked PR a human is developing as human-driven, not repo-active (#1517)" {
    # The credfeto-dotnet-repo-tools case: Issue #317's PR #318 was opened by the PR create bot
    # and has only the owner's commits, so find_human_taken_over_pr_for_issue returns it. The
    # Issue is skipped for that one reason, under the one label.
    setup_main_mocks
    fetch_all_priorities() {
        printf '[{"id":317,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]\n'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() {
        printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'
    }
    issue_json_has_blocked_label() { return 1; }
    find_human_taken_over_pr_for_issue() { printf '318'; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Issue #317 in org/repo: PR #318 is being developed by a human — standing off"* ]]
    [[ "${output}" == *"human-driven: 1"* ]]
    [[ "${output}" == *"repo-active: 0"* ]]
    [[ "${output}" != *"active-branch/PR slot occupied"* ]]
}

# --- main() integration: self-heal a plan posted without Blocked (#1286) ----

@test "main self-heals an Issue whose plan was posted but Blocked was never applied" {
    setup_main_mocks
    recover_orphaned_branch() { return 1; }
    resolve_resumable_issue_branch() { return 1; }

    fetch_all_priorities() {
        printf '[{"id":42,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]\n'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() {
        # shellcheck disable=SC2016
        printf '%s\n' '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[{"author":{"login":"testuser"},"body":"## Implementation Plan\n### Open questions\nNone, ready to proceed pending approval."}],"assignees":[],"milestone":null}'
    }
    issue_json_has_blocked_label() { return 1; }
    fingerprint_issue_json()      { printf 'same-fp\n'; }
    load_issue_fingerprint()      { printf 'same-fp\n'; }
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"plan posted but never marked Blocked — self-healing"* ]]
    grep -q "issue comment 42 --repo org/repo" "${GH_CALL_LOG}"
    grep -q 'add-label Blocked' "${GH_CALL_LOG}"
    [ -f "${SESSION_BASE_DIR}/Issue_42.plan-block" ]
}

@test "main does not re-block an Issue whose plan-block marker is already set and Blocked has since been cleared by a human (#1115 regression guard)" {
    setup_main_mocks
    recover_orphaned_branch() { return 1; }
    resolve_resumable_issue_branch() { return 1; }
    mkdir -p "${SESSION_BASE_DIR}"
    touch "${SESSION_BASE_DIR}/Issue_42.plan-block"

    fetch_all_priorities() {
        printf '[{"id":42,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]\n'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() {
        # shellcheck disable=SC2016
        printf '%s\n' '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[{"author":{"login":"testuser"},"body":"## Implementation Plan\n### Open questions\nNone, ready to proceed pending approval."}],"assignees":[],"milestone":null}'
    }
    issue_json_has_blocked_label() { return 1; }
    fingerprint_issue_json()      { printf 'same-fp\n'; }
    load_issue_fingerprint()      { printf 'same-fp\n'; }
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    touch "${GH_CALL_LOG}"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"Issue #42 in org/repo unchanged — skipping"* ]]
    [[ "${output}" != *"self-healing"* ]]
    run grep -q 'add-label Blocked' "${GH_CALL_LOG}"
    [ "${status}" -ne 0 ]
}

@test "main clears a stale plan-block marker once the Issue's plan becomes approved (#1286)" {
    setup_main_mocks
    recover_orphaned_branch() { return 1; }
    resolve_resumable_issue_branch() { return 1; }
    issue_plan_approved() { printf 'true'; }
    issue_plan_approved_or_later() { printf 'true'; }
    mkdir -p "${SESSION_BASE_DIR}"
    touch "${SESSION_BASE_DIR}/Issue_42.plan-block"

    fetch_all_priorities() {
        printf '[{"id":42,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]\n'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() {
        printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'
    }
    issue_json_has_blocked_label() { return 1; }
    fingerprint_issue_json()      { printf 'same-fp\n'; }
    load_issue_fingerprint()      { printf 'same-fp\n'; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ -f "${TEST_TMP}/claude_log" ]
    [ ! -f "${SESSION_BASE_DIR}/Issue_42.plan-block" ]
}

@test "main clears a stale plan-block marker for a card that has already progressed past Approved (#1321)" {
    # Regression coverage: the marker must clear once the plan is genuinely approved even when
    # the board has since moved on to a later column, so the exact-match issue_plan_approved
    # (which reads false here) must NOT be what gates this — only issue_plan_approved_or_later.
    setup_main_mocks
    recover_orphaned_branch() { return 1; }
    resolve_resumable_issue_branch() { return 1; }
    issue_plan_approved() { printf 'false'; }
    issue_plan_approved_or_later() { printf 'true'; }
    mkdir -p "${SESSION_BASE_DIR}"
    touch "${SESSION_BASE_DIR}/Issue_42.plan-block"

    fetch_all_priorities() {
        printf '[{"id":42,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]\n'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() {
        printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'
    }
    issue_json_has_blocked_label() { return 1; }
    fingerprint_issue_json()      { printf 'same-fp\n'; }
    load_issue_fingerprint()      { printf 'same-fp\n'; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${SESSION_BASE_DIR}/Issue_42.plan-block" ]
}

@test "main threads a resumable stale branch into the generated CLAUDE.md even when the Issue's own fingerprint changed (#1262 review)" {
    # The fingerprint-unchanged skip-decision only runs when the fingerprint matched the saved
    # one. A session that changed the Issue (e.g. posted a comment) after pushing a branch and
    # dying must still surface the existing branch to the freshly-invoked agent via the
    # work-block recomputation, or it would risk creating a duplicate branch.
    setup_main_mocks
    recover_orphaned_branch() { return 1; }
    resolve_resumable_issue_branch() { printf 'chore/42-fix\n'; return 0; }

    # Captures the 7th positional argument specifically (not just "$*"): build_issue_claude_md's
    # signature is (item_id, ai_instructions, repo_path, plan_approved, trusted_logins,
    # dirty_branch, stale_branch), so this pins that the branch landed in its own dedicated
    # stale_branch slot, distinct from dirty_branch (arg 6) — a swapped-argument regression at
    # the call site would go undetected by a substring-anywhere check on the full argument list.
    local captured_arg7="${TEST_TMP}/build-issue-claude-md-arg7"
    build_issue_claude_md() { printf '%s\n' "$7" > "${captured_arg7}"; printf 'mock-issue-claude-md\n'; }

    fetch_all_priorities() {
        printf '[{"id":42,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]\n'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() {
        printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'
    }
    issue_json_has_blocked_label() { return 1; }
    fingerprint_issue_json()      { printf 'new-fp\n'; }
    load_issue_fingerprint()      { printf 'old-fp\n'; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Found actionable Issue #42"* ]]
    [ -f "${captured_arg7}" ]
    [ "$(cat "${captured_arg7}")" = "chore/42-fix" ]
}

@test "main threads background_stall=true into the generated CLAUDE.md when the previous session stalled (#1326/#1335)" {
    setup_main_mocks
    recover_orphaned_branch() { return 1; }
    resolve_resumable_issue_branch() { return 1; }

    local captured_arg8="${TEST_TMP}/build-issue-claude-md-arg8"
    build_issue_claude_md() { printf '%s\n' "$8" > "${captured_arg8}"; printf 'mock-issue-claude-md\n'; }

    mkdir -p "${SESSION_BASE_DIR}"
    touch "${SESSION_BASE_DIR}/Issue_42.background-stall"

    fetch_all_priorities() {
        printf '[{"id":42,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]\n'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() {
        printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'
    }
    issue_json_has_blocked_label() { return 1; }
    fingerprint_issue_json()      { printf 'new-fp\n'; }
    load_issue_fingerprint()      { printf ''; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Found actionable Issue #42"* ]]
    [ -f "${captured_arg8}" ]
    [ "$(cat "${captured_arg8}")" = "true" ]
}

@test "main threads background_stall=false into the generated CLAUDE.md when no marker exists (#1326/#1335)" {
    setup_main_mocks
    recover_orphaned_branch() { return 1; }
    resolve_resumable_issue_branch() { return 1; }

    local captured_arg8="${TEST_TMP}/build-issue-claude-md-arg8-false"
    build_issue_claude_md() { printf '%s\n' "$8" > "${captured_arg8}"; printf 'mock-issue-claude-md\n'; }

    fetch_all_priorities() {
        printf '[{"id":42,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]\n'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() {
        printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'
    }
    issue_json_has_blocked_label() { return 1; }
    fingerprint_issue_json()      { printf 'new-fp\n'; }
    load_issue_fingerprint()      { printf ''; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Found actionable Issue #42"* ]]
    [ -f "${captured_arg8}" ]
    [ "$(cat "${captured_arg8}")" = "false" ]
}

@test "main does not skip a board-approved Issue whose own fields are otherwise unchanged (#1204)" {
    # Reproduces credfeto-nuget-proxy#99: the issue's own GitHub fields (title/body/state/labels/
    # comments/assignees/milestone) are identical to what was last cached, but the Workflow board
    # now says Approved. This bug is invisible if fingerprint_issue_json/compute_issue_fingerprint
    # are mocked away (as setup_main_mocks does by default), since the whole point is what the
    # REAL functions do with board-approval status — so restore them here.
    setup_main_mocks
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/lib/fingerprints"
    # compute_issue_fingerprint (called post-invocation) keys _WF_APPROVED_ITEMS off REPO_FULL,
    # which set_repo_context normally keeps in sync with item_repo per iteration; restore that
    # instead of the blanket no-op set_repo_context() setup_main_mocks stubs in.
    set_repo_context() { REPO_FULL="$1"; }

    # Named to avoid colliding with main()'s own "local issue_json" — bash's dynamic scoping
    # means a stub referencing a same-named test-body variable would see main()'s (still-empty)
    # local instead of this one once main() declares its locals.
    local fixture_issue_json='{"title":"T","body":"B","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}'
    fetch_all_priorities() {
        printf '%s\n' '[{"id":42,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '%s\n' "${fixture_issue_json}"; }
    issue_json_has_blocked_label() { return 1; }
    recover_orphaned_branch() { return 1; }

    # Fingerprint cached BEFORE the plan was approved on the board (own fields identical).
    local stale_fp
    stale_fp=$(fingerprint_issue_json "${fixture_issue_json}" '["credfeto"]' "false")
    load_issue_fingerprint() { printf '%s\n' "${stale_fp}"; }

    # Board now says Approved.
    _WF_PROJECT_ID="PVT_test"
    fetch_board_approved_items() { _WF_APPROVED_ITEMS["org/repo/42"]=1; }
    # issue_plan_approved_or_later is unrelated to what this test exercises (the exact-match
    # fetch_board_approved_items path feeding the fingerprint) — stub it directly so it doesn't
    # fall through to a real, unstubbed gh api graphql call now that oneshot calls it
    # unconditionally for every Issue (#1321 review).
    issue_plan_approved_or_later() { printf 'true'; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"Issue #42 in org/repo unchanged"* ]]
    [[ "${output}" == *"Found actionable Issue #42"* ]]
}

@test "main re-invokes on board approval, then the fingerprint stabilises and the idle budget takes over (#1204, #1264)" {
    setup_main_mocks
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/lib/fingerprints"
    # See the previous test for why this override is needed (REPO_FULL must track item_repo).
    set_repo_context() { REPO_FULL="$1"; }

    # Named to avoid colliding with main()'s own "local issue_json" (bash dynamic scoping).
    local fixture_issue_json='{"title":"T","body":"B","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}'
    fetch_all_priorities() {
        printf '%s\n' '[{"id":42,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '%s\n' "${fixture_issue_json}"; }
    issue_json_has_blocked_label() { return 1; }
    recover_orphaned_branch() { return 1; }

    _WF_PROJECT_ID="PVT_test"
    fetch_board_approved_items() { _WF_APPROVED_ITEMS["org/repo/42"]=1; }
    # See the previous test for why this is stubbed directly (#1321 review).
    issue_plan_approved_or_later() { printf 'true'; }

    # Pre-existing on-disk fingerprint, as if cached before the plan was approved. Real
    # save_issue_fingerprint/load_issue_fingerprint (via the re-source above) so state genuinely
    # persists across the two ticks below, the same as it would across two real oneshot runs.
    local stale_fp
    stale_fp=$(fingerprint_issue_json "${fixture_issue_json}" '["credfeto"]' "false")
    save_issue_fingerprint 42 "${stale_fp}"

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Found actionable Issue #42"* ]]
    # The post-invocation save must have recorded plan_approved=true, or the fingerprint would
    # keep looking "changed" every tick instead of stabilising.
    local saved_fp
    saved_fp=$(load_issue_fingerprint 42)
    [ "${saved_fp}" != "${stale_fp}" ]

    # The fingerprint itself has now stabilised (matches on the next tick) — but since the plan
    # is approved, this no longer means silence forever: it means the idle-invocation budget
    # takes over instead (#1264), re-poking a bounded number of times rather than looping
    # infinitely or going permanently quiet.
    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"fingerprint unchanged but plan approved — re-invoking to check progress"* ]]
}

# --- human-driven PR stand-off integration (#1131) -----------------------------

@test "main skips the whole repository when its Workflow board could not be converted, and still works another repository (#1519)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '[{"id":164,"itemType":"Issue","repository":"org/broken","priority":1,"status":"Open","isOnHold":false},{"id":165,"itemType":"Issue","repository":"org/broken","priority":2,"status":"Open","isOnHold":false},{"id":200,"itemType":"Issue","repository":"org/fine","priority":3,"status":"Open","isOnHold":false}]\n'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    issue_json_has_blocked_label() { return 1; }
    # setup_main_mocks stubs set_repo_context, so the repository is read from main's own loop
    # variable item_repo rather than REPO_FULL.
    discover_or_create_workflow_project() {
        _WF_CONVERSION_FAILED=""
        # shellcheck disable=SC2154  # item_repo is main's loop variable, seen here by dynamic scope
        [ "${item_repo}" != "org/broken" ] || _WF_CONVERSION_FAILED="1"
    }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"Found actionable Issue #164"* ]]
    [[ "${output}" != *"Found actionable Issue #165"* ]]
    [[ "${output}" == *"Found actionable Issue #200"* ]]
}

@test "main stands off an issue whose PR a human has taken over (#1131)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '[{"id":164,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]\n'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    issue_json_has_blocked_label() { return 1; }
    find_human_taken_over_pr_for_issue() { printf '167'; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Issue #164 in org/repo: PR #167 is being developed by a human — standing off"* ]]
    [[ "${output}" != *"Found actionable"* ]]
    [[ "${output}" == *"human-driven: 1"* ]]
}

@test "main still works another issue in the same repo after a human-driven stand-off (#1131)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '[{"id":164,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false},{"id":200,"itemType":"Issue","repository":"org/repo","priority":2,"status":"Open","isOnHold":false}]\n'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    issue_json_has_blocked_label() { return 1; }
    find_human_taken_over_pr_for_issue() {
        if [ "$1" = "164" ]; then
            printf '167'
            return 0
        fi
        return 1
    }

    run main
    [ "${status}" -eq 0 ]
    # Issue #164 is stood off, but the repo is NOT marked active...
    [[ "${output}" == *"Issue #164 in org/repo: PR #167 is being developed by a human — standing off"* ]]
    [[ "${output}" != *"repo already has active work"* ]]
    # ...so issue #200 in the same repo is still worked.
    [[ "${output}" == *"Found actionable Issue #200 in org/repo"* ]]
}

@test "main skips the item (not the run) when the human-takeover check fails transiently (#1131)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '[{"id":164,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]\n'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    issue_json_has_blocked_label() { return 1; }
    find_human_taken_over_pr_for_issue() { return 2; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Failed to check for a human-driven PR for Issue #164 in org/repo"* ]]
    [[ "${output}" != *"Found actionable"* ]]
    [[ "${output}" == *"errors: 1"* ]]
}

@test "main stands off a human-driven PR from the priorities feed without marking the repo active (#1131)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false},{"id":10,"itemType":"Issue","repository":"org/repo","priority":2,"status":"Open","isOnHold":false}]\n'
    }
    fetch_pr_json()             { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}\n'; }
    pr_json_has_blocked_label() { return 1; }
    pr_is_human_driven()        { return 0; }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[{"name":"Blocked"}],"comments":[],"assignees":[],"milestone":null}\n'; }
    issue_json_has_blocked_label() { return 0; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PR #5 in org/repo is being developed by a human — standing off"* ]]
    # The repo is NOT marked active: issue #10 reaches its own evaluation (blocked path)
    # instead of being skipped with "repo already has active work".
    [[ "${output}" != *"repo already has active work"* ]]
    [[ "${output}" == *"Issue #10 in org/repo is blocked — skipping"* ]]
    [[ "${output}" == *"human-driven: 1"* ]]
}

@test "main marks the repo active when the human-driven check fails, so issues stay serialized (#1134)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false},{"id":10,"itemType":"Issue","repository":"org/repo","priority":2,"status":"Open","isOnHold":false}]\n'
    }
    fetch_pr_json()             { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}\n'; }
    pr_json_has_blocked_label() { return 1; }
    pr_is_human_driven()        { return 2; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Failed to determine commit authorship for PR #5 in org/repo"* ]]
    # The unknown-status PR must still serialize the repo — issue #10 is skipped as active.
    [[ "${output}" == *"Skipping Issue #10 in org/repo — repo already has active work"* ]]
}

@test "main tags a human-driven PR for investigation when its issue is no longer open (#1134)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '[{"id":164,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]\n'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"CLOSED","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    find_human_taken_over_pr_for_issue() { printf '167'; }
    tag_pr_closed_issue() { printf 'TAGGED pr=%s issue=%s\n' "$1" "$2"; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Issue #164 in org/repo is closed but human-driven PR #167 is still open — tagging for investigation"* ]]
    [[ "${output}" == *"TAGGED pr=167 issue=164"* ]]
    [[ "${output}" == *"Issue #164 in org/repo is no longer open — skipping"* ]]
    # One-time check: the marker must exist so later ticks pay no API cost and post no repeat comment.
    [ -f "${SESSION_BASE_DIR}/Issue_164.closed-takeover-checked" ]
}

@test "main clears the closed-takeover marker when the issue is observed open again (#1134)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '[{"id":164,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]\n'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    issue_json_has_blocked_label() { return 1; }
    mkdir -p "${SESSION_BASE_DIR}"
    touch "${SESSION_BASE_DIR}/Issue_164.closed-takeover-checked"

    run main
    [ "${status}" -eq 0 ]
    # Reopened issue re-arms the one-time check for the next closure.
    [ ! -f "${SESSION_BASE_DIR}/Issue_164.closed-takeover-checked" ]
}

@test "main does not write the closed-takeover marker when tagging fails completely (#1134)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '[{"id":164,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]\n'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"CLOSED","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    find_human_taken_over_pr_for_issue() { printf '167'; }
    tag_pr_closed_issue() { return 1; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Failed to tag PR #167"* ]]
    # Marker unwritten — the tagging retries next tick instead of being lost forever.
    [ ! -f "${SESSION_BASE_DIR}/Issue_164.closed-takeover-checked" ]
}

# --- main() assignee standoff (#1142) -----------------------------------------

@test "main stands off an issue assigned only to a human (#1142)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]\n'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[{"login":"alice"}],"milestone":null}\n'; }
    issue_json_has_blocked_label() { return 1; }
    _GH_ME="testuser"

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Issue #10 in org/repo is assigned to another user — standing off"* ]]
    [[ "${output}" != *"Found actionable"* ]]
    [[ "${output}" == *"human-driven: 1"* ]]
}

@test "main processes an issue assigned to the bot (#1142)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]\n'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[{"login":"testuser"}],"milestone":null}\n'; }
    issue_json_has_blocked_label() { return 1; }
    _GH_ME="testuser"

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"assigned to another user"* ]]
    [[ "${output}" == *"Found actionable Issue #10"* ]]
}

@test "main processes an unassigned issue (#1142)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]\n'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    issue_json_has_blocked_label() { return 1; }
    _GH_ME="testuser"

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"assigned to another user"* ]]
    [[ "${output}" == *"Found actionable Issue #10"* ]]
}

@test "main processes an issue assigned to both the bot and a human (#1142)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]\n'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[{"login":"alice"},{"login":"testuser"}],"milestone":null}\n'; }
    issue_json_has_blocked_label() { return 1; }
    _GH_ME="testuser"

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"assigned to another user"* ]]
    [[ "${output}" == *"Found actionable Issue #10"* ]]
}

@test "main stands off a PR assigned only to a human (#1142)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false},{"id":10,"itemType":"Issue","repository":"org/repo","priority":2,"status":"Open","isOnHold":false}]\n'
    }
    fetch_pr_json()             { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[],"assignees":[{"login":"alice"}]}\n'; }
    pr_json_has_blocked_label() { return 1; }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[{"name":"Blocked"}],"comments":[],"assignees":[],"milestone":null}\n'; }
    issue_json_has_blocked_label() { return 0; }
    _GH_ME="testuser"

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PR #5 in org/repo is assigned to another user — standing off"* ]]
    # The repo is NOT marked active: issue #10 reaches its own evaluation (blocked path)
    [[ "${output}" != *"repo already has active work"* ]]
    [[ "${output}" == *"Issue #10 in org/repo is blocked — skipping"* ]]
    [[ "${output}" == *"human-driven: 1"* ]]
}

@test "main processes a PR assigned to the bot (#1142)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]\n'
    }
    fetch_pr_json()             { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[],"assignees":[{"login":"testuser"}]}\n'; }
    pr_json_has_blocked_label() { return 1; }
    _GH_ME="testuser"

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"assigned to another user"* ]]
    [[ "${output}" == *"Found actionable PullRequest #5"* ]]
}

@test "main processes an unassigned PR (#1142)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]\n'
    }
    fetch_pr_json()             { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[],"assignees":[]}\n'; }
    pr_json_has_blocked_label() { return 1; }
    _GH_ME="testuser"

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"assigned to another user"* ]]
    [[ "${output}" == *"Found actionable PullRequest #5"* ]]
}

@test "main processes a PR assigned to both the bot and a human (#1142)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]\n'
    }
    fetch_pr_json()             { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[],"assignees":[{"login":"alice"},{"login":"testuser"}]}\n'; }
    pr_json_has_blocked_label() { return 1; }
    _GH_ME="testuser"

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"assigned to another user"* ]]
    [[ "${output}" == *"Found actionable PullRequest #5"* ]]
}

@test "main processes a depends/-branch dependency PR assigned only to a human (#1142 follow-up)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]\n'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[{"name":"auto-pr"}],"headRefName":"depends/update-foo/1.2.3","headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[],"assignees":[{"login":"alice"}]}\n'; }
    pr_json_has_blocked_label() { return 1; }
    _GH_ME="testuser"

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"assigned to another user"* ]]
    [[ "${output}" == *"Found actionable PullRequest #5"* ]]
}

@test "main processes a dependencies-labelled PR assigned only to a human (#1142 follow-up)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]\n'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[{"name":"npm dependencies"}],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[],"assignees":[{"login":"alice"}]}\n'; }
    pr_json_has_blocked_label() { return 1; }
    _GH_ME="testuser"

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"assigned to another user"* ]]
    [[ "${output}" == *"Found actionable PullRequest #5"* ]]
}

@test "main marks the repo active when a feed PR's state fetch fails, keeping issues serialized (#1134)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false},{"id":10,"itemType":"Issue","repository":"org/repo","priority":2,"status":"Open","isOnHold":false}]\n'
    }
    fetch_pr_json() { return 1; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Failed to fetch state for PR #5 in org/repo"* ]]
    [[ "${output}" == *"Skipping Issue #10 in org/repo — repo already has active work"* ]]
}

@test "main does not repeat the closed-issue takeover check once the marker exists (#1134)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '[{"id":164,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]\n'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"CLOSED","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    find_human_taken_over_pr_for_issue() { printf '167'; }
    tag_pr_closed_issue() { printf 'TAGGED pr=%s issue=%s\n' "$1" "$2"; }
    mkdir -p "${SESSION_BASE_DIR}"
    touch "${SESSION_BASE_DIR}/Issue_164.closed-takeover-checked"

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"TAGGED"* ]]
    [[ "${output}" == *"Issue #164 in org/repo is no longer open — skipping"* ]]
}

# --- main startup GPG key check -----------------------------------------------

@test "main dies at startup when GIT_SIGNING_KEY is set but absent from the keyring" {
    check_required_tools() { return 0; }
    make_stub gpg 'exit 1'
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator" "${XDG_CONFIG_HOME}/gh"
    printf 'GIT_USER_NAME=Test User\nGIT_USER_EMAIL=test@example.com\nGIT_SIGNING_KEY=ABCD1234\n' \
        > "${XDG_CONFIG_HOME}/orchestrator/.env"
    printf 'github.com:\n' > "${XDG_CONFIG_HOME}/gh/hosts.yml"
    run main
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"not found in the GPG keyring"* ]]
}

@test "main does not check the keyring when GIT_SIGNING_KEY is absent from .env" {
    make_stub gpg 'exit 1'
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf 'DISCORD_WEBHOOK=https://example.com/hook\n' > "${XDG_CONFIG_HOME}/orchestrator/.env"
    # Should not reach the gpg check — verify it doesn't die due to gpg failure
    make_stub gh 'printf "{\"items\":[]}\n"'
    make_stub curl 'exit 0'
    make_stub flock 'shift; shift; exec "$@"'
    run main 2>/dev/null
    # As long as it doesn't die with a GPG error message, the check was skipped
    [[ "${output}" != *"not found in the GPG keyring"* ]]
}

# --- main: disk space check ---------------------------------------------------

@test "main exits cleanly without launching work when disk space is low" {
    setup_main_mocks
    check_disk_space() { return 1; }
    fetch_all_priorities() {
        printf '%s\n' '[{"id":1,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    local claude_log="${TEST_TMP}/claude_log"
    invoke_claude() { printf 'called\n' >> "${claude_log}"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Insufficient disk space"* ]]
    [ ! -f "${claude_log}" ]
}

@test "main notifies Discord when disk space is low" {
    setup_main_mocks
    check_disk_space() { return 1; }
    fetch_all_priorities() {
        printf '%s\n' '[{"id":1,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    local discord_log="${TEST_TMP}/discord_log"
    notify_discord_low_disk_space() { printf 'notified\n' >> "${discord_log}"; }

    run main
    [ "${status}" -eq 0 ]
    [ -f "${discord_log}" ]
}

@test "main proceeds normally when disk space is sufficient" {
    setup_main_mocks
    check_disk_space() { return 0; }
    fetch_all_priorities() {
        printf '%s\n' '[{"id":1,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[{"name":"Blocked"}],"comments":[],"assignees":[],"milestone":null}\n'; }
    issue_json_has_blocked_label() { return 0; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"Insufficient disk space"* ]]
}

# --- main: self-update staleness check (#1298) --------------------------------

@test "main refuses to run and notifies Discord when systemd-invoked and the checkout is behind origin/main" {
    setup_main_mocks
    export ORCHESTRATOR_SELF_UPDATE_MANAGED="1"
    git_commits_behind() { printf '3'; return 0; }
    fetch_all_priorities() {
        printf '%s\n' '[{"id":1,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    local discord_log="${TEST_TMP}/discord_log"
    notify_discord_self_update_stale() { printf 'notified\n' >> "${discord_log}"; }
    local claude_log="${TEST_TMP}/claude_log"
    invoke_claude() { printf 'called\n' >> "${claude_log}"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"3 commit(s) behind origin/main"* ]]
    [ -f "${discord_log}" ]
    [ ! -f "${claude_log}" ]
}

@test "main does not refuse to run when ORCHESTRATOR_SELF_UPDATE_MANAGED is unset, even when the checkout is behind origin/main (#1298 review — loop/manual invocation must not be gated by the systemd-only policy)" {
    setup_main_mocks
    # ORCHESTRATOR_SELF_UPDATE_MANAGED deliberately left unset by setup_main_mocks — this is
    # loop's or a manual invocation's shape, neither of which lib/systemd-units' ExecStartPre ran
    # ahead of. Deliberately NOT testing this via systemd's generic INVOCATION_ID: a manual shell
    # descended from an unrelated systemd --user session would have that set too, which is
    # exactly the false-positive this variable exists to avoid (#1298 review).
    git_commits_behind() { printf '3'; return 0; }
    fetch_all_priorities() {
        printf '%s\n' '[{"id":1,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    local discord_log="${TEST_TMP}/discord_log"
    notify_discord_self_update_stale() { printf 'notified\n' >> "${discord_log}"; }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[{"name":"Blocked"}],"comments":[],"assignees":[],"milestone":null}\n'; }
    issue_json_has_blocked_label() { return 0; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"behind origin/main"* ]]
    [ ! -f "${discord_log}" ]
}

@test "main proceeds normally when systemd-invoked and the checkout is up to date with origin/main" {
    setup_main_mocks
    export ORCHESTRATOR_SELF_UPDATE_MANAGED="1"
    git_commits_behind() { printf '0'; return 0; }
    fetch_all_priorities() {
        printf '%s\n' '[{"id":1,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[{"name":"Blocked"}],"comments":[],"assignees":[],"milestone":null}\n'; }
    issue_json_has_blocked_label() { return 0; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"behind origin/main"* ]]
}

@test "main proceeds normally when systemd-invoked and git_commits_behind is inconclusive (e.g. origin/main does not exist yet)" {
    setup_main_mocks
    export ORCHESTRATOR_SELF_UPDATE_MANAGED="1"
    git_commits_behind() { return 1; }
    fetch_all_priorities() {
        printf '%s\n' '[{"id":1,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[{"name":"Blocked"}],"comments":[],"assignees":[],"milestone":null}\n'; }
    issue_json_has_blocked_label() { return 0; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"behind origin/main"* ]]
}
