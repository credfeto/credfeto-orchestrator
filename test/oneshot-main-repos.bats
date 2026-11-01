#!/usr/bin/env bats
# shellcheck disable=SC2329  # functions in @test bodies are invoked indirectly via 'run'
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are used inside run() subshells where shellcheck cannot trace them

bats_require_minimum_version 1.5.0

load test_helper
load oneshot_helper

# The PR has merged.
stub_pr_merged() {
    fetch_pr_json() { printf '{"state":"MERGED","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}\n'; }
}

# --- dependency-prompt selection by branch, not label ---------------------------------------
# Issue-label sync copies a linked issue's "dependencies" label onto any bot PR, so the label must
# never select the CI-verify-only prompt that forbids code changes.

@test "pr_has_dependency_update_branch matches depends/ and dependabot/ prefixes" {
    run pr_has_dependency_update_branch '{"headRefName":"depends/dotnet/10.0.1"}'
    [ "${status}" -eq 0 ]
    run pr_has_dependency_update_branch '{"headRefName":"dependabot/github_actions/foo-1.2.3"}'
    [ "${status}" -eq 0 ]
}

@test "pr_has_dependency_update_branch does not match other branches or a mid-name depends" {
    run pr_has_dependency_update_branch '{"headRefName":"chore/982-update-github-actions-version-pins"}'
    [ "${status}" -eq 1 ]
    run pr_has_dependency_update_branch '{"headRefName":"fix/depends/thing"}'
    [ "${status}" -eq 1 ]
    run pr_has_dependency_update_branch '{}'
    [ "${status}" -eq 1 ]
}

@test "pr_should_use_dependency_prompt ignores a dependencies label on a non-dependency branch" {
    run pr_should_use_dependency_prompt '{"headRefName":"chore/982-update-github-actions-version-pins","labels":[{"name":"dependencies"}]}'
    [ "${status}" -eq 1 ]
}

@test "pr_should_use_dependency_prompt accepts a depends/ branch" {
    run pr_should_use_dependency_prompt '{"headRefName":"depends/dotnet/10.0.1","labels":[],"files":[{"path":"global.json"}]}'
    [ "${status}" -eq 0 ]
}

@test "pr_should_use_dependency_prompt falls back to the full flow when changes are requested" {
    run pr_should_use_dependency_prompt '{"headRefName":"dependabot/npm_and_yarn/x-1.0.0","reviewDecision":"CHANGES_REQUESTED"}'
    [ "${status}" -eq 1 ]
}

@test "pr_should_use_dependency_prompt falls back to the full flow when a required check has failed" {
    run pr_should_use_dependency_prompt '{"headRefName":"depends/update-xunit/3.0.1","reviewDecision":"APPROVED","statusCheckRollup":[{"name":"build-pre-release","status":"COMPLETED","conclusion":"FAILURE","isRequired":true}]}'
    [ "${status}" -eq 1 ]
}

@test "pr_should_use_dependency_prompt falls back to the full flow when a check of unknown required-ness has failed" {
    run pr_should_use_dependency_prompt '{"headRefName":"dependabot/nuget/x-1.0.1","statusCheckRollup":[{"name":"build","status":"COMPLETED","conclusion":"FAILURE"}]}'
    [ "${status}" -eq 1 ]
}

@test "pr_should_use_dependency_prompt keeps the verify-only prompt when only a non-required check failed or CI is green or pending" {
    run pr_should_use_dependency_prompt '{"headRefName":"depends/x","statusCheckRollup":[{"name":"badge","status":"COMPLETED","conclusion":"FAILURE","isRequired":false},{"name":"build","status":"COMPLETED","conclusion":"SUCCESS","isRequired":true}]}'
    [ "${status}" -eq 0 ]
    run pr_should_use_dependency_prompt '{"headRefName":"depends/x","statusCheckRollup":[{"name":"build","status":"IN_PROGRESS","conclusion":null,"isRequired":true}]}'
    [ "${status}" -eq 0 ]
}

@test "pr_should_use_dependency_prompt falls back to the full flow for a DIRTY branch so the conflict gets resolved" {
    run pr_should_use_dependency_prompt '{"headRefName":"depends/update-x/1.2.3","mergeStateStatus":"DIRTY","autoMergeRequest":{"enabledAt":"now"},"statusCheckRollup":[]}'
    [ "${status}" -eq 1 ]
}

@test "pr_should_use_dependency_prompt falls back to the full flow for a BEHIND branch the non-agentic rebase did not update" {
    run pr_should_use_dependency_prompt '{"headRefName":"depends/update-x/1.2.3","mergeStateStatus":"BEHIND","autoMergeRequest":{"enabledAt":"now"},"statusCheckRollup":[]}'
    [ "${status}" -eq 1 ]
    run pr_should_use_dependency_prompt '{"headRefName":"dependabot/npm_and_yarn/x-1.2.3","mergeStateStatus":"BEHIND","statusCheckRollup":[]}'
    [ "${status}" -eq 1 ]
}

@test "pr_should_use_dependency_prompt keeps the verify-only prompt for an up-to-date dependency branch with green checks" {
    for state in CLEAN UNSTABLE BLOCKED HAS_HOOKS; do
        run pr_should_use_dependency_prompt "{\"headRefName\":\"depends/update-x/1.2.3\",\"mergeStateStatus\":\"${state}\",\"statusCheckRollup\":[]}"
        [ "${status}" -eq 0 ]
    done
}

@test "pr_should_use_dependency_prompt keeps the verify-only prompt once a later run of the failed check passes" {
    run pr_should_use_dependency_prompt '{"headRefName":"depends/x","statusCheckRollup":[{"name":"build","workflowName":"CI","status":"COMPLETED","conclusion":"FAILURE","isRequired":true,"startedAt":"2026-10-25T10:00:00Z"},{"name":"build","workflowName":"CI","status":"COMPLETED","conclusion":"SUCCESS","isRequired":true,"startedAt":"2026-10-25T11:00:00Z"}]}'
    [ "${status}" -eq 0 ]
}

@test "pr_has_dependency_update_branch never matches a PR from a fork, so a fork PR is not exempted from the human-driven check" {
    run pr_has_dependency_update_branch '{"headRefName":"depends/x","isCrossRepository":true}'
    [ "${status}" -eq 1 ]
    run pr_has_dependency_update_branch '{"headRefName":"depends/x","isCrossRepository":false}'
    [ "${status}" -eq 0 ]
    _GH_ME="testuser"
    local fork same
    fork='{"headRefName":"depends/x","isCrossRepository":true,"author":{"login":"alice"},"commits":[{"authors":[{"login":"alice"}]}]}'
    same='{"headRefName":"depends/x","isCrossRepository":false,"author":{"login":"alice"},"commits":[{"authors":[{"login":"alice"}]}]}'
    run pr_is_human_driven "${fork}" '["alice"]'
    [ "${status}" -eq 0 ]
    run pr_is_human_driven "${same}" '["alice"]'
    [ "${status}" -eq 1 ]
}

@test "pr_should_use_dependency_prompt never applies to a PR from a fork, whatever its branch is called" {
    run pr_should_use_dependency_prompt '{"headRefName":"depends/dotnet/10.0.1","isCrossRepository":true,"files":[{"path":"global.json"}]}'
    [ "${status}" -eq 1 ]
    run pr_should_use_dependency_prompt '{"headRefName":"dependabot/npm_and_yarn/x-1.0.0","isCrossRepository":true}'
    [ "${status}" -eq 1 ]
    run pr_should_use_dependency_prompt '{"headRefName":"depends/dotnet/10.0.1","isCrossRepository":false,"files":[{"path":"global.json"}]}'
    [ "${status}" -eq 0 ]
}

@test "fetch_pr_json asks gh for isCrossRepository" {
    local fields_log="${TEST_TMP}/fields.log"
    fetch_pr_fields_json() { printf '%s\n' "$2" > "${fields_log}"; printf '{}'; }
    fetch_pr_json 5
    grep -q 'isCrossRepository' "${fields_log}"
}

@test "pr_should_use_dependency_prompt falls back to the full flow while .deleteme.now is present" {
    run pr_should_use_dependency_prompt '{"headRefName":"depends/x","files":[{"path":".deleteme.now"}]}'
    [ "${status}" -eq 1 ]
}

@test "pr_json_has_placeholder_file detects .deleteme.now only" {
    run pr_json_has_placeholder_file '{"files":[{"path":".deleteme.now"}]}'
    [ "${status}" -eq 0 ]
    run pr_json_has_placeholder_file '{"files":[{"path":"src/a.cs"}]}'
    [ "${status}" -eq 1 ]
    run pr_json_has_placeholder_file '{}'
    [ "${status}" -eq 1 ]
}

@test "pr_json_is_terminal is false for a placeholder-only PR even with auto-merge armed and green CI" {
    run pr_json_is_terminal '{"isDraft":false,"autoMergeRequest":{"enabledAt":"x"},"reviewDecision":"REVIEW_REQUIRED","statusCheckRollup":[],"files":[{"path":".deleteme.now"}]}'
    [ "${status}" -eq 1 ]
}

@test "pr_json_is_terminal is still true once the placeholder is gone" {
    run pr_json_is_terminal '{"isDraft":false,"autoMergeRequest":{"enabledAt":"x"},"reviewDecision":"REVIEW_REQUIRED","statusCheckRollup":[],"files":[{"path":"a.yml"}]}'
    [ "${status}" -eq 0 ]
}

@test "build_pr_claude_md guards auto-merge and ready against a leftover .deleteme.now in both flows" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "true"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"If .deleteme.now is listed"* ]]
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"If .deleteme.now is listed"* ]]
}

@test "build_pr_claude_md's full flow removes a placeholder left next to the real change, and the dependency flow only stops" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"remove it in its own commit (git rm .deleteme.now)"* ]]
    [[ "${output}" == *"If .deleteme.now is the only file listed, the real change has not landed"* ]]
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "true"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"git rm .deleteme.now"* ]]
    [[ "${output}" == *"If .deleteme.now is listed, the real change has not landed"* ]]
}

@test "build_pr_claude_md tells the agent to disarm auto-merge on a placeholder-only PR in both flows" {
    local flag
    for flag in true false; do
        run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "${flag}"
        [ "${status}" -eq 0 ]
        [[ "${output}" == *"cfwf pr take-back --repo ${REPO_FULL} --pr 7 --body-file -"* ]]
        [[ "${output}" == *"cfwf pr view --repo ${REPO_FULL} --pr 7 --field files"* ]]
    done
}

# Runs main once over a single feed PR with the given head branch, files JSON and isCrossRepository
# value, and prints the is_dependency_pr argument main passed to build_pr_claude_md.
main_dependency_flag() {
    local head="$1" files="$2" cross="$3"
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    PR_HEAD="${head}" PR_FILES="${files}" PR_CROSS="${cross}"
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[{"name":"dependencies"}],"headRefOid":"abc","headRefName":"%s","comments":[],"reviews":[],"statusCheckRollup":[],"files":%s,"isCrossRepository":%s}\n' "${PR_HEAD}" "${PR_FILES}" "${PR_CROSS}"; }
    fingerprint_pr_json() { printf 'fp-new\n'; }
    load_pr_fingerprint() { printf 'fp-old\n'; }
    pr_json_has_blocked_label() { return 1; }
    _GH_ME="testuser"
    build_pr_claude_md() { printf '%s\n' "$7" > "${TEST_TMP}/is_dependency_pr"; printf 'mock-pr-claude-md\n'; }
    run main
    [ "${status}" -eq 0 ]
    cat "${TEST_TMP}/is_dependency_pr"
}

@test "main gives a same-repo depends/ PR without the placeholder the dependency prompt" {
    main_dependency_flag "depends/dotnet/10.0.1" '[{"path":"global.json"}]' false > "${TEST_TMP}/flag"
    [ "$(tail -1 "${TEST_TMP}/flag")" = "true" ]
}

@test "main gives a PR that only carries the dependencies label, on a feature branch, the full flow" {
    main_dependency_flag "chore/982-update-github-actions-version-pins" '[{"path":"a.cs"}]' false > "${TEST_TMP}/flag"
    [ "$(tail -1 "${TEST_TMP}/flag")" = "false" ]
}

@test "main gives a depends/ PR that still has the placeholder the full flow" {
    main_dependency_flag "depends/dotnet/10.0.1" '[{"path":".deleteme.now"}]' false > "${TEST_TMP}/flag"
    [ "$(tail -1 "${TEST_TMP}/flag")" = "false" ]
}

@test "main gives a depends/ PR from a fork the full flow" {
    main_dependency_flag "depends/dotnet/10.0.1" '[{"path":"global.json"}]' true > "${TEST_TMP}/flag"
    [ "$(tail -1 "${TEST_TMP}/flag")" = "false" ]
}

@test "pr_is_human_driven returns 1 when the bot has authored a commit" {
    _GH_ME="testuser"
    run pr_is_human_driven '{"labels":[],"author":{"login":"testuser"},"commits":[{"authors":[{"login":"testuser"}]}]}' '["credfeto"]'
    [ "${status}" -eq 1 ]
}

@test "pr_is_human_driven returns 1 when login is unresolved but GIT_USER_EMAIL matches (#1294)" {
    _GH_ME="testuser"
    GIT_USER_EMAIL="bot@example.com"
    run pr_is_human_driven '{"labels":[],"author":{"login":"testuser"},"commits":[{"authors":[{"login":null,"email":"bot@example.com"}]}]}' '["credfeto"]'
    [ "${status}" -eq 1 ]
}

@test "pr_is_human_driven still returns 0 for a human takeover even if a co-author email matches GIT_USER_EMAIL (spoofing guard, #1294 review)" {
    # A human taking over a bot-created PR could add a "Co-Authored-By" trailer carrying the
    # bot's own commit-author email (trivially copyable from the bot's git history) without ever
    # controlling the bot's GitHub account. The resolved login on that commit is genuinely the
    # human's own — the human-takeover verdict must not flip back to "still bot-driven" just
    # because an unauthenticated email string happens to match.
    _GH_ME="testuser"
    GIT_USER_EMAIL="bot@example.com"
    run pr_is_human_driven '{"labels":[],"author":{"login":"testuser"},"commits":[{"authors":[{"login":"humanuser","email":"someone@example.com"},{"login":"humanuser","email":"bot@example.com"}]}]}' '["credfeto"]'
    [ "${status}" -eq 0 ]
}

@test "pr_is_human_driven still detects a bot-created taken-over PR when the sole commit's email does not match GIT_USER_EMAIL (#1294)" {
    # Regression guard: the email fallback must not swallow the existing "zero bot commits"
    # takeover signal (author.login == bot, but no commit — bot or otherwise-matching-email —
    # was ever authored by the bot) into a false "still bot-driven" verdict.
    _GH_ME="testuser"
    GIT_USER_EMAIL="bot@example.com"
    run pr_is_human_driven '{"labels":[],"author":{"login":"testuser"},"commits":[{"authors":[{"login":null,"email":"someone-else@example.com"}]}]}' '["credfeto"]'
    [ "${status}" -eq 0 ]
}

@test "pr_is_human_driven returns 0 for a bot-created PR with zero bot commits (taken over)" {
    _GH_ME="testuser"
    run pr_is_human_driven '{"labels":[],"author":{"login":"testuser"},"commits":[{"authors":[{"login":"credfeto"}]}]}' '["credfeto"]'
    [ "${status}" -eq 0 ]
}

@test "pr_is_human_driven returns 0 for a PR opened by the PR create bot with zero bot commits (taken over) (#1517)" {
    _GH_ME="testuser"
    run pr_is_human_driven '{"labels":[],"author":{"login":"prpixie"},"commits":[{"authors":[{"login":"credfeto"}]}]}' '["credfeto"]'
    [ "${status}" -eq 0 ]
}

@test "pr_is_human_driven returns 1 for a PR opened by the PR create bot that has the AI agent's commits (#1517)" {
    _GH_ME="testuser"
    run pr_is_human_driven '{"labels":[],"author":{"login":"prpixie"},"commits":[{"authors":[{"login":"testuser"}]}]}' '["credfeto"]'
    [ "${status}" -eq 1 ]
}

@test "pr_is_human_driven exempts a not-yet-claimed dependency-bump PR opened under the bot's own login (credfeto-enum-source-generation#118)" {
    _GH_ME="testuser"
    # The bump tooling's commit is authored by the trusted owner login, and this one rare case
    # got opened under the bot's own account instead of the usual app/github-actions — with zero
    # bot commits yet, that would otherwise look identical to a real takeover. The "depends/"
    # branch — set once at push time, never by label-sync — must win instead.
    run pr_is_human_driven '{"labels":[],"headRefName":"depends/update-funfair.codeanalysis/7.2.6.2145","author":{"login":"testuser"},"commits":[{"authors":[{"login":"credfeto"}]}]}' '["credfeto"]'
    [ "${status}" -eq 1 ]
}

@test "pr_is_human_driven still stands off a taken-over bot PR on a non-depends branch (#1134 guard)" {
    _GH_ME="testuser"
    # A real feature-branch takeover must not be exempted just because it also carries a
    # dependencies-ish label — the branch-name exemption above must not widen this hole.
    run pr_is_human_driven '{"labels":[{"name":"dependencies"}],"headRefName":"fix/123-something","author":{"login":"testuser"},"commits":[{"authors":[{"login":"credfeto"}]}]}' '["credfeto"]'
    [ "${status}" -eq 0 ]
}

@test "pr_is_human_driven returns 0 when a trusted human authored commits on a non-bot PR" {
    _GH_ME="testuser"
    run pr_is_human_driven '{"labels":[],"author":{"login":"someone-else"},"commits":[{"authors":[{"login":"credfeto"}]}]}' '["credfeto"]'
    [ "${status}" -eq 0 ]
}

@test "pr_is_human_driven returns 1 for an untrusted automation PR (dependabot-style, unlabelled)" {
    _GH_ME="testuser"
    run pr_is_human_driven '{"labels":[],"author":{"login":"app/dependabot"},"commits":[{"authors":[{"login":"app/dependabot"}]}]}' '["credfeto"]'
    [ "${status}" -eq 1 ]
}

@test "pr_is_human_driven returns 2 when the identity lookup fails" {
    _GH_ME=""
    GH_USER_RETRY_ATTEMPTS=1
    GH_USER_RETRY_DELAY_SECS=0
    make_stub gh 'exit 1'
    run pr_is_human_driven '{"labels":[],"author":{"login":"testuser"},"commits":[]}' '["credfeto"]'
    [ "${status}" -eq 2 ]
}

# --- main() skip_repos integration tests -------------------------------------
# These tests exercise the multi-repo iteration logic in main() by overriding
# all external-call functions.  No PATH stubs are used — all overrides are
# function-level so no teardown stub cleanup is required beyond the common hook.

@test "main is_skipped resets between iterations so different-repo items are not incorrectly skipped" {
    # Three-item scenario that exercises the is_skipped reset:
    # Item 1 (PR #5, org/repo): non-blocked, unchanged → skip_repos += org/repo (is_skipped stays false)
    # Item 2 (Issue #10, org/repo): for-loop matches skip_repos → is_skipped=true → "active work" skip
    # Item 3 (Issue #20, other/repo): is_skipped must be reset to false; without the reset it stays
    #   true from iteration 2 and incorrectly skips this different-repo item.
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false},{"id":10,"itemType":"Issue","repository":"org/repo","priority":2,"status":"Open","isOnHold":false},{"id":20,"itemType":"Issue","repository":"other/repo","priority":3,"status":"Open","isOnHold":false}]'
    }
    # Auto-merge enabled makes the unchanged PR terminal, so it skips (rather than being
    # re-invoked to advance a phase) — this test exercises the skip_repos/is_skipped logic.
    fetch_pr_json()             { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[],"autoMergeRequest":{"enabledAt":"now"}}\n'; }
    pr_json_has_blocked_label() { return 1; }
    fingerprint_pr_json()       { printf 'fp-same\n'; }
    load_pr_fingerprint()       { printf 'fp-same\n'; }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json()          { printf '{"title":"T","body":"","state":"OPEN","labels":[{"name":"Blocked"}],"comments":[],"assignees":[],"milestone":null}\n'; }
    issue_json_has_blocked_label() { return 0; }

    run main
    [ "${status}" -eq 0 ]
    # Item 1: PR terminal (settled) → skip_repos += org/repo
    [[ "${output}" == *"PR #5 in org/repo: settled"* ]]
    # Item 2: Issue #10 correctly skipped via skip_repos (is_skipped=true at end of this iteration)
    [[ "${output}" == *"Skipping Issue #10 in org/repo — repo already has active work"* ]]
    # Item 3: Issue #20 must be evaluated (is_skipped reset to false) and hit the "blocked" path
    [[ "${output}" == *"Issue #20 in other/repo is blocked — skipping"* ]]
    # Must NOT see "repo already has active work" for other/repo (that would be the stale-is_skipped bug)
    [[ "${output}" != *"Skipping Issue #20 in other/repo — repo already has active work"* ]]
    [[ "${output}" == *"No actionable work items found"* ]]
}

@test "main skips same-repo issue when repo has a non-blocked unchanged PR in priorities" {
    # Item 1 (PR #5, org/repo): open, non-blocked, unchanged → skip_repos += org/repo, continue
    # Item 2 (Issue #10, org/repo): same repo → skipped with "repo already has active work"
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false},{"id":10,"itemType":"Issue","repository":"org/repo","priority":2,"status":"Open","isOnHold":false}]'
    }
    # Auto-merge enabled makes the unchanged PR terminal, so it skips (rather than being
    # re-invoked to advance a phase) — this test exercises the skip_repos guard.
    fetch_pr_json()             { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[],"autoMergeRequest":{"enabledAt":"now"}}\n'; }
    pr_json_has_blocked_label() { return 1; }
    fingerprint_pr_json()       { printf 'fp-same\n'; }
    load_pr_fingerprint()       { printf 'fp-same\n'; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PR #5 in org/repo: settled"* ]]
    [[ "${output}" == *"Skipping Issue #10 in org/repo — repo already has active work"* ]]
    [[ "${output}" == *"No actionable work items found"* ]]
}

@test "main notifies Discord when a settled direct PR needs review approval (#1278)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[],"autoMergeRequest":{"enabledAt":"now"},"reviewDecision":"REVIEW_REQUIRED"}\n'; }
    pr_json_has_blocked_label() { return 1; }
    fingerprint_pr_json()       { printf 'fp-same\n'; }
    load_pr_fingerprint()       { printf 'fp-same\n'; }
    local discord_log="${TEST_TMP}/discord_log"
    notify_discord_pr_needs_approval() { printf 'notified %s: %s\n' "$1" "$2" >> "${discord_log}"; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PR #5 in org/repo: settled"* ]]
    [ -f "${discord_log}" ]
    grep -q '^notified 5: .*"title":"T"' "${discord_log}"
}

@test "main does not notify Discord when a settled direct PR is already approved (#1278)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[],"autoMergeRequest":{"enabledAt":"now"},"reviewDecision":"APPROVED"}\n'; }
    pr_json_has_blocked_label() { return 1; }
    fingerprint_pr_json()       { printf 'fp-same\n'; }
    load_pr_fingerprint()       { printf 'fp-same\n'; }
    local discord_log="${TEST_TMP}/discord_log"
    notify_discord_pr_needs_approval() { printf 'notified\n' >> "${discord_log}"; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PR #5 in org/repo: settled"* ]]
    [ ! -f "${discord_log}" ]
}

@test "main treats a direct PR as settled via the Workflow Status board fallback when auto-merge isn't supported (#1479)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[],"autoMergeRequest":null,"reviewDecision":"REVIEW_REQUIRED"}\n'; }
    pr_json_has_blocked_label() { return 1; }
    fingerprint_pr_json()       { printf 'fp-same\n'; }
    load_pr_fingerprint()       { printf 'fp-same\n'; }
    pr_review_pipeline_finished_without_auto_merge() { return 0; }
    local discord_log="${TEST_TMP}/discord_log"
    notify_discord_pr_needs_approval() { printf 'notified %s: %s\n' "$1" "$2" >> "${discord_log}"; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"PR #5 in org/repo: settled (ready to merge, nothing failed/pending) — no agent needed"* ]]
    [ -f "${discord_log}" ]
    grep -q '^notified 5: .*"title":"T"' "${discord_log}"
}

@test "main does not treat a direct PR as settled when autoMergeRequest is null and the board fallback doesn't match either (#1479)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[],"autoMergeRequest":null,"reviewDecision":"REVIEW_REQUIRED"}\n'; }
    pr_json_has_blocked_label() { return 1; }
    # pr_review_pipeline_finished_without_auto_merge defaults to false (setup_main_mocks) - not
    # overridden here, so the board never claims the pipeline finished.
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"settled"* ]]
    [ -f "${TEST_TMP}/claude_log" ]
}

@test "main notifies Discord waiting on CI for a direct PR with pending required checks (#1375)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feature/x","comments":[],"reviews":[],"statusCheckRollup":[{"isRequired":true,"status":"IN_PROGRESS"}]}\n'; }
    pr_json_has_blocked_label() { return 1; }
    local waiting_log="${TEST_TMP}/waiting_log"
    notify_discord_pr_waiting() {
        local branch
        branch=$(printf '%s' "$2" | jq -r '.headRefName // empty')
        printf 'id=%s branch=%s progress=%s\n' "$1" "${branch}" "$4" >> "${waiting_log}"
    }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PR #5 in org/repo: CI checks pending — deferring"* ]]
    [ -f "${waiting_log}" ]
    grep -q '^id=5 branch=feature/x progress=Waiting on CI$' "${waiting_log}"
}

@test "main notifies Discord waiting on human review for a settled direct PR (#1375)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feature/x","comments":[],"reviews":[],"statusCheckRollup":[],"autoMergeRequest":{"enabledAt":"now"},"reviewDecision":"APPROVED"}\n'; }
    pr_json_has_blocked_label() { return 1; }
    fingerprint_pr_json()       { printf 'fp-same\n'; }
    load_pr_fingerprint()       { printf 'fp-same\n'; }
    local waiting_log="${TEST_TMP}/waiting_log"
    notify_discord_pr_waiting() {
        local branch
        branch=$(printf '%s' "$2" | jq -r '.headRefName // empty')
        printf 'id=%s branch=%s progress=%s\n' "$1" "${branch}" "$4" >> "${waiting_log}"
    }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PR #5 in org/repo: settled"* ]]
    [ -f "${waiting_log}" ]
    grep -q '^id=5 branch=feature/x progress=Waiting on human review$' "${waiting_log}"
}

@test "main evaluates second PR in same repo when first PR is unchanged" {
    # Item 1 (PR #5, org/repo): open, non-blocked, unchanged → skip_repos += org/repo, continue
    # Item 2 (PR #17, org/repo): same repo — PRs bypass the skip_repos guard → evaluated
    #   PR #17 fingerprint differs from saved → actionable → Claude invoked → exit 0
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false},{"id":17,"itemType":"PullRequest","repository":"org/repo","priority":2,"status":"Open","isOnHold":false}]'
    }
    # PR #5 is unchanged; make it terminal (auto-merge enabled) so it skips instead of being
    # re-invoked to advance a phase. PR #17 is non-terminal and (below) fingerprint-changed.
    fetch_pr_json()             {
        if [ "$1" = "5" ]; then
            printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefName":"branch-5","autoMergeRequest":{"enabledAt":"now"}}\n'
        else
            printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefName":"branch-17"}\n'
        fi
    }
    pr_json_has_blocked_label() { return 1; }
    fingerprint_pr_json()       {
        # First call (PR #5): return saved fingerprint so it is unchanged.
        # Second call (PR #17): return a different fingerprint so it is actionable.
        local _fp_call_file="${TEST_TMP}/_fp_call"
        [ -f "${_fp_call_file}" ] || printf '0' > "${_fp_call_file}"
        local _count
        _count=$(cat "${_fp_call_file}")
        _count=$((_count + 1))
        printf '%d' "${_count}" > "${_fp_call_file}"
        [ "${_count}" -eq 1 ] && printf 'fp-same\n' || printf 'fp-new\n'
    }
    load_pr_fingerprint()       {
        # PR #5 has a saved fingerprint; PR #17 has none.
        [ "$1" = "5" ] && printf 'fp-same\n' || printf ''
    }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PR #5 in org/repo: settled"* ]]
    [[ "${output}" != *"Skipping PullRequest #17 in org/repo — repo already has active work"* ]]
    [[ "${output}" == *"Found actionable PullRequest #17 in org/repo"* ]]
}

@test "main does not add repo to skip_repos for a blocked PR in priorities so same-repo issue is still evaluated" {
    # Item 1 (PR #5, org/repo): blocked → skipped, NOT added to skip_repos
    # Item 2 (Issue #10, org/repo): must be evaluated; here it is also blocked → no work
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false},{"id":10,"itemType":"Issue","repository":"org/repo","priority":2,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json()             { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[{"name":"Blocked"}],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}\n'; }
    pr_json_has_blocked_label() { return 0; }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json()          { printf '{"title":"T","body":"","state":"OPEN","labels":[{"name":"Blocked"}],"comments":[],"assignees":[],"milestone":null}\n'; }
    issue_json_has_blocked_label() { return 0; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PR #5 in org/repo is blocked — skipping (not counting as active work)"* ]]
    # Issue #10 must be evaluated (not falsely skipped due to skip_repos from the blocked PR)
    [[ "${output}" == *"Issue #10 in org/repo is blocked — skipping"* ]]
    [[ "${output}" != *"Skipping Issue #10 in org/repo — repo already has active work"* ]]
    [[ "${output}" == *"No actionable work items found"* ]]
}

@test "main does not add repo to skip_repos when switched-to PR is no longer open" {
    # Item 1 (Issue #10, org/repo): issue is open+unblocked, finds PR #99 via list (open at
    #   list time), but fetch returns MERGED — race condition.  Repo must NOT be added to
    #   skip_repos.
    # Item 2 (Issue #20, org/repo): same repo must still be evaluated; second call to
    #   find_open_nonblocked_pr_for_repo returns empty (PR gone); issue is blocked → no work.
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false},{"id":20,"itemType":"Issue","repository":"org/repo","priority":2,"status":"Open","isOnHold":false}]'
    }
    # The function is called via $(...) substitution (subshell), so incrementing a variable
    # inside the function would not persist.  Use a temp file as a persistent call counter.
    local _pr_call_file="${TEST_TMP}/_pr_call"
    printf '0' > "${_pr_call_file}"
    find_open_nonblocked_pr_for_repo() {
        local _count
        _count=$(cat "${_pr_call_file}")
        _count=$((_count + 1))
        printf '%d' "${_count}" > "${_pr_call_file}"
        [ "${_count}" -eq 1 ] && printf '99\n' || printf ''
    }
    stub_pr_merged
    # Issue #10 (first call, pivot path): open, not blocked — allows the PR-state check to fire.
    # Issue #20 (second call, no-PR path): open, blocked.
    local _issue_call_file="${TEST_TMP}/_issue_call"
    printf '0' > "${_issue_call_file}"
    fetch_issue_json() {
        local _count
        _count=$(cat "${_issue_call_file}")
        _count=$((_count + 1))
        printf '%d' "${_count}" > "${_issue_call_file}"
        if [ "${_count}" -eq 1 ]; then
            printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'
        else
            printf '{"title":"T","body":"","state":"OPEN","labels":[{"name":"Blocked"}],"comments":[],"assignees":[],"milestone":null}\n'
        fi
    }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PR #99 in org/repo is no longer open — skipping"* ]]
    # Issue #20 must be evaluated (repo NOT in skip_repos)
    [[ "${output}" == *"Issue #20 in org/repo is blocked — skipping"* ]]
    [[ "${output}" != *"Skipping Issue #20 in org/repo — repo already has active work"* ]]
    [[ "${output}" == *"No actionable work items found"* ]]
}

@test "main skips same-repo issue when linked PR found via issue-to-PR pivot is unchanged" {
    # Item 1 (Issue #10, org/repo): find_open_nonblocked_pr_for_repo returns PR #99.
    #   Issue is open and unblocked; PR is open, non-blocked, fingerprint matches saved;
    #   issue fingerprint also matches saved → "unchanged — skipping repo".
    #   org/repo is added to skip_repos.
    # Item 2 (Issue #20, org/repo): same repo → "repo already has active work".
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false},{"id":20,"itemType":"Issue","repository":"org/repo","priority":2,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf '99\n'; }
    fetch_issue_json()          { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    # Auto-merge enabled makes the unchanged pivot PR terminal, so it skips the repo rather than
    # being re-invoked to advance a phase — this test exercises the skip_repos pivot logic.
    fetch_pr_json()             { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[],"autoMergeRequest":{"enabledAt":"now"}}\n'; }
    pr_json_has_blocked_label() { return 1; }
    fingerprint_pr_json()       { printf 'fp-same\n'; }
    load_pr_fingerprint()       { printf 'fp-same\n'; }
    fingerprint_issue_json()    { printf 'issue-fp-same\n'; }
    load_issue_fingerprint()    { printf 'issue-fp-same\n'; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PR #99 in org/repo: settled"* ]]
    [[ "${output}" == *"Skipping Issue #20 in org/repo — repo already has active work"* ]]
    [[ "${output}" == *"No actionable work items found"* ]]
}

@test "main notifies Discord when a settled pivot PR needs review approval (#1278)" {
    # Same pivot scenario as above (Issue #10 → linked PR #99, settled), but the linked PR's
    # reviewDecision is REVIEW_REQUIRED — the notifier must fire from the issue-pivot call site,
    # not just the direct-PR one.
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf '99\n'; }
    fetch_issue_json()          { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    fetch_pr_json()             { printf '{"state":"OPEN","title":"PR title","body":"","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[],"autoMergeRequest":{"enabledAt":"now"},"reviewDecision":"REVIEW_REQUIRED"}\n'; }
    pr_json_has_blocked_label() { return 1; }
    fingerprint_pr_json()       { printf 'fp-same\n'; }
    load_pr_fingerprint()       { printf 'fp-same\n'; }
    fingerprint_issue_json()    { printf 'issue-fp-same\n'; }
    load_issue_fingerprint()    { printf 'issue-fp-same\n'; }
    local discord_log="${TEST_TMP}/discord_log"
    notify_discord_pr_needs_approval() { printf 'notified %s: %s\n' "$1" "$2" >> "${discord_log}"; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PR #99 in org/repo: settled"* ]]
    [ -f "${discord_log}" ]
    grep -q '^notified 99: .*"title":"PR title"' "${discord_log}"
}

@test "main treats a pivot PR as settled via the Workflow Status board fallback when auto-merge isn't supported (#1479)" {
    # Same pivot scenario as above (Issue #10 → linked PR #99), but autoMergeRequest is null -
    # the fallback must still recognize the pipeline finished and both suppress the agent
    # invocation AND fire the review-needed nudge, from the issue-pivot call site.
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf '99\n'; }
    fetch_issue_json()          { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    fetch_pr_json()             { printf '{"state":"OPEN","title":"PR title","body":"","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[],"autoMergeRequest":null,"reviewDecision":"REVIEW_REQUIRED"}\n'; }
    pr_json_has_blocked_label() { return 1; }
    fingerprint_pr_json()       { printf 'fp-same\n'; }
    load_pr_fingerprint()       { printf 'fp-same\n'; }
    fingerprint_issue_json()    { printf 'issue-fp-same\n'; }
    load_issue_fingerprint()    { printf 'issue-fp-same\n'; }
    pr_review_pipeline_finished_without_auto_merge() { return 0; }
    local discord_log="${TEST_TMP}/discord_log"
    notify_discord_pr_needs_approval() { printf 'notified %s: %s\n' "$1" "$2" >> "${discord_log}"; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"PR #99 in org/repo: settled (ready to merge, nothing failed/pending) — no agent needed"* ]]
    [ -f "${discord_log}" ]
    grep -q '^notified 99: .*"title":"PR title"' "${discord_log}"
}

@test "main notifies Discord waiting on CI for a pivot PR with pending required checks (#1375)" {
    # This is the ONLY CI-pending check a pivoted PR ever reaches (#1375 review) — the shared
    # Work block used to have its own (unreachable) copy where this notification was originally,
    # and mistakenly, wired up.
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf '99\n'; }
    fetch_issue_json()          { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    fetch_pr_json()             { printf '{"state":"OPEN","title":"PR title","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feature/y","comments":[],"reviews":[],"statusCheckRollup":[{"isRequired":true,"status":"IN_PROGRESS"}]}\n'; }
    pr_json_has_blocked_label() { return 1; }
    local waiting_log="${TEST_TMP}/waiting_log"
    notify_discord_pr_waiting() {
        local branch
        branch=$(printf '%s' "$2" | jq -r '.headRefName // empty')
        printf 'id=%s branch=%s progress=%s\n' "$1" "${branch}" "$4" >> "${waiting_log}"
    }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PR #99 in org/repo: CI checks pending — deferring"* ]]
    [ -f "${waiting_log}" ]
    grep -q '^id=99 branch=feature/y progress=Waiting on CI$' "${waiting_log}"
}

@test "main notifies Discord waiting on human review for a settled pivot PR (#1375)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf '99\n'; }
    fetch_issue_json()          { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    fetch_pr_json()             { printf '{"state":"OPEN","title":"PR title","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feature/y","comments":[],"reviews":[],"statusCheckRollup":[],"autoMergeRequest":{"enabledAt":"now"},"reviewDecision":"APPROVED"}\n'; }
    pr_json_has_blocked_label() { return 1; }
    fingerprint_pr_json()       { printf 'fp-same\n'; }
    load_pr_fingerprint()       { printf 'fp-same\n'; }
    local waiting_log="${TEST_TMP}/waiting_log"
    notify_discord_pr_waiting() {
        local branch
        branch=$(printf '%s' "$2" | jq -r '.headRefName // empty')
        printf 'id=%s branch=%s progress=%s\n' "$1" "${branch}" "$4" >> "${waiting_log}"
    }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PR #99 in org/repo: settled"* ]]
    [ -f "${waiting_log}" ]
    grep -q '^id=99 branch=feature/y progress=Waiting on human review$' "${waiting_log}"
}

@test "main re-runs via pivot PR when PR unchanged but issue has new comment" {
    # Issue #10 has linked PR #99. PR fingerprint unchanged, but issue fingerprint changed
    # (user added a comment). Expect agent to be invoked.
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf '99\n'; }
    fetch_issue_json()          { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[{"body":"how to fix","updatedAt":"2024-01-01"}],"assignees":[],"milestone":null}\n'; }
    fetch_pr_json()             { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}\n'; }
    pr_json_has_blocked_label() { return 1; }
    fingerprint_pr_json()       { printf 'fp-same\n'; }
    load_pr_fingerprint()       { printf 'fp-same\n'; }
    fingerprint_issue_json()    { printf 'issue-fp-new\n'; }
    load_issue_fingerprint()    { printf 'issue-fp-old\n'; }
    local _invoke_log="${TEST_TMP}/invoke_log"
    invoke_claude() { printf 'invoked\n' >> "${_invoke_log}"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Issue #10 in org/repo changed — re-running against PR #99"* ]]
    [ -f "${_invoke_log}" ]
}

@test "main re-runs via pivot PR when PR unchanged and issue has no saved fingerprint" {
    # Issue #10 has linked PR #99. PR fingerprint unchanged, but there is no saved issue
    # fingerprint yet (first run after the fix was deployed). Expect agent to be invoked
    # so the issue fingerprint is initialised.
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf '99\n'; }
    fetch_issue_json()          { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    fetch_pr_json()             { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}\n'; }
    pr_json_has_blocked_label() { return 1; }
    fingerprint_pr_json()       { printf 'fp-same\n'; }
    load_pr_fingerprint()       { printf 'fp-same\n'; }
    fingerprint_issue_json()    { printf 'issue-fp-new\n'; }
    load_issue_fingerprint()    { printf ''; }
    local _invoke_log="${TEST_TMP}/invoke_log"
    invoke_claude() { printf 'invoked\n' >> "${_invoke_log}"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ -f "${_invoke_log}" ]
}

@test "main invokes the agent for an unchanged draft PR within the idle budget via issue pivot (#1447)" {
    # Both the PR's and the linked issue's fingerprints are unchanged, and the PR is a draft: this
    # must still route through the same pr_should_advance_unchanged idle-budget check a non-draft
    # pivot PR already gets, not the old unconditional "still in draft — re-running" bypass.
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf '99\n'; }
    fetch_issue_json()          { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    fetch_pr_json()             { printf '{"state":"OPEN","title":"T","body":"","isDraft":true,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}\n'; }
    pr_json_has_blocked_label() { return 1; }
    fingerprint_pr_json()       { printf 'fp-same\n'; }
    load_pr_fingerprint()       { printf 'fp-same\n'; }
    fingerprint_issue_json()    { printf 'issue-fp-same\n'; }
    load_issue_fingerprint()    { printf 'issue-fp-same\n'; }
    save_pr_invocation_counts 99 2 2
    local _invoke_log="${TEST_TMP}/invoke_log"
    invoke_claude() { printf 'invoked\n' >> "${_invoke_log}"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PR #99 in org/repo unchanged — re-invoking to advance the next workflow phase"* ]]
    [ -f "${_invoke_log}" ]
}

@test "main re-runs an unchanged pivot PR that needs a rebase even when the board is Complete (#1557)" {
    # The direct-PR path re-runs an unchanged BEHIND/DIRTY PR before it consults the board; the
    # pivot path must too, or the board's phase is handed to the agent instead of the rebase.
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf '99\n'; }
    fetch_issue_json()          { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    fetch_pr_json()             { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"fix/x","comments":[],"reviews":[],"statusCheckRollup":[],"mergeStateStatus":"DIRTY"}\n'; }
    pr_json_has_blocked_label() { return 1; }
    fingerprint_pr_json()       { printf 'fp-same\n'; }
    load_pr_fingerprint()       { printf 'fp-same\n'; }
    fingerprint_issue_json()    { printf 'issue-fp-same\n'; }
    load_issue_fingerprint()    { printf 'issue-fp-same\n'; }
    fetch_board_item_statuses() { return 0; }
    board_substatus_for_item()  { printf 'called\n' >> "${TEST_TMP}/board_lookups"; printf 'Complete'; }
    save_pr_invocation_counts 99 2 2
    local _invoke_log="${TEST_TMP}/invoke_log"
    invoke_claude() { printf 'invoked\n' >> "${_invoke_log}"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PR #99 in org/repo unchanged but DIRTY - re-running"* ]]
    [ ! -f "${TEST_TMP}/board_lookups" ]
    [ -f "${_invoke_log}" ]
}

@test "main does not charge the idle budget when a required check is still pending after the session, via issue pivot (#1463)" {
    # Same race as the direct-PR path equivalent test: the pre-invocation CI-pending check can
    # miss a check that is still genuinely running by the time the agent's own session checks
    # it, so the post-session re-check must catch it and leave the idle counter unchanged.
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf '99\n'; }
    fetch_issue_json()          { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    local _pr_json_call_file="${TEST_TMP}/_pr_json_calls"
    printf '0' > "${_pr_json_call_file}"
    fetch_pr_json() {
        local _count
        _count=$(cat "${_pr_json_call_file}")
        _count=$((_count + 1))
        printf '%d' "${_count}" > "${_pr_json_call_file}"
        if [ "${_count}" -eq 1 ]; then
            printf '{"state":"OPEN","title":"T","body":"","isDraft":true,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}\n'
        else
            printf '{"state":"OPEN","title":"T","body":"","isDraft":true,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null,"isRequired":true}]}\n'
        fi
    }
    pr_json_has_blocked_label() { return 1; }
    fingerprint_pr_json()       { printf 'fp-same\n'; }
    load_pr_fingerprint()       { printf 'fp-same\n'; }
    fingerprint_issue_json()    { printf 'issue-fp-same\n'; }
    load_issue_fingerprint()    { printf 'issue-fp-same\n'; }
    save_pr_invocation_counts 99 2 2
    local _invoke_log="${TEST_TMP}/invoke_log"
    invoke_claude() { printf 'invoked\n' >> "${_invoke_log}"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ -f "${_invoke_log}" ]
    [[ "${output}" == *"PR #99 in org/repo: still CI-pending after this session — not counting it against the idle budget"* ]]
    load_pr_invocation_counts 99
    [ "${PR_INVOCATION_IDLE}" -eq 2 ]
    [ "${PR_INVOCATION_TOTAL}" -eq 3 ]
}

@test "main resets the idle budget when the board advances during the session, via issue pivot (#1474)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf '99\n'; }
    fetch_issue_json()          { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    fetch_pr_json()             { printf '{"state":"OPEN","title":"T","body":"","isDraft":true,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}\n'; }
    local _board_call_file="${TEST_TMP}/_board_calls"
    printf '0' > "${_board_call_file}"
    fetch_single_item_workflow_status() {
        local _count
        _count=$(cat "${_board_call_file}")
        _count=$((_count + 1))
        printf '%d' "${_count}" > "${_board_call_file}"
        [ "${_count}" -eq 1 ] && printf 'AI Review' || printf 'AI Security Review'
    }
    fetch_pr_latest_trusted_comment_timestamp() { printf ''; }
    pr_json_has_blocked_label() { return 1; }
    fingerprint_pr_json()       { printf 'fp-same\n'; }
    load_pr_fingerprint()       { printf 'fp-same\n'; }
    fingerprint_issue_json()    { printf 'issue-fp-same\n'; }
    load_issue_fingerprint()    { printf 'issue-fp-same\n'; }
    save_pr_invocation_counts 99 2 2
    local _invoke_log="${TEST_TMP}/invoke_log"
    invoke_claude() { printf 'invoked\n' >> "${_invoke_log}"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ -f "${_invoke_log}" ]
    [[ "${output}" == *"PR #99 in org/repo: not charging this session against the idle budget (board moved from AI Review to AI Security Review)"* ]]
    load_pr_invocation_counts 99
    [ "${PR_INVOCATION_IDLE}" -eq 0 ]
    [ "${PR_INVOCATION_TOTAL}" -eq 3 ]
}

@test "main resets the idle budget when a new trusted comment is posted during the session, via issue pivot (#1474)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf '99\n'; }
    fetch_issue_json()          { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    fetch_pr_json()             { printf '{"state":"OPEN","title":"T","body":"","isDraft":true,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}\n'; }
    fetch_single_item_workflow_status() { printf 'Development'; }
    fetch_pr_latest_trusted_comment_timestamp() { printf '2026-09-19T12:00:00Z\n'; }
    pr_json_has_blocked_label() { return 1; }
    fingerprint_pr_json()       { printf 'fp-same\n'; }
    load_pr_fingerprint()       { printf 'fp-same\n'; }
    fingerprint_issue_json()    { printf 'issue-fp-same\n'; }
    load_issue_fingerprint()    { printf 'issue-fp-same\n'; }
    save_pr_invocation_counts 99 2 2
    local _invoke_log="${TEST_TMP}/invoke_log"
    invoke_claude() { printf 'invoked\n' >> "${_invoke_log}"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ -f "${_invoke_log}" ]
    [[ "${output}" == *"PR #99 in org/repo: not charging this session against the idle budget (a trusted comment arrived during the session and is left unaddressed for the next run)"* ]]
    load_pr_invocation_counts 99
    [ "${PR_INVOCATION_IDLE}" -eq 0 ]
    [ "${PR_INVOCATION_TOTAL}" -eq 3 ]
}

@test "main still charges the idle budget when neither the board nor comments changed, via issue pivot (#1474)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf '99\n'; }
    fetch_issue_json()          { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    fetch_pr_json()             { printf '{"state":"OPEN","title":"T","body":"","isDraft":true,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}\n'; }
    fetch_single_item_workflow_status() { printf 'AI Review'; }
    fetch_pr_latest_trusted_comment_timestamp() { printf ''; }
    pr_json_has_blocked_label() { return 1; }
    fingerprint_pr_json()       { printf 'fp-same\n'; }
    load_pr_fingerprint()       { printf 'fp-same\n'; }
    fingerprint_issue_json()    { printf 'issue-fp-same\n'; }
    load_issue_fingerprint()    { printf 'issue-fp-same\n'; }
    save_pr_invocation_counts 99 2 2
    local _invoke_log="${TEST_TMP}/invoke_log"
    invoke_claude() { printf 'invoked\n' >> "${_invoke_log}"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ -f "${_invoke_log}" ]
    [[ "${output}" == *"no progress this session"* ]]
    load_pr_invocation_counts 99
    [ "${PR_INVOCATION_IDLE}" -eq 3 ]
    [ "${PR_INVOCATION_TOTAL}" -eq 3 ]
}

@test "main blocks unchanged draft PR reached via issue pivot once idle budget exhausted with a failed required check (#1447)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf '99\n'; }
    fetch_issue_json()          { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    fetch_pr_json()             { printf '{"state":"OPEN","title":"T","body":"","isDraft":true,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"FAILURE","isRequired":true}]}\n'; }
    pr_json_has_blocked_label() { return 1; }
    fingerprint_pr_json()       { printf 'fp-same\n'; }
    load_pr_fingerprint()       { printf 'fp-same\n'; }
    fingerprint_issue_json()    { printf 'issue-fp-same\n'; }
    load_issue_fingerprint()    { printf 'issue-fp-same\n'; }
    save_pr_invocation_counts 99 4 "${MAX_PR_IDLE_INVOCATIONS}"
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    grep -q 'pr comment 99' "${GH_CALL_LOG}"
    grep -q 'Blocked' "${GH_CALL_LOG}"
}

@test "main blocks unchanged draft PR reached via issue pivot once idle budget exhausted with an unaddressed review request (#1447)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf '99\n'; }
    fetch_issue_json()          { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    fetch_pr_json()             { printf '{"state":"OPEN","title":"T","body":"","isDraft":true,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"reviewDecision":"CHANGES_REQUESTED","statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS","isRequired":true}]}\n'; }
    pr_json_has_blocked_label() { return 1; }
    fingerprint_pr_json()       { printf 'fp-same\n'; }
    load_pr_fingerprint()       { printf 'fp-same\n'; }
    fingerprint_issue_json()    { printf 'issue-fp-same\n'; }
    load_issue_fingerprint()    { printf 'issue-fp-same\n'; }
    save_pr_invocation_counts 99 4 "${MAX_PR_IDLE_INVOCATIONS}"
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    grep -q 'pr comment 99' "${GH_CALL_LOG}"
    grep -q 'Blocked' "${GH_CALL_LOG}"
}

@test "main blocks unchanged draft PR reached via issue pivot with idle budget exhausted and no known blocking reason (#1463)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf '99\n'; }
    fetch_issue_json()          { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    fetch_pr_json()             { printf '{"state":"OPEN","title":"T","body":"","isDraft":true,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS","isRequired":true}]}\n'; }
    pr_json_has_blocked_label() { return 1; }
    fingerprint_pr_json()       { printf 'fp-same\n'; }
    load_pr_fingerprint()       { printf 'fp-same\n'; }
    fingerprint_issue_json()    { printf 'issue-fp-same\n'; }
    load_issue_fingerprint()    { printf 'issue-fp-same\n'; }
    save_pr_invocation_counts 99 4 "${MAX_PR_IDLE_INVOCATIONS}"
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    grep -q 'pr comment 99' "${GH_CALL_LOG}"
    grep -q 'Blocked' "${GH_CALL_LOG}"
}

@test "main saves issue fingerprint after running agent on PR via issue pivot" {
    # Issue #10 has linked PR #99. Issue fingerprint changed → agent runs on PR #99.
    # Expect save_issue_fingerprint called with original issue ID (10), not PR ID (99).
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf '99\n'; }
    fetch_issue_json()          { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    fetch_pr_json()             { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}\n'; }
    pr_json_has_blocked_label() { return 1; }
    fingerprint_pr_json()       { printf 'fp-same\n'; }
    load_pr_fingerprint()       { printf 'fp-same\n'; }
    fingerprint_issue_json()    { printf 'issue-fp-new\n'; }
    load_issue_fingerprint()    { printf 'issue-fp-old\n'; }
    local _save_issue_log="${TEST_TMP}/save_issue_log"
    save_issue_fingerprint() { printf 'id=%s fp=%s\n' "$1" "$2" >> "${_save_issue_log}"; }

    run main
    [ "${status}" -eq 0 ]
    grep -q 'id=10' "${_save_issue_log}"
}

# --- main() git clean after session -------------------------------------------

@test "main runs git clean -fdX after invoke_claude succeeds for an Issue" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    local git_log="${TEST_TMP}/git_calls"
    cat > "${STUB_BIN}/git" << STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${git_log}"
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/git"
    hash git

    run main
    [ "${status}" -eq 0 ]
    grep -q "clean -fdX" "${git_log}"
}

# --- pre-flight/infra container failure: budget exemption (#1133) --------------

@test "main does not count a pre-flight/infra container failure against the issue invocation budget (#1133)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    invoke_claude() { return 2; }

    run main
    # Exits 1, not 0, since #1361: a pre-flight container failure must make the systemd unit fail
    # so its OnFailure= handler alerts. Without that the unit reports success and the only
    # alerting path that survives a broken oneshot never fires. The budget exemption this test
    # exists for is unaffected — that is asserted below.
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"not counted against the invocation budget"* ]]
    [[ "${output}" == *"errors: 1"* ]]
    [[ "${output}" == *"exiting non-zero so the unit's OnFailure= handler reports it"* ]]

    load_issue_invocation_counts 10
    [ "${ISSUE_INVOCATION_TOTAL}" -eq 0 ]
    # The SEPARATE consecutive-infra-failure counter DOES advance (#1133 review).
    load_infra_failure_count "Issue" 10
    [ "${INFRA_FAILURE_COUNT}" -eq 1 ]
}

@test "main does not count a pre-flight/infra container failure against the PR invocation budget (#1133)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}\n'; }
    fingerprint_pr_json() { printf 'fp-new\n'; }
    load_pr_fingerprint() { printf 'fp-old\n'; }
    invoke_claude() { return 2; }

    run main
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"not counted against the invocation budget"* ]]

    load_pr_invocation_counts 5
    [ "${PR_INVOCATION_TOTAL}" -eq 0 ]
    load_infra_failure_count "PullRequest" 5
    [ "${INFRA_FAILURE_COUNT}" -eq 1 ]
}

@test "main escalates to Blocked after MAX_CONSECUTIVE_INFRA_FAILURES consecutive infra failures (#1133 review)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    invoke_claude() { return 2; }
    apply_blocked_label() { printf 'BLOCKED %s #%s\n' "$1" "$2"; return 0; }
    make_stub gh 'exit 0'
    save_infra_failure_count "Issue" 10 "$(( MAX_CONSECUTIVE_INFRA_FAILURES - 1 ))"

    run main
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"BLOCKED Issue #10"* ]]
    [[ "${output}" == *"failed ${MAX_CONSECUTIVE_INFRA_FAILURES} times in a row before Claude could even start"* ]]
    [[ "${output}" == *"blocked: 1"* ]]
}

@test "main posts the infra-failure reason as the comment body and to Discord when escalating (#1140 review)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    invoke_claude() { return 2; }
    local call_log="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "'"${call_log}"'"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    local _notif_log="${TEST_TMP}/discord_calls"
    notify_discord_blocked_item() { printf 'type=%s id=%s reason=%s\n' "$1" "$2" "$3" >> "${_notif_log}"; }
    save_infra_failure_count "Issue" 10 "$(( MAX_CONSECUTIVE_INFRA_FAILURES - 1 ))"

    run main
    [ "${status}" -eq 1 ]
    grep -q "issue comment 10 --repo org/repo --body This item's agent container has failed ${MAX_CONSECUTIVE_INFRA_FAILURES} times in a row before Claude could even start" "${call_log}"
    grep -q "type=Issue id=10 reason=This item's agent container has failed ${MAX_CONSECUTIVE_INFRA_FAILURES} times in a row before Claude could even start" "${_notif_log}"
}

@test "main does not escalate to Blocked below the consecutive-infra-failure threshold (#1133 review)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    invoke_claude() { return 2; }
    apply_blocked_label() { printf 'BLOCKED %s #%s\n' "$1" "$2"; return 0; }
    save_infra_failure_count "Issue" 10 "$(( MAX_CONSECUTIVE_INFRA_FAILURES - 2 ))"

    run main
    [ "${status}" -eq 1 ]
    [[ "${output}" != *"BLOCKED"* ]]
    [[ "${output}" == *"errors: 1"* ]]
}

@test "main does not reset the workflow board on a second consecutive infra failure (#1133 review)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    invoke_claude() { return 2; }
    local status_log="${TEST_TMP}/status_calls"
    update_workflow_status() { printf '%s %s %s\n' "$1" "$2" "$3" >> "${status_log}"; }
    # Simulate a prior tick's infra failure already having happened.
    save_infra_failure_count "Issue" 10 1

    run main
    [ "${status}" -eq 1 ]
    [ ! -f "${status_log}" ]
}

@test "main resets the workflow board on the very first attempt even though it fails (#1133 review)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    invoke_claude() { return 2; }
    local status_log="${TEST_TMP}/status_calls"
    update_workflow_status() { printf '%s %s %s\n' "$1" "$2" "$3" >> "${status_log}"; }

    run main
    [ "${status}" -eq 1 ]
    grep -q 'Issue 10 Not Started' "${status_log}"
}

@test "main clears the infra-failure streak once a real Claude session runs (#1133 review)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    save_infra_failure_count "Issue" 10 2
    invoke_claude() { return 0; }

    run main
    [ "${status}" -eq 0 ]
    load_infra_failure_count "Issue" 10
    [ "${INFRA_FAILURE_COUNT}" -eq 0 ]
}

@test "main still runs git clean -fdX and does not die when invoke_claude returns a pre-flight failure (#1133)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    invoke_claude() { return 2; }
    local git_log="${TEST_TMP}/git_calls"
    cat > "${STUB_BIN}/git" << STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${git_log}"
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/git"
    hash git

    run main
    [ "${status}" -eq 1 ]
    grep -q "clean -fdX" "${git_log}"
    [[ "${output}" != *"Failed to invoke Claude"* ]]
}

@test "main runs git clean -fdX after invoke_claude succeeds for a PullRequest" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fingerprint_pr_json() { printf 'fp-new\n'; }
    load_pr_fingerprint() { printf 'fp-old\n'; }
    local git_log="${TEST_TMP}/git_calls"
    cat > "${STUB_BIN}/git" << STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${git_log}"
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/git"
    hash git

    run main
    [ "${status}" -eq 0 ]
    grep -q "clean -fdX" "${git_log}"
}

# --- issue-to-PR pivot: issue state/blocked checks ----------------------------

@test "main tags PR for investigation and skips when linked issue is no longer open" {
    # Issue #10 has a linked open PR #99, but the issue itself is CLOSED.
    # Expect: tag_pr_closed_issue called, no Claude invocation, repo not in skip_repos.
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf '99\n'; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"CLOSED","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    local _tag_log="${TEST_TMP}/tag_log"
    tag_pr_closed_issue() { printf 'pr=%s issue=%s\n' "$1" "$2" >> "${_tag_log}"; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Issue #10 in org/repo is no longer open"* ]]
    [[ "${output}" == *"PR #99"* ]]
    [[ "${output}" != *"Starting new Claude session"* ]]
    [[ "${output}" == *"No actionable work items found"* ]]
    grep -q 'pr=99 issue=10' "${_tag_log}"
}

@test "main tags a closed-issue PR only once across ticks via the marker file, regardless of the PR's own labels (#1103 review)" {
    # Reproduces the reviewer-found regression: tag_pr_closed_issue must not be skipped just
    # because the PR happens to already carry Blocked (for a totally unrelated reason) — dedup
    # is the marker file keyed on the Issue, not a check of the PR's current labels. Two ticks:
    # first tags (marker absent), second is a no-op (marker present).
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf '99\n'; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"CLOSED","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    local _tag_log="${TEST_TMP}/tag_log"
    tag_pr_closed_issue() { printf 'pr=%s issue=%s\n' "$1" "$2" >> "${_tag_log}"; return 0; }

    run main
    [ "${status}" -eq 0 ]
    grep -q 'pr=99 issue=10' "${_tag_log}"
    [ "$(wc -l < "${_tag_log}")" -eq 1 ]

    run main
    [ "${status}" -eq 0 ]
    [ "$(wc -l < "${_tag_log}")" -eq 1 ]
}

@test "main skips issue-to-PR pivot without tagging PR when issue is blocked" {
    # Issue #10 has a linked open PR #99, but the issue is blocked.
    # Expect: blocked skip message, no tagging, no Claude invocation.
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf '99\n'; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[{"name":"Blocked"}],"comments":[],"assignees":[],"milestone":null}\n'; }
    local _tag_log="${TEST_TMP}/tag_log"
    tag_pr_closed_issue() { printf 'pr=%s issue=%s\n' "$1" "$2" >> "${_tag_log}"; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Issue #10 in org/repo is blocked — skipping"* ]]
    [[ "${output}" != *"switching to PR workflow"* ]]
    [[ "${output}" != *"Starting new Claude session"* ]]
    [[ "${output}" == *"No actionable work items found"* ]]
    [ ! -f "${_tag_log}" ] || [ ! -s "${_tag_log}" ]
}

# --- main() Discord notification integration ----------------------------------

@test "main sends start notification when starting new work on an issue" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"Do the thing","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    load_session() { SESSION_ID=""; }
    local _notif_log="${TEST_TMP}/notif_log"
    notify_discord_work_item() { printf 'type=%s item=%s id=%s\n' "$1" "$2" "$3" >> "${_notif_log}"; }

    run main
    [ "${status}" -eq 0 ]
    grep -q 'type=start item=Issue id=10' "${_notif_log}"
}

@test "main always sends a start notification (no resume) even when prior work exists" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"Do the thing","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    local _notif_log="${TEST_TMP}/notif_log"
    notify_discord_work_item() { printf 'type=%s item=%s id=%s\n' "$1" "$2" "$3" >> "${_notif_log}"; }

    run main
    [ "${status}" -eq 0 ]
    grep -q 'type=start item=Issue id=10' "${_notif_log}"
    run grep -q 'type=resume' "${_notif_log}"
    [ "${status}" -ne 0 ]
}

@test "main sends no-work notification when no actionable items found" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[{"name":"Blocked"}],"comments":[],"assignees":[],"milestone":null}\n'; }
    local _notif_log="${TEST_TMP}/notif_log"
    notify_discord_no_work() { printf 'no_work owner=%s\n' "${1:-}" >> "${_notif_log}"; }

    run main
    [ "${status}" -eq 0 ]
    grep -q 'no_work' "${_notif_log}"
}

@test "main passes owner to no-work notification when --owner flag is set" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[{"name":"Blocked"}],"comments":[],"assignees":[],"milestone":null}\n'; }
    local _notif_log="${TEST_TMP}/notif_log"
    notify_discord_no_work() { printf 'no_work owner=%s\n' "${1:-}" >> "${_notif_log}"; }

    run main --owner org
    [ "${status}" -eq 0 ]
    grep -q 'no_work owner=org' "${_notif_log}"
}

@test "main passes blocked count of 1 to no-work notification when a single issue is blocked" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[{"name":"Blocked"}],"comments":[],"assignees":[],"milestone":null}\n'; }
    local _notif_log="${TEST_TMP}/notif_log"
    notify_discord_no_work() { printf 'blocked=%s\n' "${2:-0}" >> "${_notif_log}"; }

    run main
    [ "${status}" -eq 0 ]
    grep -q 'blocked=1' "${_notif_log}"
}

@test "main passes unchanged count of 1 to no-work notification when a single issue fingerprint is unchanged" {
    setup_main_mocks
    stub_plan_already_self_heal_marked
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json()          { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    issue_json_has_blocked_label() { return 1; }
    fingerprint_issue_json()    { printf 'fp-same\n'; }
    load_issue_fingerprint()    { printf 'fp-same\n'; }
    local _notif_log="${TEST_TMP}/notif_log"
    notify_discord_no_work() { printf 'unchanged=%s\n' "${3:-0}" >> "${_notif_log}"; }

    run main
    [ "${status}" -eq 0 ]
    grep -q 'unchanged=1' "${_notif_log}"
}

@test "main passes repo-active count to no-work notification when items are skipped for active repo" {
    # PR #5 (org/repo): unchanged → adds org/repo to skip_repos, count_unchanged=1
    # Issue #10 (org/repo): skipped because org/repo already in skip_repos, count_active_repo=1
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false},{"id":10,"itemType":"Issue","repository":"org/repo","priority":2,"status":"Open","isOnHold":false}]'
    }
    # Auto-merge enabled makes the unchanged PR terminal so it is counted as unchanged/skipped.
    fetch_pr_json()             { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[],"autoMergeRequest":{"enabledAt":"now"}}\n'; }
    pr_json_has_blocked_label() { return 1; }
    fingerprint_pr_json()       { printf 'fp-same\n'; }
    load_pr_fingerprint()       { printf 'fp-same\n'; }
    local _notif_log="${TEST_TMP}/notif_log"
    notify_discord_no_work() { printf 'unchanged=%s active=%s\n' "${3:-0}" "${4:-0}" >> "${_notif_log}"; }

    run main
    [ "${status}" -eq 0 ]
    grep -q 'unchanged=1' "${_notif_log}"
    grep -q 'active=1' "${_notif_log}"
}

@test "main's no-work Discord payload includes the blocked issue in the item breakdown (#1291)" {
    # End-to-end: unlike the notify_discord_no_work-stubbing tests above, this leaves the real
    # notifier and curl call in place to verify the item_status_log wiring actually reaches the
    # Discord payload, not just the count arguments. setup_main_mocks stubs notify_discord_no_work
    # to a no-op along with everything else, so re-source lib/discord afterward to restore the
    # real implementation while keeping every other stub in place.
    setup_main_mocks
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/lib/discord"
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[{"name":"Blocked"}],"comments":[],"assignees":[],"milestone":null}\n'; }
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"

    run main
    [ "${status}" -eq 0 ]
    grep -q "Issue #10 in org/repo" "${args_log}"
    grep -q "https://github.com/org/repo/issues/10" "${args_log}"
    grep -q "blocked - skipping" "${args_log}"
}

@test "main does not block same-repo Issue after a successful non-agentic rebase of a direct PR (#1114)" {
    # PR #5 (org/repo): BEHIND → non-agentic rebase succeeds → item_repo removed from skip_repos.
    # Issue #10 (org/repo): same repo — must be evaluated, not skipped as "active work".
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false},{"id":10,"itemType":"Issue","repository":"org/repo","priority":2,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json()              { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[],"mergeable":"MERGEABLE","mergeStateStatus":"BEHIND"}\n'; }
    pr_json_has_blocked_label()  { return 1; }
    fingerprint_pr_json()        { printf 'fp-new\n'; }
    load_pr_fingerprint()        { printf 'fp-old\n'; }
    try_nonagentic_rebase()      { return 0; }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json()           { printf '{"title":"T","body":"","state":"OPEN","labels":[{"name":"Blocked"}],"comments":[],"assignees":[],"milestone":null}\n'; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PR #5 in org/repo rebased non-agentically"* ]]
    [[ "${output}" == *"Issue #10 in org/repo is blocked — skipping"* ]]
    [[ "${output}" != *"Skipping Issue #10 in org/repo — repo already has active work"* ]]
}

@test "main does not block same-repo Issue after a successful non-agentic rebase via issue-to-PR pivot (#1114)" {
    # Issue #10 (org/repo): pivots to PR #99 which is BEHIND → non-agentic rebase succeeds
    #   → item_repo removed from skip_repos.
    # Issue #20 (org/repo): same repo — must be evaluated, not skipped as "active work".
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false},{"id":20,"itemType":"Issue","repository":"org/repo","priority":2,"status":"Open","isOnHold":false}]'
    }
    local _pr_call_file="${TEST_TMP}/_pr_call"
    printf '0' > "${_pr_call_file}"
    find_open_nonblocked_pr_for_repo() {
        local _count
        _count=$(cat "${_pr_call_file}")
        _count=$((_count + 1))
        printf '%d' "${_count}" > "${_pr_call_file}"
        [ "${_count}" -eq 1 ] && printf '99\n' || printf ''
    }
    fetch_issue_json() {
        local _id="$1"
        if [ "${_id}" = "10" ]; then
            printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'
        else
            printf '{"title":"T","body":"","state":"OPEN","labels":[{"name":"Blocked"}],"comments":[],"assignees":[],"milestone":null}\n'
        fi
    }
    fetch_pr_json()             { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[],"mergeable":"MERGEABLE","mergeStateStatus":"BEHIND"}\n'; }
    pr_json_has_blocked_label() { return 1; }
    fingerprint_pr_json()       { printf 'fp-new\n'; }
    load_pr_fingerprint()       { printf 'fp-old\n'; }
    try_nonagentic_rebase()     { return 0; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PR #99 in org/repo rebased non-agentically"* ]]
    [[ "${output}" == *"Issue #20 in org/repo is blocked — skipping"* ]]
    [[ "${output}" != *"Skipping Issue #20 in org/repo — repo already has active work"* ]]
}

# --- main() blocked Discord notification integration --------------------------

@test "main sends blocked notification when a PR in priorities is blocked" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json()             { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[{"name":"Blocked"}],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}\n'; }
    pr_json_has_blocked_label() { return 0; }
    local _notif_log="${TEST_TMP}/notif_log"
    notify_discord_blocked_item() { printf 'type=%s id=%s\n' "$1" "$2" >> "${_notif_log}"; }

    run main
    [ "${status}" -eq 0 ]
    grep -q 'type=PullRequest id=5' "${_notif_log}"
}

@test "main sends blocked notification when a direct Issue is blocked" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[{"name":"Blocked"}],"comments":[],"assignees":[],"milestone":null}\n'; }
    issue_json_has_blocked_label() { return 0; }
    local _notif_log="${TEST_TMP}/notif_log"
    notify_discord_blocked_item() { printf 'type=%s id=%s\n' "$1" "$2" >> "${_notif_log}"; }

    run main
    [ "${status}" -eq 0 ]
    grep -q 'type=Issue id=10' "${_notif_log}"
}

@test "main sends blocked notification for Issue when the Issue has a linked PR that is blocked" {
    setup_main_pivot_mocks
    fetch_pr_json()             { printf '{"state":"OPEN","title":"PR title","body":"","isDraft":false,"labels":[{"name":"Blocked"}],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}\n'; }
    pr_json_has_blocked_label() { return 0; }
    local _notif_log="${TEST_TMP}/notif_log"
    notify_discord_blocked_item() { printf 'type=%s id=%s\n' "$1" "$2" >> "${_notif_log}"; }

    run main
    [ "${status}" -eq 0 ]
    grep -q 'type=PullRequest id=99' "${_notif_log}"
}

@test "main finds and skips a Blocked linked PR via the real lookup instead of falling through to plan-approved re-invocation (#1463)" {
    # Regression test for the real end-to-end bug: find_open_nonblocked_pr_for_repo used to
    # exclude Blocked PRs from its own candidates, making a Blocked linked PR invisible to the
    # issue-pivot lookup — the Issue then fell through into "plan approved, no PR yet" idle
    # re-invocation instead of recognizing "this issue's own PR exists, but is blocked" and
    # standing off. Deliberately does NOT stub find_open_nonblocked_pr_for_repo itself, so the
    # real function — and the include_blocked=true argument threaded from oneshot's call site —
    # is exercised end to end, unlike the test above which stubs the lookup away entirely.
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    _GH_ME="testuser"
    printf '%s' '[{"number":99,"labels":[{"name":"Blocked"}],"author":{"login":"testuser"}}]' > "${TEST_TMP}/prlist.json"
    printf '%s' '{"commits":[{"authors":[{"login":"testuser"}]}]}' > "${TEST_TMP}/pr99.json"
    make_stub gh 'case "$*" in *"pr list"*) cat "'"${TEST_TMP}"'/prlist.json" ;; *"pr view 99"*"--json commits"*) cat "'"${TEST_TMP}"'/pr99.json" ;; *) exit 1 ;; esac'
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    issue_json_has_blocked_label() { return 1; }
    fetch_pr_json()             { printf '{"state":"OPEN","title":"PR title","body":"","isDraft":false,"labels":[{"name":"Blocked"}],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}\n'; }
    pr_json_has_blocked_label() { return 0; }
    local _invoke_log="${TEST_TMP}/invoke_log"
    invoke_claude() { printf 'invoked\n' >> "${_invoke_log}"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Issue #10 in org/repo: found open PR #99 — switching to PR workflow"* ]]
    [[ "${output}" == *"PR #99 in org/repo is blocked — skipping (not counting as active work)"* ]]
    [[ "${output}" != *"plan approved"* ]]
    [ ! -f "${_invoke_log}" ]
}

@test "main posts an explanatory comment and reason when no .ai-instructions is found (#1140)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    find_ai_instructions() { return 1; }
    apply_blocked_label() { return 0; }
    local comment_log="${TEST_TMP}/gh_comment_log"
    make_stub gh "if [ \"\$1\" = \"issue\" ] && [ \"\$2\" = \"comment\" ]; then printf '%s\n' \"\$*\" >> '${comment_log}'; fi; exit 0"
    local _notif_log="${TEST_TMP}/notif_log"
    notify_discord_blocked_item() { printf 'type=%s id=%s reason=%s\n' "$1" "$2" "${3:-}" >> "${_notif_log}"; }

    run main
    [ "${status}" -eq 0 ]
    [ -f "${comment_log}" ]
    grep -q "No .ai-instructions file was found" "${comment_log}"
    grep -q "reason=No .ai-instructions file was found" "${_notif_log}"
}

@test "main sends blocked notification for Issue with linked PR when the Issue itself is blocked" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf '99\n'; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[{"name":"Blocked"}],"comments":[],"assignees":[],"milestone":null}\n'; }
    issue_json_has_blocked_label() { return 0; }
    local _notif_log="${TEST_TMP}/notif_log"
    notify_discord_blocked_item() { printf 'type=%s id=%s\n' "$1" "$2" >> "${_notif_log}"; }

    run main
    [ "${status}" -eq 0 ]
    grep -q 'type=Issue id=10' "${_notif_log}"
}

# --- main() rate-limit integration --------------------------------------------

@test "main skips items for a rate-limited owner and continues to other owners" {
    setup_main_mocks
    # Let set_repo_context set OWNER so is_owner_rate_limited can check it.
    set_repo_context() { OWNER="${1%%/*}"; REPO_FULL="$1"; REPO_WORK_DIR="/work/$1"; }
    fetch_all_priorities() {
        printf '%s\n' '[{"id":1,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false},{"id":2,"itemType":"Issue","repository":"other/repo","priority":2,"status":"Open","isOnHold":false}]'
    }
    is_owner_rate_limited() {
        [ "${OWNER}" = "org" ] && return 0
        return 1
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    # Issues are open and non-blocked so they reach the rate-limit check (which now fires after ensure_repo_current).
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    issue_json_has_blocked_label() { return 1; }
    fingerprint_issue_json() { printf 'fp-new\n'; }
    load_issue_fingerprint()  { printf ''; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"rate-limited"* ]]
    # org/repo rate-limited before ensure_rules_current; other/repo must still be invoked
    [[ "${output}" == *"Issue #2 in other/repo"* ]]
}
