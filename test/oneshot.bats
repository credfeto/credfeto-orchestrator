#!/usr/bin/env bats
# shellcheck disable=SC2329  # functions in @test bodies are invoked indirectly via 'run'
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are used inside run() subshells where shellcheck cannot trace them

bats_require_minimum_version 1.5.0

load test_helper

setup() {
    setup_isolated_env
    source_oneshot
}

teardown() {
    cleanup_stubs
}

# --- prompt building (minimal bootstrap prompts) ---------------------------

@test "build_issue_prompt includes issue number, repo, and work dir" {
    run build_issue_prompt 42 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"issue #42"* ]]
    [[ "${output}" == *"${REPO_FULL}"* ]]
    [[ "${output}" == *"${REPO_WORK_DIR}"* ]]
}

@test "build_issue_prompt does not include detailed instructions (those are in CLAUDE.md)" {
    run build_issue_prompt 42 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"--add-label Blocked"* ]]
    [[ "${output}" != *"Read AI instructions"* ]]
    [[ "${output}" != *"mandatory rules"* ]]
}

@test "build_pr_prompt includes PR number, repo, and work dir" {
    run build_pr_prompt 7 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"pull request #7"* ]]
    [[ "${output}" == *"${REPO_FULL}"* ]]
    [[ "${output}" == *"${REPO_WORK_DIR}"* ]]
}

@test "build_pr_prompt does not include detailed instructions (those are in CLAUDE.md)" {
    run build_pr_prompt 7 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"--add-label Blocked"* ]]
    [[ "${output}" != *"Read AI instructions"* ]]
    [[ "${output}" != *"mandatory rules"* ]]
}

@test "build_pr_prompt with BEHIND merge state does not include rebase notice (moved to CLAUDE.md)" {
    run build_pr_prompt 7 "/resolved/.ai-instructions" "BEHIND" "feat/my-branch"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"force-with-lease"* ]]
    [[ "${output}" != *"BEHIND"* ]]
}

@test "build_pr_prompt with CLEAN merge state does not include rebase notice" {
    run build_pr_prompt 7 "/resolved/.ai-instructions" "CLEAN" ""
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"force-with-lease"* ]]
    [[ "${output}" != *"BEHIND"* ]]
}

@test "build_pr_prompt with DIRTY merge state does not include rebase notice (moved to CLAUDE.md)" {
    run build_pr_prompt 7 "/resolved/.ai-instructions" "DIRTY" "feat/my-branch"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"force-with-lease"* ]]
    [[ "${output}" != *"DIRTY"* ]]
}

@test "build_issue_prompt uses provided repo_path instead of REPO_WORK_DIR" {
    run build_issue_prompt 42 "/workspace/rules/.ai-instructions" "/workspace/repo"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"/workspace/repo"* ]]
    [[ "${output}" != *"${REPO_WORK_DIR}"* ]]
}

@test "build_pr_prompt uses provided repo_path" {
    run build_pr_prompt 7 "/workspace/rules/.ai-instructions" "BEHIND" "feat/my-branch" "/workspace/repo"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"/workspace/repo"* ]]
    [[ "${output}" != *"${REPO_WORK_DIR}"* ]]
}

# --- CLAUDE.md content building -------------------------------------------

@test "build_issue_claude_md includes role, ai instructions, issue number, repo, work dir and steps" {
    run build_issue_claude_md 42 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Orchestrator agent"* ]]
    [[ "${output}" == *"issue #42"* ]]
    [[ "${output}" == *"${REPO_FULL}"* ]]
    [[ "${output}" == *"${REPO_WORK_DIR}"* ]]
    [[ "${output}" == *"--add-label Blocked"* ]]
    [[ "${output}" == *"gh issue edit 42 --repo ${REPO_FULL} --add-label Blocked"* ]]
    [[ "${output}" == *"Read AI instructions from /resolved/.ai-instructions"* ]]
}

@test "build_issue_claude_md references AI instructions for CLI and label rules" {
    run build_issue_claude_md 42 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"mandatory rules from the AI instructions"* ]]
    [[ "${output}" == *"GitHub CLI comment bodies"* ]]
    [[ "${output}" == *"label management"* ]]
}

@test "build_issue_claude_md uses provided repo_path instead of REPO_WORK_DIR" {
    run build_issue_claude_md 42 "/workspace/rules/.ai-instructions" "/workspace/repo"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"/workspace/repo"* ]]
    [[ "${output}" != *"${REPO_WORK_DIR}"* ]]
}

@test "build_issue_claude_md warns against branch-name poll patterns in Monitor loops" {
    run build_issue_claude_md 42 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"branch names contain slashes"* ]]
    [[ "${output}" == *"foreground"* ]]
}

@test "build_issue_claude_md instructs backgrounding git commit and waiting for it to finish instead of ending the turn (#1270)" {
    run build_issue_claude_md 42 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"MUST be started with run_in_background: true"* ]]
    [[ "${output}" == *"WAIT for it to actually finish before doing anything else, including ending your turn"* ]]
}

@test "build_issue_claude_md states the container-vs-GitHub survival rule" {
    run build_issue_claude_md 42 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Container-vs-GitHub rule"* ]]
    [[ "${output}" == *"killed the instant your turn ends"* ]]
    [[ "${output}" == *"survives independently of this container"* ]]
}

@test "build_issue_claude_md omits the background-stall warning by default" {
    run build_issue_claude_md 42 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"MANDATORY, READ FIRST"* ]]
    [[ "${output}" != *"backgrounding a local check"* ]]
}

@test "build_issue_claude_md includes the background-stall warning when the previous session stalled (#1326/#1335)" {
    run build_issue_claude_md 42 "/resolved/.ai-instructions" "${REPO_WORK_DIR}" "false" "" "" "" "true"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"MANDATORY, READ FIRST"* ]]
    [[ "${output}" == *"backgrounding a local check"* ]]
    [[ "${output}" == *"wait for a Monitor notification"* ]]
    [[ "${output}" == *"killed the instant that turn ended"* ]]
}

@test "build_issue_claude_md mandates run_in_background for pre-commit, dotnet test, npm test, and bun test (#1270)" {
    run build_issue_claude_md 42 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"must always be run with run_in_background: true"* ]]
    [[ "${output}" == *"unconditional, not a per-invocation judgement call"* ]]
    [[ "${output}" == *"dotnet test"* ]]
    [[ "${output}" == *"npm test"* ]]
    [[ "${output}" == *"bun test"* ]]
    [[ "${output}" == *"git push and other bounded git operations are NOT covered by this rule"* ]]
}

@test "build_issue_claude_md instructs that a denied tool call never started and must be retried, not waited for (#1281)" {
    run build_issue_claude_md 42 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"never ran at all"* ]]
    [[ "${output}" == *"never started, try again correctly"* ]]
    [[ "${output}" == *'git -C <dir> commit -m "..." with run_in_background: true'* ]]
    [[ "${output}" == *"never a shell-level"* ]]
}

@test "build_issue_claude_md attributes a denial to either the hook layer or the permission system (#1328)" {
    run build_issue_claude_md 42 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"whether by a PreToolUse hook"* ]]
    [[ "${output}" == *"or by Claude Code's own permission system when it is active"* ]]
}

@test "build_issue_claude_md omits trusted-commenters section when logins list is empty" {
    run build_issue_claude_md 42 "/resolved/.ai-instructions" "" ""
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"Trusted commenters"* ]]
}

@test "build_issue_claude_md includes trusted-commenters section listing supplied logins" {
    run build_issue_claude_md 42 "/resolved/.ai-instructions" "" "false" '["alice","bob"]'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Trusted commenters"* ]]
    [[ "${output}" == *"- alice"* ]]
    [[ "${output}" == *"- bob"* ]]
}

@test "build_pr_claude_md omits trusted-commenters section when logins list is empty" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false" ""
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"Trusted commenters"* ]]
}

# --- Issue session dirty-branch recovery (#1140 root cause) ---------------------

@test "build_issue_claude_md omits the dirty-branch section when the working tree is clean" {
    run build_issue_claude_md 42 "/resolved/.ai-instructions" "/workspace/repo" "false" "" ""
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"WORKING TREE IS DIRTY"* ]]
}

@test "build_issue_claude_md instructs recovery when the working tree is dirty (#1140)" {
    run build_issue_claude_md 42 "/resolved/.ai-instructions" "/workspace/repo" "false" "" "dependabot/github_actions/actions/checkout-7.0.0"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"WORKING TREE IS DIRTY"* ]]
    [[ "${output}" == *"dependabot/github_actions/actions/checkout-7.0.0"* ]]
    [[ "${output}" == *"git -C /workspace/repo status"* ]]
    [[ "${output}" == *"git -C /workspace/repo checkout main"* ]]
    # Must explicitly say this is not grounds to block — the whole point of the fix.
    [[ "${output}" == *"not a reason to block the issue"* ]]
}

@test "build_issue_claude_md dirty-branch section appears before step 1 (#1140)" {
    run build_issue_claude_md 42 "/resolved/.ai-instructions" "/workspace/repo" "false" "" "some-branch"
    [ "${status}" -eq 0 ]
    local dirty_pos step1_pos
    dirty_pos=$(printf '%s' "${output}" | grep -n "WORKING TREE IS DIRTY" | head -1 | cut -d: -f1)
    step1_pos=$(printf '%s' "${output}" | grep -n "^1\. Assign yourself" | head -1 | cut -d: -f1)
    [ -n "${dirty_pos}" ]
    [ -n "${step1_pos}" ]
    [ "${dirty_pos}" -lt "${step1_pos}" ]
}

@test "build_issue_claude_md dirty-branch cleanup resets the index before checking out (#1140 review)" {
    # git reset HEAD must come BEFORE git checkout -- . — the reverse order leaves staged
    # changes present in the working tree, since checkout -- . only copies index -> worktree.
    run build_issue_claude_md 42 "/resolved/.ai-instructions" "/workspace/repo" "false" "" "some-branch"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"git -C /workspace/repo reset HEAD && git -C /workspace/repo checkout -- ."* ]]
}

@test "build_issue_claude_md dirty-branch section offers stashing when changes may be relevant (#1140)" {
    run build_issue_claude_md 42 "/resolved/.ai-instructions" "/workspace/repo" "false" "" "some-branch"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"git -C /workspace/repo stash"* ]]
    [[ "${output}" == *"clearly relevant to THIS issue"* ]]
}

# --- Issue session stale-branch resumption (#1262) -------------------------------

@test "build_issue_claude_md omits the stale-branch section when no stale branch was detected" {
    run build_issue_claude_md 42 "/resolved/.ai-instructions" "/workspace/repo" "false" "" "" ""
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"AN EXISTING BRANCH FOR THIS ISSUE ALREADY EXISTS"* ]]
}

@test "build_issue_claude_md instructs checking out an existing stale branch instead of creating a new one (#1262)" {
    run build_issue_claude_md 42 "/resolved/.ai-instructions" "/workspace/repo" "false" "" "" "chore/42-fix-something"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"AN EXISTING BRANCH FOR THIS ISSUE ALREADY EXISTS"* ]]
    [[ "${output}" == *"git -C /workspace/repo checkout chore/42-fix-something"* ]]
    [[ "${output}" == *"Do NOT create a second branch"* ]]
}

@test "build_issue_claude_md stale-branch section appears before step 1 (#1262)" {
    run build_issue_claude_md 42 "/resolved/.ai-instructions" "/workspace/repo" "false" "" "" "chore/42-fix-something"
    [ "${status}" -eq 0 ]
    local stale_pos step1_pos
    stale_pos=$(printf '%s' "${output}" | grep -n "AN EXISTING BRANCH FOR THIS ISSUE ALREADY EXISTS" | head -1 | cut -d: -f1)
    step1_pos=$(printf '%s' "${output}" | grep -n "^1\. Assign yourself" | head -1 | cut -d: -f1)
    [ -n "${stale_pos}" ]
    [ -n "${step1_pos}" ]
    [ "${stale_pos}" -lt "${step1_pos}" ]
}

@test "build_issue_claude_md step 7 tells the agent to check out the existing branch instead of creating a new one (#1262 review)" {
    run build_issue_claude_md 42 "/resolved/.ai-instructions" "/workspace/repo" "false" "" "" "chore/42-fix-something"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"7. When ready to start work: an existing branch for this issue already exists"* ]]
    [[ "${output}" == *"git -C /workspace/repo checkout chore/42-fix-something"* ]]
    [[ "${output}" == *"INSTEAD OF creating a new one"* ]]
    [[ "${output}" != *"7. When ready to start work: create a new branch BEFORE"* ]]
}

@test "build_issue_claude_md step 7 still tells the agent to create a new branch when no stale branch was detected" {
    run build_issue_claude_md 42 "/resolved/.ai-instructions" "/workspace/repo" "false" "" "" ""
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"7. When ready to start work: create a new branch BEFORE making any changes"* ]]
}

# --- dirty checkout on this issue's own resumable branch (#1262 review) ---------
# When DIRTY_BRANCH == stale_branch, the checkout is already sitting on the resumable branch
# WITH uncommitted changes: likely genuine in-progress work from the earlier session, not
# unrelated leftover state. The two sections must not independently render conflicting
# instructions (discard-and-reset-to-main vs. check-out-and-continue) for the same branch.

@test "build_issue_claude_md merges dirty and stale guidance into one section when they name the same branch (#1262 review)" {
    run build_issue_claude_md 42 "/resolved/.ai-instructions" "/workspace/repo" "false" "" "chore/42-fix-something" "chore/42-fix-something"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"WORKING TREE IS DIRTY ON THIS ISSUE'S OWN RESUMABLE BRANCH"* ]]
    [[ "${output}" == *"Do NOT discard them"* ]]
    # Neither the generic dirty-branch section nor the separate stale-branch section should
    # also render — exactly one, consistent instruction for this branch.
    [[ "${output}" != *"WORKING TREE IS DIRTY (MANDATORY"* ]]
    [[ "${output}" != *"AN EXISTING BRANCH FOR THIS ISSUE ALREADY EXISTS"* ]]
}

@test "build_issue_claude_md merged dirty/stale section does not instruct resetting to main (#1262 review)" {
    run build_issue_claude_md 42 "/resolved/.ai-instructions" "/workspace/repo" "false" "" "chore/42-fix-something" "chore/42-fix-something"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"checkout main && git -C /workspace/repo pull"* ]]
    [[ "${output}" == *"do NOT reset to main"* ]]
}

@test "build_issue_claude_md keeps both dirty and stale sections separate when they name different branches (#1262 review)" {
    run build_issue_claude_md 42 "/resolved/.ai-instructions" "/workspace/repo" "false" "" "dependabot/github_actions/actions/checkout-7.0.0" "chore/42-fix-something"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"WORKING TREE IS DIRTY (MANDATORY"* ]]
    [[ "${output}" == *"AN EXISTING BRANCH FOR THIS ISSUE ALREADY EXISTS"* ]]
    [[ "${output}" == *"git -C /workspace/repo checkout chore/42-fix-something"* ]]
}

# --- board status only advances to Development after the draft PR exists (#1262) -

@test "build_issue_claude_md no longer advances the board to Development at the start of implementation (#1262)" {
    run build_issue_claude_md 42 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'5. (Implementation mode) Proceed with the plan from the plan comment.'* ]]
}

@test "build_issue_claude_md advances the board to Development only once the draft PR has been created (#1262)" {
    run build_issue_claude_md 42 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'Only once the draft pull request (with its placeholder CHANGELOG.md entry) has been successfully created, update the Workflow board status to "Development"'* ]]
}

@test "build_issue_claude_md places the Development board-status update after draft-PR creation within step 7 (#1262)" {
    run build_issue_claude_md 42 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"create a draft pull request"*'update the Workflow board status to "Development"'* ]]
}

# --- "never block without a comment" mandatory rule (#1140) ---------------------

@test "build_issue_claude_md mandates a comment on every Blocked application" {
    run build_issue_claude_md 42 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"NEVER apply the Blocked label without ALSO posting a comment"* ]]
}

@test "build_pr_claude_md mandates a comment on every Blocked application" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false" ""
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"NEVER apply the Blocked label without ALSO posting a comment"* ]]
}

# --- tightened plan-approval re-block instruction (#1140) -----------------------

@test "build_issue_claude_md board-configured not-approved-yet text demands a diagnostic comment" {
    _WF_PROJECT_ID="PVT_test"
    run build_issue_claude_md 42 "/resolved/.ai-instructions" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"fetch the Workflow board's CURRENT status"* ]]
    [[ "${output}" == *"Silently re-applying Blocked with no comment is NEVER acceptable"* ]]
}

@test "build_issue_claude_md board-configured not-approved-yet text still instructs revising the plan on feedback (#1140 review)" {
    _WF_PROJECT_ID="PVT_test"
    run build_issue_claude_md 42 "/resolved/.ai-instructions" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"revise it and re-post the FULL updated plan"* ]]
}

@test "build_issue_claude_md no-board not-approved-yet text demands a diagnostic comment" {
    _WF_PROJECT_ID=""
    run build_issue_claude_md 42 "/resolved/.ai-instructions" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"no approval comment"* ]]
    [[ "${output}" == *"Silently re-applying Blocked with no comment is NEVER acceptable"* ]]
}

@test "build_issue_claude_md no-board not-approved-yet text still instructs revising the plan on feedback (#1140 review)" {
    _WF_PROJECT_ID=""
    run build_issue_claude_md 42 "/resolved/.ai-instructions" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"revise it and re-post the FULL updated plan"* ]]
}

@test "build_pr_claude_md includes trusted-commenters section listing supplied logins" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false" '["alice","bob"]'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Trusted commenters"* ]]
    [[ "${output}" == *"- alice"* ]]
    [[ "${output}" == *"- bob"* ]]
}

@test "build_pr_claude_md's PHASE A label-sync step excludes Blocked and On-Hold (#1321 review)" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"grep -vE '^(Blocked|On-Hold)\$'"* ]]
}

@test "build_pr_claude_md's dependency-PR label-sync step excludes Blocked and On-Hold (#1321 review)" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "true" ""
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"grep -vE '^(Blocked|On-Hold)\$'"* ]]
}

@test "build_pr_claude_md includes role, ai instructions, PR number, repo, work dir and steps" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Orchestrator agent"* ]]
    [[ "${output}" == *"pull request #7"* ]]
    [[ "${output}" == *"${REPO_FULL}"* ]]
    [[ "${output}" == *"${REPO_WORK_DIR}"* ]]
    [[ "${output}" == *"gh pr edit 7 --repo ${REPO_FULL} --add-label Blocked"* ]]
    [[ "${output}" == *"Read AI instructions from /resolved/.ai-instructions"* ]]
    [[ "${output}" == *"gh pr ready 7 --repo ${REPO_FULL}"* ]]
}

@test "build_pr_claude_md references AI instructions for CLI, label, and CI rules" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"mandatory rules from the AI instructions"* ]]
    [[ "${output}" == *"GitHub CLI comment bodies"* ]]
    [[ "${output}" == *"label management"* ]]
    [[ "${output}" == *"CI checks"* ]]
}

@test "build_pr_claude_md warns against branch-name poll patterns in Monitor loops" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"branch names contain slashes"* ]]
    [[ "${output}" == *"foreground"* ]]
}

@test "build_pr_claude_md omits the background-stall warning by default" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"MANDATORY, READ FIRST"* ]]
    [[ "${output}" != *"backgrounding a local check"* ]]
}

@test "build_pr_claude_md includes the background-stall warning when the previous session stalled (#1326/#1335)" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "UNKNOWN" "" "${REPO_WORK_DIR}" "" "false" "" "true"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"MANDATORY, READ FIRST"* ]]
    [[ "${output}" == *"backgrounding a local check"* ]]
    [[ "${output}" == *"wait for a Monitor notification"* ]]
    [[ "${output}" == *"killed the instant that turn ended"* ]]
}

@test "build_pr_claude_md omits the background-stall warning for dependency PRs even when the flag is true" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "UNKNOWN" "" "${REPO_WORK_DIR}" "" "true" "" "true"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"MANDATORY, READ FIRST"* ]]
}

@test "build_pr_claude_md instructs backgrounding git commit and waiting for it to finish instead of ending the turn (#1270)" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"MUST be started with run_in_background: true"* ]]
    [[ "${output}" == *"WAIT for it to actually finish before doing anything else, including ending your turn"* ]]
}

@test "build_pr_claude_md mandates run_in_background for pre-commit, dotnet test, npm test, and bun test (#1270)" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"must always be run with run_in_background: true"* ]]
    [[ "${output}" == *"unconditional, not a per-invocation judgement call"* ]]
    [[ "${output}" == *"dotnet test"* ]]
    [[ "${output}" == *"npm test"* ]]
    [[ "${output}" == *"bun test"* ]]
    [[ "${output}" == *"git push and other bounded git operations are NOT covered by this rule"* ]]
}

@test "build_pr_claude_md instructs that a denied tool call never started and must be retried, not waited for (#1281)" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"never ran at all"* ]]
    [[ "${output}" == *"never started, try again correctly"* ]]
    [[ "${output}" == *'git -C <dir> commit -m "..." with run_in_background: true'* ]]
    [[ "${output}" == *"never a shell-level"* ]]
}

@test "build_pr_claude_md attributes a denial to either the hook layer or the permission system (#1328)" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"whether by a PreToolUse hook"* ]]
    [[ "${output}" == *"or by Claude Code's own permission system when it is active"* ]]
}

@test "build_pr_claude_md states the container-vs-GitHub survival rule" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Container-vs-GitHub rule"* ]]
    [[ "${output}" == *"killed the instant your turn ends"* ]]
    [[ "${output}" == *"survives independently of this container"* ]]
}

@test "build_pr_claude_md with BEHIND merge state includes rebase notice with branch name and force-with-lease" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "BEHIND" "feat/my-branch"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"BEHIND"* ]]
    [[ "${output}" == *"feat/my-branch"* ]]
    [[ "${output}" == *"force-with-lease"* ]]
    [[ "${output}" == *"rebase origin/main"* ]]
}

@test "build_pr_claude_md with CLEAN merge state does not include rebase notice" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" ""
    [ "${status}" -eq 0 ]
    # A CLEAN PR must not be given rebase instructions (the word "BEHIND" still appears in the
    # generic phase-selection guidance, so assert on the rebase commands, not that token).
    [[ "${output}" != *"force-with-lease"* ]]
    [[ "${output}" != *"rebase origin/main"* ]]
}

@test "build_pr_claude_md with DIRTY merge state includes rebase notice with branch name and force-with-lease" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "DIRTY" "feat/my-branch"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"DIRTY"* ]]
    [[ "${output}" == *"feat/my-branch"* ]]
    [[ "${output}" == *"force-with-lease"* ]]
    [[ "${output}" == *"rebase origin/main"* ]]
}

@test "build_pr_claude_md rebase notice covers COVERAGE.md conflicts alongside CHANGELOG.md" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "BEHIND" "feat/my-branch"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"CHANGELOG.md conflicts: keep entries from both sides."* ]]
    [[ "${output}" == *"COVERAGE.md conflicts: take origin/main's copy"* ]]
    [[ "${output}" == *"checkout --ours -- COVERAGE.md"* ]]
    [[ "${output}" == *"rebase reverses ours/theirs vs a merge"* ]]
    [[ "${output}" == *"once the build/tests pass re-run the coverage extraction"* ]]
}

@test "build_pr_claude_md uses provided repo_path in rebase notice" {
    run build_pr_claude_md 7 "/workspace/rules/.ai-instructions" "BEHIND" "feat/my-branch" "/workspace/repo"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"/workspace/repo"* ]]
    [[ "${output}" != *"${REPO_WORK_DIR}"* ]]
    [[ "${output}" == *"feat/my-branch"* ]]
    [[ "${output}" == *"force-with-lease"* ]]
}

@test "build_pr_claude_md includes auto-merge step for regular PRs" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"gh pr merge --auto --merge 7 --repo ${REPO_FULL}"* ]]
    [[ "${output}" == *"gh pr ready 7 --repo ${REPO_FULL}"* ]]
}

@test "build_pr_claude_md for dependency PR generates compact instructions without code-work steps" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "true"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"dependency update PR"* ]]
    [[ "${output}" == *"Do NOT make any code changes"* ]]
    [[ "${output}" == *"gh pr merge --auto --merge 7 --repo ${REPO_FULL}"* ]]
    [[ "${output}" == *"gh pr edit 7 --repo ${REPO_FULL} --add-label Blocked"* ]]
    [[ "${output}" != *"mandatory rules from the AI instructions"* ]]
    [[ "${output}" != *"force-with-lease"* ]]
}

@test "build_pr_claude_md for dependency PR instructs agent to stop if CI is still pending" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "true"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PENDING"* ]]
    [[ "${output}" == *"stop without taking action"* ]]
}

@test "build_pr_claude_md for dependency PR checks for a failed required check before treating auto-merge-enabled as done" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "true"
    [ "${status}" -eq 0 ]
    local before_failed="${output%%If any required check has FAILED*}"
    local before_automerge="${output%%Else if auto-merge is already enabled*}"
    [ "${#before_failed}" -lt "${#before_automerge}" ]
}

@test "build_pr_claude_md for dependency PR skips rebase steps even when merge state is BEHIND" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "BEHIND" "feat/my-branch" "" "" "true"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"force-with-lease"* ]]
    [[ "${output}" != *"rebase origin/main"* ]]
}

@test "main passes DIRTY merge state and branch name to build_pr_claude_md" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json()           { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[],"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY"}\n'; }
    fingerprint_pr_json()     { printf 'fp-new\n'; }
    load_pr_fingerprint()     { printf 'fp-old\n'; }
    # Use TEST_TMP directly (exported) to avoid local-variable subprocess isolation issue.
    build_pr_claude_md() { printf 'merge_state=%s branch=%s\n' "$3" "$4" > "${TEST_TMP}/claude_md_log"; printf 'mock-pr-claude-md\n'; }

    run main
    [ "${status}" -eq 0 ]
    grep -q 'merge_state=DIRTY' "${TEST_TMP}/claude_md_log"
    grep -q 'branch=feat/test' "${TEST_TMP}/claude_md_log"
}

@test "main performs non-agentic rebase for BEHIND PR, saves fingerprint, and continues without invoking agent" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false},{"id":10,"itemType":"Issue","repository":"other/repo","priority":2,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json()        { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[],"mergeable":"MERGEABLE","mergeStateStatus":"BEHIND"}\n'; }
    fingerprint_pr_json()  { printf 'fp-new\n'; }
    load_pr_fingerprint()  { printf 'fp-old\n'; }
    try_nonagentic_rebase() { return 0; }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[{"name":"Blocked"}],"comments":[],"assignees":[],"milestone":null}\n'; }
    issue_json_has_blocked_label() { return 0; }
    # Use TEST_TMP directly (exported) to avoid local-variable subprocess isolation issue.
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"rebased non-agentically"* ]]
    [ ! -f "${TEST_TMP}/claude_log" ]
}

@test "main skips (does not die on) a post-rebase fingerprint compute failure (#1090)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json()        { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[],"mergeable":"MERGEABLE","mergeStateStatus":"BEHIND"}\n'; }
    fingerprint_pr_json()  { printf 'fp-new\n'; }
    load_pr_fingerprint()  { printf 'fp-old\n'; }
    try_nonagentic_rebase() { return 0; }
    compute_pr_fingerprint() { return 1; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"rebased non-agentically"* ]]
    [[ "${output}" == *"Failed to compute post-rebase fingerprint"* ]]
    [ ! -f "${TEST_TMP}/claude_log" ]
}

@test "main passes BEHIND merge state and branch name to build_pr_claude_md" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json()           { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[],"mergeable":"MERGEABLE","mergeStateStatus":"BEHIND"}\n'; }
    fingerprint_pr_json()     { printf 'fp-new\n'; }
    load_pr_fingerprint()     { printf 'fp-old\n'; }
    # Use TEST_TMP directly (exported) to avoid local-variable subprocess isolation issue.
    build_pr_claude_md() { printf 'merge_state=%s branch=%s\n' "$3" "$4" > "${TEST_TMP}/claude_md_log"; printf 'mock-pr-claude-md\n'; }

    run main
    [ "${status}" -eq 0 ]
    grep -q 'merge_state=BEHIND' "${TEST_TMP}/claude_md_log"
    grep -q 'branch=feat/test' "${TEST_TMP}/claude_md_log"
}

# --- --owner argument ---------------------------------------------------------

@test "main --owner filters priorities to only items from that owner" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":1,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false},{"id":2,"itemType":"Issue","repository":"other/repo2","priority":2,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[{"name":"Blocked"}],"comments":[],"assignees":[],"milestone":null}\n'; }

    run main --owner org
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"org/repo"* ]]
    [[ "${output}" != *"other/repo2"* ]]
    [[ "${output}" == *"No actionable work items found"* ]]
}

@test "main --owner with no value dies" {
    setup_main_mocks
    run main --owner
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"--owner requires a value"* ]]
}

@test "main with an unknown argument dies" {
    setup_main_mocks
    run main --unknown-flag
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Unknown argument"* ]]
}

@test "main still cleans up ssh-agent when it dies on the earliest argument-parsing path (#1103)" {
    setup_main_mocks
    export SSH_AUTH_SOCK="${TEST_TMP}/ssh-agent.sock"
    local pkill_log="${TEST_TMP}/pkill.log"
    make_stub pkill "printf '%s\n' \"\$*\" >> \"${pkill_log}\"; exit 0"
    run main --unknown-flag
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Unknown argument"* ]]
    grep -qxe "-u $(id -un) -f ssh-agent -a ${SSH_AUTH_SOCK}" "${pkill_log}"
}

@test "main --owner with invalid characters dies" {
    setup_main_mocks
    run main --owner "evil;rm"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"invalid characters"* ]]
}

@test "main exits cleanly when another instance holds the lock" {
    setup_main_mocks
    # Hold the lock in a background process so main's flock --nonblock fails.
    local lock_dir="${HOME}/.orchestrator/locks"
    mkdir -p "${lock_dir}"
    # Use a subshell holding fd 9 for the duration of the test.
    exec 9>"${lock_dir}/_global.lock"
    flock --exclusive 9
    # Remove the flock stub so the real flock binary is used.
    rm -f "${STUB_BIN}/flock"

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"already running"* ]]

    # Release lock.
    exec 9>&-
}

@test "main without --owner processes items from all owners" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":1,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false},{"id":2,"itemType":"Issue","repository":"other/repo2","priority":2,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[{"name":"Blocked"}],"comments":[],"assignees":[],"milestone":null}\n'; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"org/repo"* ]]
    [[ "${output}" == *"other/repo2"* ]]
    [[ "${output}" == *"No actionable work items found"* ]]
}

@test "find_ai_instructions returns repo work dir path when .ai-instructions exists there" {
    mkdir -p "${REPO_WORK_DIR}"
    printf 'instructions\n' > "${REPO_WORK_DIR}/.ai-instructions"
    run find_ai_instructions
    [ "${status}" -eq 0 ]
    [ "${output}" = "${REPO_WORK_DIR}/.ai-instructions" ]
}

@test "find_ai_instructions falls back to rules dir when repo work dir has no .ai-instructions" {
    mkdir -p "${RULES_DIR}"
    printf 'instructions\n' > "${RULES_DIR}/.ai-instructions"
    run find_ai_instructions
    [ "${status}" -eq 0 ]
    [ "${output}" = "${RULES_DIR}/.ai-instructions" ]
}

@test "find_ai_instructions prefers repo work dir over rules dir when both exist" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    printf 'repo\n' > "${REPO_WORK_DIR}/.ai-instructions"
    printf 'rules\n' > "${RULES_DIR}/.ai-instructions"
    run find_ai_instructions
    [ "${status}" -eq 0 ]
    [ "${output}" = "${REPO_WORK_DIR}/.ai-instructions" ]
}

@test "find_ai_instructions dies when neither path has .ai-instructions" {
    run find_ai_instructions
    [ "${status}" -ne 0 ]
    [[ "${output}" == *".ai-instructions"* ]]
}

# --- input validation / security ------------------------------------------

@test "load_token_for_owner rejects owners with invalid characters" {
    local bad
    # shellcheck disable=SC2016  # 'owner$x' is a deliberate literal — testing that a '$' in the owner is rejected
    for bad in 'owner;rm' 'owner space' 'owner/slash' 'owner$x' 'owner.dot'; do
        run load_token_for_owner "${bad}"
        [ "${status}" -eq 0 ]
        [ -z "${output}" ]
    done
}

@test "load_token_for_owner reads a token for a valid owner with safe perms" {
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator/tokens"
    printf 'secret-token\n' > "${XDG_CONFIG_HOME}/orchestrator/tokens/credfeto"
    chmod 600 "${XDG_CONFIG_HOME}/orchestrator/tokens/credfeto"
    run load_token_for_owner credfeto
    [ "${status}" -eq 0 ]
    [ "${output}" = "secret-token" ]
}

@test "read_token_if_safe outputs token for safe perms and skips unsafe perms" {
    local tf="${TEST_TMP}/token"
    printf '  my-token  \n' > "${tf}"

    local perm
    for perm in 600 400; do
        chmod "${perm}" "${tf}"
        run read_token_if_safe "${tf}"
        [ "${status}" -eq 0 ]
        [ "${output}" = "my-token" ]
    done

    for perm in 644 664 666 755; do
        chmod "${perm}" "${tf}"
        run read_token_if_safe "${tf}"
        [ "${status}" -eq 0 ]
        # Unsafe perms: token is skipped, only the warning (on stderr) is produced.
        [[ "${output}" != *"my-token"* ]]
    done
}

@test "read_token_if_safe outputs nothing for a missing file" {
    run read_token_if_safe "${TEST_TMP}/does-not-exist"
    [ -z "${output}" ]
}

# --- host_to_container_path ---------------------------------------------------

@test "host_to_container_path maps REPO_WORK_DIR to CONTAINER_REPO_PATH" {
    run host_to_container_path "${REPO_WORK_DIR}/.ai-instructions"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${CONTAINER_REPO_PATH}/.ai-instructions" ]
}

@test "host_to_container_path maps REPO_WORK_DIR exactly to CONTAINER_REPO_PATH" {
    run host_to_container_path "${REPO_WORK_DIR}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${CONTAINER_REPO_PATH}" ]
}

@test "host_to_container_path maps RULES_DIR to CONTAINER_RULES_PATH" {
    run host_to_container_path "${RULES_DIR}/.ai-instructions"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${CONTAINER_RULES_PATH}/.ai-instructions" ]
}

@test "host_to_container_path returns path unchanged when not matching a known dir" {
    run host_to_container_path "/some/other/path"
    [ "${status}" -eq 0 ]
    [ "${output}" = "/some/other/path" ]
}

@test "host_to_container_path prefers REPO_WORK_DIR over RULES_DIR when path starts with both" {
    # Construct a path that starts with REPO_WORK_DIR (which is a prefix match test).
    # Since REPO_WORK_DIR is checked first, it wins.
    run host_to_container_path "${REPO_WORK_DIR}/subdir"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${CONTAINER_REPO_PATH}/subdir" ]
}

# --- tool checks -----------------------------------------------------------

@test "check_required_tools dies when a required tool is missing" {
    # Override the shell builtin used for presence checks so that a chosen tool
    # reports as absent, deterministically and without altering the real system.
    command() {
        if [ "$1" = "-v" ] && [ "$2" = "podman" ]; then
            return 1
        fi
        builtin command "$@"
    }
    run check_required_tools
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Required tool not found: podman"* ]]
}

@test "check_required_tools dies when timeout is missing" {
    make_stub curl 'exit 0'
    make_stub jq 'exit 0'
    make_stub podman 'exit 0'
    make_stub gh 'exit 0'
    make_stub git 'exit 0'
    make_stub awk 'exit 0'
    make_stub grep 'exit 0'
    make_stub flock 'exit 0'
    # shellcheck disable=SC2329
    command() {
        if [ "$1" = "-v" ] && [ "$2" = "timeout" ]; then
            return 1
        fi
        builtin command "$@"
    }
    export -f command
    run check_required_tools
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Required tool not found: timeout"* ]]
}

@test "check_required_tools succeeds when all tools are present" {
    make_stub curl 'exit 0'
    make_stub jq 'exit 0'
    make_stub podman 'exit 0'
    make_stub gh 'exit 0'
    make_stub git 'exit 0'
    make_stub awk 'exit 0'
    make_stub grep 'exit 0'
    make_stub flock 'exit 0'
    make_stub sha256sum 'exit 0'
    make_stub timeout 'exit 0'
    run check_required_tools
    [ "${status}" -eq 0 ]
}

# --- parse_two_token_counters (shared by load_pr_invocation_counts / load_issue_invocation_counts, #1264) ---

@test "parse_two_token_counters extracts both tokens from a matching line" {
    parse_two_token_counters "7 3"
    [ "${_PARSED_COUNT_TOTAL}" -eq 7 ]
    [ "${_PARSED_COUNT_IDLE}" -eq 3 ]
}

@test "parse_two_token_counters fails and zeroes both outputs for a single-token line" {
    _PARSED_COUNT_TOTAL=9
    _PARSED_COUNT_IDLE=9
    local parse_rc=0
    parse_two_token_counters "7" || parse_rc=$?
    [ "${parse_rc}" -ne 0 ]
    [ "${_PARSED_COUNT_TOTAL}" -eq 0 ]
    [ "${_PARSED_COUNT_IDLE}" -eq 0 ]
}

@test "parse_two_token_counters fails for garbage input" {
    run parse_two_token_counters "garbage not numbers"
    [ "${status}" -ne 0 ]
}

# --- per-PR invocation guard -----------------------------------------------

@test "load_pr_invocation_counts defaults to 0/0 when no guard file exists" {
    load_pr_invocation_counts 42
    [ "${PR_INVOCATION_TOTAL}" -eq 0 ]
    [ "${PR_INVOCATION_IDLE}" -eq 0 ]
}

@test "save_pr_invocation_counts and load_pr_invocation_counts round-trip" {
    save_pr_invocation_counts 42 7 3
    [ -f "${SESSION_BASE_DIR}/PullRequest_42.invocations" ]
    load_pr_invocation_counts 42
    [ "${PR_INVOCATION_TOTAL}" -eq 7 ]
    [ "${PR_INVOCATION_IDLE}" -eq 3 ]
}

@test "load_pr_invocation_counts treats a corrupt guard file as 0/0" {
    mkdir -p "${SESSION_BASE_DIR}"
    printf 'garbage not numbers\n' > "${SESSION_BASE_DIR}/PullRequest_42.invocations"
    load_pr_invocation_counts 42
    [ "${PR_INVOCATION_TOTAL}" -eq 0 ]
    [ "${PR_INVOCATION_IDLE}" -eq 0 ]
}

@test "load_pr_invocation_counts treats a single-token guard file as 0/0, not aliased into both counters (#1103)" {
    mkdir -p "${SESSION_BASE_DIR}"
    # A single lone token used to alias into BOTH total and idle via independent
    # ${line%% *}/${line##* *} extraction — total=7 idle=7 would instantly exhaust a 5-idle
    # budget for a PR that was never actually invoked 7 times.
    printf '7\n' > "${SESSION_BASE_DIR}/PullRequest_42.invocations"
    load_pr_invocation_counts 42
    [ "${PR_INVOCATION_TOTAL}" -eq 0 ]
    [ "${PR_INVOCATION_IDLE}" -eq 0 ]
}

# --- consecutive infra-failure guard (#1133 review) -----------------------------

@test "load_infra_failure_count defaults to 0 when no guard file exists" {
    load_infra_failure_count "Issue" 42
    [ "${INFRA_FAILURE_COUNT}" -eq 0 ]
}

@test "save_infra_failure_count and load_infra_failure_count round-trip" {
    save_infra_failure_count "Issue" 42 3
    [ -f "${SESSION_BASE_DIR}/Issue_42.infra-failures" ]
    load_infra_failure_count "Issue" 42
    [ "${INFRA_FAILURE_COUNT}" -eq 3 ]
}

@test "load_infra_failure_count treats a corrupt guard file as 0" {
    mkdir -p "${SESSION_BASE_DIR}"
    printf 'garbage\n' > "${SESSION_BASE_DIR}/PullRequest_42.infra-failures"
    load_infra_failure_count "PullRequest" 42
    [ "${INFRA_FAILURE_COUNT}" -eq 0 ]
}

@test "clear_infra_failure_count removes the guard file" {
    save_infra_failure_count "Issue" 42 3
    clear_infra_failure_count "Issue" 42
    [ ! -f "${SESSION_BASE_DIR}/Issue_42.infra-failures" ]
}

@test "clear_infra_failure_count is a no-op when no guard file exists" {
    run clear_infra_failure_count "Issue" 999
    [ "${status}" -eq 0 ]
}

@test "reset_pr_invocation_counts_if_capped resets and clears the marker when the runaway-blocked marker is present" {
    save_pr_invocation_counts 42 "${MAX_PR_TOTAL_INVOCATIONS}" 3
    mkdir -p "${SESSION_BASE_DIR}"
    touch "${SESSION_BASE_DIR}/PullRequest_42.runaway-blocked"
    reset_pr_invocation_counts_if_capped 42
    load_pr_invocation_counts 42
    [ "${PR_INVOCATION_TOTAL}" -eq 0 ]
    [ "${PR_INVOCATION_IDLE}" -eq 0 ]
    [ ! -f "${SESSION_BASE_DIR}/PullRequest_42.runaway-blocked" ]
}

@test "reset_pr_invocation_counts_if_capped leaves the total untouched when no runaway-blocked marker exists" {
    save_pr_invocation_counts 42 5 3
    reset_pr_invocation_counts_if_capped 42
    load_pr_invocation_counts 42
    [ "${PR_INVOCATION_TOTAL}" -eq 5 ]
    [ "${PR_INVOCATION_IDLE}" -eq 3 ]
}

@test "reset_pr_invocation_counts_if_capped does not reset a total that just now reached the cap without a marker" {
    # Regression guard: the tick the backstop is ABOUT to trip on has total >= cap but no marker
    # yet (the marker is only written once the block is actually applied). Resetting here would
    # erase the counter before the backstop ever gets to fire, defeating the cap entirely.
    save_pr_invocation_counts 42 "${MAX_PR_TOTAL_INVOCATIONS}" 0
    reset_pr_invocation_counts_if_capped 42
    load_pr_invocation_counts 42
    [ "${PR_INVOCATION_TOTAL}" -eq "${MAX_PR_TOTAL_INVOCATIONS}" ]
}

# --- per-Issue invocation guard ----------------------------------------------

@test "load_issue_invocation_counts defaults to 0/0 when no guard file exists" {
    load_issue_invocation_counts 99
    [ "${ISSUE_INVOCATION_TOTAL}" -eq 0 ]
    [ "${ISSUE_INVOCATION_IDLE}" -eq 0 ]
}

@test "save_issue_invocation_counts and load_issue_invocation_counts round-trip" {
    save_issue_invocation_counts 99 4 2
    [ -f "${SESSION_BASE_DIR}/Issue_99.invocations" ]
    load_issue_invocation_counts 99
    [ "${ISSUE_INVOCATION_TOTAL}" -eq 4 ]
    [ "${ISSUE_INVOCATION_IDLE}" -eq 2 ]
}

@test "load_issue_invocation_counts treats a corrupt guard file as 0/0" {
    mkdir -p "${SESSION_BASE_DIR}"
    printf 'garbage not numbers\n' > "${SESSION_BASE_DIR}/Issue_99.invocations"
    load_issue_invocation_counts 99
    [ "${ISSUE_INVOCATION_TOTAL}" -eq 0 ]
    [ "${ISSUE_INVOCATION_IDLE}" -eq 0 ]
}

@test "load_issue_invocation_counts treats a legacy single-token guard file as total-only, idle 0 (#1264)" {
    # Pre-#1264 guard files hold only "<total>" (Issues had no idle counter until #1264 added
    # one) — must parse the total correctly and default idle to 0, not treat the whole file as
    # corrupt (that would silently discard real invocation history on every repo already running
    # before this change).
    mkdir -p "${SESSION_BASE_DIR}"
    printf '7\n' > "${SESSION_BASE_DIR}/Issue_99.invocations"
    load_issue_invocation_counts 99
    [ "${ISSUE_INVOCATION_TOTAL}" -eq 7 ]
    [ "${ISSUE_INVOCATION_IDLE}" -eq 0 ]
}

@test "load_issue_invocation_counts recovers total from a torn/corrupted line with trailing junk after a numeric total" {
    # A partial/torn write (crash mid-write, disk full) can leave a numeric total followed by
    # garbage rather than a clean second token. Recovering total here (idle defaults to 0) does
    # not reintroduce the #1103 aliasing bug, since idle is never derived from the trailing junk.
    mkdir -p "${SESSION_BASE_DIR}"
    printf '7 gar\n' > "${SESSION_BASE_DIR}/Issue_99.invocations"
    load_issue_invocation_counts 99
    [ "${ISSUE_INVOCATION_TOTAL}" -eq 7 ]
    [ "${ISSUE_INVOCATION_IDLE}" -eq 0 ]
}

@test "reset_issue_invocation_counts_if_capped resets both counters and clears the marker when the runaway-blocked marker is present" {
    save_issue_invocation_counts 99 "${MAX_ISSUE_TOTAL_INVOCATIONS}" 3
    mkdir -p "${SESSION_BASE_DIR}"
    touch "${SESSION_BASE_DIR}/Issue_99.runaway-blocked"
    reset_issue_invocation_counts_if_capped 99
    load_issue_invocation_counts 99
    [ "${ISSUE_INVOCATION_TOTAL}" -eq 0 ]
    [ "${ISSUE_INVOCATION_IDLE}" -eq 0 ]
    [ ! -f "${SESSION_BASE_DIR}/Issue_99.runaway-blocked" ]
}

@test "reset_issue_invocation_counts_if_capped leaves the counters untouched when no runaway-blocked marker exists" {
    save_issue_invocation_counts 99 5 2
    reset_issue_invocation_counts_if_capped 99
    load_issue_invocation_counts 99
    [ "${ISSUE_INVOCATION_TOTAL}" -eq 5 ]
    [ "${ISSUE_INVOCATION_IDLE}" -eq 2 ]
}

@test "reset_issue_invocation_counts_if_capped does not reset a total that just now reached the cap without a marker" {
    # Regression guard: same rationale as the PR-side test — a not-yet-blocked Issue whose total
    # just reached the cap must not be reset before the backstop gets a chance to fire.
    save_issue_invocation_counts 99 "${MAX_ISSUE_TOTAL_INVOCATIONS}" 0
    reset_issue_invocation_counts_if_capped 99
    load_issue_invocation_counts 99
    [ "${ISSUE_INVOCATION_TOTAL}" -eq "${MAX_ISSUE_TOTAL_INVOCATIONS}" ]
}

# --- mark_capped_block_for_forgiveness (#1115) ------------------------------

@test "mark_capped_block_for_forgiveness writes the marker for a PR at the cap" {
    save_pr_invocation_counts 42 "${MAX_PR_TOTAL_INVOCATIONS}" 0
    mark_capped_block_for_forgiveness PullRequest 42
    [ -f "${SESSION_BASE_DIR}/PullRequest_42.runaway-blocked" ]
}

@test "mark_capped_block_for_forgiveness does not write the marker for a PR below the cap" {
    save_pr_invocation_counts 42 5 0
    mark_capped_block_for_forgiveness PullRequest 42
    [ ! -f "${SESSION_BASE_DIR}/PullRequest_42.runaway-blocked" ]
}

@test "mark_capped_block_for_forgiveness writes the marker for an Issue at the cap" {
    save_issue_invocation_counts 99 "${MAX_ISSUE_TOTAL_INVOCATIONS}" 0
    mark_capped_block_for_forgiveness Issue 99
    [ -f "${SESSION_BASE_DIR}/Issue_99.runaway-blocked" ]
}

@test "mark_capped_block_for_forgiveness does not write the marker for an Issue below the cap" {
    save_issue_invocation_counts 99 5 0
    mark_capped_block_for_forgiveness Issue 99
    [ ! -f "${SESSION_BASE_DIR}/Issue_99.runaway-blocked" ]
}

@test "mark_capped_block_for_forgiveness then reset forgives a PR blocked by a non-backstop rule (#1115 regression)" {
    # Reproduces the #116 bug: a PR blocked by something other than oneshot's own backstop (e.g.
    # the code-review workflow's "3+ rounds" rule) while its total already sits at the cap. Before
    # this fix, no marker existed for that block, so a human clearing the label was a no-op and
    # the very next observe-unblocked tick found the same stale total.
    save_pr_invocation_counts 116 "${MAX_PR_TOTAL_INVOCATIONS}" 0
    mark_capped_block_for_forgiveness PullRequest 116
    reset_pr_invocation_counts_if_capped 116
    load_pr_invocation_counts 116
    [ "${PR_INVOCATION_TOTAL}" -eq 0 ]
    [ "${PR_INVOCATION_IDLE}" -eq 0 ]
    [ ! -f "${SESSION_BASE_DIR}/PullRequest_116.runaway-blocked" ]
}

@test "mark_capped_block_for_forgiveness writes the marker for a PR at the idle cap even when total is well below its cap (#1264 review)" {
    save_pr_invocation_counts 42 4 "${MAX_PR_IDLE_INVOCATIONS}"
    mark_capped_block_for_forgiveness PullRequest 42
    [ -f "${SESSION_BASE_DIR}/PullRequest_42.runaway-blocked" ]
}

@test "mark_capped_block_for_forgiveness writes the marker for an Issue at the idle cap even when total is well below its cap (#1264 review)" {
    save_issue_invocation_counts 99 4 "${MAX_ISSUE_IDLE_INVOCATIONS}"
    mark_capped_block_for_forgiveness Issue 99
    [ -f "${SESSION_BASE_DIR}/Issue_99.runaway-blocked" ]
}

@test "mark_capped_block_for_forgiveness then reset forgives an Issue blocked purely by idle exhaustion (#1264 review)" {
    # Without checking the idle cap, docs/oneshot.md's claim that "both caps reset automatically
    # once a human clears Blocked" was false for an idle-only block: no marker meant clearing the
    # label was a no-op, and the still-unchanged fingerprint re-blocked the Issue on the very next
    # tick.
    save_issue_invocation_counts 99 4 "${MAX_ISSUE_IDLE_INVOCATIONS}"
    mark_capped_block_for_forgiveness Issue 99
    reset_issue_invocation_counts_if_capped 99
    load_issue_invocation_counts 99
    [ "${ISSUE_INVOCATION_TOTAL}" -eq 0 ]
    [ "${ISSUE_INVOCATION_IDLE}" -eq 0 ]
    [ ! -f "${SESSION_BASE_DIR}/Issue_99.runaway-blocked" ]
}

# --- issue_plan_block marker (#1286) ----------------------------------------

@test "issue_plan_block_marked is false when no marker file exists" {
    run issue_plan_block_marked 42
    [ "${status}" -ne 0 ]
}

@test "mark_issue_plan_block writes the marker and issue_plan_block_marked then reports it" {
    mark_issue_plan_block 42
    [ -f "${SESSION_BASE_DIR}/Issue_42.plan-block" ]
    run issue_plan_block_marked 42
    [ "${status}" -eq 0 ]
}

@test "clear_issue_plan_block_marker removes the marker" {
    mark_issue_plan_block 42
    clear_issue_plan_block_marker 42
    [ ! -f "${SESSION_BASE_DIR}/Issue_42.plan-block" ]
    run issue_plan_block_marked 42
    [ "${status}" -ne 0 ]
}

@test "clear_issue_plan_block_marker is a no-op when no marker exists" {
    run clear_issue_plan_block_marker 42
    [ "${status}" -eq 0 ]
}

# --- environment-block auto-unblock (#1118) ---------------------------------

@test "pr_json_env_block_image_sha extracts the sha from a single marker comment" {
    run pr_json_env_block_image_sha '{"comments":[{"body":"Diagnosis text\n<!-- orchestrator:env-block image-sha=abc1234 -->"}]}'
    [ "${status}" -eq 0 ]
    [ "${output}" = "abc1234" ]
}

@test "pr_json_env_block_image_sha returns the LAST matching comment's sha when the agent re-diagnosed" {
    run pr_json_env_block_image_sha '{"comments":[{"body":"first\n<!-- orchestrator:env-block image-sha=abc1234 -->"},{"body":"unrelated"},{"body":"second\n<!-- orchestrator:env-block image-sha=def5678 -->"}]}'
    [ "${status}" -eq 0 ]
    [ "${output}" = "def5678" ]
}

@test "pr_json_env_block_image_sha fails when no comment carries the marker" {
    run pr_json_env_block_image_sha '{"comments":[{"body":"a normal blocked comment with no marker"}]}'
    [ "${status}" -ne 0 ]
    [ -z "${output}" ]
}

@test "pr_json_env_block_image_sha fails on an empty comments array" {
    run pr_json_env_block_image_sha '{"comments":[]}'
    [ "${status}" -ne 0 ]
}

@test "current_agent_image_sha extracts IMAGE_SHA_DEVELOPMENT_AGENT from podman inspect output" {
    # shellcheck disable=SC2016
    make_stub podman 'printf "PATH=/usr/bin\nIMAGE_SHA_DEVELOPMENT_AGENT=deadbeef\nHOME=/root\n"'
    run current_agent_image_sha
    [ "${status}" -eq 0 ]
    [ "${output}" = "deadbeef" ]
}

@test "current_agent_image_sha fails when the image has no IMAGE_SHA_DEVELOPMENT_AGENT env var" {
    make_stub podman 'printf "PATH=/usr/bin\nHOME=/root\n"'
    run current_agent_image_sha
    [ "${status}" -ne 0 ]
}

@test "current_agent_image_sha fails when podman inspect itself fails" {
    make_stub podman 'exit 1'
    run current_agent_image_sha
    [ "${status}" -ne 0 ]
}

@test "try_auto_unblock_env_diagnosed_pr does nothing when the PR has no environment-block marker" {
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; exit 0'
    run try_auto_unblock_env_diagnosed_pr 5 org/repo '{"comments":[{"body":"a design question, not an environment issue"}]}'
    [ "${status}" -ne 0 ]
    [ ! -f "${GH_CALL_LOG}" ]
}

@test "try_auto_unblock_env_diagnosed_pr does nothing when the image sha has not changed" {
    make_stub podman 'printf "IMAGE_SHA_DEVELOPMENT_AGENT=abc1234\n"'
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; exit 0'
    run try_auto_unblock_env_diagnosed_pr 5 org/repo '{"comments":[{"body":"diagnosis\n<!-- orchestrator:env-block image-sha=abc1234 -->"}]}'
    [ "${status}" -ne 0 ]
    [ ! -f "${GH_CALL_LOG}" ]
}

@test "try_auto_unblock_env_diagnosed_pr clears Blocked and comments when a newer image has been built" {
    make_stub podman 'printf "IMAGE_SHA_DEVELOPMENT_AGENT=def5678\n"'
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; exit 0'
    run try_auto_unblock_env_diagnosed_pr 5 org/repo '{"comments":[{"body":"diagnosis\n<!-- orchestrator:env-block image-sha=abc1234 -->"}]}'
    [ "${status}" -eq 0 ]
    grep -q 'pr edit 5 --repo org/repo --remove-label Blocked' "${GH_CALL_LOG}"
    grep -q 'pr comment 5' "${GH_CALL_LOG}"
    [ "$(cat "${SESSION_BASE_DIR}/PullRequest_5.env-unblocks")" = "1" ]
}

@test "try_auto_unblock_env_diagnosed_pr stops auto-clearing once MAX_PR_ENV_AUTO_UNBLOCKS is reached and notifies once" {
    save_env_unblock_attempts 5 "${MAX_PR_ENV_AUTO_UNBLOCKS}"
    make_stub podman 'printf "IMAGE_SHA_DEVELOPMENT_AGENT=def5678\n"'
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; exit 0'

    run try_auto_unblock_env_diagnosed_pr 5 org/repo '{"comments":[{"body":"diagnosis\n<!-- orchestrator:env-block image-sha=abc1234 -->"}]}'
    [ "${status}" -ne 0 ]
    grep -q 'pr comment 5' "${GH_CALL_LOG}"
    [[ "$(cat "${GH_CALL_LOG}")" != *"remove-label Blocked"* ]]
    [ -f "${SESSION_BASE_DIR}/PullRequest_5.env-unblock-cap-notified" ]

    # A second tick while still capped must not post the notice again (no new gh calls).
    : > "${GH_CALL_LOG}"
    run try_auto_unblock_env_diagnosed_pr 5 org/repo '{"comments":[{"body":"diagnosis\n<!-- orchestrator:env-block image-sha=abc1234 -->"}]}'
    [ "${status}" -ne 0 ]
    [ ! -s "${GH_CALL_LOG}" ]
}

@test "reset_env_unblock_attempts clears both the attempts counter and the cap-notice marker" {
    save_env_unblock_attempts 5 2
    mkdir -p "${SESSION_BASE_DIR}"
    touch "${SESSION_BASE_DIR}/PullRequest_5.env-unblock-cap-notified"
    reset_env_unblock_attempts 5
    [ ! -f "${SESSION_BASE_DIR}/PullRequest_5.env-unblocks" ]
    [ ! -f "${SESSION_BASE_DIR}/PullRequest_5.env-unblock-cap-notified" ]
    load_env_unblock_attempts 5
    [ "${ENV_UNBLOCK_ATTEMPTS}" -eq 0 ]
}

@test "pr_json_is_terminal is true when auto-merge is enabled and false otherwise" {
    run pr_json_is_terminal '{"autoMergeRequest":{"enabledAt":"now"}}'
    [ "${status}" -eq 0 ]
    run pr_json_is_terminal '{"autoMergeRequest":null}'
    [ "${status}" -ne 0 ]
}

@test "pr_json_is_terminal is true when auto-merge is enabled and the only required check is COMPLETED/SUCCESS" {
    run pr_json_is_terminal '{"autoMergeRequest":{"enabledAt":"now"},"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS","isRequired":true}]}'
    [ "${status}" -eq 0 ]
}

@test "pr_json_is_terminal is true when auto-merge is enabled and a required check is still IN_PROGRESS" {
    run pr_json_is_terminal '{"autoMergeRequest":{"enabledAt":"now"},"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null,"isRequired":true}]}'
    [ "${status}" -eq 0 ]
}

@test "pr_json_is_terminal is false when auto-merge is enabled but a required CheckRun has FAILED" {
    run pr_json_is_terminal '{"autoMergeRequest":{"enabledAt":"now"},"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"FAILURE","isRequired":true}]}'
    [ "${status}" -ne 0 ]
}

@test "pr_json_is_terminal is true when auto-merge is enabled and only a non-required check has FAILED" {
    run pr_json_is_terminal '{"autoMergeRequest":{"enabledAt":"now"},"statusCheckRollup":[{"name":"badge","status":"COMPLETED","conclusion":"FAILURE","isRequired":false}]}'
    [ "${status}" -eq 0 ]
}

@test "pr_json_is_terminal is false when auto-merge is enabled but a required legacy StatusContext has state FAILURE" {
    run pr_json_is_terminal '{"autoMergeRequest":{"enabledAt":"now"},"statusCheckRollup":[{"name":"legacy","state":"FAILURE","isRequired":true}]}'
    [ "${status}" -ne 0 ]
}

@test "pr_json_is_terminal is true when auto-merge is enabled and a required legacy StatusContext has state SUCCESS" {
    run pr_json_is_terminal '{"autoMergeRequest":{"enabledAt":"now"},"statusCheckRollup":[{"name":"legacy","state":"SUCCESS","isRequired":true}]}'
    [ "${status}" -eq 0 ]
}

@test "pr_json_is_terminal is false when auto-merge is enabled but reviewDecision is CHANGES_REQUESTED (#1083)" {
    run pr_json_is_terminal '{"autoMergeRequest":{"enabledAt":"now"},"reviewDecision":"CHANGES_REQUESTED"}'
    [ "${status}" -ne 0 ]
}

@test "pr_json_is_terminal is true when auto-merge is enabled and reviewDecision is APPROVED or absent (#1083)" {
    run pr_json_is_terminal '{"autoMergeRequest":{"enabledAt":"now"},"reviewDecision":"APPROVED"}'
    [ "${status}" -eq 0 ]
    run pr_json_is_terminal '{"autoMergeRequest":{"enabledAt":"now"}}'
    [ "${status}" -eq 0 ]
}

@test "pr_json_is_terminal is true when auto-merge is enabled, mergeStateStatus is BLOCKED, and statusCheckRollup is empty (#1266)" {
    run pr_json_is_terminal '{"autoMergeRequest":{"enabledAt":"now"},"mergeStateStatus":"BLOCKED","statusCheckRollup":[]}'
    [ "${status}" -eq 0 ]
}

@test "pr_json_has_unaddressed_trusted_comment is false when there are no comments (#1307)" {
    run pr_json_has_unaddressed_trusted_comment '{"comments":[]}' '["credfeto"]' ""
    [ "${status}" -eq 1 ]
}

@test "pr_json_has_unaddressed_trusted_comment is true for any trusted comment when last_seen_timestamp is empty (#1307)" {
    run pr_json_has_unaddressed_trusted_comment '{"comments":[{"author":{"login":"credfeto"},"updatedAt":"2026-08-12T07:26:12Z"}]}' '["credfeto"]' ""
    [ "${status}" -eq 0 ]
}

@test "pr_json_has_unaddressed_trusted_comment is false when every trusted comment is at or before last_seen_timestamp (#1307)" {
    run pr_json_has_unaddressed_trusted_comment '{"comments":[{"author":{"login":"credfeto"},"updatedAt":"2026-08-12T07:26:12Z"}]}' '["credfeto"]' "2026-08-12T07:26:12Z"
    [ "${status}" -eq 1 ]
}

@test "pr_json_has_unaddressed_trusted_comment is true when a trusted comment is newer than last_seen_timestamp (#1307)" {
    run pr_json_has_unaddressed_trusted_comment '{"comments":[{"author":{"login":"credfeto"},"updatedAt":"2026-08-12T10:05:07Z"}]}' '["credfeto"]' "2026-08-12T07:26:12Z"
    [ "${status}" -eq 0 ]
}

@test "pr_json_has_unaddressed_trusted_comment ignores comments from untrusted logins (#1307)" {
    run pr_json_has_unaddressed_trusted_comment '{"comments":[{"author":{"login":"random-passerby"},"updatedAt":"2026-08-12T10:05:07Z"}]}' '["credfeto"]' "2026-08-12T07:26:12Z"
    [ "${status}" -eq 1 ]
}

@test "pr_json_has_unaddressed_trusted_comment treats every commenter as trusted when trusted_logins is null (#1307)" {
    run pr_json_has_unaddressed_trusted_comment '{"comments":[{"author":{"login":"random-passerby"},"updatedAt":"2026-08-12T10:05:07Z"}]}' 'null' "2026-08-12T07:26:12Z"
    [ "${status}" -eq 0 ]
}

@test "pr_json_latest_trusted_comment_timestamp returns empty string when there are no trusted comments (#1307)" {
    run pr_json_latest_trusted_comment_timestamp '{"comments":[{"author":{"login":"random-passerby"},"updatedAt":"2026-08-12T10:05:07Z"}]}' '["credfeto"]'
    [ "${status}" -eq 0 ]
    [ "${output}" = "" ]
}

@test "pr_json_latest_trusted_comment_timestamp returns the newest trusted comment's timestamp (#1307)" {
    run pr_json_latest_trusted_comment_timestamp '{"comments":[{"author":{"login":"credfeto"},"updatedAt":"2026-08-12T07:26:12Z"},{"author":{"login":"credfeto"},"updatedAt":"2026-08-12T10:05:07Z"}]}' '["credfeto"]'
    [ "${status}" -eq 0 ]
    [ "${output}" = "2026-08-12T10:05:07Z" ]
}

@test "pr_json_latest_trusted_comment_timestamp picks up a trusted review even with no top-level comments (#1307 review)" {
    run pr_json_latest_trusted_comment_timestamp '{"comments":[],"reviews":[{"author":{"login":"credfeto"},"state":"COMMENTED","submittedAt":"2026-08-12T10:05:07Z"}]}' '["credfeto"]'
    [ "${status}" -eq 0 ]
    [ "${output}" = "2026-08-12T10:05:07Z" ]
}

@test "pr_json_latest_trusted_comment_timestamp picks up a trusted inline review comment via the third argument (#1307 review)" {
    run pr_json_latest_trusted_comment_timestamp '{"comments":[],"reviews":[]}' '["credfeto"]' '[{"user":{"login":"credfeto"},"updated_at":"2026-08-12T10:05:07Z"}]'
    [ "${status}" -eq 0 ]
    [ "${output}" = "2026-08-12T10:05:07Z" ]
}

@test "pr_json_latest_trusted_comment_timestamp ignores an untrusted review and inline comment (#1307 review)" {
    run pr_json_latest_trusted_comment_timestamp '{"comments":[],"reviews":[{"author":{"login":"random-passerby"},"submittedAt":"2026-08-12T10:05:07Z"}]}' '["credfeto"]' '[{"user":{"login":"random-passerby"},"updated_at":"2026-08-12T10:05:07Z"}]'
    [ "${status}" -eq 0 ]
    [ "${output}" = "" ]
}

@test "pr_json_latest_trusted_comment_timestamp returns the newest across all three trusted-activity sources (#1307 review)" {
    run pr_json_latest_trusted_comment_timestamp '{"comments":[{"author":{"login":"credfeto"},"updatedAt":"2026-08-12T06:00:00Z"}],"reviews":[{"author":{"login":"credfeto"},"submittedAt":"2026-08-12T07:00:00Z"}]}' '["credfeto"]' '[{"user":{"login":"credfeto"},"updated_at":"2026-08-12T10:05:07Z"}]'
    [ "${status}" -eq 0 ]
    [ "${output}" = "2026-08-12T10:05:07Z" ]
}

@test "pr_json_has_unaddressed_trusted_comment is true for a trusted review with no top-level comments (#1307 review)" {
    run pr_json_has_unaddressed_trusted_comment '{"comments":[],"reviews":[{"author":{"login":"credfeto"},"submittedAt":"2026-08-12T10:05:07Z"}]}' '["credfeto"]' "2026-08-12T07:26:12Z"
    [ "${status}" -eq 0 ]
}

@test "pr_json_has_unaddressed_trusted_comment is true for a trusted inline review comment via the fourth argument (#1307 review)" {
    run pr_json_has_unaddressed_trusted_comment '{"comments":[],"reviews":[]}' '["credfeto"]' "2026-08-12T07:26:12Z" '[{"user":{"login":"credfeto"},"updated_at":"2026-08-12T10:05:07Z"}]'
    [ "${status}" -eq 0 ]
}

@test "pr_json_has_unaddressed_review_request is true for reviewDecision CHANGES_REQUESTED (#1083)" {
    run pr_json_has_unaddressed_review_request '{"reviewDecision":"CHANGES_REQUESTED"}'
    [ "${status}" -eq 0 ]
}

@test "pr_json_needs_review_approval is true for reviewDecision REVIEW_REQUIRED (#1278)" {
    run pr_json_needs_review_approval '{"reviewDecision":"REVIEW_REQUIRED"}'
    [ "${status}" -eq 0 ]
}

@test "pr_json_needs_review_approval is false for reviewDecision APPROVED, CHANGES_REQUESTED, or absent (#1278)" {
    run pr_json_needs_review_approval '{"reviewDecision":"APPROVED"}'
    [ "${status}" -ne 0 ]
    run pr_json_needs_review_approval '{"reviewDecision":"CHANGES_REQUESTED"}'
    [ "${status}" -ne 0 ]
    run pr_json_needs_review_approval '{}'
    [ "${status}" -ne 0 ]
}

# --- apply_blocked_label (#1092) ----------------------------------------------

@test "apply_blocked_label returns 0 when the label is confirmed present on first try (#1092)" {
    # shellcheck disable=SC2016
    make_stub gh 'case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    run apply_blocked_label "PullRequest" 5 "org/repo"
    [ "${status}" -eq 0 ]
}

@test "apply_blocked_label self-heals by creating the label then retries (#1092)" {
    # First view (before any create attempt) reports false; after "label create" runs, report true.
    # shellcheck disable=SC2016
    make_stub gh 'case "$*" in
        *"label create"*) printf "created\n" >> "'"${TEST_TMP}"'/created"; exit 0 ;;
        *"--json labels"*) if [ -f "'"${TEST_TMP}"'/created" ]; then printf "true\n"; else printf "false\n"; fi ;;
    esac
    exit 0'
    run apply_blocked_label "PullRequest" 5 "org/repo"
    [ "${status}" -eq 0 ]
    [ -f "${TEST_TMP}/created" ]
}

@test "apply_blocked_label returns 1 without dying when the label never verifies as present (#1092)" {
    # shellcheck disable=SC2016
    make_stub gh 'case "$*" in *"--json labels"*) printf "false\n" ;; esac; exit 0'
    run apply_blocked_label "PullRequest" 5 "org/repo"
    [ "${status}" -ne 0 ]
}

@test "apply_blocked_label uses the issue noun for Issue items (#1092)" {
    local call_log="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "'"${call_log}"'"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    run apply_blocked_label "Issue" 5 "org/repo"
    [ "${status}" -eq 0 ]
    grep -qx 'issue edit 5 --repo org/repo --add-label Blocked' "${call_log}"
}

@test "block_pr_for_idle_exhausted_failure does not post a comment when the label cannot be verified (#1092)" {
    local call_log="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "'"${call_log}"'"; case "$*" in *"--json labels"*) printf "false\n" ;; esac; exit 0'
    notify_discord_blocked_item() { printf 'notified %s #%s\n' "$1" "$2" >> "${TEST_TMP}/discord_calls"; }

    run block_pr_for_idle_exhausted_failure 5 "org/repo"
    [ "${status}" -ne 0 ]
    run grep -q 'pr comment 5' "${call_log}"
    [ "${status}" -ne 0 ]
    grep -qx 'notified PullRequest #5' "${TEST_TMP}/discord_calls"
}

@test "block_pr_for_idle_exhausted_failure posts the comment once the label is verified present (#1092)" {
    local call_log="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "'"${call_log}"'"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    notify_discord_blocked_item() { printf 'notified %s #%s\n' "$1" "$2" >> "${TEST_TMP}/discord_calls"; }

    run block_pr_for_idle_exhausted_failure 5 "org/repo"
    [ "${status}" -eq 0 ]
    grep -q 'pr comment 5' "${call_log}"
    grep -qx 'notified PullRequest #5' "${TEST_TMP}/discord_calls"
}

@test "block_pr_for_idle_exhausted_review does not post a comment when the label cannot be verified (#1140 review)" {
    local call_log="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "'"${call_log}"'"; case "$*" in *"--json labels"*) printf "false\n" ;; esac; exit 0'
    notify_discord_blocked_item() { printf 'notified %s #%s reason=%s\n' "$1" "$2" "$3" >> "${TEST_TMP}/discord_calls"; }

    run block_pr_for_idle_exhausted_review 5 "org/repo"
    [ "${status}" -ne 0 ]
    run grep -q 'pr comment 5' "${call_log}"
    [ "${status}" -ne 0 ]
    grep -q 'notified PullRequest #5 reason=This PR has an unaddressed review requesting changes' "${TEST_TMP}/discord_calls"
}

@test "block_pr_for_idle_exhausted_review posts the review-specific reason once the label is verified present (#1140 review)" {
    local call_log="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "'"${call_log}"'"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    notify_discord_blocked_item() { printf 'notified %s #%s reason=%s\n' "$1" "$2" "$3" >> "${TEST_TMP}/discord_calls"; }

    run block_pr_for_idle_exhausted_review 5 "org/repo"
    [ "${status}" -eq 0 ]
    grep -q 'pr comment 5 --repo org/repo --body This PR has an unaddressed review requesting changes' "${call_log}"
    grep -q 'notified PullRequest #5 reason=This PR has an unaddressed review requesting changes' "${TEST_TMP}/discord_calls"
}

# --- apply_blocked_label_with_reason (#1140 review) -----------------------------

@test "apply_blocked_label_with_reason posts the reason as a comment and notifies with it on success" {
    local call_log="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "'"${call_log}"'"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    local _notif_log="${TEST_TMP}/discord_calls"
    notify_discord_blocked_item() { printf 'type=%s id=%s reason=%s\n' "$1" "$2" "$3" >> "${_notif_log}"; }

    run apply_blocked_label_with_reason "Issue" 42 "org/repo" "custom reason text"
    [ "${status}" -eq 0 ]
    grep -q "issue comment 42 --repo org/repo --body custom reason text" "${call_log}"
    grep -qx "type=Issue id=42 reason=custom reason text" "${_notif_log}"
}

@test "apply_blocked_label_with_reason still notifies but skips the comment when the label cannot be verified" {
    local call_log="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "'"${call_log}"'"; case "$*" in *"--json labels"*) printf "false\n" ;; esac; exit 0'
    local _notif_log="${TEST_TMP}/discord_calls"
    notify_discord_blocked_item() { printf 'type=%s id=%s reason=%s\n' "$1" "$2" "$3" >> "${_notif_log}"; }

    run apply_blocked_label_with_reason "PullRequest" 5 "org/repo" "unverifiable reason"
    [ "${status}" -ne 0 ]
    run grep -q 'comment 5' "${call_log}"
    [ "${status}" -ne 0 ]
    grep -qx "type=PullRequest id=5 reason=unverifiable reason" "${_notif_log}"
}

@test "apply_blocked_label_with_reason still notifies and returns success when the label verifies but the comment call itself fails (#1140 review)" {
    # The label is confirmed present, but the "gh ... comment" invocation fails (e.g. a transient
    # API error) — the 2>/dev/null || true swallows that failure, so the function must still
    # report the label's own success and must still fire the Discord notification with the reason.
    # shellcheck disable=SC2016
    make_stub gh 'case "$*" in
        *"--json labels"*) printf "true\n" ;;
        *"comment"*) exit 1 ;;
    esac
    exit 0'
    local _notif_log="${TEST_TMP}/discord_calls"
    notify_discord_blocked_item() { printf 'type=%s id=%s reason=%s\n' "$1" "$2" "$3" >> "${_notif_log}"; }

    run apply_blocked_label_with_reason "Issue" 42 "org/repo" "custom reason text"
    [ "${status}" -eq 0 ]
    grep -qx "type=Issue id=42 reason=custom reason text" "${_notif_log}"
}

# --- sync_pr_labels_from_linked_issues (#1321) --------------------------------

@test "sync_pr_labels_from_linked_issues never copies Blocked or On-Hold, but still copies other labels" {
    set_repo_context "org/repo"
    local call_log="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "'"${call_log}"'"
    case "$*" in
        *"pr view 42 --repo org/repo --json closingIssuesReferences"*) printf "164\n" ;;
        *"issue view 164 --repo org/repo --json labels"*) printf "Bug\nBlocked\nOn-Hold\n" ;;
        *"pr edit"*) exit 0 ;;
    esac'

    sync_pr_labels_from_linked_issues 42 '{"labels":[]}'

    grep -q -- "pr edit 42 --repo org/repo --add-label Bug" "${call_log}"
    run grep -- "--add-label Blocked" "${call_log}"
    [ "${status}" -ne 0 ]
    run grep -- "--add-label On-Hold" "${call_log}"
    [ "${status}" -ne 0 ]
}

@test "sync_pr_labels_from_linked_issues does not call gh pr edit when there is nothing new to add" {
    set_repo_context "org/repo"
    local call_log="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "'"${call_log}"'"
    case "$*" in
        *"pr view 42 --repo org/repo --json closingIssuesReferences"*) printf "164\n" ;;
        *"issue view 164 --repo org/repo --json labels"*) printf "Blocked\nOn-Hold\n" ;;
        *"pr edit"*) exit 0 ;;
    esac'

    sync_pr_labels_from_linked_issues 42 '{"labels":[]}'

    run grep -- "pr edit" "${call_log}"
    [ "${status}" -ne 0 ]
}

# --- block_pr_for_ci_timeout (#1140 review) --------------------------------------

@test "block_pr_for_ci_timeout posts the timeout-specific reason and clears the pending-CI state once the label is verified (#1140 review)" {
    local call_log="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "'"${call_log}"'"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    local _notif_log="${TEST_TMP}/discord_calls"
    notify_discord_blocked_item() { printf 'notified %s #%s reason=%s\n' "$1" "$2" "$3" >> "${_notif_log}"; }
    CI_CHECK_TIMEOUT_MINUTES=60
    save_pr_head_oid 5 "abc123" "$(date +%s)"

    run block_pr_for_ci_timeout 5 "org/repo"
    [ "${status}" -eq 0 ]
    grep -q "pr comment 5 --repo org/repo --body CI checks have been pending for over 60 minutes" "${call_log}"
    grep -q 'notified PullRequest #5 reason=CI checks have been pending for over 60 minutes' "${_notif_log}"
    [ ! -f "$(pr_head_oid_file_path 5)" ]
}

@test "block_pr_for_ci_timeout leaves the pending-CI state alone when the label cannot be verified (#1140 review)" {
    # If escalation itself failed, the timeout clock must NOT be cleared — otherwise the next
    # tick silently re-arms a fresh full-length wait instead of re-attempting the escalation.
    # shellcheck disable=SC2016
    make_stub gh 'case "$*" in *"--json labels"*) printf "false\n" ;; esac; exit 0'
    notify_discord_blocked_item() { :; }
    CI_CHECK_TIMEOUT_MINUTES=60
    save_pr_head_oid 5 "abc123" "$(date +%s)"

    run block_pr_for_ci_timeout 5 "org/repo"
    [ "${status}" -ne 0 ]
    [ -f "$(pr_head_oid_file_path 5)" ]
}

@test "pr_json_has_unaddressed_review_request is false for reviewDecision APPROVED, REVIEW_REQUIRED, or absent (#1083)" {
    run pr_json_has_unaddressed_review_request '{"reviewDecision":"APPROVED"}'
    [ "${status}" -ne 0 ]
    run pr_json_has_unaddressed_review_request '{"reviewDecision":"REVIEW_REQUIRED"}'
    [ "${status}" -ne 0 ]
    run pr_json_has_unaddressed_review_request '{}'
    [ "${status}" -ne 0 ]
}

@test "pr_json_has_failed_required_check is true for a required CheckRun with conclusion FAILURE" {
    run pr_json_has_failed_required_check '{"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"FAILURE","isRequired":true}]}'
    [ "${status}" -eq 0 ]
}

@test "pr_json_has_failed_required_check is false for a non-required CheckRun with conclusion FAILURE" {
    run pr_json_has_failed_required_check '{"statusCheckRollup":[{"name":"badge","status":"COMPLETED","conclusion":"FAILURE","isRequired":false}]}'
    [ "${status}" -ne 0 ]
}

@test "pr_json_has_failed_required_check is false when all required checks are SUCCESS or pending" {
    run pr_json_has_failed_required_check '{"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS","isRequired":true},{"name":"lint","status":"IN_PROGRESS","conclusion":null,"isRequired":true}]}'
    [ "${status}" -ne 0 ]
}

@test "pr_json_has_failed_required_check is true for a required legacy StatusContext with state FAILURE" {
    run pr_json_has_failed_required_check '{"statusCheckRollup":[{"name":"legacy","state":"FAILURE","isRequired":true}]}'
    [ "${status}" -eq 0 ]
}

@test "pr_json_has_failed_required_check is true for a required legacy StatusContext with state ERROR" {
    run pr_json_has_failed_required_check '{"statusCheckRollup":[{"name":"legacy","state":"ERROR","isRequired":true}]}'
    [ "${status}" -eq 0 ]
}

@test "pr_json_has_failed_required_check is false for a required legacy StatusContext with state SUCCESS or PENDING" {
    run pr_json_has_failed_required_check '{"statusCheckRollup":[{"name":"legacy","state":"SUCCESS","isRequired":true}]}'
    [ "${status}" -ne 0 ]
    run pr_json_has_failed_required_check '{"statusCheckRollup":[{"name":"legacy","state":"PENDING","isRequired":true}]}'
    [ "${status}" -ne 0 ]
}

@test "pr_json_has_failed_required_check is false when statusCheckRollup is empty or absent" {
    run pr_json_has_failed_required_check '{"statusCheckRollup":[]}'
    [ "${status}" -ne 0 ]
    run pr_json_has_failed_required_check '{}'
    [ "${status}" -ne 0 ]
}

@test "pr_should_advance_unchanged parks a terminal (auto-merge enabled) PR" {
    run pr_should_advance_unchanged 42 '{"autoMergeRequest":{"enabledAt":"now"}}'
    [ "${status}" -ne 0 ]
}

@test "pr_should_advance_unchanged advances a PR with auto-merge enabled but a failed required check" {
    save_pr_invocation_counts 42 4 2
    run pr_should_advance_unchanged 42 '{"autoMergeRequest":{"enabledAt":"now"},"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"FAILURE","isRequired":true}]}'
    [ "${status}" -eq 0 ]
}

@test "pr_should_advance_unchanged advances a non-terminal PR within the idle budget" {
    save_pr_invocation_counts 42 4 2
    run pr_should_advance_unchanged 42 '{"autoMergeRequest":null}'
    [ "${status}" -eq 0 ]
}

@test "pr_should_advance_unchanged parks a non-terminal PR once the idle budget is exhausted" {
    save_pr_invocation_counts 42 10 "${MAX_PR_IDLE_INVOCATIONS}"
    run pr_should_advance_unchanged 42 '{"autoMergeRequest":null}'
    [ "${status}" -ne 0 ]
}

@test "pr_should_advance_unchanged advances a terminal PR within the idle budget when has_unaddressed_comment is true (#1307 review)" {
    run pr_should_advance_unchanged 42 '{"autoMergeRequest":{"enabledAt":"now"}}' "true"
    [ "${status}" -eq 0 ]
}

@test "pr_should_advance_unchanged still parks a terminal PR when has_unaddressed_comment is false (#1307 review)" {
    run pr_should_advance_unchanged 42 '{"autoMergeRequest":{"enabledAt":"now"}}' "false"
    [ "${status}" -ne 0 ]
}

@test "pr_should_advance_unchanged parks a terminal PR with has_unaddressed_comment true once the idle budget is exhausted (#1307 review)" {
    # The escalation-defeating regression this guards against: an unaddressed comment must not
    # exempt a PR from the idle budget forever, or the failed-check/unaddressed-review-request
    # escalation in oneshot's caller never gets a real chance to fire.
    save_pr_invocation_counts 42 10 "${MAX_PR_IDLE_INVOCATIONS}"
    run pr_should_advance_unchanged 42 '{"autoMergeRequest":{"enabledAt":"now"}}' "true"
    [ "${status}" -ne 0 ]
}

# --- issue_should_advance_unchanged / block_issue_for_idle_exhausted_no_progress (#1264) ---

@test "issue_should_advance_unchanged is false when the plan is not approved, regardless of idle count" {
    run issue_should_advance_unchanged 99 "false"
    [ "${status}" -ne 0 ]
}

@test "issue_should_advance_unchanged is true when the plan is approved and idle count is below budget" {
    save_issue_invocation_counts 99 4 2
    run issue_should_advance_unchanged 99 "true"
    [ "${status}" -eq 0 ]
}

@test "issue_should_advance_unchanged is false when the plan is approved but the idle budget is exhausted" {
    save_issue_invocation_counts 99 10 "${MAX_ISSUE_IDLE_INVOCATIONS}"
    run issue_should_advance_unchanged 99 "true"
    [ "${status}" -ne 0 ]
}

@test "issue_should_advance_unchanged is true for a fresh Issue (no guard file) that is plan-approved" {
    run issue_should_advance_unchanged 99 "true"
    [ "${status}" -eq 0 ]
}

@test "block_issue_for_idle_exhausted_no_progress does not post a comment when the label cannot be verified" {
    local call_log="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "'"${call_log}"'"; case "$*" in *"--json labels"*) printf "false\n" ;; esac; exit 0'
    notify_discord_blocked_item() { printf 'notified %s #%s reason=%s\n' "$1" "$2" "$3" >> "${TEST_TMP}/discord_calls"; }

    run block_issue_for_idle_exhausted_no_progress 99 "org/repo"
    [ "${status}" -ne 0 ]
    run grep -q 'issue comment 99' "${call_log}"
    [ "${status}" -ne 0 ]
    grep -q 'notified Issue #99 reason=This issue.s plan is approved' "${TEST_TMP}/discord_calls"
}

@test "block_issue_for_idle_exhausted_no_progress posts the reason once the label is verified present" {
    local call_log="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "'"${call_log}"'"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    notify_discord_blocked_item() { printf 'notified %s #%s reason=%s\n' "$1" "$2" "$3" >> "${TEST_TMP}/discord_calls"; }

    run block_issue_for_idle_exhausted_no_progress 99 "org/repo"
    [ "${status}" -eq 0 ]
    grep -q "issue comment 99 --repo org/repo --body This issue's plan is approved" "${call_log}"
    grep -q "notified Issue #99 reason=This issue.s plan is approved" "${TEST_TMP}/discord_calls"
}

# --- fingerprinting --------------------------------------------------------

@test "hash_sha256 is deterministic and matches the known SHA-256 of 'hello'" {
    run bash -c 'source "'"${REPO_ROOT}"'/oneshot"; printf "hello" | hash_sha256'
    [ "${status}" -eq 0 ]
    [ "${output}" = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824" ]
}

# --- AGENT_TIMEOUT_MINUTES validation (#1103) -------------------------------

@test "AGENT_TIMEOUT_MINUTES falls back to 90 when unset" {
    run bash -c 'unset AGENT_TIMEOUT_MINUTES; source "'"${REPO_ROOT}"'/oneshot"; printf "%s" "${AGENT_TIMEOUT_MINUTES}"'
    [ "${status}" -eq 0 ]
    [ "${output}" = "90" ]
}

@test "AGENT_TIMEOUT_MINUTES falls back to 90 for a non-numeric value" {
    run bash -c 'export AGENT_TIMEOUT_MINUTES=abc; source "'"${REPO_ROOT}"'/oneshot"; printf "%s" "${AGENT_TIMEOUT_MINUTES}"'
    [ "${status}" -eq 0 ]
    [ "${output}" = "90" ]
}

@test "AGENT_TIMEOUT_MINUTES falls back to 90 for a value with a trailing non-digit" {
    run bash -c 'export AGENT_TIMEOUT_MINUTES=1x; source "'"${REPO_ROOT}"'/oneshot"; printf "%s" "${AGENT_TIMEOUT_MINUTES}"'
    [ "${status}" -eq 0 ]
    [ "${output}" = "90" ]
}

@test "AGENT_TIMEOUT_MINUTES falls back to 90 for zero" {
    run bash -c 'export AGENT_TIMEOUT_MINUTES=0; source "'"${REPO_ROOT}"'/oneshot"; printf "%s" "${AGENT_TIMEOUT_MINUTES}"'
    [ "${status}" -eq 0 ]
    [ "${output}" = "90" ]
}

@test "AGENT_TIMEOUT_MINUTES accepts a valid positive integer" {
    run bash -c 'export AGENT_TIMEOUT_MINUTES=45; source "'"${REPO_ROOT}"'/oneshot"; printf "%s" "${AGENT_TIMEOUT_MINUTES}"'
    [ "${status}" -eq 0 ]
    [ "${output}" = "45" ]
}

@test "fingerprint_pr_json is deterministic and changes when input changes" {
    local pr_a='{"title":"T","body":"B","isDraft":false,"labels":[{"name":"bug"}],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}'
    local pr_b='{"title":"T2","body":"B","isDraft":false,"labels":[{"name":"bug"}],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}'

    local fp1 fp2 fp3
    fp1=$(fingerprint_pr_json "${pr_a}")
    fp2=$(fingerprint_pr_json "${pr_a}")
    fp3=$(fingerprint_pr_json "${pr_b}")
    [ -n "${fp1}" ]
    [ "${fp1}" = "${fp2}" ]
    [ "${fp1}" != "${fp3}" ]
}

@test "fingerprint_pr_json changes when autoMergeRequest transitions from null to set" {
    local pr_no_automerge='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[],"autoMergeRequest":null}'
    local pr_with_automerge='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[],"autoMergeRequest":{"mergeMethod":"MERGE"}}'

    local fp1 fp2
    fp1=$(fingerprint_pr_json "${pr_no_automerge}")
    fp2=$(fingerprint_pr_json "${pr_with_automerge}")
    [ -n "${fp1}" ]
    [ "${fp1}" != "${fp2}" ]
}

@test "fingerprint_pr_json changes when a legacy StatusContext check's .state changes, with no .conclusion/.status present (#1210)" {
    local pr_pending='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[{"name":"codecov/project","state":"PENDING"}]}'
    local pr_failed='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[{"name":"codecov/project","state":"FAILURE"}]}'

    local fp1 fp2
    fp1=$(fingerprint_pr_json "${pr_pending}")
    fp2=$(fingerprint_pr_json "${pr_failed}")
    [ -n "${fp1}" ]
    [ "${fp1}" != "${fp2}" ]
}

@test "fingerprint_issue_json is deterministic and changes when input changes" {
    local issue_a='{"title":"T","body":"B","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}'
    local issue_b='{"title":"T","body":"CHANGED","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}'

    local fp1 fp2 fp3
    fp1=$(fingerprint_issue_json "${issue_a}")
    fp2=$(fingerprint_issue_json "${issue_a}")
    fp3=$(fingerprint_issue_json "${issue_b}")
    [ -n "${fp1}" ]
    [ "${fp1}" = "${fp2}" ]
    [ "${fp1}" != "${fp3}" ]
}

@test "pr_json_has_blocked_label detects 'blocked' case-insensitively and is false when absent" {
    run pr_json_has_blocked_label '{"labels":[{"name":"Blocked"}]}'
    [ "${status}" -eq 0 ]

    run pr_json_has_blocked_label '{"labels":[{"name":"BLOCKED"}]}'
    [ "${status}" -eq 0 ]

    run pr_json_has_blocked_label '{"labels":[{"name":"bug"},{"name":"enhancement"}]}'
    [ "${status}" -ne 0 ]
}

@test "issue_json_has_blocked_label detects 'blocked' case-insensitively and is false when absent" {
    run issue_json_has_blocked_label '{"labels":[{"name":"blocked"}]}'
    [ "${status}" -eq 0 ]

    run issue_json_has_blocked_label '{"labels":[{"name":"BlOcKeD"}]}'
    [ "${status}" -eq 0 ]

    run issue_json_has_blocked_label '{"labels":[{"name":"wontfix"}]}'
    [ "${status}" -ne 0 ]
}

@test "pr_json_has_blocked_label and issue_json_has_blocked_label do not error when labels is absent (#1102)" {
    run pr_json_has_blocked_label '{}'
    [ "${status}" -ne 0 ]
    [[ "${output}" != *"jq: error"* ]]

    run issue_json_has_blocked_label '{}'
    [ "${status}" -ne 0 ]
    [[ "${output}" != *"jq: error"* ]]
}

# --- plan-awaiting-human-approval detection (#1286) -------------------------

@test "issue_json_has_plan_comment detects the heading case-insensitively and is false when absent" {
    run issue_json_has_plan_comment '{"comments":[{"body":"## implementation plan\n\nstuff"}]}'
    [ "${status}" -eq 0 ]

    run issue_json_has_plan_comment '{"comments":[{"body":"just chatting"}]}'
    [ "${status}" -ne 0 ]
}

@test "issue_json_has_human_plan_approval is true for a trusted human approval comment posted after the plan" {
    local issue='{"comments":[{"author":{"login":"bot"},"body":"## Implementation Plan\n..."},{"author":{"login":"credfeto"},"body":"approved"}]}'
    run issue_json_has_human_plan_approval "${issue}" "bot" '["credfeto"]'
    [ "${status}" -eq 0 ]
}

@test "issue_json_has_human_plan_approval is false when only the bot's OWN comment matches the approval keyword (#434, #615 regression)" {
    # Live-verified: funfair-build-check#434's only "approved"-matching comment was the bot's own,
    # explaining that approval was NOT found. The pre-#1286 matcher (no author restriction) read
    # this as approved.
    local issue='{"comments":[{"author":{"login":"bot"},"body":"## Implementation Plan\n..."},{"author":{"login":"bot"},"body":"I cannot treat it as approved yet: the board status is Todo, not Approved."}]}'
    run issue_json_has_human_plan_approval "${issue}" "bot" '["credfeto"]'
    [ "${status}" -ne 0 ]
}

@test "issue_json_has_human_plan_approval is false when the approving author is not in the trusted logins list" {
    local issue='{"comments":[{"author":{"login":"bot"},"body":"## Implementation Plan\n..."},{"author":{"login":"randomer"},"body":"lgtm"}]}'
    run issue_json_has_human_plan_approval "${issue}" "bot" '["credfeto"]'
    [ "${status}" -ne 0 ]
}

@test "issue_json_has_human_plan_approval is false when the approval comment precedes the plan comment" {
    local issue='{"comments":[{"author":{"login":"credfeto"},"body":"looks good"},{"author":{"login":"bot"},"body":"## Implementation Plan\n..."}]}'
    run issue_json_has_human_plan_approval "${issue}" "bot" '["credfeto"]'
    [ "${status}" -ne 0 ]
}

@test "issue_json_has_human_plan_approval is false when there is no plan comment at all" {
    local issue='{"comments":[{"author":{"login":"credfeto"},"body":"approved"}]}'
    run issue_json_has_human_plan_approval "${issue}" "bot" '["credfeto"]'
    [ "${status}" -ne 0 ]
}

@test "issue_plan_awaiting_human_approval is true for a plan comment with no human approval since (#1232-shaped)" {
    local issue='{"comments":[{"author":{"login":"bot"},"body":"## Implementation Plan\n### Open questions\nNone, ready to proceed pending approval."}]}'
    run issue_plan_awaiting_human_approval "${issue}" "bot" '["credfeto"]'
    [ "${status}" -eq 0 ]
}

@test "issue_plan_awaiting_human_approval is false once a trusted human approves" {
    local issue='{"comments":[{"author":{"login":"bot"},"body":"## Implementation Plan\n..."},{"author":{"login":"credfeto"},"body":"go ahead"}]}'
    run issue_plan_awaiting_human_approval "${issue}" "bot" '["credfeto"]'
    [ "${status}" -ne 0 ]
}

@test "issue_plan_awaiting_human_approval is false when there is no plan comment at all (key negative case, #3613-shaped)" {
    # funfair-ethereum-proxy-server-monitor#3613: a tracking issue whose own open questions live on
    # sub-issues, not itself — must never be flagged just because it has comments.
    local issue='{"comments":[{"author":{"login":"bot"},"body":"Status update. Sub-issue status: ..."}]}'
    run issue_plan_awaiting_human_approval "${issue}" "bot" '["credfeto"]'
    [ "${status}" -ne 0 ]
}

@test "human_plan_approval_jq_literal bakes in the login and trusted-logins literals and matches issue_json_has_human_plan_approval's own verdict" {
    local issue='{"comments":[{"author":{"login":"bot"},"body":"## Implementation Plan\n..."},{"author":{"login":"bot"},"body":"not approved yet"}]}'
    local jq_expr
    jq_expr=$(human_plan_approval_jq_literal "bot" '["credfeto"]')
    [[ "${jq_expr}" == *'"bot"'* ]]
    [[ "${jq_expr}" == *'["credfeto"]'* ]]
    run bash -c 'printf "%s" "$1" | jq -e "$2"' -- "${issue}" "${jq_expr}"
    [ "${status}" -ne 0 ]
}

@test "fingerprint_issue_json with trusted logins: trusted comment changes fingerprint" {
    local issue_base='{"title":"T","body":"B","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}'
    local issue_trusted='{"title":"T","body":"B","state":"OPEN","labels":[],"comments":[{"author":{"login":"owner"},"body":"hello","updatedAt":"2024-01-01T00:00:00Z"}],"assignees":[],"milestone":null}'
    local trusted='["owner"]'
    local fp_base fp_trusted
    fp_base=$(fingerprint_issue_json "${issue_base}" "${trusted}")
    fp_trusted=$(fingerprint_issue_json "${issue_trusted}" "${trusted}")
    [ "${fp_base}" != "${fp_trusted}" ]
}

@test "fingerprint_issue_json with trusted logins: untrusted comment does not change fingerprint" {
    local issue_base='{"title":"T","body":"B","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}'
    local issue_untrusted='{"title":"T","body":"B","state":"OPEN","labels":[],"comments":[{"author":{"login":"randomer"},"body":"hello","updatedAt":"2024-01-01T00:00:00Z"}],"assignees":[],"milestone":null}'
    local trusted='["owner"]'
    local fp_base fp_untrusted
    fp_base=$(fingerprint_issue_json "${issue_base}" "${trusted}")
    fp_untrusted=$(fingerprint_issue_json "${issue_untrusted}" "${trusted}")
    [ "${fp_base}" = "${fp_untrusted}" ]
}

@test "fingerprint_issue_json without trusted logins uses all comments" {
    local issue_base='{"title":"T","body":"B","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}'
    local issue_comment='{"title":"T","body":"B","state":"OPEN","labels":[],"comments":[{"author":{"login":"anyone"},"body":"hi","updatedAt":"2024-01-01T00:00:00Z"}],"assignees":[],"milestone":null}'
    local fp_base fp_with
    fp_base=$(fingerprint_issue_json "${issue_base}")
    fp_with=$(fingerprint_issue_json "${issue_comment}")
    [ "${fp_base}" != "${fp_with}" ]
}

@test "fingerprint_issue_json changes when plan_approved flips, with no other field changed (#1204)" {
    local issue='{"title":"T","body":"B","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}'
    local fp_unapproved fp_approved
    fp_unapproved=$(fingerprint_issue_json "${issue}" "null" "false")
    fp_approved=$(fingerprint_issue_json "${issue}" "null" "true")
    [ "${fp_unapproved}" != "${fp_approved}" ]
}

@test "fingerprint_issue_json defaults plan_approved to false when the third argument is omitted (#1204)" {
    local issue='{"title":"T","body":"B","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}'
    local fp_omitted fp_explicit_false
    fp_omitted=$(fingerprint_issue_json "${issue}")
    fp_explicit_false=$(fingerprint_issue_json "${issue}" "null" "false")
    [ "${fp_omitted}" = "${fp_explicit_false}" ]
}

@test "fingerprint_issue_json and fingerprint_pr_json prepend FINGERPRINT_SCHEMA_VERSION and a stale version compares unequal (#1204)" {
    local issue='{"title":"T","body":"B","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}'
    local fp_v1 fp_v2
    fp_v1=$(fingerprint_issue_json "${issue}")
    [[ "${fp_v1}" == "${FINGERPRINT_SCHEMA_VERSION}:"* ]]

    FINGERPRINT_SCHEMA_VERSION=$(( FINGERPRINT_SCHEMA_VERSION + 1 ))
    fp_v2=$(fingerprint_issue_json "${issue}")
    [[ "${fp_v2}" == "${FINGERPRINT_SCHEMA_VERSION}:"* ]]
    [ "${fp_v1}" != "${fp_v2}" ]

    local pr='{"title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}'
    local pr_fp
    pr_fp=$(fingerprint_pr_json "${pr}")
    [[ "${pr_fp}" == "${FINGERPRINT_SCHEMA_VERSION}:"* ]]
}

@test "fingerprint_issue_json and fingerprint_pr_json return non-zero (do not hash a partial/empty stream) when jq fails on malformed input (#1102)" {
    run fingerprint_issue_json 'not valid json'
    [ "${status}" -ne 0 ]
    [[ "${output}" != "${FINGERPRINT_SCHEMA_VERSION}:"* ]]

    run fingerprint_pr_json 'not valid json'
    [ "${status}" -ne 0 ]
    [[ "${output}" != "${FINGERPRINT_SCHEMA_VERSION}:"* ]]
}

@test "fingerprint_issue_json happy-path hash is unchanged by the jq-failure-guard refactor (#1102)" {
    local issue='{"title":"T","body":"B","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}'
    local fp
    fp=$(fingerprint_issue_json "${issue}" "null" "false")
    [ "${fp}" = "${FINGERPRINT_SCHEMA_VERSION}:36d5acf9d9297f831145e17ec71ce45fcbd20d60b9af5b25ef6773cacbdc5116" ]
}

@test "fingerprint_pr_json with trusted logins: trusted comment changes fingerprint" {
    local pr_base='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}'
    local pr_trusted='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[{"author":{"login":"owner"},"body":"lgtm","updatedAt":"2024-01-01T00:00:00Z"}],"reviews":[],"statusCheckRollup":[]}'
    local trusted='["owner"]'
    local fp_base fp_trusted
    fp_base=$(fingerprint_pr_json "${pr_base}" "${trusted}")
    fp_trusted=$(fingerprint_pr_json "${pr_trusted}" "${trusted}")
    [ "${fp_base}" != "${fp_trusted}" ]
}

@test "fingerprint_pr_json with trusted logins: untrusted comment does not change fingerprint" {
    local pr_base='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}'
    local pr_untrusted='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[{"author":{"login":"randomer"},"body":"spam","updatedAt":"2024-01-01T00:00:00Z"}],"reviews":[],"statusCheckRollup":[]}'
    local trusted='["owner"]'
    local fp_base fp_untrusted
    fp_base=$(fingerprint_pr_json "${pr_base}" "${trusted}")
    fp_untrusted=$(fingerprint_pr_json "${pr_untrusted}" "${trusted}")
    [ "${fp_base}" = "${fp_untrusted}" ]
}

@test "fingerprint_pr_json with trusted logins: trusted review changes fingerprint" {
    local pr_base='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}'
    local pr_review='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[{"author":{"login":"owner"},"state":"APPROVED","submittedAt":"2024-01-01T00:00:00Z"}],"statusCheckRollup":[]}'
    local trusted='["owner"]'
    local fp_base fp_review
    fp_base=$(fingerprint_pr_json "${pr_base}" "${trusted}")
    fp_review=$(fingerprint_pr_json "${pr_review}" "${trusted}")
    [ "${fp_base}" != "${fp_review}" ]
}

@test "fingerprint_pr_json with trusted logins: untrusted review does not change fingerprint" {
    local pr_base='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}'
    local pr_untrusted_review='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[{"author":{"login":"spammer"},"state":"CHANGES_REQUESTED","submittedAt":"2024-01-01T00:00:00Z"}],"statusCheckRollup":[]}'
    local trusted='["owner"]'
    local fp_base fp_untrusted
    fp_base=$(fingerprint_pr_json "${pr_base}" "${trusted}")
    fp_untrusted=$(fingerprint_pr_json "${pr_untrusted_review}" "${trusted}")
    [ "${fp_base}" = "${fp_untrusted}" ]
}

@test "fingerprint_pr_json without trusted logins uses all comments and reviews" {
    local pr_base='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}'
    local pr_review='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[{"author":{"login":"anyone"},"state":"APPROVED","submittedAt":"2024-01-01T00:00:00Z"}],"statusCheckRollup":[]}'
    local fp_base fp_review
    fp_base=$(fingerprint_pr_json "${pr_base}")
    fp_review=$(fingerprint_pr_json "${pr_review}")
    [ "${fp_base}" != "${fp_review}" ]
}

@test "fingerprint_pr_json changes when reviewDecision flips (#1096)" {
    local pr_a='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[],"reviewDecision":"APPROVED"}'
    local pr_b='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[],"reviewDecision":"REVIEW_REQUIRED"}'
    local fp_a fp_b
    fp_a=$(fingerprint_pr_json "${pr_a}")
    fp_b=$(fingerprint_pr_json "${pr_b}")
    [ "${fp_a}" != "${fp_b}" ]
}

@test "fingerprint_pr_json changes when baseRefName is retargeted (#1096)" {
    local pr_a='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","baseRefName":"main","comments":[],"reviews":[],"statusCheckRollup":[]}'
    local pr_b='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","baseRefName":"develop","comments":[],"reviews":[],"statusCheckRollup":[]}'
    local fp_a fp_b
    fp_a=$(fingerprint_pr_json "${pr_a}")
    fp_b=$(fingerprint_pr_json "${pr_b}")
    [ "${fp_a}" != "${fp_b}" ]
}

@test "fingerprint_pr_json changes when a reviewer is requested or removed (#1096)" {
    local pr_none='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[],"reviewRequests":[]}'
    local pr_requested='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[],"reviewRequests":[{"login":"alice"}]}'
    local fp_none fp_requested
    fp_none=$(fingerprint_pr_json "${pr_none}")
    fp_requested=$(fingerprint_pr_json "${pr_requested}")
    [ "${fp_none}" != "${fp_requested}" ]
}

@test "fingerprint_pr_json includes team review requests by slug (#1096)" {
    local pr_a='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[],"reviewRequests":[{"slug":"team-a"}]}'
    local pr_b='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[],"reviewRequests":[{"slug":"team-b"}]}'
    local fp_a fp_b
    fp_a=$(fingerprint_pr_json "${pr_a}")
    fp_b=$(fingerprint_pr_json "${pr_b}")
    [ "${fp_a}" != "${fp_b}" ]
}

@test "fingerprint_pr_json changes when a PR is assigned (#1096)" {
    local pr_unassigned='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[],"assignees":[]}'
    local pr_assigned='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[],"assignees":[{"login":"bob"}]}'
    local fp_unassigned fp_assigned
    fp_unassigned=$(fingerprint_pr_json "${pr_unassigned}")
    fp_assigned=$(fingerprint_pr_json "${pr_assigned}")
    [ "${fp_unassigned}" != "${fp_assigned}" ]
}

@test "fingerprint_pr_json changes when milestone is set or changed (#1096)" {
    local pr_none='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[],"milestone":null}'
    local pr_v1='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[],"milestone":{"title":"v1"}}'
    local pr_v2='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[],"milestone":{"title":"v2"}}'
    local fp_none fp_v1 fp_v2
    fp_none=$(fingerprint_pr_json "${pr_none}")
    fp_v1=$(fingerprint_pr_json "${pr_v1}")
    fp_v2=$(fingerprint_pr_json "${pr_v2}")
    [ "${fp_none}" != "${fp_v1}" ]
    [ "${fp_v1}" != "${fp_v2}" ]
}

@test "fingerprint_pr_json with trusted logins: trusted comment body edit changes fingerprint even with updatedAt null (#1095)" {
    local pr_base='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[{"author":{"login":"owner"},"body":"original","updatedAt":null}],"reviews":[],"statusCheckRollup":[]}'
    local pr_edited='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[{"author":{"login":"owner"},"body":"edited","updatedAt":null}],"reviews":[],"statusCheckRollup":[]}'
    local trusted='["owner"]'
    local fp_base fp_edited
    fp_base=$(fingerprint_pr_json "${pr_base}" "${trusted}")
    fp_edited=$(fingerprint_pr_json "${pr_edited}" "${trusted}")
    [ "${fp_base}" != "${fp_edited}" ]
}

@test "fingerprint_pr_json with trusted logins: trusted review body edit changes fingerprint with same state/submittedAt (#1095)" {
    local pr_base='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[{"author":{"login":"owner"},"state":"CHANGES_REQUESTED","submittedAt":"2024-01-01T00:00:00Z","body":"terse"}],"statusCheckRollup":[]}'
    local pr_edited='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[{"author":{"login":"owner"},"state":"CHANGES_REQUESTED","submittedAt":"2024-01-01T00:00:00Z","body":"full required-changes list"}],"statusCheckRollup":[]}'
    local trusted='["owner"]'
    local fp_base fp_edited
    fp_base=$(fingerprint_pr_json "${pr_base}" "${trusted}")
    fp_edited=$(fingerprint_pr_json "${pr_edited}" "${trusted}")
    [ "${fp_base}" != "${fp_edited}" ]
}

@test "fingerprint_pr_json with trusted logins: untrusted comment and review body edits do not change fingerprint (#1095)" {
    local pr_base='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[{"author":{"login":"randomer"},"body":"original","updatedAt":null}],"reviews":[{"author":{"login":"randomer"},"state":"COMMENTED","submittedAt":"2024-01-01T00:00:00Z","body":"terse"}],"statusCheckRollup":[]}'
    local pr_edited='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[{"author":{"login":"randomer"},"body":"edited","updatedAt":null}],"reviews":[{"author":{"login":"randomer"},"state":"COMMENTED","submittedAt":"2024-01-01T00:00:00Z","body":"edited too"}],"statusCheckRollup":[]}'
    local trusted='["owner"]'
    local fp_base fp_edited
    fp_base=$(fingerprint_pr_json "${pr_base}" "${trusted}")
    fp_edited=$(fingerprint_pr_json "${pr_edited}" "${trusted}")
    [ "${fp_base}" = "${fp_edited}" ]
}

@test "fingerprint_pr_json is stable across runs for identical JSON regardless of comment/review array order (#1095)" {
    local pr_order_a='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[{"author":{"login":"a"},"body":"first","updatedAt":null},{"author":{"login":"b"},"body":"second","updatedAt":null}],"reviews":[{"author":{"login":"a"},"state":"APPROVED","submittedAt":"2024-01-01T00:00:00Z","body":"lgtm"},{"author":{"login":"b"},"state":"COMMENTED","submittedAt":"2024-01-02T00:00:00Z","body":"nit"}],"statusCheckRollup":[]}'
    local pr_order_b='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[{"author":{"login":"b"},"body":"second","updatedAt":null},{"author":{"login":"a"},"body":"first","updatedAt":null}],"reviews":[{"author":{"login":"b"},"state":"COMMENTED","submittedAt":"2024-01-02T00:00:00Z","body":"nit"},{"author":{"login":"a"},"state":"APPROVED","submittedAt":"2024-01-01T00:00:00Z","body":"lgtm"}],"statusCheckRollup":[]}'
    local fp_a fp_b fp_a_again
    fp_a=$(fingerprint_pr_json "${pr_order_a}")
    fp_b=$(fingerprint_pr_json "${pr_order_b}")
    fp_a_again=$(fingerprint_pr_json "${pr_order_a}")
    [ "${fp_a}" = "${fp_b}" ]
    [ "${fp_a}" = "${fp_a_again}" ]
}

@test "fetch_pr_json requests baseRefName, reviewDecision, reviewRequests, assignees, and milestone fields (#1096)" {
    make_stub gh 'printf "%s" "$*" > "'"${TEST_TMP}"'/gh_args"; printf "{}"'
    fetch_pr_json 42 > /dev/null
    run cat "${TEST_TMP}/gh_args"
    [[ "${output}" == *"baseRefName"* ]]
    [[ "${output}" == *"reviewDecision"* ]]
    [[ "${output}" == *"reviewRequests"* ]]
    [[ "${output}" == *"assignees"* ]]
    [[ "${output}" == *"milestone"* ]]
}

@test "fingerprint_pr_json changes when a new inline review comment appears with no other field changed (#1127)" {
    local pr='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}'
    local rc_none='[]'
    local rc_one='[{"user":{"login":"anyone"},"body":"Why this change?","updated_at":"2024-01-01T00:00:00Z"}]'
    local fp_none fp_one
    fp_none=$(fingerprint_pr_json "${pr}" "null" "${rc_none}")
    fp_one=$(fingerprint_pr_json "${pr}" "null" "${rc_one}")
    [ "${fp_none}" != "${fp_one}" ]
}

@test "fingerprint_pr_json defaults inline review comments to empty when the third argument is omitted (#1127)" {
    local pr='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}'
    local fp_omitted fp_explicit_empty
    fp_omitted=$(fingerprint_pr_json "${pr}")
    fp_explicit_empty=$(fingerprint_pr_json "${pr}" "null" "[]")
    [ "${fp_omitted}" = "${fp_explicit_empty}" ]
}

@test "fingerprint_pr_json with trusted logins: trusted inline review comment changes fingerprint (#1127)" {
    local pr='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}'
    local rc_none='[]'
    local rc_trusted='[{"user":{"login":"owner"},"body":"Why this change?","updated_at":"2024-01-01T00:00:00Z"}]'
    local trusted='["owner"]'
    local fp_none fp_trusted
    fp_none=$(fingerprint_pr_json "${pr}" "${trusted}" "${rc_none}")
    fp_trusted=$(fingerprint_pr_json "${pr}" "${trusted}" "${rc_trusted}")
    [ "${fp_none}" != "${fp_trusted}" ]
}

@test "fingerprint_pr_json with trusted logins: untrusted inline review comment does not change fingerprint (#1127)" {
    local pr='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}'
    local rc_none='[]'
    local rc_untrusted='[{"user":{"login":"randomer"},"body":"spam","updated_at":"2024-01-01T00:00:00Z"}]'
    local trusted='["owner"]'
    local fp_none fp_untrusted
    fp_none=$(fingerprint_pr_json "${pr}" "${trusted}" "${rc_none}")
    fp_untrusted=$(fingerprint_pr_json "${pr}" "${trusted}" "${rc_untrusted}")
    [ "${fp_none}" = "${fp_untrusted}" ]
}

@test "fingerprint_pr_json succeeds when inline review comments exceed 128KiB (#1254)" {
    # Linux caps a single execve argument at MAX_ARG_STRLEN (128KiB), well below the ~2MiB total
    # ARG_MAX. A PR with enough inline review comments serialises past that per-argument ceiling;
    # passing the blob to jq via --argjson (a command-line argument) used to fail with
    # "jq: Argument list too long" once a real PR (credfeto-docker-registry#8) crossed it.
    local pr='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}'
    local big_body
    big_body=$(head -c 200000 /dev/zero | tr '\0' 'a')
    local rc="[{\"user\":{\"login\":\"bob\"},\"updated_at\":\"2024-01-01T00:00:00Z\",\"body\":\"${big_body}\"}]"

    run fingerprint_pr_json "${pr}" "null" "${rc}"
    [ "${status}" -eq 0 ]
    [ -n "${output}" ]
}

# --- fetch_pr_review_comments (#1127) -------------------------------------------

@test "fetch_pr_review_comments requests the pulls/<n>/comments REST endpoint with pagination and slurp (#1127)" {
    make_stub gh 'printf "%s" "$*" > "'"${TEST_TMP}"'/gh_args"; printf "[]"'
    fetch_pr_review_comments 42 > /dev/null
    run cat "${TEST_TMP}/gh_args"
    [[ "${output}" == *"repos/credfeto/credfeto-orchestrator/pulls/42/comments"* ]]
    [[ "${output}" == *"--paginate"* ]]
    [[ "${output}" == *"--slurp"* ]]
}

@test "fetch_pr_review_comments flattens multiple pages into a single flat array of comments (#1127)" {
    # --slurp wraps multi-page gh api --paginate output into one array of page-arrays
    # ([[...page1...],[...page2...]]); without flattening, a PR with enough inline comments
    # to span two pages would produce a nested structure that miscounts/breaks downstream jq.
    make_stub gh 'printf "[[{\"id\":1},{\"id\":2}],[{\"id\":3}]]"'
    run fetch_pr_review_comments 42
    [ "${status}" -eq 0 ]
    [ "${output}" = '[{"id":1},{"id":2},{"id":3}]' ]
}

@test "fetch_pr_review_comments retries and succeeds after a transient gh failure (#1127)" {
    GH_ITEM_FETCH_RETRY_ATTEMPTS=3
    GH_ITEM_FETCH_RETRY_DELAY_SECS=0
    # shellcheck disable=SC2016  # $n/$(...) are intentionally literal — evaluated inside the stub at run time
    make_stub gh 'n=$(cat "'"${TEST_TMP}"'/ghcount" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "'"${TEST_TMP}"'/ghcount"; [ "$n" -lt 2 ] && exit 1; printf "[]\n"'
    run fetch_pr_review_comments 5
    [ "${status}" -eq 0 ]
    [ "${output}" = "[]" ]
}

@test "fetch_pr_review_comments returns 1 without dying after exhausting retries (#1127)" {
    GH_ITEM_FETCH_RETRY_ATTEMPTS=2
    GH_ITEM_FETCH_RETRY_DELAY_SECS=0
    make_stub gh 'exit 1'
    run fetch_pr_review_comments 5
    [ "${status}" -ne 0 ]
}

# --- get_trusted_logins --------------------------------------------------------

@test "get_trusted_logins includes OWNER" {
    set_repo_context "myorg/myrepo"
    WHITELISTED_USERS=""
    make_stub gh 'printf ""'
    local result
    result=$(get_trusted_logins)
    printf '%s' "${result}" | jq -e 'index("myorg") != null' > /dev/null
}

@test "get_trusted_logins includes repo collaborators from GitHub API" {
    set_repo_context "myorg/myrepo"
    WHITELISTED_USERS=""
    make_stub gh 'printf "collab1\ncollab2\n"'
    local result
    result=$(get_trusted_logins)
    printf '%s' "${result}" | jq -e 'index("collab1") != null' > /dev/null
    printf '%s' "${result}" | jq -e 'index("collab2") != null' > /dev/null
}

@test "get_trusted_logins includes copilot-pull-request-reviewer" {
    set_repo_context "myorg/myrepo"
    WHITELISTED_USERS=""
    make_stub gh 'printf ""'
    local result
    result=$(get_trusted_logins)
    printf '%s' "${result}" | jq -e 'index("copilot-pull-request-reviewer") != null' > /dev/null
}

@test "get_trusted_logins includes github-advanced-security[bot]" {
    set_repo_context "myorg/myrepo"
    WHITELISTED_USERS=""
    make_stub gh 'printf ""'
    local result
    result=$(get_trusted_logins)
    printf '%s' "${result}" | jq -e 'index("github-advanced-security[bot]") != null' > /dev/null
}

@test "get_trusted_logins includes whitelisted users from WHITELISTED_USERS" {
    set_repo_context "myorg/myrepo"
    WHITELISTED_USERS="trusted1,trusted2"
    make_stub gh 'printf ""'
    local result
    result=$(get_trusted_logins)
    printf '%s' "${result}" | jq -e 'index("trusted1") != null' > /dev/null
    printf '%s' "${result}" | jq -e 'index("trusted2") != null' > /dev/null
}

@test "get_trusted_logins trims spaces from WHITELISTED_USERS entries" {
    set_repo_context "myorg/myrepo"
    WHITELISTED_USERS=" spaced1 , spaced2 "
    make_stub gh 'printf ""'
    local result
    result=$(get_trusted_logins)
    printf '%s' "${result}" | jq -e 'index("spaced1") != null' > /dev/null
    printf '%s' "${result}" | jq -e 'index("spaced2") != null' > /dev/null
}

@test "get_trusted_logins fails closed (does not fall back to a shrunken list) when GitHub API always fails (#1094)" {
    set_repo_context "myorg/myrepo"
    WHITELISTED_USERS=""
    GH_COLLABORATORS_RETRY_DELAY_SECS=0
    make_stub gh 'exit 1'
    run get_trusted_logins
    [ "${status}" -ne 0 ]
    [ -z "${_TRUSTED_LOGINS_JSON}" ]
}

@test "get_trusted_logins retries GH_COLLABORATORS_RETRY_ATTEMPTS times before giving up (#1094)" {
    set_repo_context "myorg/myrepo"
    WHITELISTED_USERS=""
    GH_COLLABORATORS_RETRY_ATTEMPTS=3
    GH_COLLABORATORS_RETRY_DELAY_SECS=0
    local call_log="${TEST_TMP}/gh_calls"
    make_stub gh "printf 'called\n' >> '${call_log}'; exit 1"
    run get_trusted_logins
    [ "${status}" -ne 0 ]
    [ "$(wc -l < "${call_log}")" -eq 3 ]
}

@test "get_trusted_logins succeeds after a transient failure on an earlier attempt (#1094)" {
    set_repo_context "myorg/myrepo"
    WHITELISTED_USERS=""
    GH_COLLABORATORS_RETRY_DELAY_SECS=0
    local call_log="${TEST_TMP}/gh_calls"
    make_stub gh "printf 'called\n' >> '${call_log}'; if [ \$(wc -l < '${call_log}') -lt 2 ]; then exit 1; fi; printf 'collab1\n'"
    local result
    result=$(get_trusted_logins)
    printf '%s' "${result}" | jq -e 'index("collab1") != null' > /dev/null
}

@test "get_trusted_logins passes --paginate to the collaborators API call (#1094)" {
    set_repo_context "myorg/myrepo"
    WHITELISTED_USERS=""
    export ARGS_LOG="${TEST_TMP}/gh_args"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${ARGS_LOG}"; exit 0'
    get_trusted_logins > /dev/null
    grep -q -- '--paginate' "${ARGS_LOG}"
}

@test "get_trusted_logins does not cache a failed fetch, so the next call retries (#1094)" {
    set_repo_context "myorg/myrepo"
    WHITELISTED_USERS=""
    GH_COLLABORATORS_RETRY_DELAY_SECS=0
    local call_log="${TEST_TMP}/gh_calls"
    make_stub gh "printf 'called\n' >> '${call_log}'; exit 1"
    run get_trusted_logins
    [ "${status}" -ne 0 ]
    local first_calls
    first_calls=$(wc -l < "${call_log}")
    run get_trusted_logins
    [ "${status}" -ne 0 ]
    [ "$(wc -l < "${call_log}")" -gt "${first_calls}" ]
}

@test "get_trusted_logins deduplicates logins when OWNER appears as a collaborator" {
    set_repo_context "myorg/myrepo"
    WHITELISTED_USERS=""
    make_stub gh 'printf "myorg\ncollab1\n"'
    local result
    result=$(get_trusted_logins)
    local count
    count=$(printf '%s' "${result}" | jq '[.[] | select(. == "myorg")] | length')
    [ "${count}" = "1" ]
}

@test "get_trusted_logins caches result so GitHub API is called only once per repo context" {
    set_repo_context "myorg/myrepo"
    WHITELISTED_USERS=""
    local call_log="${TEST_TMP}/gh_calls"
    make_stub gh "printf 'called\n' >> '${call_log}'; printf 'collab1\n'"

    _TRUSTED_LOGINS_JSON=""
    get_trusted_logins > /dev/null
    local first_calls
    first_calls=$(wc -l < "${call_log}" 2>/dev/null || printf '0')

    get_trusted_logins > /dev/null
    local second_calls
    second_calls=$(wc -l < "${call_log}" 2>/dev/null || printf '0')

    [ "${first_calls}" = "${second_calls}" ]
}

@test "compute_issue_fingerprint passes trusted logins from get_trusted_logins to fingerprint_issue_json" {
    local captured_trusted="none"
    fetch_issue_json() { printf '{"title":"T","body":"B","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    get_trusted_logins() { printf '["testowner"]\n'; }
    fingerprint_issue_json() { captured_trusted="${2:-missing}"; printf 'test-fp\n'; }
    compute_issue_fingerprint 42
    [ "${captured_trusted}" = '["testowner"]' ]
}

@test "compute_pr_fingerprint passes trusted logins from get_trusted_logins to fingerprint_pr_json" {
    local captured_trusted="none"
    fetch_pr_json() { printf '{"title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}\n'; }
    get_trusted_logins() { printf '["testowner"]\n'; }
    fetch_pr_review_comments() { printf '[]\n'; }
    fingerprint_pr_json() { captured_trusted="${2:-missing}"; printf 'test-fp\n'; }
    compute_pr_fingerprint 5
    [ "${captured_trusted}" = '["testowner"]' ]
}

@test "compute_pr_fingerprint passes inline review comments from fetch_pr_review_comments to fingerprint_pr_json (#1127)" {
    local captured_review_comments="none"
    fetch_pr_json() { printf '{"title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}\n'; }
    get_trusted_logins() { printf '["testowner"]\n'; }
    fetch_pr_review_comments() { printf '[{"user":{"login":"testowner"},"body":"Why this change?","updated_at":"2024-01-01T00:00:00Z"}]\n'; }
    fingerprint_pr_json() { captured_review_comments="${3:-missing}"; printf 'test-fp\n'; }
    compute_pr_fingerprint 5
    printf '%s' "${captured_review_comments}" | jq -e '.[0].body == "Why this change?"' > /dev/null
}

@test "compute_pr_fingerprint returns non-zero without calling fingerprint_pr_json when fetch_pr_review_comments fails (#1127)" {
    fetch_pr_json() { printf '{"title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}\n'; }
    get_trusted_logins() { printf '["testowner"]\n'; }
    fetch_pr_review_comments() { return 1; }
    fingerprint_pr_json() { printf 'called\n' >> "${TEST_TMP}/fp_called"; printf 'test-fp\n'; }
    run compute_pr_fingerprint 5
    [ "${status}" -ne 0 ]
    [ ! -f "${TEST_TMP}/fp_called" ]
}

@test "compute_issue_fingerprint passes the item's board plan-approval status to fingerprint_issue_json (#1204)" {
    local captured_plan_approved="none"
    _WF_PROJECT_ID="PVT_test"
    REPO_FULL="owner/repo"
    fetch_issue_json() { printf '{"title":"T","body":"B","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    get_trusted_logins() { printf '["testowner"]\n'; }
    fetch_board_approved_items() { _WF_APPROVED_ITEMS["owner/repo/42"]=1; }
    fingerprint_issue_json() { captured_plan_approved="${3:-missing}"; printf 'test-fp\n'; }
    compute_issue_fingerprint 42
    [ "${captured_plan_approved}" = "true" ]
}

@test "compute_issue_fingerprint passes plan_approved=false when the item is not in _WF_APPROVED_ITEMS (#1204)" {
    local captured_plan_approved="none"
    _WF_PROJECT_ID="PVT_test"
    REPO_FULL="owner/repo"
    fetch_issue_json() { printf '{"title":"T","body":"B","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    get_trusted_logins() { printf '["testowner"]\n'; }
    fetch_board_approved_items() { return 0; }
    fingerprint_issue_json() { captured_plan_approved="${3:-missing}"; printf 'test-fp\n'; }
    compute_issue_fingerprint 42
    [ "${captured_plan_approved}" = "false" ]
}

@test "compute_issue_fingerprint returns non-zero without calling fingerprint_issue_json when get_trusted_logins fails (#1094)" {
    fetch_issue_json() { printf '{"title":"T","body":"B","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    get_trusted_logins() { return 1; }
    fingerprint_issue_json() { printf 'called\n' >> "${TEST_TMP}/fp_called"; printf 'test-fp\n'; }
    run compute_issue_fingerprint 42
    [ "${status}" -ne 0 ]
    [ ! -f "${TEST_TMP}/fp_called" ]
}

@test "compute_pr_fingerprint returns non-zero without calling fingerprint_pr_json when get_trusted_logins fails (#1094)" {
    fetch_pr_json() { printf '{"title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}\n'; }
    get_trusted_logins() { return 1; }
    fingerprint_pr_json() { printf 'called\n' >> "${TEST_TMP}/fp_called"; printf 'test-fp\n'; }
    run compute_pr_fingerprint 5
    [ "${status}" -ne 0 ]
    [ ! -f "${TEST_TMP}/fp_called" ]
}

# --- model selection -----------------------------------------------------------

@test "invoke_claude passes --model opusplan to podman claude command for a new session" {
    local args_log="${TEST_TMP}/podman_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
[ "\$1" = "pull" ] && exit 0
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    invoke_claude "test prompt" "" "" "# mock CLAUDE.md" 2>/dev/null
    grep -qx -- '--model' "${args_log}"
    grep -qx 'opusplan' "${args_log}"
}

@test "invoke_claude passes the prompt as a trailing positional argument to claude, not via stdin (#1062)" {
    local args_log="${TEST_TMP}/podman_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
[ "\$1" = "pull" ] && exit 0
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    invoke_claude "unique-prompt-marker-xyz" "" "" "# mock CLAUDE.md" 2>/dev/null
    # The prompt text must appear as its own argv element (the CLAUDE_PROMPT
    # trailing entry in PODMAN_CLAUDE_ARGS), not be piped in via stdin.
    grep -qx -- 'unique-prompt-marker-xyz' "${args_log}"
}

@test "invoke_claude terminates option parsing with -- immediately before the prompt so --add-dir cannot swallow it (#1062 recurrence)" {
    local args_log="${TEST_TMP}/podman_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
[ "\$1" = "pull" ] && exit 0
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    invoke_claude "unique-prompt-marker-xyz" "" "" "# mock CLAUDE.md" 2>/dev/null
    # --add-dir takes <directories...> (variadic) — without a "--" separator right
    # before the prompt, the CLI parser swallows the prompt as an extra --add-dir
    # value instead of the positional [prompt] argument. Assert "--" is the line
    # immediately preceding the prompt marker in the logged argv.
    local prompt_line
    prompt_line=$(grep -nx -- 'unique-prompt-marker-xyz' "${args_log}" | cut -d: -f1)
    [ -n "${prompt_line}" ]
    local separator_line=$((prompt_line - 1))
    [ "$(sed -n "${separator_line}p" "${args_log}")" = "--" ]
}

@test "invoke_claude registers CONTAINER_REPO_PATH, CONTAINER_RULES_PATH, and CONTAINER_SCRATCH_PATH as --add-dir args in that order (#1351, #1377)" {
    local args_log="${TEST_TMP}/podman_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    invoke_claude "unique-prompt-marker-xyz" "" "" "# mock CLAUDE.md" 2>/dev/null
    local add_dir_line
    add_dir_line=$(grep -nx -- '--add-dir' "${args_log}" | cut -d: -f1)
    [ -n "${add_dir_line}" ]
    [ "$(sed -n "$((add_dir_line + 1))p" "${args_log}")" = "${CONTAINER_REPO_PATH}" ]
    [ "$(sed -n "$((add_dir_line + 2))p" "${args_log}")" = "${CONTAINER_RULES_PATH}" ]
    [ "$(sed -n "$((add_dir_line + 3))p" "${args_log}")" = "${CONTAINER_SCRATCH_PATH}" ]
}

@test "invoke_claude bind-mounts a fresh host scratch dir at CONTAINER_SCRATCH_PATH read-write (#1351)" {
    local args_log="${TEST_TMP}/podman_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    invoke_claude "unique-prompt-marker-xyz" "" "" "# mock CLAUDE.md" 2>/dev/null
    grep -qE -- ":${CONTAINER_SCRATCH_PATH}:rw\$" "${args_log}"
}

@test "invoke_claude removes the host scratch dir on successful completion, leaving no orphan (#1351)" {
    local args_log="${TEST_TMP}/podman_args"
    local scratch_dir_log="${TEST_TMP}/scratch_dir_seen"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    invoke_claude "unique-prompt-marker-xyz" "" "" "# mock CLAUDE.md" 2>/dev/null
    # The --volume argv element is HOST:CONTAINER:rw as a single token; strip the
    # container-side suffix to recover the host-side scratch dir invoke_claude created.
    local scratch_dir
    scratch_dir=$(grep -E -- ":${CONTAINER_SCRATCH_PATH}:rw\$" "${args_log}" | sed -E "s#:${CONTAINER_SCRATCH_PATH}:rw\$##")
    # invoke_claude resets CLAUDE_SCRATCH_TMPDIR to "" on its own cleanup path once removed —
    # the directory it captured in argv above must no longer exist on disk.
    [ -n "${scratch_dir}" ]
    [ ! -d "${scratch_dir}" ]
    [ -z "${CLAUDE_SCRATCH_TMPDIR}" ]
}

@test "invoke_claude passes resource limit flags to podman run" {
    local args_log="${TEST_TMP}/podman_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"
    # Stub jq to return canned values matching the podman stub's JSON output.
    # Needed in environments where jq is not installed.
    cat > "${STUB_BIN}/jq" << 'JQSTUB'
#!/usr/bin/env bash
# Minimal stub: reads the last argument (file path) and returns canned values
# for the specific queries invoke_claude makes in the happy path.
case "$*" in
    *".is_error"*)   printf 'false\n' ;;
    *".result"*)     printf 'done\n' ;;
    *".session_id"*) printf '12345678-1234-1234-1234-123456789abc\n' ;;
    *)               printf '\n' ;;
esac
JQSTUB
    chmod +x "${STUB_BIN}/jq"

    invoke_claude "test prompt" "" "" "# mock CLAUDE.md" 2>/dev/null
    [ -f "${args_log}" ]
    grep -qFx -- '--cpus=4' "${args_log}"
    grep -qFx -- '--memory=12g' "${args_log}"
    grep -qFx -- '--memory-swap=12g' "${args_log}"
    grep -qFx -- '--pids-limit=4096' "${args_log}"
    grep -qFx -- '--userns=keep-id:uid=1000,gid=1000' "${args_log}"
}

# --- invoke_claude error handling ---------------------------------------------

@test "invoke_claude fails fast before calling podman when prompt exceeds MAX_PROMPT_CHARS" {
    local args_log="${TEST_TMP}/podman_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
[ "\$1" = "pull" ] && exit 0
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    DISCORD_WEBHOOK_URL=""
    local long_prompt
    long_prompt=$(printf '%*s' $((MAX_PROMPT_CHARS + 1)) '' | tr ' ' 'x')
    run invoke_claude "${long_prompt}" "Issue" "1"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"too long"* ]]
    [ ! -f "${args_log}" ]
}

@test "invoke_claude sends Discord notification when prompt exceeds MAX_PROMPT_CHARS" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "pull" ] && exit 0
[ "$1" = "inspect" ] && exit 1
[ "$1" = "pull" ] && exit 0
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"

    local long_prompt
    long_prompt=$(printf '%*s' $((MAX_PROMPT_CHARS + 1)) '' | tr ' ' 'x')
    run invoke_claude "${long_prompt}" "Issue" "42"
    [ "${status}" -ne 0 ]
    grep -q "https://discord.example.com/hook" "${args_log}"
}

@test "invoke_claude dies and sends Discord notification when Claude returns is_error true" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "pull" ] && exit 0
[ "$1" = "inspect" ] && exit 1
[ "$1" = "pull" ] && exit 0
printf '{"is_error":true,"terminal_reason":"api_error","session_id":"12345678-1234-1234-1234-123456789abc","result":"API Error"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"API Error"* ]]
    grep -q "https://discord.example.com/hook" "${args_log}"
}

@test "invoke_claude dies with Discord notification on blocking_limit for a new session" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "pull" ] && exit 0
[ "$1" = "inspect" ] && exit 1
[ "$1" = "pull" ] && exit 0
printf '{"is_error":true,"terminal_reason":"blocking_limit","session_id":"12345678-1234-1234-1234-123456789abc","result":"Prompt is too long"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -ne 0 ]
    grep -q "https://discord.example.com/hook" "${args_log}"
}

@test "invoke_claude dies with a timeout message when the container exceeds AGENT_TIMEOUT_MINUTES" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "pull" ] && exit 0
[ "$1" = "inspect" ] && exit 1
[ "$1" = "rm" ] && exit 0
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/podman"
    make_stub timeout 'exit 124'

    DISCORD_WEBHOOK_URL=""
    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"timed out"* ]]
}

@test "invoke_claude sends Discord notification when the container times out" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "pull" ] && exit 0
[ "$1" = "inspect" ] && exit 1
[ "$1" = "rm" ] && exit 0
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/podman"
    make_stub timeout 'exit 124'

    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -ne 0 ]
    grep -q "https://discord.example.com/hook" "${args_log}"
}

# --- notify_discord_claude_error -----------------------------------------------

@test "notify_discord_claude_error does not call curl when DISCORD_WEBHOOK_URL is empty" {
    DISCORD_WEBHOOK_URL=""
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_claude_error "Issue" "42" "Prompt is too long"
    [ "${status}" -eq 0 ]
    [ ! -f "${args_log}" ]
}

@test "notify_discord_claude_error calls curl with embed payload including issue URL and error message" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_claude_error "Issue" "42" "Prompt is too long"
    [ "${status}" -eq 0 ]
    grep -q "https://discord.example.com/hook" "${args_log}"
    grep -q "https://github.com/org/repo/issues/42" "${args_log}"
    grep -q "Prompt is too long" "${args_log}"
}

@test "notify_discord_claude_error calls curl with embed payload including PR URL" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_claude_error "PullRequest" "7" "API Error"
    [ "${status}" -eq 0 ]
    grep -q "https://github.com/org/repo/pull/7" "${args_log}"
    grep -q "API Error" "${args_log}"
}

@test "notify_discord_claude_error uses repo URL when item type is unknown" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_claude_error "" "" "Some error"
    [ "${status}" -eq 0 ]
    grep -q "https://github.com/org/repo" "${args_log}"
}

# --- notify_discord_permission_denials (#1328) ----------------------------------

@test "notify_discord_permission_denials does not call curl when DISCORD_WEBHOOK_URL is empty" {
    DISCORD_WEBHOOK_URL=""
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_permission_denials "Issue" "42" "- Bash: git status"
    [ "${status}" -eq 0 ]
    [ ! -f "${args_log}" ]
}

@test "notify_discord_permission_denials calls curl with embed payload including issue URL, count, and summary" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_permission_denials "Issue" "42" "- Bash: git status" "1"
    [ "${status}" -eq 0 ]
    grep -q "https://discord.example.com/hook" "${args_log}"
    grep -q "https://github.com/org/repo/issues/42" "${args_log}"
    grep -q "Bash: git status" "${args_log}"
    grep -q "Permission Denials (1)" "${args_log}"
}

@test "notify_discord_permission_denials appends a truncation marker when the summary exceeds the field limit" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    local long_summary
    long_summary=$(printf -- '- Bash: git status %.0s' $(seq 1 100))
    run notify_discord_permission_denials "Issue" "42" "${long_summary}" "100"
    [ "${status}" -eq 0 ]
    grep -q "truncated; see the run log for the full list" "${args_log}"
    grep -q "Permission Denials (100)" "${args_log}"
}

@test "notify_discord_permission_denials does not append a truncation marker for a short summary" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_permission_denials "Issue" "42" "- Bash: git status" "1"
    [ "${status}" -eq 0 ]
    [ "$(grep -c "truncated; see the run log" "${args_log}")" -eq 0 ]
}

@test "notify_discord_permission_denials uses repo URL when item type is unknown" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_permission_denials "" "" "- Bash: git status" "1"
    [ "${status}" -eq 0 ]
    grep -q "https://github.com/org/repo" "${args_log}"
}

@test "invoke_claude uses container name orchestrator-OWNER" {
    local args_log="${TEST_TMP}/podman_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
[ "\$1" = "pull" ] && exit 0
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    invoke_claude "test prompt" "" "" "# mock CLAUDE.md" 2>/dev/null
    grep -qx 'orchestrator-credfeto' "${args_log}"
}

@test "invoke_claude mounts REPO_WORK_DIR read-write and RULES_DIR read-only" {
    local args_log="${TEST_TMP}/podman_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
[ "\$1" = "pull" ] && exit 0
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    invoke_claude "test prompt" "" "" "# mock CLAUDE.md" 2>/dev/null
    grep -qx "${REPO_WORK_DIR}:${CONTAINER_REPO_PATH}:rw" "${args_log}"
    grep -qx "${RULES_DIR}:${CONTAINER_RULES_PATH}:ro" "${args_log}"
}

@test "invoke_claude mounts CLAUDE.md read-only as a single file when claude_md_content is provided" {
    local args_log="${TEST_TMP}/podman_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/jq" << 'JQEOF'
#!/usr/bin/env bash
case "$2" in
    '.is_error // false')    printf 'false\n' ;;
    '.result // ""')         printf '\n' ;;
    '.session_id // empty')  printf '12345678-1234-1234-1234-123456789abc\n' ;;
esac
JQEOF
    chmod +x "${STUB_BIN}/jq"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
[ "\$1" = "pull" ] && exit 0
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    invoke_claude "test prompt" "" "" "# per-item instructions" 2>/dev/null
    grep -q ':/home/developer/.claude/CLAUDE.md:ro' "${args_log}"
}

@test "invoke_claude mounts the five persistent Claude state subdirectories read-write" {
    local args_log="${TEST_TMP}/podman_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/jq" << 'JQEOF'
#!/usr/bin/env bash
case "$2" in
    '.is_error // false')    printf 'false\n' ;;
    '.result // ""')         printf '\n' ;;
    '.session_id // empty')  printf '12345678-1234-1234-1234-123456789abc\n' ;;
esac
JQEOF
    chmod +x "${STUB_BIN}/jq"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
[ "\$1" = "pull" ] && exit 0
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    invoke_claude "test prompt" "" "" "# per-item instructions" 2>/dev/null
    for d in sessions session-env plans cache backups; do
        grep -qx "${CLAUDE_STATE_DIR}/${d}:/home/developer/.claude/${d}:rw" "${args_log}"
        [ -d "${CLAUDE_STATE_DIR}/${d}" ]
    done
}

@test "invoke_claude mounts the persistent orchestrator cache global directory read-write (#1380)" {
    local args_log="${TEST_TMP}/podman_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/jq" << 'JQEOF'
#!/usr/bin/env bash
case "$2" in
    '.is_error // false')    printf 'false\n' ;;
    '.result // ""')         printf '\n' ;;
    '.session_id // empty')  printf '12345678-1234-1234-1234-123456789abc\n' ;;
esac
JQEOF
    chmod +x "${STUB_BIN}/jq"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
[ "\$1" = "pull" ] && exit 0
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    invoke_claude "test prompt" "" "" "# per-item instructions" 2>/dev/null
    grep -qx "${ORCHESTRATOR_CACHE_DIR}/global:/home/developer/.cache/orchestrator/global:rw" "${args_log}"
    [ -d "${ORCHESTRATOR_CACHE_DIR}/global" ]
    # Only "global" is mounted - "local" is created by entrypoint.sh itself and stays
    # container-ephemeral, so invoke_claude must not create or mount it.
    [ ! -e "${ORCHESTRATOR_CACHE_DIR}/local" ]
    [ "$(grep -c "${ORCHESTRATOR_CACHE_DIR}/local:" "${args_log}")" -eq 0 ]
}

@test "invoke_claude dies when claude_md_content is empty" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "inspect" ] && exit 1
[ "$1" = "pull" ] && exit 0
[ "$1" = "pull" ] && exit 0
STUBEOF
    chmod +x "${STUB_BIN}/podman"
    run invoke_claude "test prompt" "" "" ""
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"claude_md_content is required"* ]]
}

@test "invoke_claude notifies Discord before dying when claude_md_content is empty (#1103)" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "inspect" ] && exit 1
[ "$1" = "pull" ] && exit 0
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    local notify_log="${TEST_TMP}/notify.log"
    notify_discord_claude_error() { printf '%s\n' "$*" >> "${notify_log}"; }

    run invoke_claude "test prompt" "Issue" "42" ""
    [ "${status}" -ne 0 ]
    grep -q "claude_md_content is required" "${notify_log}"
}

@test "invoke_claude surfaces permission_denials via Discord even when the run also errors (#1328)" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "inspect" ] && exit 1
[ "$1" = "pull" ] && exit 0
printf '{"is_error":true,"api_error_status":"500","result":"internal error","permission_denials":[{"tool_name":"Bash","tool_input":{"command":"git status"}}]}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    notify_discord_claude_error() { return 0; }
    local notify_log="${TEST_TMP}/denial_notify.log"
    notify_discord_permission_denials() { printf '%s\n' "$*" >> "${notify_log}"; }

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    # Overall run still fails: handle_claude_is_error always dies - but the denial must have
    # been surfaced before tmpfile was deleted on that path (#1328).
    [ "${status}" -ne 0 ]
    grep -q "git status" "${notify_log}"
}

@test "invoke_claude surfaces permission_denials via Discord on a successful run (#1328)" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "inspect" ] && exit 1
[ "$1" = "pull" ] && exit 0
printf '{"is_error":false,"result":"done","permission_denials":[{"tool_name":"Bash","tool_input":{"command":"git status"}}]}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    local notify_log="${TEST_TMP}/denial_notify.log"
    notify_discord_permission_denials() { printf '%s\n' "$*" >> "${notify_log}"; }

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -eq 0 ]
    grep -q "git status" "${notify_log}"
}

@test "invoke_claude does not call notify_discord_permission_denials when permission_denials is absent (#1328)" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "inspect" ] && exit 1
[ "$1" = "pull" ] && exit 0
printf '{"is_error":false,"result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    local notify_log="${TEST_TMP}/denial_notify.log"
    notify_discord_permission_denials() { printf '%s\n' "$*" >> "${notify_log}"; }

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -eq 0 ]
    [ ! -f "${notify_log}" ]
}

# --- cleanup_claude_invocation_tmpfiles (#1133 review, Copilot) ----------------

@test "cleanup_claude_invocation_tmpfiles is safe to call twice in a row" {
    # Mirrors the real EXIT-trap backstop calling it again after the explicit call on every
    # normal path already cleared these globals to empty — must not error the second time.
    local tmpfile gpgdir
    tmpfile=$(mktemp)
    gpgdir=$(mktemp -d)
    CLAUDE_MD_TMPFILE="${tmpfile}"
    GPG_PUBKEY_TMPDIR="${gpgdir}"

    cleanup_claude_invocation_tmpfiles
    [ -z "${CLAUDE_MD_TMPFILE}" ]
    [ -z "${GPG_PUBKEY_TMPDIR}" ]
    [ ! -e "${tmpfile}" ]
    [ ! -e "${gpgdir}" ]

    run cleanup_claude_invocation_tmpfiles
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "invoke_claude does not leak CLAUDE_MD_TMPFILE when the state-dir mkdir loop fails (#1103)" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    export XDG_RUNTIME_DIR="${TEST_TMP}/runtime"
    mkdir -p "${XDG_RUNTIME_DIR}"
    local claude_md_path="${XDG_RUNTIME_DIR}/fixed.claude-md"
    cat > "${STUB_BIN}/mktemp" << STUBEOF
#!/usr/bin/env bash
touch "${claude_md_path}"
printf '%s\n' "${claude_md_path}"
STUBEOF
    chmod +x "${STUB_BIN}/mktemp"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "inspect" ] && exit 1
[ "$1" = "pull" ] && exit 0
STUBEOF
    chmod +x "${STUB_BIN}/podman"
    # A FILE (not a directory) at the first state-dir path forces "mkdir -p" to fail there,
    # between CLAUDE_MD_TMPFILE being populated and the container ever starting.
    mkdir -p "${CLAUDE_STATE_DIR}"
    touch "${CLAUDE_STATE_DIR}/sessions"

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Failed to create persistent Claude state directory"* ]]
    [ ! -e "${claude_md_path}" ]
}

@test "invoke_claude cleans up CLAUDE_MD_TMPFILE after successful invocation" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/jq" << 'JQEOF'
#!/usr/bin/env bash
case "$2" in
    '.is_error // false')    printf 'false\n' ;;
    '.result // ""')         printf '\n' ;;
    '.session_id // empty')  printf '12345678-1234-1234-1234-123456789abc\n' ;;
esac
JQEOF
    chmod +x "${STUB_BIN}/jq"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "pull" ] && exit 0
[ "$1" = "inspect" ] && exit 1
[ "$1" = "pull" ] && exit 0
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    CLAUDE_MD_TMPFILE="sentinel"
    invoke_claude "test prompt" "" "" "# per-item instructions" 2>/dev/null
    [ -z "${CLAUDE_MD_TMPFILE}" ]
}

@test "invoke_claude marks the background-stall marker when the session result matches the pattern (#1326/#1335)" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/jq" << 'JQEOF'
#!/usr/bin/env bash
case "$2" in
    '.is_error // false')    printf 'false\n' ;;
    '.result // ""')         printf "I'll pause here and wait for the Monitor notification when it completes.\n" ;;
    '.session_id // empty')  printf '12345678-1234-1234-1234-123456789abc\n' ;;
esac
JQEOF
    chmod +x "${STUB_BIN}/jq"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "pull" ] && exit 0
[ "$1" = "inspect" ] && exit 1
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"..."}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    invoke_claude "test prompt" "Issue" "215" "# per-item instructions" 2>/dev/null
    [ -f "${SESSION_BASE_DIR}/Issue_215.background-stall" ]
}

@test "invoke_claude clears the background-stall marker when the session result does not match the pattern" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}" "${SESSION_BASE_DIR}"
    touch "${SESSION_BASE_DIR}/Issue_215.background-stall"
    cat > "${STUB_BIN}/jq" << 'JQEOF'
#!/usr/bin/env bash
case "$2" in
    '.is_error // false')    printf 'false\n' ;;
    '.result // ""')         printf 'Opened draft PR #284 and moved the board to Development.\n' ;;
    '.session_id // empty')  printf '12345678-1234-1234-1234-123456789abc\n' ;;
esac
JQEOF
    chmod +x "${STUB_BIN}/jq"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "pull" ] && exit 0
[ "$1" = "inspect" ] && exit 1
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"..."}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    invoke_claude "test prompt" "Issue" "215" "# per-item instructions" 2>/dev/null
    [ ! -f "${SESSION_BASE_DIR}/Issue_215.background-stall" ]
}

@test "invoke_claude creates CLAUDE_MD_TMPFILE as a regular file (not a directory) from XDG_RUNTIME_DIR when set" {
    local args_log="${TEST_TMP}/podman_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    export XDG_RUNTIME_DIR="${TEST_TMP}/runtime"
    mkdir -p "${XDG_RUNTIME_DIR}"
    cat > "${STUB_BIN}/jq" << 'JQEOF'
#!/usr/bin/env bash
case "$2" in
    '.is_error // false')    printf 'false\n' ;;
    '.result // ""')         printf '\n' ;;
    '.session_id // empty')  printf '12345678-1234-1234-1234-123456789abc\n' ;;
esac
JQEOF
    chmod +x "${STUB_BIN}/jq"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "${args_log}"
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"
    invoke_claude "test prompt" "" "" "# per-item instructions" 2>/dev/null
    grep -q "${XDG_RUNTIME_DIR}" "${args_log}"
}

@test "invoke_claude creates Podman secret and uses --secret for owner token instead of --env" {
    local args_log="${TEST_TMP}/podman_args"
    local secret_log="${TEST_TMP}/podman_secret"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator/tokens"
    printf 'my-claude-token\n' > "${XDG_CONFIG_HOME}/orchestrator/tokens/credfeto"
    chmod 600 "${XDG_CONFIG_HOME}/orchestrator/tokens/credfeto"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
if [ "\$1" = "secret" ]; then
    printf "%s\n" "\$@" >> "${secret_log}"
    exit 0
fi
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    invoke_claude "test prompt" "" "" "# mock CLAUDE.md" 2>/dev/null
    # Secret was created with the owner-scoped name
    grep -q "create" "${secret_log}"
    grep -q "claude-oauth-credfeto" "${secret_log}"
    # Token is NOT passed via --env
    run grep -q 'CLAUDE_CODE_OAUTH_TOKEN=' "${args_log}"
    [ "${status}" -ne 0 ]
    # --secret flag IS present in the podman run args
    grep -q 'claude-oauth-credfeto' "${args_log}"
}

@test "invoke_claude notifies Discord before dying when creating the Claude OAuth Podman secret fails (#1103)" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator/tokens"
    printf 'my-claude-token\n' > "${XDG_CONFIG_HOME}/orchestrator/tokens/credfeto"
    chmod 600 "${XDG_CONFIG_HOME}/orchestrator/tokens/credfeto"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "secret" ] && [ "$2" = "create" ] && exit 1
[ "$1" = "secret" ] && exit 0
[ "$1" = "pull" ] && exit 0
[ "$1" = "inspect" ] && exit 1
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    local notify_log="${TEST_TMP}/notify.log"
    notify_discord_claude_error() { printf '%s\n' "$*" >> "${notify_log}"; }

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Failed to create Podman secret for Claude OAuth token"* ]]
    grep -q "Failed to create Podman secret for Claude OAuth token" "${notify_log}"
}

@test "invoke_claude passes GH_ENTERPRISE_TOKEN via Podman secret instead of --env" {
    local args_log="${TEST_TMP}/podman_args"
    local secret_log="${TEST_TMP}/podman_secret"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    # shellcheck disable=SC2030
    GH_ENTERPRISE_TOKEN="my-gh-token"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
if [ "\$1" = "secret" ]; then
    printf "%s\n" "\$@" >> "${secret_log}"
    exit 0
fi
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    invoke_claude "test prompt" "" "" "# mock CLAUDE.md" 2>/dev/null
    # Secret was created with the enterprise token secret name
    grep -q "create" "${secret_log}"
    grep -q "gh-enterprise-token" "${secret_log}"
    # Token is NOT passed via --env
    run grep -q 'GH_ENTERPRISE_TOKEN=my-gh-token' "${args_log}"
    [ "${status}" -ne 0 ]
    # --secret flag IS present in the podman run args
    grep -q 'gh-enterprise-token' "${args_log}"
}

@test "invoke_claude notifies Discord before dying when creating the GH_ENTERPRISE_TOKEN Podman secret fails (#1103)" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    # shellcheck disable=SC2030
    GH_ENTERPRISE_TOKEN="my-gh-token"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "secret" ] && [ "$2" = "create" ] && exit 1
[ "$1" = "secret" ] && exit 0
[ "$1" = "pull" ] && exit 0
[ "$1" = "inspect" ] && exit 1
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    local notify_log="${TEST_TMP}/notify.log"
    notify_discord_claude_error() { printf '%s\n' "$*" >> "${notify_log}"; }

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Failed to create Podman secret for GH_ENTERPRISE_TOKEN"* ]]
    grep -q "Failed to create Podman secret for GH_ENTERPRISE_TOKEN" "${notify_log}"
}

@test "invoke_claude never passes --resume (every run is a fresh session)" {
    local args_log="${TEST_TMP}/podman_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
[ "\$1" = "pull" ] && exit 0
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md" 2>/dev/null
    run grep -qx -- '--resume' "${args_log}"
    [ "${status}" -ne 0 ]
}

@test "invoke_claude dies if container already exists and is running" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "inspect" ] && [ "$2" = "--format" ] && { printf 'true\n'; exit 0; }
[ "$1" = "inspect" ] && exit 0
[ "$1" = "pull" ] && exit 0
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"already exists and is running"* ]]
}

@test "invoke_claude notifies Discord before dying when container already exists and is running (#1103)" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "inspect" ] && [ "$2" = "--format" ] && { printf 'true\n'; exit 0; }
[ "$1" = "inspect" ] && exit 0
[ "$1" = "pull" ] && exit 0
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    local notify_log="${TEST_TMP}/notify.log"
    notify_discord_claude_error() { printf '%s\n' "$*" >> "${notify_log}"; }

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -ne 0 ]
    grep -q "already exists and is running" "${notify_log}"
}

@test "invoke_claude notifies Discord before dying when a leftover container cannot be removed (#1103)" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "inspect" ] && [ "$2" = "--format" ] && { printf 'false\n'; exit 0; }
[ "$1" = "inspect" ] && exit 0
[ "$1" = "rm" ] && exit 1
[ "$1" = "pull" ] && exit 0
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    local notify_log="${TEST_TMP}/notify.log"
    notify_discord_claude_error() { printf '%s\n' "$*" >> "${notify_log}"; }

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Failed to remove leftover container"* ]]
    grep -q "Failed to remove leftover container" "${notify_log}"
}

@test "invoke_claude removes a leftover non-running container and proceeds (#1090)" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    local args_log="${TEST_TMP}/podman_args"
    # shellcheck disable=SC2016
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
printf "%s\n" "\$*" >> "${args_log}"
[ "\$1" = "inspect" ] && [ "\$2" = "--format" ] && { printf 'false\n'; exit 0; }
[ "\$1" = "inspect" ] && exit 0
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "rm" ] && exit 0
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -eq 0 ]
    grep -qx -- "rm -f orchestrator-credfeto" "${args_log}"
}

@test "invoke_claude returns 2 (not a hard die) when podman run fails due to container name in use (#1361)" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "pull" ] && exit 0
[ "$1" = "inspect" ] && exit 1
[ "$1" = "pull" ] && exit 0
printf 'Error: container name "orchestrator-credfeto" is already in use by container abc123def456\n' >&2
exit 1
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    local notify_log="${TEST_TMP}/notify.log"
    notify_discord_claude_error() { printf '%s\n' "$*" >> "${notify_log}"; }

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    # Must be 2, not just any non-zero: main()'s MAX_CONSECUTIVE_INFRA_FAILURES escalation
    # (#1133) only ever triggers on exactly 2. This branch used to die, which bypassed that
    # escalation entirely and let a wedged container retry ~3,000 times unreported (#1361).
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"already in use"* ]]
    # Must NOT notify from here: returning 2 lets main() continue to the next item, so a
    # host-scoped fault would post one Discord message per item per 30s tick. Alerting for this
    # class belongs to the unit-level OnFailure= handler, which fires once per failed tick.
    [ ! -f "${notify_log}" ]
}


@test "invoke_claude passes --replace to podman run so a stale container name cannot wedge it (#1361)" {
    local args_log="${TEST_TMP}/podman_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
printf "%s\n" "\$@" >> "${args_log}"
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    invoke_claude "test prompt" "" "" "# mock CLAUDE.md" 2>/dev/null
    grep -qx -- '--replace' "${args_log}"
}

@test "invoke_claude still refuses to clobber a genuinely running container despite --replace (#1361)" {
    local args_log="${TEST_TMP}/podman_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
printf "%s\n" "\$*" >> "${args_log}"
[ "\$1" = "inspect" ] && [ "\$2" = "--format" ] && { printf 'true\n'; exit 0; }
[ "\$1" = "inspect" ] && exit 0
[ "\$1" = "pull" ] && exit 0
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    # --replace would happily destroy another invocation's in-flight work; the pre-flight guard
    # is what prevents that, so it must still fire before podman run is ever reached.
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"already exists and is running"* ]]
    [ "$(grep -c -- '--replace' "${args_log}")" -eq 0 ]
}

# --- pre-flight/infra container failure (#1133) --------------------------------

@test "invoke_claude returns 2 when the container fails before Claude produces any result" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "pull" ] && exit 0
[ "$1" = "inspect" ] && exit 1
if [ "$1" = "run" ]; then
    printf '✗ Repo checkout contains /workspace/repo/.claude/settings.json — refusing to grant workspace trust\n' >&2
    exit 1
fi
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -eq 2 ]
}

@test "invoke_claude removes the Claude OAuth podman secret when the container fails before Claude produces any result (#1133 review)" {
    local secret_log="${TEST_TMP}/podman_secret"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator/tokens"
    printf 'my-claude-token\n' > "${XDG_CONFIG_HOME}/orchestrator/tokens/credfeto"
    chmod 600 "${XDG_CONFIG_HOME}/orchestrator/tokens/credfeto"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
if [ "\$1" = "secret" ]; then
    printf "%s\n" "\$@" >> "${secret_log}"
    exit 0
fi
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
if [ "\$1" = "run" ]; then
    exit 1
fi
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    run invoke_claude "test prompt" "" "" "# mock CLAUDE.md"
    [ "${status}" -eq 2 ]
    # The stub logs one argument per line, so "podman secret rm X" appears as three lines.
    # "rm" must appear twice: once as the pre-create cleanup of any stale secret from a prior
    # run, once as THIS invocation's own post-failure cleanup (#1133 review) — previously only
    # the first (pre-create) rm happened; the post-failure one was missing entirely.
    local rm_count
    rm_count=$(grep -c '^rm$' "${secret_log}" || true)
    [ "${rm_count}" -eq 2 ]
}

@test "invoke_claude cleans up CLAUDE_MD_TMPFILE when the container fails before Claude produces any result" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    export XDG_RUNTIME_DIR="${TEST_TMP}/runtime"
    mkdir -p "${XDG_RUNTIME_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "pull" ] && exit 0
[ "$1" = "inspect" ] && exit 1
if [ "$1" = "run" ]; then
    exit 1
fi
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -eq 2 ]
    # The CLAUDE.md tempfile (created under XDG_RUNTIME_DIR) must not survive the call.
    [ -z "$(find "${XDG_RUNTIME_DIR}" -name '*.claude-md' 2>/dev/null)" ]
}

@test "invoke_claude still dies (not returns 2) when podman exits nonzero but Claude produced a valid is_error result" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "pull" ] && exit 0
[ "$1" = "inspect" ] && exit 1
if [ "$1" = "run" ]; then
    printf '{"type":"result","is_error":true,"result":"boom"}\n'
    exit 1
fi
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -ne 2 ]
}

@test "invoke_claude does not return 2 when podman exits nonzero but Claude produced a genuinely successful result (#1133 review, Copilot)" {
    # A valid is_error:false result proves Claude actually ran, even if the container's own
    # exit code is nonzero for an unrelated reason (e.g. a kill racing a clean exit) — this
    # must be classified as a real (successful) invocation, not a pre-flight infra failure.
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "pull" ] && exit 0
[ "$1" = "inspect" ] && exit 1
if [ "$1" = "run" ]; then
    printf '{"type":"result","is_error":false,"result":"done"}\n'
    exit 1
fi
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -ne 2 ]
}

@test "invoke_claude does not mount host .claude directory" {
    local args_log="${TEST_TMP}/podman_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}" "${HOME}/.claude"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
[ "\$1" = "pull" ] && exit 0
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    invoke_claude "test prompt" "" "" "# mock CLAUDE.md" 2>/dev/null
    run grep -q ".claude:/home/developer/.claude" "${args_log}"
    [ "${status}" -ne 0 ]
}

# --- set_repo_context ---------------------------------------------------------

@test "set_repo_context sets OWNER REPO REPO_FULL RULES_DIR REPO_WORK_DIR SESSION_BASE_DIR" {
    set_repo_context "myorg/myrepo"
    [ "${OWNER}"    = "myorg" ]
    [ "${REPO}"     = "myrepo" ]
    [ "${REPO_FULL}" = "myorg/myrepo" ]
    [ "${RULES_DIR}"     = "${WORK}/myorg/myrepo/rules" ]
    [ "${REPO_WORK_DIR}" = "${WORK}/myorg/myrepo/repo" ]
    [ "${SESSION_BASE_DIR}" = "${HOME}/.orchestrator/myorg/myrepo" ]
    [ "${CLAUDE_STATE_DIR}" = "${SESSION_BASE_DIR}/claude" ]
    [ "${ORCHESTRATOR_CACHE_DIR}" = "${SESSION_BASE_DIR}/orchestrator-cache" ]
}

@test "set_repo_context is idempotent when called twice with the same repo" {
    set_repo_context "orgA/repoA"
    set_repo_context "orgA/repoA"
    [ "${REPO_FULL}" = "orgA/repoA" ]
    [ "${OWNER}" = "orgA" ]
}

@test "set_repo_context correctly switches context between two different repos" {
    set_repo_context "orgA/repoA"
    [ "${REPO_FULL}" = "orgA/repoA" ]
    [ "${OWNER}" = "orgA" ]

    set_repo_context "orgB/repoB"
    [ "${REPO_FULL}" = "orgB/repoB" ]
    [ "${OWNER}" = "orgB" ]
    [ "${REPO_WORK_DIR}" = "${WORK}/orgB/repoB/repo" ]
}

@test "set_repo_context resets _TRUSTED_LOGINS_JSON so get_trusted_logins refetches for each repo" {
    _TRUSTED_LOGINS_JSON='["stale-value"]'
    set_repo_context "neworg/newrepo"
    [ -z "${_TRUSTED_LOGINS_JSON}" ]
}

# --- fetch_all_priorities -----------------------------------------------------

@test "fetch_all_priorities returns all open and draft non-on-hold items in API order" {
    make_stub curl 'printf '"'"'{"priorities":[
        {"id":3,"itemType":"Issue","repository":"org/repo","status":"Open","isOnHold":false,"priority":3},
        {"id":1,"itemType":"Issue","repository":"org/repo","status":"Open","isOnHold":false,"priority":1},
        {"id":2,"itemType":"PullRequest","repository":"org/repo","status":"Draft","isOnHold":false,"priority":2},
        {"id":4,"itemType":"Issue","repository":"org/repo","status":"Closed","isOnHold":false,"priority":4},
        {"id":5,"itemType":"Issue","repository":"org/repo","status":"Open","isOnHold":true,"priority":0}
    ]}\n'"'"

    run fetch_all_priorities
    [ "${status}" -eq 0 ]
    # The 3 open/draft non-on-hold items appear in API order; Closed and on-hold are excluded
    local ids
    ids=$(printf '%s' "${output}" | jq -r '.[].id')
    [ "${ids}" = "$(printf '3\n1\n2')" ]
}

@test "fetch_all_priorities includes Draft items" {
    make_stub curl 'printf '"'"'{"priorities":[
        {"id":1,"itemType":"PullRequest","repository":"org/repo","status":"Draft","isOnHold":false,"priority":1},
        {"id":2,"itemType":"PullRequest","repository":"org/repo","status":"Open","isOnHold":false,"priority":2}
    ]}\n'"'"

    run fetch_all_priorities
    [ "${status}" -eq 0 ]
    local ids
    ids=$(printf '%s' "${output}" | jq -r '.[].id')
    [ "${ids}" = "$(printf '1\n2')" ]
}

@test "fetch_all_priorities returns empty array when no open items exist" {
    make_stub curl 'printf '"'"'{"priorities":[]}\n'"'"
    run fetch_all_priorities
    [ "${status}" -eq 0 ]
    [ "${output}" = "[]" ]
}

@test "fetch_all_priorities includes items from multiple repositories" {
    make_stub curl 'printf '"'"'{"priorities":[
        {"id":10,"itemType":"Issue","repository":"org/repoA","status":"Open","isOnHold":false,"priority":1},
        {"id":20,"itemType":"Issue","repository":"org/repoB","status":"Open","isOnHold":false,"priority":2}
    ]}\n'"'"

    run fetch_all_priorities
    [ "${status}" -eq 0 ]
    local repos
    repos=$(printf '%s' "${output}" | jq -r '.[].repository')
    [[ "${repos}" == *"org/repoA"* ]]
    [[ "${repos}" == *"org/repoB"* ]]
}

@test "fetch_all_priorities retries and succeeds after a transient curl failure (#1089)" {
    PRIORITIES_FETCH_RETRY_ATTEMPTS=3
    PRIORITIES_FETCH_RETRY_DELAY_SECS=0
    # shellcheck disable=SC2016  # $n/$(...) are intentionally literal — evaluated inside the stub at run time
    make_stub curl 'n=$(cat "'"${TEST_TMP}"'/curlcount" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "'"${TEST_TMP}"'/curlcount"; [ "$n" -lt 2 ] && exit 1; printf "{\"priorities\":[]}\n"'

    run fetch_all_priorities
    [ "${status}" -eq 0 ]
    [ "${output}" = "[]" ]
}

@test "fetch_all_priorities returns 1 without dying after exhausting retries on a persistent curl failure (#1089)" {
    PRIORITIES_FETCH_RETRY_ATTEMPTS=2
    PRIORITIES_FETCH_RETRY_DELAY_SECS=0
    make_stub curl 'exit 1'

    run fetch_all_priorities
    [ "${status}" -eq 1 ]
}

@test "fetch_all_priorities returns 2 (not 1) without dying when the response is not valid JSON (#1089, #1171)" {
    PRIORITIES_FETCH_RETRY_ATTEMPTS=1
    PRIORITIES_FETCH_RETRY_DELAY_SECS=0
    make_stub curl 'printf "not json"'

    run fetch_all_priorities
    [ "${status}" -eq 2 ]
}

# --- find_open_nonblocked_pr_for_repo -----------------------------------------

@test "find_open_nonblocked_pr_for_repo returns first non-blocked PR with a bot-authored commit (#1131)" {
    _GH_ME="testuser"
    printf '%s' '[{"number":42,"labels":[],"author":{"login":"testuser"}},{"number":99,"labels":[{"name":"enhancement"}],"author":{"login":"testuser"}}]' > "${TEST_TMP}/prlist.json"
    printf '%s' '{"commits":[{"authors":[{"login":"testuser"}]}]}' > "${TEST_TMP}/pr42.json"
    make_stub gh 'case "$*" in *"pr list"*) cat "'"${TEST_TMP}"'/prlist.json" ;; *"pr view 42"*"--json commits"*) cat "'"${TEST_TMP}"'/pr42.json" ;; *) exit 1 ;; esac'
    run find_open_nonblocked_pr_for_repo "org/repo"
    [ "${status}" -eq 0 ]
    [ "${output}" = "42" ]
}

@test "find_open_nonblocked_pr_for_repo skips PRs with the Blocked label" {
    _GH_ME="testuser"
    printf '%s' '[{"number":7,"labels":[{"name":"Blocked"}],"author":{"login":"testuser"}},{"number":8,"labels":[],"author":{"login":"testuser"}}]' > "${TEST_TMP}/prlist.json"
    printf '%s' '{"commits":[{"authors":[{"login":"testuser"}]}]}' > "${TEST_TMP}/pr8.json"
    make_stub gh 'case "$*" in *"pr list"*) cat "'"${TEST_TMP}"'/prlist.json" ;; *"pr view 8"*"--json commits"*) cat "'"${TEST_TMP}"'/pr8.json" ;; *) exit 1 ;; esac'
    run find_open_nonblocked_pr_for_repo "org/repo"
    [ "${status}" -eq 0 ]
    [ "${output}" = "8" ]
}

@test "find_open_nonblocked_pr_for_repo skips a candidate with no bot-authored commits and returns the next (#1131)" {
    _GH_ME="testuser"
    printf '%s' '[{"number":42,"labels":[],"author":{"login":"testuser"}},{"number":50,"labels":[],"author":{"login":"testuser"}}]' > "${TEST_TMP}/prlist.json"
    printf '%s' '{"commits":[{"authors":[{"login":"humanuser"}]}]}' > "${TEST_TMP}/pr42.json"
    printf '%s' '{"commits":[{"authors":[{"login":"testuser"}]}]}' > "${TEST_TMP}/pr50.json"
    make_stub gh 'case "$*" in *"pr list"*) cat "'"${TEST_TMP}"'/prlist.json" ;; *"pr view 42"*"--json commits"*) cat "'"${TEST_TMP}"'/pr42.json" ;; *"pr view 50"*"--json commits"*) cat "'"${TEST_TMP}"'/pr50.json" ;; *) exit 1 ;; esac'
    run --separate-stderr find_open_nonblocked_pr_for_repo "org/repo"
    [ "${status}" -eq 0 ]
    [ "${output}" = "50" ]
    # shellcheck disable=SC2154  # stderr is set by run --separate-stderr
    [[ "${stderr}" == *"treating as human-driven"* ]]
}

@test "find_open_nonblocked_pr_for_repo returns empty when the only candidate has no bot-authored commits (#1131)" {
    _GH_ME="testuser"
    printf '%s' '[{"number":42,"labels":[],"author":{"login":"testuser"}}]' > "${TEST_TMP}/prlist.json"
    printf '%s' '{"commits":[{"authors":[{"login":"humanuser"}]}]}' > "${TEST_TMP}/pr42.json"
    make_stub gh 'case "$*" in *"pr list"*) cat "'"${TEST_TMP}"'/prlist.json" ;; *"pr view 42"*"--json commits"*) cat "'"${TEST_TMP}"'/pr42.json" ;; *) exit 1 ;; esac'
    run --separate-stderr find_open_nonblocked_pr_for_repo "org/repo"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    # shellcheck disable=SC2154  # stderr is set by run --separate-stderr
    [[ "${stderr}" == *"treating as human-driven"* ]]
}

@test "find_open_nonblocked_pr_for_repo returns 1 when the commits fetch fails (#1131)" {
    _GH_ME="testuser"
    GH_ITEM_FETCH_RETRY_ATTEMPTS=1
    GH_ITEM_FETCH_RETRY_DELAY_SECS=0
    printf '%s' '[{"number":42,"labels":[],"author":{"login":"testuser"}}]' > "${TEST_TMP}/prlist.json"
    make_stub gh 'case "$*" in *"pr list"*) cat "'"${TEST_TMP}"'/prlist.json" ;; *) exit 1 ;; esac'
    run find_open_nonblocked_pr_for_repo "org/repo"
    [ "${status}" -ne 0 ]
}

@test "find_open_nonblocked_pr_for_repo scans past a broken candidate to a healthy bot PR (#1134)" {
    _GH_ME="testuser"
    GH_ITEM_FETCH_RETRY_ATTEMPTS=1
    GH_ITEM_FETCH_RETRY_DELAY_SECS=0
    printf '%s' '[{"number":7,"labels":[],"author":{"login":"testuser"}},{"number":9,"labels":[],"author":{"login":"testuser"}}]' > "${TEST_TMP}/prlist.json"
    printf '%s' '{"commits":[{"authors":[{"login":"testuser"}]}]}' > "${TEST_TMP}/pr9.json"
    # PR 7's commits fetch always fails; PR 9 is healthy and bot-driven.
    make_stub gh 'case "$*" in *"pr list"*) cat "'"${TEST_TMP}"'/prlist.json" ;; *"pr view 9"*"--json commits"*) cat "'"${TEST_TMP}"'/pr9.json" ;; *) exit 1 ;; esac'
    run find_open_nonblocked_pr_for_repo "org/repo"
    [ "${status}" -eq 0 ]
    # stderr carries the "continuing scan" warning for PR 7; the selected PR is the last line.
    [[ "${output}" == *"continuing scan"* ]]
    [ "${lines[-1]}" = "9" ]
}

@test "find_open_nonblocked_pr_for_repo returns empty when all PRs are blocked" {
    _GH_ME="testuser"
    make_stub gh 'printf '"'"'[{"number":7,"labels":[{"name":"blocked"}],"author":{"login":"testuser"}}]\n'"'"
    run find_open_nonblocked_pr_for_repo "org/repo"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "find_open_nonblocked_pr_for_repo returns empty when no PRs exist" {
    _GH_ME="testuser"
    make_stub gh 'printf '"'"'[]\n'"'"
    run find_open_nonblocked_pr_for_repo "org/repo"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "find_open_nonblocked_pr_for_repo returns empty when all open PRs are by other authors" {
    _GH_ME="testuser"
    make_stub gh 'printf '"'"'[{"number":7,"labels":[],"author":{"login":"dependabot"}},{"number":8,"labels":[],"author":{"login":"github-actions"}}]\n'"'"
    run find_open_nonblocked_pr_for_repo "org/repo"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "find_open_nonblocked_pr_for_repo returns 1 when gh fails" {
    _GH_ME="testuser"
    make_stub gh 'exit 1'
    run find_open_nonblocked_pr_for_repo "org/repo"
    [ "${status}" -ne 0 ]
}

# --- find_any_open_pr_for_repo (#1326) ---------------------------------------------

@test "find_any_open_pr_for_repo returns the first open PR regardless of author or Blocked label" {
    # shellcheck disable=SC2016
    make_stub gh 'printf '"'"'[{"number":99,"labels":[{"name":"Blocked"}],"author":{"login":"someone-else"}}]\n'"'"
    run find_any_open_pr_for_repo "org/repo"
    [ "${status}" -eq 0 ]
    [ "${output}" = "99" ]
}

@test "find_any_open_pr_for_repo returns empty when the repo has no open PR" {
    make_stub gh 'printf "[]\n"'
    run find_any_open_pr_for_repo "org/repo"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "find_any_open_pr_for_repo returns 1 when gh fails" {
    make_stub gh 'exit 1'
    run find_any_open_pr_for_repo "org/repo"
    [ "${status}" -ne 0 ]
}

# --- json_has_commit_author_identity (#1294) --------------------------------------

@test "json_has_commit_author_identity matches on resolved login" {
    run json_has_commit_author_identity "testuser" <<< '{"commits":[{"authors":[{"login":"testuser"}]}]}'
    [ "${status}" -eq 0 ]
}

@test "json_has_commit_author_identity fails when neither login nor email is given/matches" {
    run json_has_commit_author_identity "testuser" <<< '{"commits":[{"authors":[{"login":"humanuser"}]}]}'
    [ "${status}" -ne 0 ]
}

@test "json_has_commit_author_identity matches on email when login is null (#1294)" {
    run json_has_commit_author_identity "testuser" "bot@example.com" \
        <<< '{"commits":[{"authors":[{"login":null,"email":"bot@example.com"}]}]}'
    [ "${status}" -eq 0 ]
}

@test "json_has_commit_author_identity ignores email match when the email argument is empty (#1294)" {
    run json_has_commit_author_identity "testuser" "" \
        <<< '{"commits":[{"authors":[{"login":null,"email":"bot@example.com"}]}]}'
    [ "${status}" -ne 0 ]
}

@test "json_has_commit_author_identity ignores email match when the email argument is omitted (#1294)" {
    run json_has_commit_author_identity "testuser" <<< '{"commits":[{"authors":[{"login":null,"email":"bot@example.com"}]}]}'
    [ "${status}" -ne 0 ]
}

@test "json_has_commit_author_identity ignores an email match when login is resolved to someone else (spoofing guard, #1294 review)" {
    # Security regression guard: a resolved (verified) login that is NOT the bot must win over a
    # spoofable raw email that happens to equal GIT_USER_EMAIL — otherwise anyone with push access
    # could claim bot authorship just by setting their commit-author email to a value copied from
    # the bot's own commit history, defeating the human-takeover check (#1131/#1134).
    run json_has_commit_author_identity "testuser" "bot@example.com" \
        <<< '{"commits":[{"authors":[{"login":"humanuser","email":"bot@example.com"}]}]}'
    [ "${status}" -ne 0 ]
}

@test "json_has_commit_author_identity email match is case-insensitive (#1294 review)" {
    run json_has_commit_author_identity "testuser" "Bot@Example.com" \
        <<< '{"commits":[{"authors":[{"login":null,"email":"bot@example.com"}]}]}'
    [ "${status}" -eq 0 ]
}

@test "json_has_commit_author_identity ignores a co-author email spoof when the same commit's primary author already resolved to a human (spoofing guard round 2, #1294 review)" {
    # A resolved GitHub identity anywhere on a commit (author or co-author) must gate the email
    # fallback for that WHOLE commit, not just the individual author entry it appears on —
    # otherwise a human could take over with their own resolved commit and add a free-text
    # "Co-authored-by: <name> <bot's email>" trailer to flip the commit back to "bot-authored"
    # even though GitHub has already unambiguously attributed the commit to them.
    run json_has_commit_author_identity "testuser" "bot@example.com" \
        <<< '{"commits":[{"authors":[{"login":"humanuser","email":"human@example.com"},{"login":null,"email":"bot@example.com"}]}]}'
    [ "${status}" -ne 0 ]
}

@test "json_has_commit_author_identity still matches email when every author entry on the commit is unresolved (#1294 review)" {
    # Companion to the above: a commit where NEITHER author nor co-author has a resolved login
    # yet must still get the lag-fix benefit of the doubt via email — the per-commit gate must
    # not become so strict it stops matching the original #1294 scenario.
    run json_has_commit_author_identity "testuser" "bot@example.com" \
        <<< '{"commits":[{"authors":[{"login":null,"email":"someone-else@example.com"},{"login":null,"email":"bot@example.com"}]}]}'
    [ "${status}" -eq 0 ]
}

@test "json_has_commit_author_identity does not match a different email (#1294)" {
    run json_has_commit_author_identity "testuser" "bot@example.com" \
        <<< '{"commits":[{"authors":[{"login":null,"email":"someone-else@example.com"}]}]}'
    [ "${status}" -ne 0 ]
}

# --- pr_has_bot_authored_commit (#1131) ----------------------------------------

@test "pr_has_bot_authored_commit returns 0 when the bot authored a commit" {
    _GH_ME="testuser"
    make_stub gh 'printf '"'"'{"commits":[{"authors":[{"login":"humanuser"}]},{"authors":[{"login":"testuser"}]}]}\n'"'"
    run pr_has_bot_authored_commit "org/repo" 5
    [ "${status}" -eq 0 ]
}

@test "pr_has_bot_authored_commit returns 0 when the bot co-authored a commit" {
    _GH_ME="testuser"
    make_stub gh 'printf '"'"'{"commits":[{"authors":[{"login":"humanuser"},{"login":"testuser"}]}]}\n'"'"
    run pr_has_bot_authored_commit "org/repo" 5
    [ "${status}" -eq 0 ]
}

@test "pr_has_bot_authored_commit returns 1 when only humans authored commits" {
    _GH_ME="testuser"
    make_stub gh 'printf '"'"'{"commits":[{"authors":[{"login":"humanuser"}]}]}\n'"'"
    run pr_has_bot_authored_commit "org/repo" 5
    [ "${status}" -eq 1 ]
}

@test "pr_has_bot_authored_commit ignores commits whose author has no mapped login" {
    _GH_ME="testuser"
    make_stub gh 'printf '"'"'{"commits":[{"authors":[{"login":null}]},{"authors":[]}]}\n'"'"
    run pr_has_bot_authored_commit "org/repo" 5
    [ "${status}" -eq 1 ]
}

@test "pr_has_bot_authored_commit falls back to matching GIT_USER_EMAIL when login is unresolved (#1294)" {
    # Simulates GitHub's commit-author login resolution lagging right after a push: the login is
    # still null, but the raw commit-author email (present immediately, not GitHub-derived) is
    # the bot's own — this must still classify as bot-authored.
    _GH_ME="testuser"
    GIT_USER_EMAIL="bot@example.com"
    make_stub gh 'printf '"'"'{"commits":[{"authors":[{"login":null,"email":"bot@example.com"}]}]}\n'"'"
    run pr_has_bot_authored_commit "org/repo" 5
    [ "${status}" -eq 0 ]
}

@test "pr_has_bot_authored_commit does not match on email when GIT_USER_EMAIL is unset" {
    # Regression guard for the pre-#1294 behaviour: no email means no email-based match, so this
    # falls back to login-only, matching every other pr_has_bot_authored_commit test in this file.
    _GH_ME="testuser"
    GIT_USER_EMAIL=""
    make_stub gh 'printf '"'"'{"commits":[{"authors":[{"login":null,"email":"bot@example.com"}]}]}\n'"'"
    run pr_has_bot_authored_commit "org/repo" 5
    [ "${status}" -eq 1 ]
}

@test "pr_has_bot_authored_commit still returns 1 when neither login nor GIT_USER_EMAIL match (#1294)" {
    _GH_ME="testuser"
    GIT_USER_EMAIL="bot@example.com"
    make_stub gh 'printf '"'"'{"commits":[{"authors":[{"login":"humanuser","email":"human@example.com"}]}]}\n'"'"
    run pr_has_bot_authored_commit "org/repo" 5
    [ "${status}" -eq 1 ]
}

@test "pr_has_bot_authored_commit returns 1 for a resolved human commit even with a spoofed matching email (#1294 review)" {
    # Security regression guard: find_human_taken_over_pr_for_issue relies on this returning 1
    # (not bot-authored) to detect a genuine takeover. A resolved, non-bot login must win over an
    # unauthenticated commit-author email that happens to equal GIT_USER_EMAIL - otherwise a
    # takeover is invisible to the stand-off logic and oneshot opens a duplicate branch/PR
    # alongside the human's already-in-progress work.
    _GH_ME="testuser"
    GIT_USER_EMAIL="bot@example.com"
    make_stub gh 'printf '"'"'{"commits":[{"authors":[{"login":"humanuser","email":"bot@example.com"}]}]}\n'"'"
    run pr_has_bot_authored_commit "org/repo" 5
    [ "${status}" -eq 1 ]
}

@test "pr_has_bot_authored_commit returns 2 when gh fails after retries" {
    _GH_ME="testuser"
    GH_ITEM_FETCH_RETRY_ATTEMPTS=2
    GH_ITEM_FETCH_RETRY_DELAY_SECS=0
    make_stub gh 'exit 1'
    run pr_has_bot_authored_commit "org/repo" 5
    [ "${status}" -eq 2 ]
}

# --- find_human_taken_over_pr_for_issue (#1131) --------------------------------

@test "find_human_taken_over_pr_for_issue returns the PR that closes the issue when a human took it over" {
    _GH_ME="testuser"
    printf '%s' '[{"number":42,"labels":[],"author":{"login":"testuser"}}]' > "${TEST_TMP}/prlist.json"
    printf '%s' '{"commits":[{"authors":[{"login":"humanuser"}]}]}' > "${TEST_TMP}/pr42commits.json"
    printf '%s' '{"closingIssuesReferences":[{"number":164}]}' > "${TEST_TMP}/pr42refs.json"
    make_stub gh 'case "$*" in *"pr list"*) cat "'"${TEST_TMP}"'/prlist.json" ;; *"pr view 42"*"--json commits"*) cat "'"${TEST_TMP}"'/pr42commits.json" ;; *"pr view 42"*"--json closingIssuesReferences"*) cat "'"${TEST_TMP}"'/pr42refs.json" ;; *) exit 1 ;; esac'
    run find_human_taken_over_pr_for_issue 164
    [ "${status}" -eq 0 ]
    [ "${output}" = "42" ]
}

@test "find_human_taken_over_pr_for_issue returns 1 when the taken-over PR closes a different issue" {
    _GH_ME="testuser"
    printf '%s' '[{"number":42,"labels":[],"author":{"login":"testuser"}}]' > "${TEST_TMP}/prlist.json"
    printf '%s' '{"commits":[{"authors":[{"login":"humanuser"}]}]}' > "${TEST_TMP}/pr42commits.json"
    printf '%s' '{"closingIssuesReferences":[{"number":164}]}' > "${TEST_TMP}/pr42refs.json"
    make_stub gh 'case "$*" in *"pr list"*) cat "'"${TEST_TMP}"'/prlist.json" ;; *"pr view 42"*"--json commits"*) cat "'"${TEST_TMP}"'/pr42commits.json" ;; *"pr view 42"*"--json closingIssuesReferences"*) cat "'"${TEST_TMP}"'/pr42refs.json" ;; *) exit 1 ;; esac'
    run find_human_taken_over_pr_for_issue 99
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
}

@test "find_human_taken_over_pr_for_issue returns 1 when the candidate PR has bot-authored commits" {
    _GH_ME="testuser"
    printf '%s' '[{"number":42,"labels":[],"author":{"login":"testuser"}}]' > "${TEST_TMP}/prlist.json"
    printf '%s' '{"commits":[{"authors":[{"login":"testuser"}]}]}' > "${TEST_TMP}/pr42commits.json"
    printf '%s' '{"closingIssuesReferences":[{"number":164}],"headRefName":"feature/164-x"}' > "${TEST_TMP}/pr42refs.json"
    make_stub gh 'case "$*" in *"pr list"*) cat "'"${TEST_TMP}"'/prlist.json" ;; *"pr view 42"*"--json commits"*) cat "'"${TEST_TMP}"'/pr42commits.json" ;; *"pr view 42"*"--json closingIssuesReferences"*) cat "'"${TEST_TMP}"'/pr42refs.json" ;; *) exit 1 ;; esac'
    run find_human_taken_over_pr_for_issue 164
    [ "${status}" -eq 1 ]
}

@test "find_human_taken_over_pr_for_issue scans past a candidate with unreadable references to a later match (#1134)" {
    _GH_ME="testuser"
    GH_ITEM_FETCH_RETRY_ATTEMPTS=1
    GH_ITEM_FETCH_RETRY_DELAY_SECS=0
    # PR 7's fetches always fail; PR 42 is a readable taken-over PR owning issue 164.
    printf '%s' '[{"number":7,"labels":[],"author":{"login":"testuser"}},{"number":42,"labels":[],"author":{"login":"testuser"}}]' > "${TEST_TMP}/prlist.json"
    printf '%s' '{"commits":[{"authors":[{"login":"humanuser"}]}]}' > "${TEST_TMP}/pr42commits.json"
    printf '%s' '{"closingIssuesReferences":[{"number":164}],"headRefName":"feature/164-x"}' > "${TEST_TMP}/pr42refs.json"
    make_stub gh 'case "$*" in *"pr list"*) cat "'"${TEST_TMP}"'/prlist.json" ;; *"pr view 42"*"--json commits"*) cat "'"${TEST_TMP}"'/pr42commits.json" ;; *"pr view 42"*"--json closingIssuesReferences"*) cat "'"${TEST_TMP}"'/pr42refs.json" ;; *) exit 1 ;; esac'
    run --separate-stderr find_human_taken_over_pr_for_issue 164
    [ "${status}" -eq 0 ]
    [ "${output}" = "42" ]
}

@test "find_human_taken_over_pr_for_issue returns 2 when the only candidate has unreadable references (#1134)" {
    _GH_ME="testuser"
    GH_ITEM_FETCH_RETRY_ATTEMPTS=1
    GH_ITEM_FETCH_RETRY_DELAY_SECS=0
    printf '%s' '[{"number":7,"labels":[],"author":{"login":"testuser"}}]' > "${TEST_TMP}/prlist.json"
    make_stub gh 'case "$*" in *"pr list"*) cat "'"${TEST_TMP}"'/prlist.json" ;; *) exit 1 ;; esac'
    run find_human_taken_over_pr_for_issue 164
    [ "${status}" -eq 2 ]
}

@test "list_bot_created_open_prs raises the gh pr list page size above the default 30 (#1134)" {
    _GH_ME="testuser"
    # shellcheck disable=SC2016  # $* expands inside the stub at run time
    make_stub gh 'printf "%s\n" "$*" > "'"${TEST_TMP}"'/gh_args"; printf "[]"'
    run list_bot_created_open_prs "org/repo" false
    [ "${status}" -eq 0 ]
    grep -q -- "--limit 200" "${TEST_TMP}/gh_args"
}

# --- tag_pr_closed_issue result contract (#1134) --------------------------------

@test "tag_pr_closed_issue returns 0 when at least one gh action lands" {
    make_stub gh 'case "$*" in *"pr comment"*) exit 0 ;; *) exit 1 ;; esac'
    run tag_pr_closed_issue 42 164
    [ "${status}" -eq 0 ]
}

@test "tag_pr_closed_issue returns 1 when every gh action fails" {
    make_stub gh 'exit 1'
    run tag_pr_closed_issue 42 164
    [ "${status}" -eq 1 ]
}

@test "tag_pr_closed_issue still tags a PR that is already Blocked for an unrelated reason (#1103 review)" {
    # tag_pr_closed_issue itself must not special-case an existing Blocked label — the PR may be
    # blocked for a totally unrelated reason (CI timeout, a human block) and still need the
    # closed-issue investigation comment posted for the first time. Deduplication against
    # repeated calls belongs to the caller (a marker file), not this function.
    local gh_log="${TEST_TMP}/gh.log"
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${gh_log}"
case "\$*" in
    *"pr view"*) printf '{"labels":[{"name":"Blocked"}]}' ;;
    *"pr comment"*) exit 0 ;;
    *) exit 1 ;;
esac
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    run tag_pr_closed_issue 42 164
    [ "${status}" -eq 0 ]
    grep -q "pr comment" "${gh_log}"
}

@test "find_human_taken_over_pr_for_issue returns 2 when the PR list fetch fails" {
    _GH_ME="testuser"
    GH_ITEM_FETCH_RETRY_ATTEMPTS=1
    GH_ITEM_FETCH_RETRY_DELAY_SECS=0
    make_stub gh 'exit 1'
    run find_human_taken_over_pr_for_issue 164
    [ "${status}" -eq 2 ]
}

@test "find_human_taken_over_pr_for_issue falls back to the branch-name convention when the closing reference is gone (#1134)" {
    _GH_ME="testuser"
    printf '%s' '[{"number":42,"labels":[],"author":{"login":"testuser"}}]' > "${TEST_TMP}/prlist.json"
    printf '%s' '{"commits":[{"authors":[{"login":"humanuser"}]}]}' > "${TEST_TMP}/pr42commits.json"
    printf '%s' '{"closingIssuesReferences":[],"headRefName":"feature/164-buildtest-skip-benchmarks"}' > "${TEST_TMP}/pr42refs.json"
    make_stub gh 'case "$*" in *"pr list"*) cat "'"${TEST_TMP}"'/prlist.json" ;; *"pr view 42"*"--json commits"*) cat "'"${TEST_TMP}"'/pr42commits.json" ;; *"pr view 42"*"--json closingIssuesReferences"*) cat "'"${TEST_TMP}"'/pr42refs.json" ;; *) exit 1 ;; esac'
    run find_human_taken_over_pr_for_issue 164
    [ "${status}" -eq 0 ]
    [ "${output}" = "42" ]
}

@test "find_human_taken_over_pr_for_issue does not match a branch whose issue number merely starts with the target (#1134)" {
    _GH_ME="testuser"
    printf '%s' '[{"number":42,"labels":[],"author":{"login":"testuser"}}]' > "${TEST_TMP}/prlist.json"
    printf '%s' '{"commits":[{"authors":[{"login":"humanuser"}]}]}' > "${TEST_TMP}/pr42commits.json"
    printf '%s' '{"closingIssuesReferences":[],"headRefName":"feature/1640-other-work"}' > "${TEST_TMP}/pr42refs.json"
    make_stub gh 'case "$*" in *"pr list"*) cat "'"${TEST_TMP}"'/prlist.json" ;; *"pr view 42"*"--json commits"*) cat "'"${TEST_TMP}"'/pr42commits.json" ;; *"pr view 42"*"--json closingIssuesReferences"*) cat "'"${TEST_TMP}"'/pr42refs.json" ;; *) exit 1 ;; esac'
    run find_human_taken_over_pr_for_issue 164
    [ "${status}" -eq 1 ]
}

@test "find_human_taken_over_pr_for_issue lets explicit closing references beat a stale branch name (#1134)" {
    _GH_ME="testuser"
    # PR was retargeted to issue 264 (body edited) but still lives on branch fix/164-foo:
    # querying 164 must NOT match — the explicit reference wins over the branch convention.
    printf '%s' '[{"number":42,"labels":[],"author":{"login":"testuser"}}]' > "${TEST_TMP}/prlist.json"
    printf '%s' '{"commits":[{"authors":[{"login":"humanuser"}]}]}' > "${TEST_TMP}/pr42commits.json"
    printf '%s' '{"closingIssuesReferences":[{"number":264}],"headRefName":"fix/164-foo"}' > "${TEST_TMP}/pr42refs.json"
    make_stub gh 'case "$*" in *"pr list"*) cat "'"${TEST_TMP}"'/prlist.json" ;; *"pr view 42"*"--json commits"*) cat "'"${TEST_TMP}"'/pr42commits.json" ;; *"pr view 42"*"--json closingIssuesReferences"*) cat "'"${TEST_TMP}"'/pr42refs.json" ;; *) exit 1 ;; esac'
    run find_human_taken_over_pr_for_issue 164
    [ "${status}" -eq 1 ]
}

@test "find_human_taken_over_pr_for_issue still sees a Blocked taken-over PR (#1134)" {
    _GH_ME="testuser"
    # Tagging a taken-over PR adds Blocked; the stand-off must not go blind because of it,
    # or a reopened issue would get duplicate work.
    printf '%s' '[{"number":42,"labels":[{"name":"Blocked"}],"author":{"login":"testuser"}}]' > "${TEST_TMP}/prlist.json"
    printf '%s' '{"commits":[{"authors":[{"login":"humanuser"}]}]}' > "${TEST_TMP}/pr42commits.json"
    printf '%s' '{"closingIssuesReferences":[{"number":164}],"headRefName":"feature/164-x"}' > "${TEST_TMP}/pr42refs.json"
    make_stub gh 'case "$*" in *"pr list"*) cat "'"${TEST_TMP}"'/prlist.json" ;; *"pr view 42"*"--json commits"*) cat "'"${TEST_TMP}"'/pr42commits.json" ;; *"pr view 42"*"--json closingIssuesReferences"*) cat "'"${TEST_TMP}"'/pr42refs.json" ;; *) exit 1 ;; esac'
    run find_human_taken_over_pr_for_issue 164
    [ "${status}" -eq 0 ]
    [ "${output}" = "42" ]
}

# --- resolve_resumable_issue_branch (#1262) -------------------------------------

@test "resolve_resumable_issue_branch returns 1 when find_stale_issue_branch finds no candidate" {
    REPO_FULL="org/repo"
    find_stale_issue_branch() { return 1; }
    run resolve_resumable_issue_branch 42
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
}

@test "resolve_resumable_issue_branch returns the branch when no PR covers it" {
    REPO_FULL="org/repo"
    find_stale_issue_branch() { printf 'chore/42-fix\n'; return 0; }
    make_stub gh 'case "$*" in
        "pr list --repo org/repo --head chore/42-fix --state open --json number --jq length") printf "0\n" ;;
        *) exit 1 ;;
    esac'
    run resolve_resumable_issue_branch 42
    [ "${status}" -eq 0 ]
    [ "${output}" = "chore/42-fix" ]
}

@test "resolve_resumable_issue_branch returns 1 when a PR already covers the candidate branch (#1262)" {
    REPO_FULL="org/repo"
    find_stale_issue_branch() { printf 'chore/42-fix\n'; return 0; }
    make_stub gh 'case "$*" in
        "pr list --repo org/repo --head chore/42-fix --state open --json number --jq length") printf "1\n" ;;
        *) exit 1 ;;
    esac'
    run resolve_resumable_issue_branch 42
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
}

@test "resolve_resumable_issue_branch returns 1 (fails safe) when the gh pr list check itself fails" {
    REPO_FULL="org/repo"
    find_stale_issue_branch() { printf 'chore/42-fix\n'; return 0; }
    make_stub gh 'exit 1'
    run resolve_resumable_issue_branch 42
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
}

# --- pr_is_human_driven (#1131) -------------------------------------------------
# Operates on the caller's pr_json (author/commits included by fetch_pr_json, #1134) — no gh
# fetch of its own; the stubs below exist only to prove no call happens or to fail resolve_gh_me.

@test "pr_is_human_driven exempts a dependencies-labelled dependency PR even after a trusted human pushed to it" {
    _GH_ME="testuser"
    # No gh call should be needed — everything comes from the passed pr_json.
    make_stub gh 'exit 1'
    run pr_is_human_driven '{"labels":[{"name":"Dependencies"}],"author":{"login":"app/dependabot"},"commits":[{"authors":[{"login":"credfeto"}]}]}' '["credfeto"]'
    [ "${status}" -eq 1 ]
}

@test "pr_is_human_driven exempts customised dependency label variants like 'npm dependencies' (#1134)" {
    _GH_ME="testuser"
    run pr_is_human_driven '{"labels":[{"name":"npm dependencies"}],"author":{"login":"app/dependabot"},"commits":[{"authors":[{"login":"app/dependabot"}]}]}' '["credfeto"]'
    [ "${status}" -eq 1 ]
}

@test "pr_is_human_driven stands off a taken-over bot PR regardless of a dependencies-ish label (#1134)" {
    _GH_ME="testuser"
    # Issue-label sync can put any label on a bot-created PR — a takeover must win over the
    # label exemption (the author check runs first).
    run pr_is_human_driven '{"labels":[{"name":"update-dependencies-major"}],"author":{"login":"testuser"},"commits":[{"authors":[{"login":"credfeto"}]}]}' '["credfeto"]'
    [ "${status}" -eq 0 ]
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

# --- resolve_gh_me (#1085) ----------------------------------------------------

@test "resolve_gh_me sets _GH_ME and returns 0 when gh api user succeeds (#1085)" {
    _GH_ME=""
    GH_USER_RETRY_DELAY_SECS=0
    make_stub gh 'printf "testuser\n"'
    run resolve_gh_me
    [ "${status}" -eq 0 ]
    resolve_gh_me
    [ "${_GH_ME}" = "testuser" ]
}

@test "resolve_gh_me short-circuits and returns 0 when _GH_ME is already cached (#1085)" {
    _GH_ME="cacheduser"
    GH_USER_RETRY_DELAY_SECS=0
    make_stub gh 'exit 1'
    run resolve_gh_me
    [ "${status}" -eq 0 ]
}

@test "resolve_gh_me retries and succeeds after a transient failure (#1085)" {
    _GH_ME=""
    GH_USER_RETRY_ATTEMPTS=3
    GH_USER_RETRY_DELAY_SECS=0
    # shellcheck disable=SC2016  # $n/$(...) are intentionally literal — evaluated inside the stub at run time
    make_stub gh 'n=$(cat "'"${TEST_TMP}"'/ghuser" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "'"${TEST_TMP}"'/ghuser"; [ "$n" -lt 2 ] && exit 1; printf "testuser\n"'
    resolve_gh_me
    [ "${_GH_ME}" = "testuser" ]
}

@test "resolve_gh_me returns 1 without dying after exhausting retries (#1085)" {
    _GH_ME=""
    GH_USER_RETRY_ATTEMPTS=2
    GH_USER_RETRY_DELAY_SECS=0
    make_stub gh 'exit 1'
    run resolve_gh_me
    [ "${status}" -ne 0 ]
    [ -z "${_GH_ME}" ]
}

@test "find_open_nonblocked_pr_for_repo returns 1 (not fatal) when identity lookup fails (#1085)" {
    _GH_ME=""
    GH_USER_RETRY_ATTEMPTS=1
    GH_USER_RETRY_DELAY_SECS=0
    make_stub gh 'exit 1'
    run find_open_nonblocked_pr_for_repo "org/repo"
    [ "${status}" -ne 0 ]
}

# --- fetch_pr_json / fetch_issue_json retry (#1090) ---------------------------

@test "fetch_pr_json retries and succeeds after a transient gh failure (#1090)" {
    GH_ITEM_FETCH_RETRY_ATTEMPTS=3
    GH_ITEM_FETCH_RETRY_DELAY_SECS=0
    # shellcheck disable=SC2016  # $n/$(...) are intentionally literal — evaluated inside the stub at run time
    make_stub gh 'n=$(cat "'"${TEST_TMP}"'/ghcount" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "'"${TEST_TMP}"'/ghcount"; [ "$n" -lt 2 ] && exit 1; printf "{}\n"'
    run fetch_pr_json 5
    [ "${status}" -eq 0 ]
    [ "${output}" = "{}" ]
}

@test "fetch_pr_json returns 1 without dying after exhausting retries (#1090)" {
    GH_ITEM_FETCH_RETRY_ATTEMPTS=2
    GH_ITEM_FETCH_RETRY_DELAY_SECS=0
    make_stub gh 'exit 1'
    run fetch_pr_json 5
    [ "${status}" -ne 0 ]
}

@test "fetch_issue_json retries and succeeds after a transient gh failure (#1090)" {
    GH_ITEM_FETCH_RETRY_ATTEMPTS=3
    GH_ITEM_FETCH_RETRY_DELAY_SECS=0
    # shellcheck disable=SC2016  # $n/$(...) are intentionally literal — evaluated inside the stub at run time
    make_stub gh 'n=$(cat "'"${TEST_TMP}"'/ghcount" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "'"${TEST_TMP}"'/ghcount"; [ "$n" -lt 2 ] && exit 1; printf "{}\n"'
    run fetch_issue_json 5
    [ "${status}" -eq 0 ]
    [ "${output}" = "{}" ]
}

@test "fetch_issue_json returns 1 without dying after exhausting retries (#1090)" {
    GH_ITEM_FETCH_RETRY_ATTEMPTS=2
    GH_ITEM_FETCH_RETRY_DELAY_SECS=0
    make_stub gh 'exit 1'
    run fetch_issue_json 5
    [ "${status}" -ne 0 ]
}

# --- find_ai_instructions (updated behaviour) ---------------------------------

@test "find_ai_instructions returns non-zero (not die) when neither path has .ai-instructions" {
    # Function should return 1 and emit a warning, not call die/exit.
    run find_ai_instructions
    [ "${status}" -ne 0 ]
    [[ "${output}" == *".ai-instructions"* ]]
}

# --- main() skip_repos integration tests -------------------------------------
# These tests exercise the multi-repo iteration logic in main() by overriding
# all external-call functions.  No PATH stubs are used — all overrides are
# function-level so no teardown stub cleanup is required beyond the common hook.

# Common overrides shared across main() integration tests.
# Call this inside each test after sourcing (i.e. after setup has run) to
# replace every function that performs real I/O.
setup_main_mocks() {
    # Deterministic baseline for the self-update staleness gate (#1298): never inherit a real
    # ORCHESTRATOR_SELF_UPDATE_MANAGED from whatever environment is actually running these tests.
    # Individual tests opt into the "systemd-managed self-update ran" path by exporting it
    # themselves.
    unset ORCHESTRATOR_SELF_UPDATE_MANAGED
    make_stub flock 'exit 0'
    check_required_tools()      { return 0; }
    set_repo_context()          { return 0; }
    ensure_rules_current()      { return 0; }
    ensure_repo_current()       { return 0; }
    recover_orphaned_branch()   { return 1; }
    resolve_resumable_issue_branch() { return 1; }
    try_nonagentic_rebase()     { return 1; }
    # Default: no human-driven PRs anywhere (#1131) — tests that exercise the
    # stand-off paths override these individually.
    find_human_taken_over_pr_for_issue() { return 1; }
    pr_is_human_driven()                 { return 1; }
    # Stub resolve_gh_me for the assignee standoff check (#1142) — no real gh call
    # in integration tests.  := preserves any _GH_ME set directly by unit tests.
    resolve_gh_me()                      { _GH_ME="${_GH_ME:-testuser}"; return 0; }
    find_ai_instructions()      { printf '/mock/.ai-instructions\n'; }
    host_to_container_path()    { printf '%s\n' "$1"; }
    build_issue_prompt()        { printf 'mock-issue-prompt\n'; }
    build_pr_prompt()           { printf 'mock-pr-prompt\n'; }
    build_issue_claude_md()     { printf 'mock-issue-claude-md\n'; }
    build_pr_claude_md()        { printf 'mock-pr-claude-md\n'; }
    invoke_claude()             { return 0; }
    compute_pr_fingerprint()    { printf 'new-fp\n'; }
    compute_issue_fingerprint() { printf 'new-fp\n'; }
    save_pr_fingerprint()       { return 0; }
    save_issue_fingerprint()    { return 0; }
    # Default: no unaddressed trusted comment recorded/observed (#1307) — tests exercising the
    # unaddressed-comment override (terminal-skip/non-agentic-rebase bypass, save timing) set
    # fetch_pr_json's "comments" and/or these individually.
    load_pr_last_agent_comment_seen()    { printf ''; }
    save_pr_last_agent_comment_seen()    { return 0; }
    compute_pr_last_agent_comment_seen() { printf ''; }
    fingerprint_issue_json()    { printf 'issue-fp-default\n'; }
    load_issue_fingerprint()    { printf ''; }
    # No Workflow board by default (#1204) — tests exercising board-approval behaviour override
    # these individually, matching how fetch_board_approved_items itself is a no-op when
    # _WF_PROJECT_ID is empty.
    discover_or_create_workflow_project() { return 0; }
    fetch_board_approved_items()          { return 0; }
    tag_pr_closed_issue()       { return 0; }
    is_owner_rate_limited()       { return 1; }
    load_env_config()             { return 0; }
    validate_config()             { return 0; }
    get_trusted_logins()          { printf '["credfeto"]\n'; }
    fetch_pr_review_comments()    { printf '[]\n'; }
    notify_discord_work_item()         { return 0; }
    notify_discord_pr_waiting()        { return 0; }
    notify_discord_no_work()           { return 0; }
    notify_discord_blocked_item()      { return 0; }
    notify_discord_pr_needs_approval() { return 0; }
    notify_discord_claude_error()      { return 0; }
    notify_discord_rate_limited()      { return 0; }
    notify_discord_low_disk_space()    { return 0; }
    notify_discord_priorities_unreachable() { return 0; }
    check_disk_space()                 { return 0; }
    sync_pr_labels_from_linked_issues() { return 0; }
}

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
    fetch_pr_json() { printf '{"state":"MERGED","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}\n'; }
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

# --- repository name validation -----------------------------------------------

@test "main dies loudly (does not report success) when fetch_all_priorities ultimately fails (#1089)" {
    setup_main_mocks
    fetch_all_priorities() { return 1; }

    run main
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Failed to fetch priorities"* ]]
    [[ "${output}" != *"No actionable work items"* ]]
    [[ "${output}" != *"No open work items"* ]]
}

@test "main notifies Discord before dying when fetch_all_priorities ultimately fails (#1171)" {
    setup_main_mocks
    fetch_all_priorities() { return 1; }
    local discord_log="${TEST_TMP}/discord_log"
    notify_discord_priorities_unreachable() { printf 'notified\n' >> "${discord_log}"; }

    run main
    [ "${status}" -ne 0 ]
    [ -f "${discord_log}" ]
}

@test "main does NOT notify Discord when fetch_all_priorities fails to parse (rc 2, not unreachable) (#1171)" {
    setup_main_mocks
    fetch_all_priorities() { return 2; }
    local discord_log="${TEST_TMP}/discord_log"
    notify_discord_priorities_unreachable() { printf 'notified\n' >> "${discord_log}"; }

    run main
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Failed to fetch priorities"* ]]
    [ ! -f "${discord_log}" ]
}

@test "main dies loudly when the priorities item count cannot be determined (#1089)" {
    setup_main_mocks
    fetch_all_priorities() { printf 'not valid json\n'; }

    run main
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Failed to determine item count from priorities JSON"* ]]
}

@test "main skips (does not die on) a malformed repository name from priorities API (path traversal) (#1090)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":1,"itemType":"Issue","repository":"../evil/path","priority":1,"status":"Open","isOnHold":false}]'
    }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"Malformed repository from priorities API"* ]]
    [[ "${output}" == *"errors: 1"* ]]
}

@test "main skips (does not die on) a repository name with no slash from priorities API (#1090)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":1,"itemType":"Issue","repository":"noslash","priority":1,"status":"Open","isOnHold":false}]'
    }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"Malformed repository from priorities API"* ]]
    [[ "${output}" == *"errors: 1"* ]]
}

@test "main accepts a well-formed owner/repo name from priorities API" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":1,"itemType":"Issue","repository":"org/my-repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[{"name":"Blocked"}],"comments":[],"assignees":[],"milestone":null}\n'; }
    issue_json_has_blocked_label() { return 0; }

    run main
    [ "${status}" -eq 0 ]
    # Valid repo name accepted — issue processed (then skipped as blocked)
    [[ "${output}" == *"Issue #1 in org/my-repo is blocked"* ]]
}

@test "main skips an Issue and does not die when the PR lookup fails transiently (#1085)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":1,"itemType":"Issue","repository":"org/my-repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { return 1; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    # A transient PR-lookup failure must skip the item, not abort the run.
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"Failed to query open PRs for org/my-repo — skipping"* ]]
    [[ "${output}" == *"errors: 1"* ]]
}

@test "main accepts a repo name starting with underscore from priorities API" {
    # GitHub allows repo names like _git_ignore_patterns — must not die with "Malformed"
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":1,"itemType":"Issue","repository":"isaacs/_git_ignore_patterns","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[{"name":"Blocked"}],"comments":[],"assignees":[],"milestone":null}\n'; }
    issue_json_has_blocked_label() { return 0; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"Malformed repository from priorities API"* ]]
    [[ "${output}" == *"Issue #1 in isaacs/_git_ignore_patterns is blocked"* ]]
}

@test "main skips (does not die on) a non-numeric id from priorities API (#1090)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":"not-a-number","itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"Non-numeric id from priorities API"* ]]
    [[ "${output}" == *"errors: 1"* ]]
}

@test "main skips (does not die on) an unexpected itemType from priorities API (#1090)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":1,"itemType":"Discussion","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"Unexpected itemType from priorities API"* ]]
    [[ "${output}" == *"errors: 1"* ]]
}

@test "main skips (does not die on) a non-numeric open PR number from GitHub (#1090)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":1,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf 'not-a-number\n'; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"Non-numeric open PR number from GitHub"* ]]
    [[ "${output}" == *"errors: 1"* ]]
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

# --- load_env_config ------------------------------------------------------

@test "load_env_config sets DISCORD_WEBHOOK_URL from env file" {
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf 'DISCORD_WEBHOOK=https://discord.example.com/webhook/123\n' \
        > "${XDG_CONFIG_HOME}/orchestrator/.env"
    DISCORD_WEBHOOK_URL=""
    load_env_config
    [ "${DISCORD_WEBHOOK_URL}" = "https://discord.example.com/webhook/123" ]
}

@test "load_env_config strips double quotes from value" {
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf 'DISCORD_WEBHOOK="https://discord.example.com/webhook/456"\n' \
        > "${XDG_CONFIG_HOME}/orchestrator/.env"
    DISCORD_WEBHOOK_URL=""
    load_env_config
    [ "${DISCORD_WEBHOOK_URL}" = "https://discord.example.com/webhook/456" ]
}

@test "load_env_config strips single quotes from value" {
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf "DISCORD_WEBHOOK='https://discord.example.com/webhook/789'\n" \
        > "${XDG_CONFIG_HOME}/orchestrator/.env"
    DISCORD_WEBHOOK_URL=""
    load_env_config
    [ "${DISCORD_WEBHOOK_URL}" = "https://discord.example.com/webhook/789" ]
}

@test "load_env_config leaves DISCORD_WEBHOOK_URL empty when file is absent" {
    DISCORD_WEBHOOK_URL="should-be-cleared"
    load_env_config
    [ -z "${DISCORD_WEBHOOK_URL}" ]
}

@test "load_env_config leaves DISCORD_WEBHOOK_URL empty when key is absent from file" {
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf 'OTHER_KEY=some-value\n' > "${XDG_CONFIG_HOME}/orchestrator/.env"
    DISCORD_WEBHOOK_URL="should-be-cleared"
    load_env_config
    [ -z "${DISCORD_WEBHOOK_URL}" ]
}

@test "load_env_config strips trailing CR from CRLF env files" {
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf 'DISCORD_WEBHOOK=https://discord.example.com/hook\r\n' \
        > "${XDG_CONFIG_HOME}/orchestrator/.env"
    DISCORD_WEBHOOK_URL=""
    load_env_config
    [ "${DISCORD_WEBHOOK_URL}" = "https://discord.example.com/hook" ]
}

@test "load_env_config does not strip unmatched leading quote" {
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf 'DISCORD_WEBHOOK="https://discord.example.com/hook\n' \
        > "${XDG_CONFIG_HOME}/orchestrator/.env"
    DISCORD_WEBHOOK_URL=""
    load_env_config
    [ "${DISCORD_WEBHOOK_URL}" = '"https://discord.example.com/hook' ]
}

@test "load_env_config reads GH_TOKEN and GH_HOST and exports them" {
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf 'GH_TOKEN=ghp_testtoken\nGH_HOST=github-api.example.com\n' \
        > "${XDG_CONFIG_HOME}/orchestrator/.env"
    load_env_config
    [ "${GH_HOST}" = "github-api.example.com" ]
    # shellcheck disable=SC2031
    [ "${GH_ENTERPRISE_TOKEN}" = "ghp_testtoken" ]
}

@test "load_env_config does not export GH vars when GH_HOST is absent" {
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf 'GH_TOKEN=ghp_testtoken\n' > "${XDG_CONFIG_HOME}/orchestrator/.env"
    unset GH_HOST GH_ENTERPRISE_TOKEN || true
    load_env_config
    # shellcheck disable=SC2031
    [ -z "${GH_ENTERPRISE_TOKEN:-}" ]
}

@test "load_env_config reads all three keys from the same env file" {
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf 'DISCORD_WEBHOOK=https://hook.example.com/1\nGH_TOKEN=ghp_abc\nGH_HOST=proxy.example.com\n' \
        > "${XDG_CONFIG_HOME}/orchestrator/.env"
    DISCORD_WEBHOOK_URL=""
    load_env_config
    [ "${DISCORD_WEBHOOK_URL}" = "https://hook.example.com/1" ]
    # shellcheck disable=SC2031
    [ "${GH_ENTERPRISE_TOKEN}" = "ghp_abc" ]
    [ "${GH_HOST}" = "proxy.example.com" ]
}

@test "load_env_config reads WHITELISTED_USERS from env file" {
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf 'WHITELISTED_USERS=alice,bob\n' > "${XDG_CONFIG_HOME}/orchestrator/.env"
    WHITELISTED_USERS=""
    load_env_config
    [ "${WHITELISTED_USERS}" = "alice,bob" ]
}

@test "load_env_config leaves WHITELISTED_USERS empty when key is absent from env file" {
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf 'DISCORD_WEBHOOK=https://hook.example.com/1\n' > "${XDG_CONFIG_HOME}/orchestrator/.env"
    WHITELISTED_USERS=""
    load_env_config
    [ -z "${WHITELISTED_USERS}" ]
}

@test "load_env_config reads CI_CHECK_TIMEOUT_MINUTES from env file" {
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf 'CI_CHECK_TIMEOUT_MINUTES=30\n' > "${XDG_CONFIG_HOME}/orchestrator/.env"
    CI_CHECK_TIMEOUT_MINUTES=60
    load_env_config
    [ "${CI_CHECK_TIMEOUT_MINUTES}" = "30" ]
}

@test "load_env_config ignores non-integer CI_CHECK_TIMEOUT_MINUTES and warns" {
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf 'CI_CHECK_TIMEOUT_MINUTES=abc\n' > "${XDG_CONFIG_HOME}/orchestrator/.env"
    CI_CHECK_TIMEOUT_MINUTES=60
    run load_env_config
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"CI_CHECK_TIMEOUT_MINUTES must be a positive integer"* ]]
    [ "${CI_CHECK_TIMEOUT_MINUTES}" = "60" ]
}

@test "load_env_config ignores zero CI_CHECK_TIMEOUT_MINUTES and warns" {
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf 'CI_CHECK_TIMEOUT_MINUTES=0\n' > "${XDG_CONFIG_HOME}/orchestrator/.env"
    CI_CHECK_TIMEOUT_MINUTES=60
    run load_env_config
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"CI_CHECK_TIMEOUT_MINUTES must be a positive integer"* ]]
    [ "${CI_CHECK_TIMEOUT_MINUTES}" = "60" ]
}

# --- notify_discord_work_item -------------------------------------------------

@test "notify_discord_work_item warns and returns for unknown msg_type without calling curl" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_work_item "unknown_type" "Issue" "1" "Title"
    [ "${status}" -eq 0 ]
    [ ! -f "${args_log}" ]
    [[ "${output}" == *"unknown notification type"* ]]
}

@test "notify_discord_work_item does not call curl when DISCORD_WEBHOOK_URL is empty" {
    DISCORD_WEBHOOK_URL=""
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_work_item "start" "Issue" "42" "Fix the bug"
    [ "${status}" -eq 0 ]
    [ ! -f "${args_log}" ]
}

@test "notify_discord_work_item calls curl with embed payload for Issue start" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_work_item "start" "Issue" "42" "Fix the bug"
    [ "${status}" -eq 0 ]
    grep -q "https://discord.example.com/hook" "${args_log}"
    grep -q "Fix the bug" "${args_log}"
    grep -q "https://github.com/org/repo/issues/42" "${args_log}"
    # No board configured and no labels passed — status/sub-status/priority fall back
    # gracefully (#1136) rather than the old meaningless New/Resume "session status".
    grep -q "Priority" "${args_log}"
    grep -q "Undefined" "${args_log}"
    grep -q "Sub-status" "${args_log}"
    grep -q "Unknown" "${args_log}"
}

@test "notify_discord_work_item calls curl with embed payload for PullRequest resume" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_work_item "resume" "PullRequest" "7" "Update deps"
    [ "${status}" -eq 0 ]
    grep -q "https://github.com/org/repo/pull/7" "${args_log}"
    grep -q "Update deps" "${args_log}"
}

@test "notify_discord_work_item includes the item's priority-rank name in the payload (#1375)" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_work_item "start" "Issue" "42" "Fix the bug" "3"
    [ "${status}" -eq 0 ]
    grep -q "Priority" "${args_log}"
    grep -q "High" "${args_log}"
}

@test "notify_discord_work_item maps priority rank 5 to Security and 0 to Default (#1375)" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_work_item "start" "Issue" "42" "Fix the bug" "5"
    [ "${status}" -eq 0 ]
    grep -q "Security" "${args_log}"

    : > "${args_log}"
    run notify_discord_work_item "start" "Issue" "43" "Fix another bug" "0"
    [ "${status}" -eq 0 ]
    grep -q "Default" "${args_log}"
}

@test "notify_discord_work_item falls back to Undefined for a missing or out-of-range priority rank (#1375)" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_work_item "start" "Issue" "42" "Fix the bug" "99"
    [ "${status}" -eq 0 ]
    grep -q "Undefined" "${args_log}"
}

@test "notify_discord_work_item enriches Sub-status with round progress and keeps Status derived from the raw substatus (#1375)" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    # Shadow board_substatus_for_item rather than standing up a full fake GraphQL board — proves
    # notify_discord_work_item feeds its raw output into enrich_substatus_with_round_progress for
    # display, while still deriving the coarse Status field from the raw (unenriched) name (a real
    # ordering bug caught during review: computing Status from the already-enriched text made
    # every round-tracked phase silently show "Unknown").
    board_substatus_for_item() { printf 'AI Review'; }
    make_stub gh 'printf "%s" "{\"comments\":[{\"body\":\"Code review round: fixed 1 finding\"}]}"'
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_work_item "start" "PullRequest" "42" "Fix the bug" "3" "feature/x"
    [ "${status}" -eq 0 ]
    grep -q "AI Review (round 1 of ${MAX_CODE_REVIEW_ITERATIONS})" "${args_log}"
    grep -q "In Progress" "${args_log}"
}

@test "notify_discord_work_item defaults Progress to Running and omits Overall when not given (#1375)" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_work_item "start" "Issue" "42" "Fix the bug"
    [ "${status}" -eq 0 ]
    grep -q "Progress" "${args_log}"
    grep -q "Running" "${args_log}"
    [ "$(grep -c "Overall" "${args_log}")" -eq 0 ]
}

@test "notify_discord_work_item includes Overall when given (#1375)" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_work_item "start" "Issue" "42" "Fix the bug" "" "" "Running" "3 / 57"
    [ "${status}" -eq 0 ]
    grep -q "Overall" "${args_log}"
    grep -q "3 / 57" "${args_log}"
}

@test "notify_discord_work_item waiting sends a Progress field describing why it's parked (#1375)" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_work_item "waiting" "PullRequest" "42" "Fix the bug" "" "" "Waiting on CI"
    [ "${status}" -eq 0 ]
    grep -q "Progress" "${args_log}"
    grep -q "Waiting on CI" "${args_log}"
}

@test "notify_discord_work_item waiting suppresses an identical repeat but re-sends on a real change (#1375)" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local call_log="${TEST_TMP}/curl_calls"
    make_stub curl "printf 'call\n' >> '${call_log}'"

    run notify_discord_work_item "waiting" "PullRequest" "42" "Fix the bug" "" "" "Waiting on CI"
    [ "${status}" -eq 0 ]
    [ "$(wc -l < "${call_log}")" -eq 1 ]

    # Identical content again — suppressed, no second curl call.
    run notify_discord_work_item "waiting" "PullRequest" "42" "Fix the bug" "" "" "Waiting on CI"
    [ "${status}" -eq 0 ]
    [ "$(wc -l < "${call_log}")" -eq 1 ]

    # Genuine state change (now waiting on human review instead) — sends again.
    run notify_discord_work_item "waiting" "PullRequest" "42" "Fix the bug" "" "" "Waiting on human review"
    [ "${status}" -eq 0 ]
    [ "$(wc -l < "${call_log}")" -eq 2 ]
}

@test "notify_discord_work_item waiting does not record the dedup state on a failed send (#1375)" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    make_stub curl 'exit 1'
    run notify_discord_work_item "waiting" "PullRequest" "42" "Fix the bug" "" "" "Waiting on CI"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"webhook notification failed"* ]]

    local call_log="${TEST_TMP}/curl_calls"
    make_stub curl "printf 'call\n' >> '${call_log}'"
    run notify_discord_work_item "waiting" "PullRequest" "42" "Fix the bug" "" "" "Waiting on CI"
    [ "${status}" -eq 0 ]
    [ "$(wc -l < "${call_log}")" -eq 1 ]
}

# --- notify_discord_pr_waiting -------------------------------------------------

@test "notify_discord_pr_waiting derives title, branch_name and comments from pr_json and forwards to notify_discord_work_item (#1375)" {
    set_repo_context "org/repo"
    discover_or_create_workflow_project() { return 0; }
    local call_log="${TEST_TMP}/notify_calls"
    notify_discord_work_item() { printf '%s\n' "$*" >> "${call_log}"; }
    local pr_json='{"title":"Fix the bug","headRefName":"feature/x","comments":[{"body":"hi"}]}'

    run notify_discord_pr_waiting "42" "${pr_json}" "3" "Waiting on CI"
    [ "${status}" -eq 0 ]
    [ -f "${call_log}" ]
    grep -q '^waiting PullRequest 42 Fix the bug 3 feature/x Waiting on CI  \[{"body":"hi"}\]$' "${call_log}"
}

@test "notify_discord_pr_waiting calls discover_or_create_workflow_project before notifying (#1375)" {
    set_repo_context "org/repo"
    local call_log="${TEST_TMP}/discover_calls"
    discover_or_create_workflow_project() { printf 'called\n' >> "${call_log}"; }
    notify_discord_work_item() { return 0; }

    run notify_discord_pr_waiting "42" '{"title":"T","comments":[]}' "" "Waiting on CI"
    [ "${status}" -eq 0 ]
    [ -f "${call_log}" ]
}

@test "notify_discord_pr_waiting defaults comments to an empty array when pr_json has none (#1375)" {
    set_repo_context "org/repo"
    discover_or_create_workflow_project() { return 0; }
    local call_log="${TEST_TMP}/notify_calls"
    notify_discord_work_item() { printf '%s\n' "$*" >> "${call_log}"; }

    run notify_discord_pr_waiting "42" '{"title":"T"}' "" "Waiting on CI"
    [ "${status}" -eq 0 ]
    grep -q '\[\]$' "${call_log}"
}

# --- notify_discord_no_work ---------------------------------------------------

@test "notify_discord_no_work does not call curl when DISCORD_WEBHOOK_URL is empty" {
    DISCORD_WEBHOOK_URL=""
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_no_work
    [ "${status}" -eq 0 ]
    [ ! -f "${args_log}" ]
}

@test "notify_discord_no_work calls curl with content payload" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_no_work
    [ "${status}" -eq 0 ]
    grep -q "https://discord.example.com/hook" "${args_log}"
    grep -q "No actionable work items found" "${args_log}"
}

@test "notify_discord_no_work prefixes message with owner when owner argument provided" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_no_work "credfeto"
    [ "${status}" -eq 0 ]
    grep -q "\[credfeto\] No actionable work items found" "${args_log}"
}

@test "notify_discord_no_work omits prefix when no owner argument provided" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_no_work
    [ "${status}" -eq 0 ]
    # Should NOT have bracket-prefixed owner
    run grep -q "\[.*\] No actionable" "${args_log}"
    [ "${status}" -ne 0 ]
    grep -q "No actionable work items found" "${args_log}"
}

@test "notify_discord_no_work appends blocked count when count_blocked is non-zero" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_no_work "" 3 0 0 0
    [ "${status}" -eq 0 ]
    grep -q "No actionable work items found" "${args_log}"
    grep -q "blocked: 3" "${args_log}"
}

@test "notify_discord_no_work appends unchanged count when count_unchanged is non-zero" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_no_work "" 0 5 0 0
    [ "${status}" -eq 0 ]
    grep -q "No actionable work items found" "${args_log}"
    grep -q "unchanged: 5" "${args_log}"
}

@test "notify_discord_no_work appends repo-active count when count_active_repo is non-zero" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_no_work "" 0 0 2 0
    [ "${status}" -eq 0 ]
    grep -q "No actionable work items found" "${args_log}"
    grep -q "repo-active: 2" "${args_log}"
}

@test "notify_discord_no_work appends not-open count when count_not_open is non-zero" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_no_work "" 0 0 0 1
    [ "${status}" -eq 0 ]
    grep -q "No actionable work items found" "${args_log}"
    grep -q "not-open: 1" "${args_log}"
}

@test "notify_discord_no_work omits detail suffix when all counts are zero" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_no_work "" 0 0 0 0
    [ "${status}" -eq 0 ]
    grep -q "No actionable work items found" "${args_log}"
    run grep -q "blocked:\|unchanged:\|repo-active:\|not-open:" "${args_log}"
    [ "${status}" -ne 0 ]
}

@test "notify_discord_no_work includes all non-zero counts in detail" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_no_work "myorg" 2 3 1 4
    [ "${status}" -eq 0 ]
    grep -q "\[myorg\] No actionable work items found" "${args_log}"
    grep -q "blocked: 2" "${args_log}"
    grep -q "unchanged: 3" "${args_log}"
    grep -q "repo-active: 1" "${args_log}"
    grep -q "not-open: 4" "${args_log}"
}

@test "notify_discord_no_work suppresses duplicate message sent within the last hour" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    make_stub date "echo 1700000000"

    local args_log1="${TEST_TMP}/curl_first"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log1}'"
    run notify_discord_no_work "" 0 5 0 0
    [ "${status}" -eq 0 ]
    [ -f "${args_log1}" ]

    local args_log2="${TEST_TMP}/curl_second"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log2}'"
    run notify_discord_no_work "" 0 5 0 0
    [ "${status}" -eq 0 ]
    [ ! -f "${args_log2}" ]
}

@test "notify_discord_no_work resends same content after one hour has elapsed" {
    # Two sequential real calls with IDENTICAL args, so the second call's dedup_hash genuinely
    # matches the state file the first call wrote — this is what actually exercises the
    # elapsed-time branch (elapsed > 3600), rather than a placeholder hash that can never match
    # regardless of timing (#1291 review: the prior version of this test used a hand-seeded
    # placeholder hash and would still pass even if the elapsed-time check were broken).
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"

    make_stub date "echo 1700000000"
    local args_log1="${TEST_TMP}/curl_first"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log1}'"
    run notify_discord_no_work "" 0 0 0 0
    [ "${status}" -eq 0 ]
    [ -f "${args_log1}" ]

    make_stub date "echo 1700003601"   # 3601s later — just past the one-hour window
    local args_log2="${TEST_TMP}/curl_second"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log2}'"
    run notify_discord_no_work "" 0 0 0 0
    [ "${status}" -eq 0 ]
    [ -f "${args_log2}" ]
    grep -q "No actionable work items found" "${args_log2}"
}

@test "notify_discord_no_work sends different content immediately even within the last hour" {
    # Two sequential real calls with DIFFERENT args at the SAME timestamp, so the second call's
    # dedup_hash genuinely differs from the state file the first call wrote (#1291 review — see
    # rationale on the sibling elapsed-time test above).
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    make_stub date "echo 1700000000"

    local args_log1="${TEST_TMP}/curl_first"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log1}'"
    run notify_discord_no_work "" 0 0 0 0
    [ "${status}" -eq 0 ]
    [ -f "${args_log1}" ]

    local args_log2="${TEST_TMP}/curl_second"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log2}'"
    run notify_discord_no_work "" 0 5 0 0
    [ "${status}" -eq 0 ]
    [ -f "${args_log2}" ]
    grep -q "unchanged: 5" "${args_log2}"
}

@test "notify_discord_no_work saves a hash (not raw text) to disk after sending" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    make_stub curl "exit 0"
    make_stub date "echo 1700000000"

    run notify_discord_no_work "" 0 0 0 0
    [ "${status}" -eq 0 ]

    local state_file="${HOME}/.orchestrator/.no_work__global.state"
    [ -f "${state_file}" ]
    local stored_hash
    stored_hash=$(sed -n '1p' "${state_file}")
    # sha256 hex digest: 64 lowercase hex characters — the dedup key, not the message text
    # (#1291: the breakdown can now be multi-line and much larger than a single content string).
    [[ "${stored_hash}" =~ ^[0-9a-f]{64}$ ]]
    grep -q "1700000000" "${state_file}"
}

@test "notify_discord_no_work uses owner-scoped state file" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    make_stub date "echo 1700000000"

    local args_log1="${TEST_TMP}/curl_first"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log1}'"
    run notify_discord_no_work "myorg" 0 5 0 0
    [ "${status}" -eq 0 ]
    [ -f "${args_log1}" ]

    # Same message, same owner — should be suppressed
    local args_log2="${TEST_TMP}/curl_second"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log2}'"
    run notify_discord_no_work "myorg" 0 5 0 0
    [ "${status}" -eq 0 ]
    [ ! -f "${args_log2}" ]

    # Same message, different owner — should still send (different state file)
    local args_log3="${TEST_TMP}/curl_third"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log3}'"
    run notify_discord_no_work "otherorg" 0 5 0 0
    [ "${status}" -eq 0 ]
    grep -q "otherorg" "${args_log3}"
}

# --- notify_discord_no_work: per-item breakdown (#1291) ------------------------

@test "notify_discord_no_work includes item breakdown lines with a working link" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    local items='[{"type":"Issue","id":"42","repo":"org/repo","reason":"blocked - skipping"}]'
    run notify_discord_no_work "" 1 0 0 0 0 0 "${items}"
    [ "${status}" -eq 0 ]
    grep -q "Issue #42 in org/repo" "${args_log}"
    grep -q "https://github.com/org/repo/issues/42" "${args_log}"
    grep -q "blocked - skipping" "${args_log}"
}

@test "notify_discord_no_work omits breakdown lines when items_json is empty" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_no_work
    [ "${status}" -eq 0 ]
    run grep -q ' in .*):' "${args_log}"
    [ "${status}" -ne 0 ]
}

@test "notify_discord_no_work defaults items_json to an empty breakdown when omitted" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_no_work "" 1 0 0 0 0 0
    [ "${status}" -eq 0 ]
    grep -q "blocked: 1" "${args_log}"
}

@test "notify_discord_no_work suppresses identical items within the last hour" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    make_stub date "echo 1700000000"
    local items='[{"type":"Issue","id":"1","repo":"org/repo","reason":"unchanged - skipping"}]'

    local args_log1="${TEST_TMP}/curl_first"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log1}'"
    run notify_discord_no_work "" 0 1 0 0 0 0 "${items}"
    [ "${status}" -eq 0 ]
    [ -f "${args_log1}" ]

    local args_log2="${TEST_TMP}/curl_second"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log2}'"
    run notify_discord_no_work "" 0 1 0 0 0 0 "${items}"
    [ "${status}" -eq 0 ]
    [ ! -f "${args_log2}" ]
}

@test "notify_discord_no_work resends immediately when a single item's reason changes" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    make_stub date "echo 1700000000"

    local args_log1="${TEST_TMP}/curl_first"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log1}'"
    run notify_discord_no_work "" 0 1 0 0 0 0 '[{"type":"Issue","id":"1","repo":"org/repo","reason":"unchanged - skipping"}]'
    [ "${status}" -eq 0 ]
    [ -f "${args_log1}" ]

    local args_log2="${TEST_TMP}/curl_second"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log2}'"
    run notify_discord_no_work "" 0 1 0 0 0 0 '[{"type":"Issue","id":"1","repo":"org/repo","reason":"blocked - skipping"}]'
    [ "${status}" -eq 0 ]
    [ -f "${args_log2}" ]
    grep -q "blocked - skipping" "${args_log2}"
}

# --- record_item_status / serialize_item_status_log unit tests -----------------
# record_item_status is a pure function (outputs JSON, does not mutate a caller array) and
# serialize_item_status_log takes its entries as positional arguments (#1291 review: makes the
# data flow explicit at every call site instead of relying on bash's dynamic scoping).

@test "record_item_status outputs a compact JSON object for the given fields" {
    local obj
    obj=$(record_item_status "Issue" "42" "org/repo" "blocked - skipping")
    [ "$(printf '%s' "${obj}" | jq -r '.type')" = "Issue" ]
    [ "$(printf '%s' "${obj}" | jq -r '.id')" = "42" ]
    [ "$(printf '%s' "${obj}" | jq -r '.repo')" = "org/repo" ]
    [ "$(printf '%s' "${obj}" | jq -r '.reason')" = "blocked - skipping" ]
}

@test "serialize_item_status_log returns an empty JSON array when given no arguments" {
    [ "$(serialize_item_status_log)" = "[]" ]
}

@test "serialize_item_status_log combines multiple entries into one JSON array, in order" {
    local -a item_status_log=()
    item_status_log+=("$(record_item_status "Issue" "1" "org/repo" "reason one")")
    item_status_log+=("$(record_item_status "PullRequest" "2" "org/repo2" "reason two")")
    local combined
    combined=$(serialize_item_status_log "${item_status_log[@]}")
    [ "$(printf '%s' "${combined}" | jq 'length')" -eq 2 ]
    [ "$(printf '%s' "${combined}" | jq -r '.[0].id')" = "1" ]
    [ "$(printf '%s' "${combined}" | jq -r '.[1].id')" = "2" ]
}

# --- _build_no_work_item_breakdown unit tests -----------------------------------

@test "_build_no_work_item_breakdown returns empty for an empty items array" {
    [ -z "$(_build_no_work_item_breakdown '[]')" ]
}

@test "_build_no_work_item_breakdown builds one markdown line per item with a working link" {
    local items='[{"type":"Issue","id":"42","repo":"org/repo","reason":"blocked - skipping"}]'
    run _build_no_work_item_breakdown "${items}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "- [Issue #42 in org/repo](https://github.com/org/repo/issues/42): blocked - skipping" ]
}

@test "_build_no_work_item_breakdown uses each item's own repo for its link" {
    local items='[{"type":"PullRequest","id":"7","repo":"owner/other-repo","reason":"CI checks pending"}]'
    run _build_no_work_item_breakdown "${items}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"https://github.com/owner/other-repo/pull/7"* ]]
}

@test "_build_no_work_item_breakdown truncates and appends a trailer when over budget" {
    local items
    items=$(jq -cn '[range(0;400) | {type:"Issue", id:(.|tostring), repo:"org/repo", reason:"unchanged - skipping"}]')
    run _build_no_work_item_breakdown "${items}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"more (see the journal for full detail)"* ]]
    [[ "${output}" != *"Issue #399"* ]]

    # Assert the trailer's stated count and kept-item count actually add up to 400, and that a
    # substantial number of items were kept (not just one) — an off-by-one in the trailer count,
    # or a budget/line-length regression that keeps far fewer items than expected, would both
    # still pass the substring-only assertions above (#1291 review).
    local kept_count trailer_count
    kept_count=$(printf '%s\n' "${output}" | grep -c '^- \[Issue #')
    trailer_count=$(printf '%s\n' "${output}" | sed -n 's/^\.\.\. and \([0-9]\+\) more.*/\1/p')
    [ -n "${trailer_count}" ]
    [ "$(( kept_count + trailer_count ))" -eq 400 ]
    [ "${kept_count}" -gt 30 ]
}

# --- build_item_url: repo override (#1291) --------------------------------------

@test "build_item_url uses the explicit repo argument over REPO_FULL when given" {
    [ "$(build_item_url "Issue" "42" "other/repo")" = "https://github.com/other/repo/issues/42" ]
}

@test "build_item_url falls back to REPO_FULL when no repo argument is given" {
    [ "$(build_item_url "PullRequest" "17")" = "https://github.com/${REPO_FULL}/pull/17" ]
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

# --- notify_discord_blocked_item -----------------------------------------------

@test "notify_discord_blocked_item does not call curl when DISCORD_WEBHOOK_URL is empty" {
    DISCORD_WEBHOOK_URL=""
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_blocked_item "Issue" "42"
    [ "${status}" -eq 0 ]
    [ ! -f "${args_log}" ]
}

@test "notify_discord_blocked_item calls curl with embed payload for a blocked Issue" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    make_stub gh 'printf "{\"title\":\"T\",\"labels\":[],\"comments\":[]}"'
    run notify_discord_blocked_item "Issue" "42"
    [ "${status}" -eq 0 ]
    grep -q "https://discord.example.com/hook" "${args_log}"
    grep -q "https://github.com/org/repo/issues/42" "${args_log}"
    grep -q "Blocked" "${args_log}"
}

@test "notify_discord_blocked_item calls curl with embed payload for a blocked PullRequest" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    make_stub gh 'printf "{\"title\":\"T\",\"labels\":[],\"comments\":[]}"'
    run notify_discord_blocked_item "PullRequest" "7"
    [ "${status}" -eq 0 ]
    grep -q "https://github.com/org/repo/pull/7" "${args_log}"
    grep -q "Blocked" "${args_log}"
}

@test "notify_discord_blocked_item includes the item's priority label in the payload (#1136)" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    make_stub gh 'printf "{\"title\":\"T\",\"labels\":[{\"name\":\"Urgent\"}],\"comments\":[]}"'
    run notify_discord_blocked_item "Issue" "42"
    [ "${status}" -eq 0 ]
    grep -q "Priority" "${args_log}"
    grep -q "Urgent" "${args_log}"
}

@test "notify_discord_blocked_item defaults priority to Undefined when the label fetch fails (#1136)" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    make_stub gh 'exit 1'
    run notify_discord_blocked_item "Issue" "42"
    [ "${status}" -eq 0 ]
    grep -q "Priority" "${args_log}"
    grep -q "Undefined" "${args_log}"
}

@test "notify_discord_blocked_item uses the item's real title, not just type and number (#1140)" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    make_stub gh 'printf "{\"title\":\"Cache writes are not atomic\",\"labels\":[],\"comments\":[]}"'
    run notify_discord_blocked_item "Issue" "42"
    [ "${status}" -eq 0 ]
    grep -q "Blocked: Cache writes are not atomic" "${args_log}"
}

@test "notify_discord_blocked_item falls back to type and number when the title fetch fails (#1140)" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    make_stub gh 'exit 1'
    run notify_discord_blocked_item "Issue" "42"
    [ "${status}" -eq 0 ]
    grep -q "Blocked: Issue #42" "${args_log}"
}

@test "notify_discord_blocked_item uses an explicit reason when the caller provides one (#1140)" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    make_stub gh 'printf "{\"title\":\"T\",\"labels\":[],\"comments\":[{\"body\":\"unrelated latest comment\"}]}"'
    run notify_discord_blocked_item "Issue" "42" "CI checks have been pending for over 1440 minutes."
    [ "${status}" -eq 0 ]
    grep -q "CI checks have been pending for over 1440 minutes" "${args_log}"
    run grep -q "unrelated latest comment" "${args_log}"
    [ "${status}" -ne 0 ]
}

@test "notify_discord_blocked_item falls back to the item's most recent comment when no reason is given (#1140)" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    make_stub gh 'printf "{\"title\":\"T\",\"labels\":[],\"comments\":[{\"body\":\"first comment\"},{\"body\":\"most recent explanation\"}]}"'
    run notify_discord_blocked_item "Issue" "42"
    [ "${status}" -eq 0 ]
    grep -q "most recent explanation" "${args_log}"
    run grep -q "first comment" "${args_log}"
    [ "${status}" -ne 0 ]
}

@test "notify_discord_blocked_item shows a placeholder reason when there are no comments to fall back on (#1140)" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    make_stub gh 'printf "{\"title\":\"T\",\"labels\":[],\"comments\":[]}"'
    run notify_discord_blocked_item "Issue" "42"
    [ "${status}" -eq 0 ]
    grep -q "No reason found" "${args_log}"
}

@test "notify_discord_blocked_item truncates a very long reason to 900 characters (#1140)" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    make_stub gh 'printf "{\"title\":\"T\",\"labels\":[],\"comments\":[]}"'
    local long_reason
    long_reason=$(printf 'x%.0s' $(seq 1 2000))
    run notify_discord_blocked_item "Issue" "42" "${long_reason}"
    [ "${status}" -eq 0 ]
    run grep -q "$(printf 'x%.0s' $(seq 1 2000))" "${args_log}"
    [ "${status}" -ne 0 ]
    grep -q "$(printf 'x%.0s' $(seq 1 900))" "${args_log}"
}

@test "notify_discord_blocked_item truncates a very long title to stay under Discord's embed title limit (#1140 review)" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    local long_title
    long_title=$(printf 'y%.0s' $(seq 1 300))
    make_stub gh "printf '{\"title\":\"${long_title}\",\"labels\":[],\"comments\":[]}'"
    run notify_discord_blocked_item "Issue" "42"
    [ "${status}" -eq 0 ]
    run grep -q "$(printf 'y%.0s' $(seq 1 300))" "${args_log}"
    [ "${status}" -ne 0 ]
    grep -q "$(printf 'y%.0s' $(seq 1 240))" "${args_log}"
}

@test "notify_discord_blocked_item is silent on a repeat call while the item stays blocked" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    make_stub gh 'printf "{\"title\":\"T\",\"labels\":[],\"comments\":[]}"'

    notify_discord_blocked_item "Issue" "42"
    notify_discord_blocked_item "Issue" "42"

    # The webhook URL appears once per curl invocation; only the first call notifies.
    [ "$(grep -c 'https://discord.example.com/hook' "${args_log}")" -eq 1 ]
    [ -f "$(blocked_marker_file_path Issue 42)" ]
}

@test "notify_discord_blocked_item notifies again after clear_blocked_marker re-arms it" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    make_stub gh 'printf "{\"title\":\"T\",\"labels\":[],\"comments\":[]}"'

    notify_discord_blocked_item "Issue" "42"
    clear_blocked_marker "Issue" "42"
    [ ! -f "$(blocked_marker_file_path Issue 42)" ]
    notify_discord_blocked_item "Issue" "42"

    # Two distinct blocked spells — two notifications.
    [ "$(grep -c 'https://discord.example.com/hook' "${args_log}")" -eq 2 ]
}

@test "clear_blocked_marker on a missing marker is a silent no-op" {
    set_repo_context "org/repo"
    run clear_blocked_marker "PullRequest" "7"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
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
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf '99\n'; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    issue_json_has_blocked_label() { return 1; }
    fetch_pr_json()             { printf '{"state":"OPEN","title":"PR title","body":"","isDraft":false,"labels":[{"name":"Blocked"}],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}\n'; }
    pr_json_has_blocked_label() { return 0; }
    local _notif_log="${TEST_TMP}/notif_log"
    notify_discord_blocked_item() { printf 'type=%s id=%s\n' "$1" "$2" >> "${_notif_log}"; }

    run main
    [ "${status}" -eq 0 ]
    grep -q 'type=PullRequest id=99' "${_notif_log}"
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

# --- parse_reset_time ---------------------------------------------------------

@test "parse_reset_time returns empty for non-matching input" {
    run parse_reset_time "Some unrelated error message"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "parse_reset_time converts 3pm UTC to correct unix timestamp" {
    # Use UTC so the test is timezone-independent.
    local result
    result=$(parse_reset_time "You've hit your limit · resets 3pm (UTC)")
    [ -n "${result}" ]
    [[ "${result}" =~ ^[0-9]+$ ]]
    # The result must be in the future (either today at 15:00 UTC or tomorrow).
    local now_unix
    now_unix=$(date +%s)
    [ "${result}" -gt "${now_unix}" ]
}

@test "parse_reset_time converts 7:10pm UTC to correct unix timestamp" {
    result=$(parse_reset_time "You've hit your limit · resets 7:10pm (UTC)")
    [ -n "${result}" ]

    now_unix=$(date +%s)
    # Expected: today or tomorrow at 19:10:00 UTC
    expected_unix=$(date -u -d "today 19:10:00" +%s)
    if [ "${expected_unix}" -le "${now_unix}" ]; then
        expected_unix=$(date -u -d "tomorrow 19:10:00" +%s)
    fi
    [ "${result}" -eq "${expected_unix}" ]
}

@test "parse_reset_time converts 12am UTC to hour 0 and returns future timestamp" {
    local result
    result=$(parse_reset_time "hit your limit · resets 12am (UTC)")
    [ -n "${result}" ]
    [[ "${result}" =~ ^[0-9]+$ ]]
    local now_unix
    now_unix=$(date +%s)
    [ "${result}" -gt "${now_unix}" ]
}

@test "parse_reset_time converts 12pm UTC to hour 12 and returns future timestamp" {
    local result
    result=$(parse_reset_time "hit your limit · resets 12pm (UTC)")
    [ -n "${result}" ]
    [[ "${result}" =~ ^[0-9]+$ ]]
    local now_unix
    now_unix=$(date +%s)
    [ "${result}" -gt "${now_unix}" ]
}

@test "parse_reset_time converts 'Jul 3, 10pm (UTC)' to correct unix timestamp" {
    result=$(parse_reset_time "You've hit your limit · resets Jul 3, 10pm (UTC)")
    [ -n "${result}" ]
    expected_unix=$(date -u -d "Jul 3 22:00:00" +%s)
    [ "${result}" -eq "${expected_unix}" ]
}

@test "parse_reset_time converts 'Jul 3, 10:30am (UTC)' to correct unix timestamp" {
    result=$(parse_reset_time "You've hit your limit · resets Jul 3, 10:30am (UTC)")
    [ -n "${result}" ]
    expected_unix=$(date -u -d "Jul 3 10:30:00" +%s)
    [ "${result}" -eq "${expected_unix}" ]
}

@test "parse_reset_time rejects timezone strings with dangerous characters" {
    run parse_reset_time "resets 3pm (UTC;rm -rf /)"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

# --- handle_claude_is_error tmpfile cleanup -----------------------------------

@test "handle_claude_is_error removes tmpfile before dying on rate-limit (429)" {
    notify_discord_rate_limited()      { return 0; }
    save_rate_limit()                  { return 0; }
    report_unparseable_rate_limit()    { return 0; }

    local tmpfile
    tmpfile="$(mktemp "${TEST_TMP}/claude.XXXXXX.json")"
    printf '%s' '{"api_error_status":"429","result":"Claude AI usage limit reached"}' > "${tmpfile}"

    run handle_claude_is_error "${tmpfile}" "" "Issue" "1"
    # die exits non-zero.
    [ "${status}" -ne 0 ]
    # The temp file must not be leaked on the rate-limit path.
    [ ! -f "${tmpfile}" ]
}

@test "handle_claude_is_error removes tmpfile before dying on generic error" {
    notify_discord_claude_error() { return 0; }

    local tmpfile
    tmpfile="$(mktemp "${TEST_TMP}/claude.XXXXXX.json")"
    printf '%s' '{"api_error_status":"500","result":"internal error"}' > "${tmpfile}"

    run handle_claude_is_error "${tmpfile}" "" "PullRequest" "2"
    # die exits non-zero.
    [ "${status}" -ne 0 ]
    # The temp file must not be leaked on the generic-error path.
    [ ! -f "${tmpfile}" ]
}

# --- handle_claude_permission_denials (#1328) -----------------------------------

@test "handle_claude_permission_denials is a no-op when permission_denials is absent" {
    local tmpfile
    tmpfile="$(mktemp "${TEST_TMP}/claude.XXXXXX.json")"
    printf '%s' '{"is_error":false,"result":"done"}' > "${tmpfile}"

    local notify_log="${TEST_TMP}/denial_notify.log"
    notify_discord_permission_denials() { printf '%s\n' "$*" >> "${notify_log}"; }

    run handle_claude_permission_denials "${tmpfile}" "Issue" "42"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    [ ! -f "${notify_log}" ]
}

@test "handle_claude_permission_denials is a no-op when permission_denials is an empty array" {
    local tmpfile
    tmpfile="$(mktemp "${TEST_TMP}/claude.XXXXXX.json")"
    printf '%s' '{"is_error":false,"result":"done","permission_denials":[]}' > "${tmpfile}"

    local notify_log="${TEST_TMP}/denial_notify.log"
    notify_discord_permission_denials() { printf '%s\n' "$*" >> "${notify_log}"; }

    run handle_claude_permission_denials "${tmpfile}" "Issue" "42"
    [ "${status}" -eq 0 ]
    [ ! -f "${notify_log}" ]
}

@test "handle_claude_permission_denials logs and notifies on a single Bash denial" {
    local tmpfile
    tmpfile="$(mktemp "${TEST_TMP}/claude.XXXXXX.json")"
    printf '%s' '{"is_error":false,"result":"done","permission_denials":[{"tool_name":"Bash","tool_input":{"command":"git status"}}]}' > "${tmpfile}"

    local notify_log="${TEST_TMP}/denial_notify.log"
    notify_discord_permission_denials() { printf '%s\n' "$*" >> "${notify_log}"; }

    run handle_claude_permission_denials "${tmpfile}" "Issue" "42"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"1 permission denial"* ]]
    [[ "${output}" == *"Bash: git status"* ]]
    grep -q "Bash: git status" "${notify_log}"
    # The count is passed through as a trailing argument so the Discord embed can show it
    # rather than the reviewer only being able to infer it by counting summary lines.
    grep -q " 1\$" "${notify_log}"
}

@test "handle_claude_permission_denials summarizes multiple denials across different tools" {
    local tmpfile
    tmpfile="$(mktemp "${TEST_TMP}/claude.XXXXXX.json")"
    printf '%s' '{"is_error":false,"result":"done","permission_denials":[{"tool_name":"Bash","tool_input":{"command":"git status"}},{"tool_name":"Edit","tool_input":{"file_path":"/workspace/repo/.database"}}]}' > "${tmpfile}"

    local notify_log="${TEST_TMP}/denial_notify.log"
    notify_discord_permission_denials() { printf '%s\n' "$*" >> "${notify_log}"; }

    run handle_claude_permission_denials "${tmpfile}" "PullRequest" "7"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"2 permission denial"* ]]
    [[ "${output}" == *"Bash: git status"* ]]
    [[ "${output}" == *"Edit: /workspace/repo/.database"* ]]
    grep -q "Bash: git status" "${notify_log}"
    grep -q "Edit: /workspace/repo/.database" "${notify_log}"
    grep -q " 2\$" "${notify_log}"
}

@test "handle_claude_permission_denials does not remove the tmpfile (caller owns cleanup)" {
    local tmpfile
    tmpfile="$(mktemp "${TEST_TMP}/claude.XXXXXX.json")"
    printf '%s' '{"is_error":false,"result":"done","permission_denials":[{"tool_name":"Bash","tool_input":{"command":"git status"}}]}' > "${tmpfile}"

    notify_discord_permission_denials() { return 0; }

    run handle_claude_permission_denials "${tmpfile}" "Issue" "42"
    [ "${status}" -eq 0 ]
    [ -f "${tmpfile}" ]
}

@test "handle_claude_permission_denials survives a non-object tool_input without losing the rest of the batch (code review, #1328)" {
    # A scalar tool_input makes jq's .tool_input.command indexing a runtime error, not a null -
    # without normalizing tool_input to an object first, jq aborts the whole $d[] iteration on
    # the first such entry, and only entries before it would ever reach the summary.
    local tmpfile
    tmpfile="$(mktemp "${TEST_TMP}/claude.XXXXXX.json")"
    printf '%s' '{"is_error":false,"result":"done","permission_denials":[{"tool_name":"Bash","tool_input":"not-an-object"},{"tool_name":"Bash","tool_input":{"command":"echo hi"}}]}' > "${tmpfile}"

    local notify_log="${TEST_TMP}/denial_notify.log"
    notify_discord_permission_denials() { printf '%s\n' "$*" >> "${notify_log}"; }

    run handle_claude_permission_denials "${tmpfile}" "Issue" "42"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"2 permission denial"* ]]
    [[ "${output}" == *"Bash: not-an-object"* ]]
    [[ "${output}" == *"Bash: echo hi"* ]]
    grep -q "Bash: echo hi" "${notify_log}"
    grep -q " 2\$" "${notify_log}"
}

@test "handle_claude_permission_denials survives a non-object denial ARRAY ELEMENT without losing the rest of the batch (code review, #1328)" {
    # A bare string (or number, etc.) sitting directly in the permission_denials array - not
    # inside tool_input, the array element itself - makes jq's .tool_name/.tool_input indexing a
    # runtime error, not a null: without coercing every $d[] element to an object first, jq
    # aborts the whole iteration on the first such entry and every denial after it is silently
    # dropped from the summary with no indication anything went wrong.
    local tmpfile
    tmpfile="$(mktemp "${TEST_TMP}/claude.XXXXXX.json")"
    printf '%s' '{"is_error":false,"result":"done","permission_denials":["a bare string entry",{"tool_name":"Bash","tool_input":{"command":"echo hi"}}]}' > "${tmpfile}"

    local notify_log="${TEST_TMP}/denial_notify.log"
    notify_discord_permission_denials() { printf '%s\n' "$*" >> "${notify_log}"; }

    run handle_claude_permission_denials "${tmpfile}" "Issue" "42"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"2 permission denial"* ]]
    [[ "${output}" == *"malformed-denial-entry"* ]]
    [[ "${output}" == *"Bash: echo hi"* ]]
    grep -q "Bash: echo hi" "${notify_log}"
    grep -q " 2\$" "${notify_log}"
}

@test "handle_claude_permission_denials collapses an embedded newline in a denied command to a single summary line" {
    # Without collapsing embedded newlines, a multi-line denied command (or a malformed entry's
    # raw JSON dump) would break the "one denial = one summary line" invariant the bash-side
    # line-count derivation of denials_count depends on.
    local tmpfile
    tmpfile="$(mktemp "${TEST_TMP}/claude.XXXXXX.json")"
    printf '%s' '{"is_error":false,"result":"done","permission_denials":[{"tool_name":"Bash","tool_input":{"command":"echo one\necho two"}},{"tool_name":"Bash","tool_input":{"command":"echo three"}}]}' > "${tmpfile}"

    local notify_log="${TEST_TMP}/denial_notify.log"
    notify_discord_permission_denials() { printf '%s\n' "$*" >> "${notify_log}"; }

    run handle_claude_permission_denials "${tmpfile}" "Issue" "42"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"2 permission denial"* ]]
    [[ "${output}" == *"Bash: echo one echo two"* ]]
    grep -q " 2\$" "${notify_log}"
}

@test "handle_claude_permission_denials truncates an oversized tool_input dump instead of logging it unbounded" {
    local tmpfile long_value
    tmpfile="$(mktemp "${TEST_TMP}/claude.XXXXXX.json")"
    long_value=$(printf 'x%.0s' $(seq 1 500))
    printf '{"is_error":false,"result":"done","permission_denials":[{"tool_name":"WebFetch","tool_input":{"url":"%s"}}]}' "${long_value}" > "${tmpfile}"

    notify_discord_permission_denials() { return 0; }

    run handle_claude_permission_denials "${tmpfile}" "Issue" "42"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"...(truncated)"* ]]
    [[ "${output}" != *"${long_value}"* ]]
}

@test "handle_claude_permission_denials falls back to {} rendering for a null or absent tool_input" {
    local tmpfile
    tmpfile="$(mktemp "${TEST_TMP}/claude.XXXXXX.json")"
    printf '%s' '{"is_error":false,"result":"done","permission_denials":[{"tool_name":"Weird","tool_input":null},{"tool_name":"NoInput"}]}' > "${tmpfile}"

    notify_discord_permission_denials() { return 0; }

    run handle_claude_permission_denials "${tmpfile}" "Issue" "42"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"2 permission denial"* ]]
    [[ "${output}" == *"Weird: {}"* ]]
    [[ "${output}" == *"NoInput: {}"* ]]
}

# --- report_unparseable_rate_limit --------------------------------------------

@test "handle_claude_is_error does not call report_unparseable_rate_limit when parse_reset_time succeeds" {
    # A parseable 429 message (resets 3pm UTC) → save_rate_limit is called, no GH issue raised.
    save_rate_limit()               { return 0; }
    notify_discord_rate_limited()   { return 0; }

    local gh_log="${TEST_TMP}/gh_calls"
    make_stub gh "printf '%s\n' \"\$@\" >> '${gh_log}'"

    local tmpfile
    tmpfile="$(mktemp "${TEST_TMP}/claude.XXXXXX.json")"
    printf '%s' '{"api_error_status":"429","result":"You'"'"'ve hit your Sonnet limit · resets 3pm (UTC)"}' > "${tmpfile}"

    run handle_claude_is_error "${tmpfile}" "" "Issue" "42"
    # Still fails (rate-limited).
    [ "${status}" -ne 0 ]
    # gh must NOT have been called — no tracking issue created.
    [ ! -f "${gh_log}" ] || [ ! -s "${gh_log}" ]
}

# --- claude_result_indicates_background_stall (#1326/#1335) --------------------

@test "claude_result_indicates_background_stall matches every confirmed #215 incident phrasing" {
    local texts=(
        "The pre-commit baseline check (buildcheck + build) is still running in the background. I'll pause here and wait for the Monitor notification when it completes before proceeding to branch creation and the draft PR."
        "Waiting for the backgrounded pre-commit baseline check to finish; the Monitor will notify me when it completes."
        "I'll pause here and wait for the pre-commit Monitor task to notify me before continuing."
        "Still waiting on the background pre-commit/test run to complete."
        "I'll skip detailed task tracking overhead and just wait for the baseline check notification before proceeding."
        "I'm now waiting on the mandatory Pre-Work Baseline Check (pre-commit --all-files, running in background) to finish before creating the branch — I'll continue automatically once that completes."
    )
    local t
    for t in "${texts[@]}"; do
        run claude_result_indicates_background_stall "${t}"
        [ "${status}" -eq 0 ] || { echo "expected match for: ${t}"; false; }
    done
}

@test "claude_result_indicates_background_stall matches the #1374 recurrence phrasing that slipped past the #215 patterns" {
    local texts=(
        "Build and monitor are running in the background — I'll pick this up once the completion notification arrives."
        "I'll pick it up once the background test run finishes."
        "I'll resume once the background job completes."
        "I'll continue this once the background check finishes."
    )
    local t
    for t in "${texts[@]}"; do
        run claude_result_indicates_background_stall "${t}"
        [ "${status}" -eq 0 ] || { echo "expected match for: ${t}"; false; }
    done
}

@test "claude_result_indicates_background_stall matches when the background/monitor mention precedes the resume phrase, not just follows it" {
    # The four cases above all happen to satisfy the anchor-after alternative
    # (I.ll ...[^.]*(background|monitor|notification)) on its own - none of them isolate the
    # anchor-before alternative added alongside it. Confirmed by testing the anchor-after
    # pattern alone against all four: it matches every one, so this repo's own coverage never
    # actually exercised the anchor-before branch. This case only matches via anchor-before.
    run claude_result_indicates_background_stall "The build is running in the background; I'll resume when it finishes."
    [ "${status}" -eq 0 ]
}

@test "claude_result_indicates_background_stall does not match legitimate GitHub-side stop reasons" {
    local texts=(
        "PHASE H complete: PR #216 was still a draft, so it was moved out of draft and auto-merge was enabled, with a status comment posted. Stopping here per phase discipline — the next cycle will pick up once GitHub settles this state."
        "Auto-merge is already enabled and no other phase applies — the PR is ready and just waiting on the required human review/checks, which is expected branch-protection behavior."
        "Phase F (Security review) is complete: security review found no findings, board advanced from AI Security Review to AI Coverage. Per phase discipline, stopping here — the next cycle will pick up PHASE G (Coverage)."
        "Work on issue #177 is complete for this cycle. Opened draft PR #216, assigned myself. Updated Workflow board status to Development."
        "Issue #244 is blocked pending explicit human approval — done for this session."
        "Waiting for a human to review and approve the plan before proceeding."
        "PR #99 CI checks pending — deferring to the next cycle when GitHub settles."
        ""
    )
    local t
    for t in "${texts[@]}"; do
        run claude_result_indicates_background_stall "${t}"
        [ "${status}" -ne 0 ] || { echo "expected no match for: ${t}"; false; }
    done
}

@test "claude_result_indicates_background_stall does not match an ordinary 'I'll resume/continue ... once/when' sentence unrelated to backgrounding" {
    # Simplify-review finding on #1376: the first version of the #1374 fix added
    # `I.ll (pick (this|it) up|resume|continue this)[^.]*(once|when|after)` with no
    # background/monitor/notification anchor, so it matched any ordinary "I'll resume/continue
    # X once/when Y" sentence regardless of subject matter - the exact false-positive shape the
    # function's own header comment forbids. These three are all confirmed false positives of
    # that unanchored version.
    local texts=(
        "I'll resume the migration script once the schema review is done, then continue with the rollout."
        "I'll continue this work once code review comments land."
        "I'll resume tomorrow once I have more context."
    )
    local t
    for t in "${texts[@]}"; do
        run claude_result_indicates_background_stall "${t}"
        [ "${status}" -ne 0 ] || { echo "expected no match for: ${t}"; false; }
    done
}

# --- background-stall marker (lib/state, #1326/#1335) ---------------------------

@test "background_stall_marked is false when no marker file exists" {
    run background_stall_marked "Issue" "42"
    [ "${status}" -ne 0 ]
}

@test "mark_background_stall then background_stall_marked round-trips" {
    mark_background_stall "Issue" "42"
    run background_stall_marked "Issue" "42"
    [ "${status}" -eq 0 ]
}

@test "clear_background_stall_marker removes the marker" {
    mark_background_stall "PullRequest" "7"
    clear_background_stall_marker "PullRequest" "7"
    run background_stall_marked "PullRequest" "7"
    [ "${status}" -ne 0 ]
}

@test "clear_background_stall_marker is a no-op when no marker exists" {
    run clear_background_stall_marker "Issue" "99"
    [ "${status}" -eq 0 ]
}

@test "background_stall marker is keyed independently per item type and id" {
    mark_background_stall "Issue" "1"
    run background_stall_marked "PullRequest" "1"
    [ "${status}" -ne 0 ]
    run background_stall_marked "Issue" "2"
    [ "${status}" -ne 0 ]
}

@test "report_unparseable_rate_limit creates a new issue when no open tracking issue exists" {
    local gh_log="${TEST_TMP}/gh_args"
    # Stub: gh issue list outputs nothing (no open tracker found after jq filtering).
    # All other gh calls (issue create) have their args logged.
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
if [ "\$1" = "issue" ] && [ "\$2" = "list" ]; then
    exit 0
fi
printf '%s\n' "\$@" >> '${gh_log}'
STUBEOF
    chmod +x "${STUB_BIN}/gh"

    local raw_msg="Rate limit reached — unknown format with no reset time"
    report_unparseable_rate_limit "Issue" "7" "${raw_msg}"

    [ -f "${gh_log}" ]
    # gh issue create must have been called with the expected flags.
    grep -q "^create$" "${gh_log}"
    grep -q "^${RATE_LIMIT_ISSUE_TITLE}$" "${gh_log}"
    grep -q "^AI-Work$" "${gh_log}"
    grep -q "^${RATE_LIMIT_ISSUE_REPO}$" "${gh_log}"
    # The verbatim raw message must appear in the body.
    grep -q "${raw_msg}" "${gh_log}"
    # gh issue comment must NOT have been called.
    run grep -q "^comment$" "${gh_log}"
    [ "${status}" -ne 0 ]
}

@test "report_unparseable_rate_limit appends to existing open tracking issue" {
    local tracker_number=99
    local gh_log="${TEST_TMP}/gh_args"
    # Stub: gh issue list outputs just the issue number (simulating jq-filtered output from gh).
    # All other gh calls (issue comment) have their args logged.
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
if [ "\$1" = "issue" ] && [ "\$2" = "list" ]; then
    printf '%s\n' '${tracker_number}'
    exit 0
fi
printf '%s\n' "\$@" >> '${gh_log}'
STUBEOF
    chmod +x "${STUB_BIN}/gh"

    local raw_msg="Some brand-new unparseable Claude 429 message"
    report_unparseable_rate_limit "PullRequest" "15" "${raw_msg}"

    [ -f "${gh_log}" ]
    # gh issue comment must have been called with the existing issue number.
    grep -q "^comment$" "${gh_log}"
    grep -q "^${tracker_number}$" "${gh_log}"
    # The verbatim raw message must appear in the body.
    grep -q "${raw_msg}" "${gh_log}"
    # gh issue create must NOT have been called.
    run grep -q "^create$" "${gh_log}"
    [ "${status}" -ne 0 ]
}

# --- rate-limit file management -----------------------------------------------

@test "is_owner_rate_limited returns false when no rate-limit file exists" {
    run is_owner_rate_limited
    [ "${status}" -ne 0 ]
}

@test "is_owner_rate_limited returns true when file has a future timestamp" {
    local future_unix
    future_unix=$(( $(date +%s) + 3600 ))
    mkdir -p "${HOME}/.orchestrator/${OWNER}"
    printf '%s\n' "${future_unix}" > "${HOME}/.orchestrator/${OWNER}/rate-limit"
    run is_owner_rate_limited
    [ "${status}" -eq 0 ]
}

@test "is_owner_rate_limited returns false and removes file when timestamp is in the past" {
    local past_unix
    past_unix=$(( $(date +%s) - 60 ))
    mkdir -p "${HOME}/.orchestrator/${OWNER}"
    local rate_file="${HOME}/.orchestrator/${OWNER}/rate-limit"
    printf '%s\n' "${past_unix}" > "${rate_file}"
    run is_owner_rate_limited
    [ "${status}" -ne 0 ]
    [ ! -f "${rate_file}" ]
}

@test "is_owner_rate_limited returns false and removes file when content is non-numeric" {
    mkdir -p "${HOME}/.orchestrator/${OWNER}"
    local rate_file="${HOME}/.orchestrator/${OWNER}/rate-limit"
    printf 'not-a-number\n' > "${rate_file}"
    run is_owner_rate_limited
    [ "${status}" -ne 0 ]
    [ ! -f "${rate_file}" ]
}

# --- notify_discord_rate_limited -----------------------------------------------

@test "notify_discord_rate_limited does not call curl when DISCORD_WEBHOOK_URL is empty" {
    DISCORD_WEBHOOK_URL=""
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_rate_limited "Issue" "42" "You've hit your Sonnet limit" ""
    [ "${status}" -eq 0 ]
    [ ! -f "${args_log}" ]
}

@test "notify_discord_rate_limited calls curl with embed including issue URL and error" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_rate_limited "Issue" "42" "You've hit your Sonnet limit" ""
    [ "${status}" -eq 0 ]
    grep -q "https://discord.example.com/hook" "${args_log}"
    grep -q "https://github.com/org/repo/issues/42" "${args_log}"
    grep -q "Sonnet limit" "${args_log}"
}

@test "notify_discord_rate_limited includes Discord timestamp markup when reset_unix is provided" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    set_repo_context "org/repo"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"
    run notify_discord_rate_limited "Issue" "42" "Sonnet limit" "1700000000"
    [ "${status}" -eq 0 ]
    grep -q '<t:1700000000:t>' "${args_log}"
    grep -q '<t:1700000000:R>' "${args_log}"
}

# --- invoke_claude 429 handling ------------------------------------------------

@test "invoke_claude saves rate-limit file and sends Discord notification on HTTP 429" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "pull" ] && exit 0
[ "$1" = "inspect" ] && exit 1
[ "$1" = "pull" ] && exit 0
printf '%s\n' '{"is_error":true,"api_error_status":429,"terminal_reason":"completed","session_id":"12345678-1234-1234-1234-123456789abc","result":"You'\''ve hit your Sonnet limit \u00b7 resets 3pm (UTC)"}'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"rate limited"* ]]
    grep -q "https://discord.example.com/hook" "${args_log}"
}

@test "invoke_claude persists rate-limit file on HTTP 429 so subsequent runs skip the owner" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "pull" ] && exit 0
[ "$1" = "inspect" ] && exit 1
[ "$1" = "pull" ] && exit 0
printf '%s\n' '{"is_error":true,"api_error_status":429,"terminal_reason":"completed","session_id":"12345678-1234-1234-1234-123456789abc","result":"You'\''ve hit your Sonnet limit \u00b7 resets 3pm (UTC)"}'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    DISCORD_WEBHOOK_URL=""
    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -ne 0 ]
    # Rate-limit file must exist and contain reset_time + 1hr buffer, both in the future.
    local rate_file="${HOME}/.orchestrator/${OWNER}/rate-limit"
    [ -f "${rate_file}" ]
    local saved_unix
    saved_unix=$(cat "${rate_file}")
    [[ "${saved_unix}" =~ ^[0-9]+$ ]]
    local now_unix
    now_unix=$(date +%s)
    [ "${saved_unix}" -gt "${now_unix}" ]
    # Buffer must be at least RATE_LIMIT_RESUME_BUFFER_SECS (3600) seconds from now.
    [ "${saved_unix}" -ge "$((now_unix + RATE_LIMIT_RESUME_BUFFER_SECS))" ]
}

@test "invoke_claude saves rate-limit file when Claude CLI exits non-zero with 429 JSON on new session" {
    # Reproduces the production failure: Claude writes valid is_error JSON but exits 1.
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "pull" ] && exit 0
[ "$1" = "inspect" ] && exit 1
printf '%s\n' '{"type":"result","is_error":true,"api_error_status":429,"terminal_reason":"completed","session_id":"12345678-1234-1234-1234-123456789abc","result":"You'\''ve hit your Sonnet limit · resets 3pm (UTC)"}'
exit 1
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    DISCORD_WEBHOOK_URL=""
    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -ne 0 ]
    local rate_file="${HOME}/.orchestrator/${OWNER}/rate-limit"
    [ -f "${rate_file}" ]
    local saved_unix
    saved_unix=$(cat "${rate_file}")
    [[ "${saved_unix}" =~ ^[0-9]+$ ]]
    local now_unix
    now_unix=$(date +%s)
    [ "${saved_unix}" -gt "${now_unix}" ]
}

@test "invoke_claude sends Discord notification when Claude CLI exits non-zero with 429 JSON" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "pull" ] && exit 0
[ "$1" = "inspect" ] && exit 1
printf '%s\n' '{"type":"result","is_error":true,"api_error_status":429,"terminal_reason":"completed","session_id":"12345678-1234-1234-1234-123456789abc","result":"You'\''ve hit your Sonnet limit · resets 3pm (UTC)"}'
exit 1
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    DISCORD_WEBHOOK_URL="https://discord.example.com/hook"
    local args_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> '${args_log}'"

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -ne 0 ]
    grep -q "https://discord.example.com/hook" "${args_log}"
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

@test "main does not block a plan-approved Issue on idle exhaustion when another open PR occupies the repo (#1326)" {
    setup_main_mocks
    recover_orphaned_branch() { return 1; }
    resolve_resumable_issue_branch() { return 1; }
    issue_plan_approved() { printf 'true'; }
    issue_plan_approved_or_later() { printf 'true'; }

    fetch_all_priorities() {
        printf '[{"id":42,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]\n'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    find_any_open_pr_for_repo()        { printf '99\n'; }
    fetch_issue_json() {
        printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'
    }
    issue_json_has_blocked_label() { return 1; }
    fingerprint_issue_json()      { printf 'same-fp\n'; }
    load_issue_fingerprint()      { printf 'same-fp\n'; }
    save_issue_invocation_counts 42 4 "${MAX_ISSUE_IDLE_INVOCATIONS}"
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"idle budget exhausted but another open PR occupies the repo's active-branch slot — deferring, not blocking"* ]]
    [[ "${output}" != *"idle budget exhausted with plan approved but no progress — blocking"* ]]
    [ ! -f "${GH_CALL_LOG}" ] || ! grep -q 'add-label Blocked' "${GH_CALL_LOG}"
    [ ! -f "${GH_CALL_LOG}" ] || ! grep -q 'issue comment' "${GH_CALL_LOG}"
}

@test "main does not block a plan-approved Issue on idle exhaustion when the occupying-PR check itself fails (#1326)" {
    setup_main_mocks
    recover_orphaned_branch() { return 1; }
    resolve_resumable_issue_branch() { return 1; }
    issue_plan_approved() { printf 'true'; }
    issue_plan_approved_or_later() { printf 'true'; }

    fetch_all_priorities() {
        printf '[{"id":42,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]\n'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    find_any_open_pr_for_repo()        { return 1; }
    fetch_issue_json() {
        printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'
    }
    issue_json_has_blocked_label() { return 1; }
    fingerprint_issue_json()      { printf 'same-fp\n'; }
    load_issue_fingerprint()      { printf 'same-fp\n'; }
    save_issue_invocation_counts 42 4 "${MAX_ISSUE_IDLE_INVOCATIONS}"
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"Failed to check for an occupying PR in org/repo — not blocking Issue #42 on an uncertain read"* ]]
    [[ "${output}" != *"idle budget exhausted with plan approved but no progress — blocking"* ]]
    [ ! -f "${GH_CALL_LOG}" ] || ! grep -q 'add-label Blocked' "${GH_CALL_LOG}"
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

# --- load_env_config git identity tests ----------------------------------------

@test "load_env_config reads GIT_USER_NAME from .env" {
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf 'GIT_USER_NAME=Alice\n' > "${XDG_CONFIG_HOME}/orchestrator/.env"
    load_env_config
    [ "${GIT_USER_NAME}" = "Alice" ]
}

@test "load_env_config reads GIT_USER_EMAIL from .env" {
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf 'GIT_USER_EMAIL=alice@example.com\n' > "${XDG_CONFIG_HOME}/orchestrator/.env"
    load_env_config
    [ "${GIT_USER_EMAIL}" = "alice@example.com" ]
}

@test "load_env_config reads GIT_SIGNING_KEY from .env" {
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf 'GIT_SIGNING_KEY=ABCD1234\n' > "${XDG_CONFIG_HOME}/orchestrator/.env"
    load_env_config
    [ "${GIT_SIGNING_KEY}" = "ABCD1234" ]
}

@test "load_env_config leaves git identity vars empty when absent from .env" {
    mkdir -p "${XDG_CONFIG_HOME}/orchestrator"
    printf 'DISCORD_WEBHOOK=https://example.com/hook\n' > "${XDG_CONFIG_HOME}/orchestrator/.env"
    load_env_config
    [ -z "${GIT_USER_NAME}" ]
    [ -z "${GIT_USER_EMAIL}" ]
    [ -z "${GIT_SIGNING_KEY}" ]
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

make_gpg_stubs() {
    local extra_socket="${TEST_TMP}/S.gpg-agent.extra"
    # Create a real socket file so [ -S ] passes.
    python3 -c "import socket,os; s=socket.socket(socket.AF_UNIX); s.bind('${extra_socket}')"
    cat > "${STUB_BIN}/gpgconf" << STUBEOF
#!/usr/bin/env bash
printf '%s\n' "${extra_socket}"
STUBEOF
    chmod +x "${STUB_BIN}/gpgconf"
    cat > "${STUB_BIN}/gpg" << 'STUBEOF'
#!/usr/bin/env bash
# Simulate export producing real bytes, import succeeding, and key listing succeeding.
if [[ "$*" == *"--export"* ]]; then
    printf 'FAKEPUBKEYDATA\n'
    exit 0
fi
if [[ "$*" == *"--import"* ]]; then
    exit 0
fi
if [[ "$*" == *"--list-secret-keys"* ]]; then
    exit 0
fi
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/gpg"
    make_stub gpg-connect-agent 'exit 0'
}

# --- build_item_url unit tests --------------------------------------------------

@test "build_item_url builds an issues URL for an Issue" {
    [ "$(build_item_url "Issue" "42")" = "https://github.com/${REPO_FULL}/issues/42" ]
}

@test "build_item_url builds a pull URL for a PullRequest" {
    [ "$(build_item_url "PullRequest" "17")" = "https://github.com/${REPO_FULL}/pull/17" ]
}

@test "build_item_url falls back to the bare repo URL for an unrecognised item_type" {
    [ "$(build_item_url "" "")" = "https://github.com/${REPO_FULL}" ]
}

# --- invoke_claude git identity env var passing --------------------------------

@test "invoke_claude passes GIT_USER_NAME as container env var when set" {
    local args_log="${TEST_TMP}/podman_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    GIT_USER_NAME="Alice"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
[ "\$1" = "pull" ] && exit 0
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    invoke_claude "test prompt" "" "" "# mock CLAUDE.md" 2>/dev/null
    grep -qx 'GIT_USER_NAME=Alice' "${args_log}"
}

@test "invoke_claude passes CLAUDE_CODE_AUTO_COMPACT_WINDOW as container env var (#1070)" {
    local args_log="${TEST_TMP}/podman_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
[ "\$1" = "pull" ] && exit 0
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    invoke_claude "test prompt" "" "" "# mock CLAUDE.md" 2>/dev/null
    grep -qx 'CLAUDE_CODE_AUTO_COMPACT_WINDOW=100000' "${args_log}"
}

@test "invoke_claude respects a CLAUDE_CODE_AUTO_COMPACT_WINDOW override from the environment (#1070)" {
    local args_log="${TEST_TMP}/podman_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    CLAUDE_CODE_AUTO_COMPACT_WINDOW=50000
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
[ "\$1" = "pull" ] && exit 0
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    invoke_claude "test prompt" "" "" "# mock CLAUDE.md" 2>/dev/null
    grep -qx 'CLAUDE_CODE_AUTO_COMPACT_WINDOW=50000' "${args_log}"
}

@test "invoke_claude passes GIT_USER_EMAIL as container env var when set" {
    local args_log="${TEST_TMP}/podman_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    GIT_USER_EMAIL="alice@example.com"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
[ "\$1" = "pull" ] && exit 0
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    invoke_claude "test prompt" "" "" "# mock CLAUDE.md" 2>/dev/null
    grep -qx 'GIT_USER_EMAIL=alice@example.com' "${args_log}"
}

@test "invoke_claude passes GIT_SIGNING_KEY as container env var when set" {
    local args_log="${TEST_TMP}/podman_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    GIT_SIGNING_KEY="ABCD1234"
    make_gpg_stubs
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "secret" ] && exit 0
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    invoke_claude "test prompt" "" "" "# mock CLAUDE.md" 2>/dev/null
    grep -qx 'GIT_SIGNING_KEY=ABCD1234' "${args_log}"
}

@test "invoke_claude does not pass GIT_USER_NAME when not set" {
    local args_log="${TEST_TMP}/podman_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    GIT_USER_NAME=""
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
[ "\$1" = "pull" ] && exit 0
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    invoke_claude "test prompt" "" "" "# mock CLAUDE.md" 2>/dev/null
    run grep -qx 'GIT_USER_NAME=' "${args_log}"
    [ "${status}" -ne 0 ]
}

@test "invoke_claude passes WORK_ITEM_URL as container env var for an Issue" {
    local args_log="${TEST_TMP}/podman_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md" 2>/dev/null
    grep -qx "WORK_ITEM_URL=https://github.com/${REPO_FULL}/issues/42" "${args_log}"
}

@test "invoke_claude passes WORK_ITEM_URL as container env var for a PullRequest" {
    local args_log="${TEST_TMP}/podman_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    invoke_claude "test prompt" "PullRequest" "17" "# mock CLAUDE.md" 2>/dev/null
    grep -qx "WORK_ITEM_URL=https://github.com/${REPO_FULL}/pull/17" "${args_log}"
}

@test "invoke_claude does not pass WORK_ITEM_URL when item_type and item_id are empty" {
    local args_log="${TEST_TMP}/podman_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    invoke_claude "test prompt" "" "" "# mock CLAUDE.md" 2>/dev/null
    run grep -q 'WORK_ITEM_URL=' "${args_log}"
    [ "${status}" -ne 0 ]
}

@test "invoke_claude does not mount the host HOME gitconfig" {
    local args_log="${TEST_TMP}/podman_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
[ "\$1" = "pull" ] && exit 0
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    invoke_claude "test prompt" "" "" "# mock CLAUDE.md" 2>/dev/null
    run grep -qF ".gitconfig" "${args_log}"
    [ "${status}" -ne 0 ]
}

# --- add_gpg_podman_args unit tests --------------------------------------------

@test "add_gpg_podman_args uses socket forwarding when extra socket and signing key are available" {
    make_gpg_stubs
    PODMAN_RUN_ARGS=()
    GIT_SIGNING_KEY="ABCD1234"
    add_gpg_podman_args
    # Should contain at least one --volume arg referencing /home/developer/.gnupg
    local found=0
    for arg in "${PODMAN_RUN_ARGS[@]}"; do
        [[ "${arg}" == *":/home/developer/.gnupg"* ]] && found=1
    done
    [ "${found}" -eq 1 ]
}

@test "add_gpg_podman_args mounts extra socket at /home/developer/.gnupg/S.gpg-agent:ro" {
    make_gpg_stubs
    PODMAN_RUN_ARGS=()
    GIT_SIGNING_KEY="ABCD1234"
    add_gpg_podman_args
    local found=0
    for arg in "${PODMAN_RUN_ARGS[@]}"; do
        [[ "${arg}" == *":/home/developer/.gnupg/S.gpg-agent:ro"* ]] && found=1
    done
    [ "${found}" -eq 1 ]
}

@test "add_gpg_podman_args sets GPG_PUBKEY_TMPDIR when forwarding succeeds" {
    make_gpg_stubs
    PODMAN_RUN_ARGS=()
    GIT_SIGNING_KEY="ABCD1234"
    GPG_PUBKEY_TMPDIR=""
    add_gpg_podman_args
    [ -n "${GPG_PUBKEY_TMPDIR}" ]
    [ -d "${GPG_PUBKEY_TMPDIR}" ]
}

@test "add_gpg_podman_args creates GPG_PUBKEY_TMPDIR under XDG_RUNTIME_DIR when set" {
    make_gpg_stubs
    export XDG_RUNTIME_DIR="${TEST_TMP}/runtime"
    mkdir -p "${XDG_RUNTIME_DIR}"
    PODMAN_RUN_ARGS=()
    GIT_SIGNING_KEY="ABCD1234"
    GPG_PUBKEY_TMPDIR=""
    add_gpg_podman_args
    [ -n "${GPG_PUBKEY_TMPDIR}" ]
    [[ "${GPG_PUBKEY_TMPDIR}" == "${XDG_RUNTIME_DIR}/"* ]]
}

@test "add_gpg_podman_args dies when extra socket is absent and GIT_SIGNING_KEY is set" {
    # No gpgconf stub → gpgconf fails, extra_socket is empty, [ -S "" ] is false.
    make_stub gpgconf 'exit 1'
    mkdir -p "${HOME}/.gnupg"
    PODMAN_RUN_ARGS=()
    GIT_SIGNING_KEY="ABCD1234"
    run add_gpg_podman_args
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"GPG agent extra socket not available"* ]]
    # No ~/.gnupg mount should be added — there is no safe fallback
    local found=0
    for arg in "${PODMAN_RUN_ARGS[@]}"; do
        [[ "${arg}" == *".gnupg"* ]] && found=1
    done
    [ "${found}" -eq 0 ]
}

@test "add_gpg_podman_args dies when gpg export fails" {
    local extra_socket="${TEST_TMP}/S.gpg-agent.extra"
    python3 -c "import socket,os; s=socket.socket(socket.AF_UNIX); s.bind('${extra_socket}')"
    cat > "${STUB_BIN}/gpgconf" << STUBEOF
#!/usr/bin/env bash
printf '%s\n' "${extra_socket}"
STUBEOF
    chmod +x "${STUB_BIN}/gpgconf"
    # gpg export produces empty output → import fails
    cat > "${STUB_BIN}/gpg" << 'STUBEOF'
#!/usr/bin/env bash
if [[ "$*" == *"--export"* ]]; then printf ''; exit 0; fi
if [[ "$*" == *"--import"* ]]; then exit 1; fi
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/gpg"
    mkdir -p "${HOME}/.gnupg"
    PODMAN_RUN_ARGS=()
    GIT_SIGNING_KEY="ABCD1234"
    run add_gpg_podman_args
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"GPG public key export/import failed"* ]]
    # No ~/.gnupg mount should be added — there is no safe fallback
    local found=0
    for arg in "${PODMAN_RUN_ARGS[@]}"; do
        [[ "${arg}" == *".gnupg"* ]] && found=1
    done
    [ "${found}" -eq 0 ]
}

@test "add_gpg_podman_args skips all mounts when GIT_SIGNING_KEY is empty and ~/.gnupg absent" {
    make_stub gpgconf 'exit 1'
    PODMAN_RUN_ARGS=()
    GIT_SIGNING_KEY=""
    add_gpg_podman_args 2>/dev/null
    local found=0
    for arg in "${PODMAN_RUN_ARGS[@]}"; do
        [[ "${arg}" == *".gnupg"* ]] && found=1
    done
    [ "${found}" -eq 0 ]
}

@test "add_gpg_podman_args prefers XDG_RUNTIME_DIR socket over gpgconf path when available" {
    local runtime_socket="${TEST_TMP}/runtime/gnupg/S.gpg-agent.extra"
    mkdir -p "${TEST_TMP}/runtime/gnupg"
    python3 -c "import socket,os; s=socket.socket(socket.AF_UNIX); s.bind('${runtime_socket}')"
    # gpgconf returns a path with no actual socket; the XDG runtime path should win.
    make_stub gpgconf 'printf "/no/such/socket\n"'
    cat > "${STUB_BIN}/gpg" << 'STUBEOF'
#!/usr/bin/env bash
if [[ "$*" == *"--export"* ]]; then printf 'FAKEPUBKEYDATA\n'; exit 0; fi
if [[ "$*" == *"--import"* ]]; then exit 0; fi
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/gpg"
    export XDG_RUNTIME_DIR="${TEST_TMP}/runtime"
    PODMAN_RUN_ARGS=()
    GIT_SIGNING_KEY="ABCD1234"
    add_gpg_podman_args
    local found=0
    for arg in "${PODMAN_RUN_ARGS[@]}"; do
        [[ "${arg}" == "${runtime_socket}"* ]] && found=1
    done
    [ "${found}" -eq 1 ]
}

@test "add_gpg_podman_args GPG_PUBKEY_TMPDIR is cleaned up by invoke_claude on success" {
    make_gpg_stubs
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/jq" << 'JQEOF'
#!/usr/bin/env bash
case "$2" in
    '.is_error // false')    printf 'false\n' ;;
    '.result // ""')         printf '\n' ;;
    '.session_id // empty')  printf '12345678-1234-1234-1234-123456789abc\n' ;;
esac
JQEOF
    chmod +x "${STUB_BIN}/jq"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "inspect" ] && exit 1
[ "$1" = "pull" ] && exit 0
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    GIT_SIGNING_KEY="ABCD1234"
    GPG_PUBKEY_TMPDIR=""
    invoke_claude "test prompt" "" "" "# per-item instructions" 2>/dev/null
    [ -z "${GPG_PUBKEY_TMPDIR}" ]
}

# --- preload_ssh_keys unit tests ----------------------------------------------

@test "preload_ssh_keys is a no-op when SSH_AUTH_SOCK is unset" {
    unset SSH_AUTH_SOCK
    make_stub ssh-add 'exit 1'
    run preload_ssh_keys
    [ "${status}" -eq 0 ]
}

@test "preload_ssh_keys is a no-op when SSH_AUTH_SOCK is not a socket" {
    export SSH_AUTH_SOCK="${TEST_TMP}/not-a-socket"
    make_stub ssh-add 'exit 1'
    run preload_ssh_keys
    [ "${status}" -eq 0 ]
}

@test "preload_ssh_keys is a no-op when keys are already loaded (ssh-add -l exits 0)" {
    local ssh_sock="${TEST_TMP}/ssh-agent.sock"
    python3 -c "import socket,os; s=socket.socket(socket.AF_UNIX); s.bind('${ssh_sock}')"
    export SSH_AUTH_SOCK="${ssh_sock}"
    # ssh-add -l returns 0 = keys present; ssh-add (load) should never be called
    cat > "${STUB_BIN}/ssh-add" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "-l" ] && exit 0
exit 1
STUBEOF
    chmod +x "${STUB_BIN}/ssh-add"
    run preload_ssh_keys
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"could not load"* ]]
}

@test "preload_ssh_keys calls ssh-add when agent has no keys (ssh-add -l exits 1)" {
    local ssh_sock="${TEST_TMP}/ssh-agent.sock"
    python3 -c "import socket,os; s=socket.socket(socket.AF_UNIX); s.bind('${ssh_sock}')"
    export SSH_AUTH_SOCK="${ssh_sock}"
    local add_log="${TEST_TMP}/ssh-add.log"
    cat > "${STUB_BIN}/ssh-add" << STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${add_log}"
[ "\$1" = "-l" ] && exit 1
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/ssh-add"
    preload_ssh_keys
    grep -qx "\-q" "${add_log}"
}

@test "preload_ssh_keys dies when ssh-add fails to load keys" {
    local ssh_sock="${TEST_TMP}/ssh-agent.sock"
    python3 -c "import socket,os; s=socket.socket(socket.AF_UNIX); s.bind('${ssh_sock}')"
    export SSH_AUTH_SOCK="${ssh_sock}"
    cat > "${STUB_BIN}/ssh-add" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "-l" ] && exit 1
exit 1
STUBEOF
    chmod +x "${STUB_BIN}/ssh-add"
    run preload_ssh_keys
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"no SSH keys could be loaded"* ]]
}

@test "preload_ssh_keys dies rather than silently passing when ssh-add cannot connect to the agent (exit 2, #1103)" {
    local ssh_sock="${TEST_TMP}/ssh-agent.sock"
    python3 -c "import socket,os; s=socket.socket(socket.AF_UNIX); s.bind('${ssh_sock}')"
    export SSH_AUTH_SOCK="${ssh_sock}"
    # Exit 2 = "cannot connect to the agent" — a dead/stale socket. This must not be treated
    # like exit 0 (already loaded); it must fail fast on the host instead of letting a dead
    # socket get mounted into every agent container.
    cat > "${STUB_BIN}/ssh-add" << 'STUBEOF'
#!/usr/bin/env bash
exit 2
STUBEOF
    chmod +x "${STUB_BIN}/ssh-add"
    run preload_ssh_keys
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"cannot connect to the agent"* ]]
}

# --- stop_ssh_agent unit tests ------------------------------------------------

@test "stop_ssh_agent is a no-op when SSH_AUTH_SOCK is unset" {
    unset SSH_AUTH_SOCK
    local pkill_log="${TEST_TMP}/pkill.log"
    make_stub pkill "printf '%s\n' \"\$*\" >> \"${pkill_log}\""
    run stop_ssh_agent
    [ "${status}" -eq 0 ]
    [ ! -f "${pkill_log}" ]
}

@test "stop_ssh_agent calls pkill scoped to its own user and socket when SSH_AUTH_SOCK is set (#1122)" {
    export SSH_AUTH_SOCK="${TEST_TMP}/ssh-agent.sock"
    local pkill_log="${TEST_TMP}/pkill.log"
    make_stub pkill "printf '%s\n' \"\$*\" >> \"${pkill_log}\"; exit 0"
    stop_ssh_agent
    grep -qxe "-u $(id -un) -f ssh-agent -a ${SSH_AUTH_SOCK}" "${pkill_log}"
}

@test "stop_ssh_agent succeeds even when pkill finds no process" {
    export SSH_AUTH_SOCK="${TEST_TMP}/ssh-agent.sock"
    make_stub pkill 'exit 1'
    run stop_ssh_agent
    [ "${status}" -eq 0 ]
}

@test "stop_ssh_agent does not kill an unrelated ssh-agent bound to a different socket (#1122)" {
    local decoy_sock="${TEST_TMP}/decoy-agent.sock"
    ssh-agent -a "${decoy_sock}" > /dev/null
    local decoy_pid
    decoy_pid=$(pgrep -u "$(id -un)" -f "ssh-agent -a ${decoy_sock}")
    [ -n "${decoy_pid}" ]

    export SSH_AUTH_SOCK="${TEST_TMP}/this-run-agent.sock"
    stop_ssh_agent

    local still_alive=0
    kill -0 "${decoy_pid}" 2>/dev/null || still_alive=1
    kill "${decoy_pid}" 2>/dev/null || true
    [ "${still_alive}" -eq 0 ]
}

# --- cleanup_dangling_images unit tests ---------------------------------------

@test "cleanup_dangling_images calls podman image prune --force" {
    local args_log="${TEST_TMP}/podman_args"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "image" ] && printf '%s\n' "\$@" >> "${args_log}" && exit 0
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/podman"
    cleanup_dangling_images
    [ -f "${args_log}" ]
    grep -qFx 'image' "${args_log}"
    grep -qFx 'prune' "${args_log}"
    grep -qFx -- '--force' "${args_log}"
}

@test "cleanup_dangling_images succeeds even when podman image prune fails" {
    make_stub podman 'exit 1'
    run cleanup_dangling_images
    [ "${status}" -eq 0 ]
}

@test "invoke_claude falls back to the cached image when podman pull fails but the image exists locally (#1090)" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "inspect" ] && exit 1
[ "$1" = "pull" ] && exit 1
[ "$1" = "image" ] && [ "$2" = "exists" ] && exit 0
[ "$1" = "image" ] && exit 0
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"falling back to the cached local image"* ]]
}

@test "invoke_claude dies when podman pull fails and no cached image exists locally (#1090)" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "inspect" ] && exit 1
[ "$1" = "pull" ] && exit 1
[ "$1" = "image" ] && [ "$2" = "exists" ] && exit 1
[ "$1" = "image" ] && exit 0
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"no cached local image is available"* ]]
}

@test "invoke_claude notifies Discord before dying when podman pull fails and no cached image exists locally (#1103)" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "inspect" ] && exit 1
[ "$1" = "pull" ] && exit 1
[ "$1" = "image" ] && [ "$2" = "exists" ] && exit 1
[ "$1" = "image" ] && exit 0
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    local notify_log="${TEST_TMP}/notify.log"
    notify_discord_claude_error() { printf '%s\n' "$*" >> "${notify_log}"; }

    run invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md"
    [ "${status}" -ne 0 ]
    grep -q "no cached local image is available" "${notify_log}"
}

@test "invoke_claude prunes dangling images before pulling the orchestrator image" {
    local call_log="${TEST_TMP}/podman_calls"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "image" ]   && printf 'image_prune\n'  >> "${call_log}" && exit 0
[ "\$1" = "pull" ]    && printf 'pull\n'         >> "${call_log}" && exit 0
[ "\$1" = "inspect" ] && exit 1
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"
    invoke_claude "test prompt" "" "" "# mock CLAUDE.md" 2>/dev/null
    [ -f "${call_log}" ]
    local prune_line pull_line
    prune_line=$(grep -n 'image_prune' "${call_log}" | head -1 | cut -d: -f1)
    pull_line=$(grep -n 'pull' "${call_log}" | head -1 | cut -d: -f1)
    [ -n "${prune_line}" ]
    [ -n "${pull_line}" ]
    [ "${prune_line}" -lt "${pull_line}" ]
}

@test "invoke_claude prunes dangling images twice per run (before pull and after container exits)" {
    local call_log="${TEST_TMP}/podman_calls"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "image" ]   && printf 'image_prune\n'  >> "${call_log}" && exit 0
[ "\$1" = "pull" ]    && exit 0
[ "\$1" = "inspect" ] && exit 1
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"
    invoke_claude "test prompt" "" "" "# mock CLAUDE.md" 2>/dev/null
    [ -f "${call_log}" ]
    local count
    count=$(grep -c 'image_prune' "${call_log}")
    [ "${count}" -eq 2 ]
}

# --- SSH agent socket forwarding unit tests -----------------------------------

@test "invoke_claude mounts SSH_AUTH_SOCK as /tmp/ssh-agent.sock and sets env var" {
    local args_log="${TEST_TMP}/podman_args"
    local ssh_sock="${TEST_TMP}/ssh-agent.sock"
    python3 -c "import socket,os; s=socket.socket(socket.AF_UNIX); s.bind('${ssh_sock}')"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    SSH_AUTH_SOCK="${ssh_sock}"
    # stop_ssh_agent runs as an EXIT trap inside invoke_claude — stub pkill so the
    # trap never reaches the real system binary (#1122).
    make_stub pkill 'exit 1'
    make_gpg_stubs
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"
    GIT_SIGNING_KEY=""
    invoke_claude "test prompt" "" "" "# mock CLAUDE.md" 2>/dev/null
    grep -q "${ssh_sock}:/tmp/ssh-agent.sock:ro" "${args_log}"
    grep -qx "SSH_AUTH_SOCK=/tmp/ssh-agent.sock" "${args_log}"
}

@test "invoke_claude warns and skips SSH mount when SSH_AUTH_SOCK is unset" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    unset SSH_AUTH_SOCK
    make_gpg_stubs
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "pull" ] && exit 0
[ "$1" = "inspect" ] && exit 1
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"
    GIT_SIGNING_KEY=""
    run invoke_claude "test prompt" "" "" "# mock CLAUDE.md"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"SSH_AUTH_SOCK is not set"* ]]
}

@test "invoke_claude warns and skips SSH mount when SSH_AUTH_SOCK path is not a socket" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    export SSH_AUTH_SOCK="${TEST_TMP}/nonexistent-sock"
    # stop_ssh_agent runs as an EXIT trap inside invoke_claude even though the
    # socket path is bogus — SSH_AUTH_SOCK is still non-empty. Stub pkill so the
    # trap never reaches the real system binary (#1122).
    make_stub pkill 'exit 1'
    make_gpg_stubs
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "pull" ] && exit 0
[ "$1" = "inspect" ] && exit 1
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"
    GIT_SIGNING_KEY=""
    run invoke_claude "test prompt" "" "" "# mock CLAUDE.md"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"SSH_AUTH_SOCK is not set or socket is absent"* ]]
}

@test "invoke_claude does not mount ~/.ssh directory" {
    local args_log="${TEST_TMP}/podman_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}" "${HOME}/.ssh"
    unset SSH_AUTH_SOCK
    make_gpg_stubs
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"
    GIT_SIGNING_KEY=""
    invoke_claude "test prompt" "" "" "# mock CLAUDE.md" 2>/dev/null
    run grep -q "\.ssh:/home/developer/.ssh" "${args_log}"
    [ "${status}" -ne 0 ]
}

# --- $HOME/.database mount tests ----------------------------------------------

@test "invoke_claude mounts \$HOME/.database read-only when file exists" {
    local args_log="${TEST_TMP}/podman_args"
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    printf 'fake-db-credentials\n' > "${HOME}/.database"
    unset SSH_AUTH_SOCK
    make_gpg_stubs
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
printf "%s\n" "\$@" >> "${args_log}"
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"
    GIT_SIGNING_KEY=""
    invoke_claude "test prompt" "" "" "# mock CLAUDE.md" 2>/dev/null
    grep -q "${HOME}/.database:/home/developer/.database:ro" "${args_log}"
}

@test "invoke_claude warns and skips .database mount when \$HOME/.database is absent" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    /bin/rm -f "${HOME}/.database"
    unset SSH_AUTH_SOCK
    make_gpg_stubs
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "pull" ] && exit 0
[ "$1" = "inspect" ] && exit 1
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"
    GIT_SIGNING_KEY=""
    run invoke_claude "test prompt" "" "" "# mock CLAUDE.md"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *".database not found"* ]]
}

# --- invoke_claude prompt-file and empty-prompt guards ------------------------

@test "invoke_claude dies before starting podman when prompt is empty" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    local podman_log="${TEST_TMP}/podman_calls"
    cat > "${STUB_BIN}/podman" << STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "${podman_log}"
[ "\$1" = "pull" ] && exit 0
[ "\$1" = "inspect" ] && exit 1
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"
    run invoke_claude "" "" "" "# mock CLAUDE.md"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Prompt is empty"* ]]
    run grep -qx "run" "${podman_log}"
    [ "${status}" -ne 0 ]
}

@test "invoke_claude sets CLAUDE_PROMPT to the prompt text before starting the container" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "pull" ]    && exit 0
[ "$1" = "inspect" ] && exit 1
[ "$1" = "secret" ]  && exit 0
[ "$1" = "image" ]   && exit 0
printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
STUBEOF
    chmod +x "${STUB_BIN}/podman"
    invoke_claude "hello from prompt" "" "" "# mock CLAUDE.md" 2>/dev/null
    [ "${CLAUDE_PROMPT}" = "hello from prompt" ]
}

# --- notify_github_blocked unit tests -----------------------------------------

@test "notify_github_blocked posts issue comment and adds Blocked label for Issue" {
    cat > "${STUB_BIN}/gh" << 'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TEST_TMP}/gh.log"
GHEOF
    chmod +x "${STUB_BIN}/gh"
    REPO_FULL="owner/repo"
    notify_github_blocked "Issue" "42" "test message"
    grep -q "issue comment 42 --repo owner/repo" "${TEST_TMP}/gh.log"
    grep -q "issue edit 42 --repo owner/repo --add-label Blocked" "${TEST_TMP}/gh.log"
}

@test "notify_github_blocked posts pr comment and adds Blocked label for PullRequest" {
    cat > "${STUB_BIN}/gh" << 'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TEST_TMP}/gh.log"
GHEOF
    chmod +x "${STUB_BIN}/gh"
    REPO_FULL="owner/repo"
    notify_github_blocked "PullRequest" "7" "test message"
    grep -q "pr comment 7 --repo owner/repo" "${TEST_TMP}/gh.log"
    grep -q "pr edit 7 --repo owner/repo --add-label Blocked" "${TEST_TMP}/gh.log"
}

@test "notify_github_blocked is silent when item_type is empty" {
    cat > "${STUB_BIN}/gh" << 'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TEST_TMP}/gh.log"
GHEOF
    chmod +x "${STUB_BIN}/gh"
    REPO_FULL="owner/repo"
    notify_github_blocked "" "42" "test message"
    [ ! -f "${TEST_TMP}/gh.log" ]
}

# --- verify_gpg_signing_ready unit tests --------------------------------------

@test "verify_gpg_signing_ready passes when agent is running and key is present" {
    make_stub gpg-connect-agent 'exit 0'
    make_stub gpg 'exit 0'
    GIT_SIGNING_KEY="ABCD1234"
    run verify_gpg_signing_ready "" ""
    [ "${status}" -eq 0 ]
}

@test "verify_gpg_signing_ready is a no-op when GIT_SIGNING_KEY is empty" {
    make_stub gpg-connect-agent 'exit 1'
    GIT_SIGNING_KEY=""
    run verify_gpg_signing_ready "" ""
    [ "${status}" -eq 0 ]
}

@test "verify_gpg_signing_ready dies when gpg-agent is not running" {
    make_stub gpg-connect-agent 'exit 1'
    make_stub gh 'exit 0'
    GIT_SIGNING_KEY="ABCD1234"
    run verify_gpg_signing_ready "" ""
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"gpg-agent is not running"* ]]
}

@test "verify_gpg_signing_ready dies when signing key is absent from keyring" {
    make_stub gpg-connect-agent 'exit 0'
    cat > "${STUB_BIN}/gpg" << 'STUBEOF'
#!/usr/bin/env bash
if [[ "$*" == *"--list-secret-keys"* ]]; then exit 1; fi
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/gpg"
    make_stub gh 'exit 0'
    GIT_SIGNING_KEY="ABCD1234"
    run verify_gpg_signing_ready "" ""
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"not found in GPG keyring"* ]]
}

@test "verify_gpg_signing_ready notifies GitHub when gpg-agent is not running" {
    make_stub gpg-connect-agent 'exit 1'
    cat > "${STUB_BIN}/gh" << 'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TEST_TMP}/gh.log"
GHEOF
    chmod +x "${STUB_BIN}/gh"
    REPO_FULL="owner/repo"
    GIT_SIGNING_KEY="ABCD1234"
    run verify_gpg_signing_ready "Issue" "42"
    [ "${status}" -ne 0 ]
    [ -f "${TEST_TMP}/gh.log" ]
    grep -q "issue comment 42 --repo owner/repo" "${TEST_TMP}/gh.log"
}

@test "verify_gpg_signing_ready notifies GitHub when signing key is absent" {
    make_stub gpg-connect-agent 'exit 0'
    cat > "${STUB_BIN}/gpg" << 'STUBEOF'
#!/usr/bin/env bash
if [[ "$*" == *"--list-secret-keys"* ]]; then exit 1; fi
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/gpg"
    cat > "${STUB_BIN}/gh" << 'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TEST_TMP}/gh.log"
GHEOF
    chmod +x "${STUB_BIN}/gh"
    REPO_FULL="owner/repo"
    GIT_SIGNING_KEY="ABCD1234"
    run verify_gpg_signing_ready "Issue" "42"
    [ "${status}" -ne 0 ]
    [ -f "${TEST_TMP}/gh.log" ]
    grep -q "issue comment 42 --repo owner/repo" "${TEST_TMP}/gh.log"
}

# --- ensure_repo_current: SSH URL enforcement ---------------------------------

@test "ensure_repo_current resets HTTPS origin URL to SSH before fetching" {
    mkdir -p "${REPO_WORK_DIR}/.git"
    local git_log="${TEST_TMP}/git_calls"
    # PATH stub avoids shell function override (which triggers SC2218 on earlier
    # real git calls in the file) and avoids real git operations in temp dirs
    # that fail in CI due to GIT_CONFIG_GLOBAL safe.directory restrictions.
    cat > "${STUB_BIN}/git" << STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${git_log}"
for arg in "\$@"; do [ "\${arg}" = "--show-current" ] && { printf 'main\n'; exit 0; }; done
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/git"
    # Flush the bash hash table so PATH is re-searched for git; without this
    # the subshell created by `run` inherits the cached real-git path and
    # bypasses the stub.
    hash git

    run ensure_repo_current
    [ "${status}" -eq 0 ]
    grep -q "config remote.origin.url git@github.com:${OWNER}/${REPO}.git" "${git_log}"
}

@test "ensure_repo_current clears all fetch and push URL entries before setting the canonical SSH URL" {
    mkdir -p "${REPO_WORK_DIR}/.git"
    local git_log="${TEST_TMP}/git_calls"
    cat > "${STUB_BIN}/git" << STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${git_log}"
for arg in "\$@"; do [ "\${arg}" = "--show-current" ] && { printf 'main\n'; exit 0; }; done
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/git"
    # Flush the bash hash table so PATH is re-searched for git; without this
    # the subshell created by `run` inherits the cached real-git path and
    # bypasses the stub.
    hash git

    run ensure_repo_current
    [ "${status}" -eq 0 ]
    # All existing fetch URLs must be removed first (--unset-all handles multiple entries).
    grep -q "config --unset-all remote.origin.url" "${git_log}"
    # Exactly the canonical SSH URL must be written as the sole fetch URL.
    grep -q "config remote.origin.url git@github.com:${REPO_FULL}.git" "${git_log}"
    # All push-URL overrides must be removed (--unset-all handles multiple entries).
    grep -q "config --unset-all remote.origin.pushurl" "${git_log}"
}

@test "ensure_repo_current unsets url pushInsteadOf rules left in local git config by a previous agent session" {
    mkdir -p "${REPO_WORK_DIR}/.git"
    local git_log="${TEST_TMP}/git_calls"
    cat > "${STUB_BIN}/git" << STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${git_log}"
for arg in "\$@"; do [ "\${arg}" = "--show-current" ] && { printf 'main\n'; exit 0; }; done
case "\$*" in
    *"--local --name-only --list"*)
        printf 'url.https://x-oauth-basic:@github.com/.pushinsteadof\n'
        exit 0
        ;;
esac
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/git"
    hash git

    run ensure_repo_current
    [ "${status}" -eq 0 ]
    grep -q -- "--local --unset-all url.https://x-oauth-basic:@github.com/.pushinsteadof" "${git_log}"
}

@test "ensure_repo_current returns 2 (not dies) when git fetch fails transiently (#1090)" {
    mkdir -p "${REPO_WORK_DIR}/.git"
    cat > "${STUB_BIN}/git" << 'STUBEOF'
#!/usr/bin/env bash
for arg in "$@"; do [ "${arg}" = "fetch" ] && exit 1; done
for arg in "$@"; do [ "${arg}" = "--show-current" ] && { printf 'main\n'; exit 0; }; done
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/git"
    hash git

    run ensure_repo_current
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"Failed to fetch from origin"* ]]
}

# --- ensure_rules_current (#1090) ---------------------------------------------

@test "ensure_rules_current returns 1 (not dies) when the pull fails transiently" {
    mkdir -p "${RULES_DIR}/.git"
    cat > "${STUB_BIN}/git" << 'STUBEOF'
#!/usr/bin/env bash
for arg in "$@"; do [ "${arg}" = "pull" ] && exit 1; done
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/git"
    hash git

    run ensure_rules_current
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Failed to update cs-template"* ]]
}

@test "ensure_rules_current returns 1 (not dies) when the initial clone fails transiently" {
    make_stub git 'exit 1'

    run ensure_rules_current
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Failed to clone cs-template"* ]]
}

@test "ensure_rules_current succeeds when checkout and pull both succeed" {
    mkdir -p "${RULES_DIR}/.git"
    make_stub git 'exit 0'

    run ensure_rules_current
    [ "${status}" -eq 0 ]
}

# --- disk_space_available_kb --------------------------------------------------

@test "disk_space_available_kb outputs a numeric value" {
    make_stub df 'printf "Filesystem 1K-blocks Used Available Use%% Mounted on\ntmpfs 4096000 1024 4094976 1%% /\n"'
    hash df
    run disk_space_available_kb
    [ "${status}" -eq 0 ]
    [[ "${output}" =~ ^[0-9]+$ ]]
}

@test "disk_space_available_kb uses WORK path when it exists" {
    mkdir -p "${TEST_TMP}/work"
    WORK="${TEST_TMP}/work"
    local df_log="${TEST_TMP}/df_calls"
    make_stub df "printf '%s\n' \"\$*\" >> ${df_log}; printf 'Filesystem 1K-blocks Used Available Use%% Mounted on\ntmpfs 4096000 1024 20971520 1%% /\n'"
    hash df
    run disk_space_available_kb
    [ "${status}" -eq 0 ]
    grep -q "${TEST_TMP}/work" "${df_log}"
}

@test "disk_space_available_kb falls back to HOME when WORK does not exist" {
    WORK="${TEST_TMP}/nonexistent"
    local df_log="${TEST_TMP}/df_calls"
    make_stub df "printf '%s\n' \"\$*\" >> ${df_log}; printf 'Filesystem 1K-blocks Used Available Use%% Mounted on\ntmpfs 4096000 1024 20971520 1%% /\n'"
    hash df
    run disk_space_available_kb
    [ "${status}" -eq 0 ]
    grep -q "${HOME}" "${df_log}"
}

# --- check_disk_space ---------------------------------------------------------

@test "check_disk_space returns 0 when space is above threshold" {
    # 20 GB available; MIN_DISK_SPACE_KB = 10 * 1024 * 1024 = 10485760
    disk_space_available_kb() { printf '20971520\n'; }
    run check_disk_space
    [ "${status}" -eq 0 ]
}

@test "check_disk_space returns 1 when space is below threshold" {
    # 5 GB available
    disk_space_available_kb() { printf '5242880\n'; }
    run check_disk_space
    [ "${status}" -ne 0 ]
}

@test "check_disk_space returns 0 when space equals threshold" {
    # Exactly 10 GB available
    disk_space_available_kb() { printf '10485760\n'; }
    run check_disk_space
    [ "${status}" -eq 0 ]
}

@test "check_disk_space warns and returns 0 when df output is unparseable" {
    disk_space_available_kb() { printf 'not-a-number\n'; }
    run check_disk_space
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Could not determine available disk space"* ]]
}

@test "check_disk_space warns and returns 0 when df output is empty" {
    disk_space_available_kb() { printf ''; }
    run check_disk_space
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Could not determine available disk space"* ]]
}

# --- notify_discord_low_disk_space --------------------------------------------

@test "notify_discord_low_disk_space does nothing when DISCORD_WEBHOOK_URL is unset" {
    DISCORD_WEBHOOK_URL=""
    disk_space_available_kb() { printf '5242880\n'; }
    local curl_log="${TEST_TMP}/curl_log"
    make_stub curl "printf 'called\n' >> ${curl_log}"
    hash curl
    run notify_discord_low_disk_space
    [ "${status}" -eq 0 ]
    [ ! -f "${curl_log}" ]
}

@test "notify_discord_low_disk_space sends embed when webhook is set and space is low" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    disk_space_available_kb() { printf '5242880\n'; }
    local curl_log="${TEST_TMP}/curl_log"
    make_stub curl "printf '%s\n' \"\$*\" >> ${curl_log}"
    hash curl
    run notify_discord_low_disk_space
    [ "${status}" -eq 0 ]
    [ -f "${curl_log}" ]
    grep -q "discord.example.com" "${curl_log}"
}

@test "notify_discord_low_disk_space includes owner in title when owner is provided" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    disk_space_available_kb() { printf '5242880\n'; }
    local curl_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> ${curl_log}"
    hash curl
    run notify_discord_low_disk_space "myowner"
    [ "${status}" -eq 0 ]
    [ -f "${curl_log}" ]
    grep -q "myowner" "${curl_log}"
}

@test "notify_discord_low_disk_space suppresses duplicate notification within 1 hour" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    disk_space_available_kb() { printf '5242880\n'; }
    local curl_log="${TEST_TMP}/curl_log"
    make_stub curl "printf 'called\n' >> ${curl_log}"
    hash curl

    # Write a state file with a timestamp from 30 minutes ago.
    mkdir -p "${HOME}/.orchestrator"
    printf '%s\n' "$(( $(date +%s) - 1800 ))" > "${HOME}/.orchestrator/.low_disk_space__global.state"

    run notify_discord_low_disk_space
    [ "${status}" -eq 0 ]
    [ ! -f "${curl_log}" ]
}

@test "notify_discord_low_disk_space resends after 1 hour has elapsed" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    disk_space_available_kb() { printf '5242880\n'; }
    local curl_log="${TEST_TMP}/curl_log"
    make_stub curl "printf 'called\n' >> ${curl_log}"
    hash curl

    # Write a state file with a timestamp from 90 minutes ago.
    mkdir -p "${HOME}/.orchestrator"
    printf '%s\n' "$(( $(date +%s) - 5400 ))" > "${HOME}/.orchestrator/.low_disk_space__global.state"

    run notify_discord_low_disk_space
    [ "${status}" -eq 0 ]
    [ -f "${curl_log}" ]
}

@test "notify_discord_low_disk_space does not record dedup state when the curl POST fails (#1171 review)" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    disk_space_available_kb() { printf '5242880\n'; }
    make_stub curl 'exit 1'
    hash curl

    run notify_discord_low_disk_space
    [ "${status}" -eq 0 ]
    [ ! -f "${HOME}/.orchestrator/.low_disk_space__global.state" ]
}

@test "notify_discord_low_disk_space uses owner-scoped state file" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    disk_space_available_kb() { printf '5242880\n'; }
    local curl_log="${TEST_TMP}/curl_log"
    make_stub curl "printf 'called\n' >> ${curl_log}"
    hash curl

    # Write a state file for a different owner — should not suppress this call.
    mkdir -p "${HOME}/.orchestrator"
    printf '%s\n' "$(( $(date +%s) - 1800 ))" > "${HOME}/.orchestrator/.low_disk_space_other_owner.state"

    run notify_discord_low_disk_space "myowner"
    [ "${status}" -eq 0 ]
    [ -f "${curl_log}" ]
}

# --- notify_discord_self_update_stale (#1298) ---------------------------------

@test "notify_discord_self_update_stale does nothing when DISCORD_WEBHOOK_URL is unset" {
    DISCORD_WEBHOOK_URL=""
    local curl_log="${TEST_TMP}/curl_log"
    make_stub curl "printf 'called\n' >> ${curl_log}"
    hash curl
    run notify_discord_self_update_stale "" "abc1234" "3"
    [ "${status}" -eq 0 ]
    [ ! -f "${curl_log}" ]
}

@test "notify_discord_self_update_stale sends embed with the commit sha and behind count when webhook is set" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    local curl_log="${TEST_TMP}/curl_log"
    make_stub curl "printf '%s\n' \"\$*\" >> ${curl_log}"
    hash curl
    run notify_discord_self_update_stale "" "abc1234" "3"
    [ "${status}" -eq 0 ]
    [ -f "${curl_log}" ]
    grep -q "discord.example.com" "${curl_log}"
    grep -q "abc1234" "${curl_log}"
}

@test "notify_discord_self_update_stale includes owner in title when owner is provided" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    local curl_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> ${curl_log}"
    hash curl
    run notify_discord_self_update_stale "myowner" "abc1234" "3"
    [ "${status}" -eq 0 ]
    [ -f "${curl_log}" ]
    grep -q "myowner" "${curl_log}"
}

@test "notify_discord_self_update_stale suppresses duplicate notification within 1 hour" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    local curl_log="${TEST_TMP}/curl_log"
    make_stub curl "printf 'called\n' >> ${curl_log}"
    hash curl

    # Write a state file with a timestamp from 30 minutes ago.
    mkdir -p "${HOME}/.orchestrator"
    printf '%s\n' "$(( $(date +%s) - 1800 ))" > "${HOME}/.orchestrator/.self_update_stale__global.state"

    run notify_discord_self_update_stale "" "abc1234" "3"
    [ "${status}" -eq 0 ]
    [ ! -f "${curl_log}" ]
}

@test "notify_discord_self_update_stale resends after 1 hour has elapsed" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    local curl_log="${TEST_TMP}/curl_log"
    make_stub curl "printf 'called\n' >> ${curl_log}"
    hash curl

    # Write a state file with a timestamp from 90 minutes ago.
    mkdir -p "${HOME}/.orchestrator"
    printf '%s\n' "$(( $(date +%s) - 5400 ))" > "${HOME}/.orchestrator/.self_update_stale__global.state"

    run notify_discord_self_update_stale "" "abc1234" "3"
    [ "${status}" -eq 0 ]
    [ -f "${curl_log}" ]
}

@test "notify_discord_self_update_stale does not record dedup state when the curl POST fails" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    make_stub curl 'exit 1'
    hash curl

    run notify_discord_self_update_stale "" "abc1234" "3"
    [ "${status}" -eq 0 ]
    [ ! -f "${HOME}/.orchestrator/.self_update_stale__global.state" ]
}

@test "notify_discord_self_update_stale uses owner-scoped state file" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    local curl_log="${TEST_TMP}/curl_log"
    make_stub curl "printf 'called\n' >> ${curl_log}"
    hash curl

    # Write a state file for a different owner — should not suppress this call.
    mkdir -p "${HOME}/.orchestrator"
    printf '%s\n' "$(( $(date +%s) - 1800 ))" > "${HOME}/.orchestrator/.self_update_stale_other_owner.state"

    run notify_discord_self_update_stale "myowner" "abc1234" "3"
    [ "${status}" -eq 0 ]
    [ -f "${curl_log}" ]
}

# --- notify_discord_priorities_unreachable --------------------------------------------

@test "notify_discord_priorities_unreachable does nothing when DISCORD_WEBHOOK_URL is unset" {
    DISCORD_WEBHOOK_URL=""
    local curl_log="${TEST_TMP}/curl_log"
    make_stub curl "printf 'called\n' >> ${curl_log}"
    hash curl
    run notify_discord_priorities_unreachable
    [ "${status}" -eq 0 ]
    [ ! -f "${curl_log}" ]
}

@test "notify_discord_priorities_unreachable sends embed referencing PRIORITIES_URL when webhook is set" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    local curl_log="${TEST_TMP}/curl_log"
    make_stub curl "printf '%s\n' \"\$*\" >> ${curl_log}"
    hash curl
    run notify_discord_priorities_unreachable
    [ "${status}" -eq 0 ]
    [ -f "${curl_log}" ]
    grep -q "discord.example.com" "${curl_log}"
    grep -q "${PRIORITIES_URL}" "${curl_log}"
}

@test "notify_discord_priorities_unreachable includes owner in title when owner is provided" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    local curl_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> ${curl_log}"
    hash curl
    run notify_discord_priorities_unreachable "myowner"
    [ "${status}" -eq 0 ]
    [ -f "${curl_log}" ]
    grep -q "myowner" "${curl_log}"
}

@test "notify_discord_priorities_unreachable suppresses duplicate notification within 1 hour" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    local curl_log="${TEST_TMP}/curl_log"
    make_stub curl "printf 'called\n' >> ${curl_log}"
    hash curl

    # Write a state file with a timestamp from 30 minutes ago.
    mkdir -p "${HOME}/.orchestrator"
    printf '%s\n' "$(( $(date +%s) - 1800 ))" > "${HOME}/.orchestrator/.priorities_unreachable__global.state"

    run notify_discord_priorities_unreachable
    [ "${status}" -eq 0 ]
    [ ! -f "${curl_log}" ]
}

@test "notify_discord_priorities_unreachable resends after 1 hour has elapsed" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    local curl_log="${TEST_TMP}/curl_log"
    make_stub curl "printf 'called\n' >> ${curl_log}"
    hash curl

    # Write a state file with a timestamp from 90 minutes ago.
    mkdir -p "${HOME}/.orchestrator"
    printf '%s\n' "$(( $(date +%s) - 5400 ))" > "${HOME}/.orchestrator/.priorities_unreachable__global.state"

    run notify_discord_priorities_unreachable
    [ "${status}" -eq 0 ]
    [ -f "${curl_log}" ]
}

@test "notify_discord_priorities_unreachable shares one dedup state file across owners (#1171 review)" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    local curl_log="${TEST_TMP}/curl_log"
    make_stub curl "printf 'called\n' >> ${curl_log}"
    hash curl

    # PRIORITIES_URL is one global endpoint, not per-owner — a recent alert for a different
    # owner must suppress this call too, rather than each owner getting its own hourly quota.
    mkdir -p "${HOME}/.orchestrator"
    printf '%s\n' "$(( $(date +%s) - 1800 ))" > "${HOME}/.orchestrator/.priorities_unreachable__global.state"

    run notify_discord_priorities_unreachable "myowner"
    [ "${status}" -eq 0 ]
    [ ! -f "${curl_log}" ]
}

# --- notify_discord_pr_needs_approval (#1278) ---------------------------------

@test "notify_discord_pr_needs_approval does nothing when DISCORD_WEBHOOK_URL is unset" {
    DISCORD_WEBHOOK_URL=""
    REPO_FULL="org/repo"
    local curl_log="${TEST_TMP}/curl_log"
    make_stub curl "printf 'called\n' >> ${curl_log}"
    hash curl
    run notify_discord_pr_needs_approval 397 '{"title":"Some PR title"}'
    [ "${status}" -eq 0 ]
    [ ! -f "${curl_log}" ]
}

@test "notify_discord_pr_needs_approval sends embed naming the PR and repo" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    REPO_FULL="org/repo"
    local curl_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> ${curl_log}"
    hash curl
    run notify_discord_pr_needs_approval 397 '{"title":"Some PR title"}'
    [ "${status}" -eq 0 ]
    [ -f "${curl_log}" ]
    grep -q "discord.example.com" "${curl_log}"
    grep -q "org/repo/pull/397" "${curl_log}"
    grep -q "Some PR title" "${curl_log}"
}

@test "notify_discord_pr_needs_approval suppresses duplicate notification within 1 hour" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    REPO_FULL="org/repo"
    local curl_log="${TEST_TMP}/curl_log"
    make_stub curl "printf 'called\n' >> ${curl_log}"
    hash curl

    mkdir -p "${HOME}/.orchestrator"
    printf '%s\n' "$(( $(date +%s) - 1800 ))" > "${HOME}/.orchestrator/.pr_needs_approval_org_repo_397.state"

    run notify_discord_pr_needs_approval 397 '{"title":"Some PR title"}'
    [ "${status}" -eq 0 ]
    [ ! -f "${curl_log}" ]
}

@test "notify_discord_pr_needs_approval resends after 1 hour has elapsed" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    REPO_FULL="org/repo"
    local curl_log="${TEST_TMP}/curl_log"
    make_stub curl "printf 'called\n' >> ${curl_log}"
    hash curl

    mkdir -p "${HOME}/.orchestrator"
    printf '%s\n' "$(( $(date +%s) - 5400 ))" > "${HOME}/.orchestrator/.pr_needs_approval_org_repo_397.state"

    run notify_discord_pr_needs_approval 397 '{"title":"Some PR title"}'
    [ "${status}" -eq 0 ]
    [ -f "${curl_log}" ]
}

@test "notify_discord_pr_needs_approval does not record dedup state when the curl POST fails" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    REPO_FULL="org/repo"
    make_stub curl 'exit 1'
    hash curl

    run notify_discord_pr_needs_approval 397 '{"title":"Some PR title"}'
    [ "${status}" -eq 0 ]
    [ ! -f "${HOME}/.orchestrator/.pr_needs_approval_org_repo_397.state" ]
}

@test "notify_discord_pr_needs_approval scopes its dedup state per repo-and-PR, not just PR number" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    REPO_FULL="org/repo"
    local curl_log="${TEST_TMP}/curl_log"
    make_stub curl "printf 'called\n' >> ${curl_log}"
    hash curl

    # A recent alert for PR #397 in a DIFFERENT repo must not suppress this call — same PR
    # number, different repo, is a different PR.
    mkdir -p "${HOME}/.orchestrator"
    printf '%s\n' "$(( $(date +%s) - 1800 ))" > "${HOME}/.orchestrator/.pr_needs_approval_other_repo_397.state"

    run notify_discord_pr_needs_approval 397 '{"title":"Some PR title"}'
    [ "${status}" -eq 0 ]
    [ -f "${curl_log}" ]
}

@test "notify_discord_pr_needs_approval falls back to a generic title when pr_json has none" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    REPO_FULL="org/repo"
    local curl_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> ${curl_log}"
    hash curl
    run notify_discord_pr_needs_approval 397 '{}'
    [ "${status}" -eq 0 ]
    grep -q "PullRequest #397" "${curl_log}"
}

@test "notify_discord_pr_needs_approval truncates an over-long title to stay under Discord's embed-title cap" {
    DISCORD_WEBHOOK_URL="https://discord.example.com/webhook"
    REPO_FULL="org/repo"
    local curl_log="${TEST_TMP}/curl_args"
    make_stub curl "printf '%s\n' \"\$@\" >> ${curl_log}"
    hash curl
    local long_title
    long_title=$(printf '%*s' 300 '' | tr ' ' 'x')
    run notify_discord_pr_needs_approval 397 "$(jq -n --arg t "${long_title}" '{title:$t}')"
    [ "${status}" -eq 0 ]
    # 240-char slice of the title, plus the "Needs Approval: " prefix, must appear; the raw
    # 300-char title must not (it would have been sliced down).
    grep -qE "x{240}" "${curl_log}"
    [ "$(grep -cE "x{300}" "${curl_log}")" -eq 0 ]
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
    # loop's or a manual invocation's shape, neither of which install-timer's ExecStartPre ran
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

# --- MAX_CODE_REVIEW_ITERATIONS / MAX_SECURITY_REVIEW_ITERATIONS / MAX_COVERAGE_ITERATIONS ----

@test "MAX_CODE_REVIEW_ITERATIONS defaults to 15" {
    [ "${MAX_CODE_REVIEW_ITERATIONS}" -eq 15 ]
}

@test "MAX_CODE_REVIEW_ITERATIONS can be overridden via environment variable" {
    MAX_CODE_REVIEW_ITERATIONS=5
    [ "${MAX_CODE_REVIEW_ITERATIONS}" -eq 5 ]
}

@test "MAX_CODE_REVIEW_ITERATIONS falls back to its default when given a non-numeric override" {
    export MAX_CODE_REVIEW_ITERATIONS="not-a-number"
    source_oneshot
    [ "${MAX_CODE_REVIEW_ITERATIONS}" -eq 15 ]
}

@test "MAX_CODE_REVIEW_ITERATIONS falls back to its default when given an override too large to sum safely" {
    export MAX_CODE_REVIEW_ITERATIONS="99999999999999999999"
    source_oneshot
    [ "${MAX_CODE_REVIEW_ITERATIONS}" -eq 15 ]
}

@test "MAX_SECURITY_REVIEW_ITERATIONS defaults to 15" {
    [ "${MAX_SECURITY_REVIEW_ITERATIONS}" -eq 15 ]
}

@test "MAX_SECURITY_REVIEW_ITERATIONS can be overridden via environment variable" {
    MAX_SECURITY_REVIEW_ITERATIONS=5
    [ "${MAX_SECURITY_REVIEW_ITERATIONS}" -eq 5 ]
}

@test "MAX_SECURITY_REVIEW_ITERATIONS falls back to its default when given a non-numeric override" {
    export MAX_SECURITY_REVIEW_ITERATIONS="not-a-number"
    source_oneshot
    [ "${MAX_SECURITY_REVIEW_ITERATIONS}" -eq 15 ]
}

@test "MAX_COVERAGE_ITERATIONS defaults to 6" {
    [ "${MAX_COVERAGE_ITERATIONS}" -eq 6 ]
}

@test "MAX_COVERAGE_ITERATIONS can be overridden via environment variable" {
    MAX_COVERAGE_ITERATIONS=2
    [ "${MAX_COVERAGE_ITERATIONS}" -eq 2 ]
}

@test "MAX_COVERAGE_ITERATIONS falls back to its default when given a non-numeric override" {
    export MAX_COVERAGE_ITERATIONS="not-a-number"
    source_oneshot
    [ "${MAX_COVERAGE_ITERATIONS}" -eq 6 ]
}

@test "MAX_PR_TOTAL_INVOCATIONS defaults to 57 (sum of per-phase budgets plus flat headroom)" {
    [ "${MAX_PR_TOTAL_INVOCATIONS}" -eq 57 ]
}

# --- MAX_SIMPLIFY_ITERATIONS / SIMPLIFY_THRASH_LIMIT constants ----------------

@test "MAX_SIMPLIFY_ITERATIONS defaults to 10" {
    [ "${MAX_SIMPLIFY_ITERATIONS}" -eq 10 ]
}

@test "MAX_SIMPLIFY_ITERATIONS can be overridden via environment variable" {
    MAX_SIMPLIFY_ITERATIONS=20
    [ "${MAX_SIMPLIFY_ITERATIONS}" -eq 20 ]
}

@test "MAX_SIMPLIFY_ITERATIONS falls back to its default when given a non-numeric override" {
    export MAX_SIMPLIFY_ITERATIONS="not-a-number"
    source_oneshot
    [ "${MAX_SIMPLIFY_ITERATIONS}" -eq 10 ]
}

@test "SIMPLIFY_THRASH_LIMIT defaults to 3" {
    [ "${SIMPLIFY_THRASH_LIMIT}" -eq 3 ]
}

@test "SIMPLIFY_THRASH_LIMIT can be overridden via environment variable" {
    SIMPLIFY_THRASH_LIMIT=5
    [ "${SIMPLIFY_THRASH_LIMIT}" -eq 5 ]
}

@test "MIN_REVIEW_CONVERGENCE_ROUNDS defaults to 3" {
    [ "${MIN_REVIEW_CONVERGENCE_ROUNDS}" -eq 3 ]
}

@test "MIN_REVIEW_CONVERGENCE_ROUNDS can be overridden via environment variable" {
    MIN_REVIEW_CONVERGENCE_ROUNDS=5
    [ "${MIN_REVIEW_CONVERGENCE_ROUNDS}" -eq 5 ]
}

@test "MIN_REVIEW_CONVERGENCE_ROUNDS falls back to its default when given a non-numeric override" {
    export MIN_REVIEW_CONVERGENCE_ROUNDS="not-a-number"
    source_oneshot
    [ "${MIN_REVIEW_CONVERGENCE_ROUNDS}" -eq 3 ]
}

@test "MIN_REVIEW_CONVERGENCE_ROUNDS falls back to its default when given an overflow-sized override" {
    export MIN_REVIEW_CONVERGENCE_ROUNDS="9999999"
    source_oneshot
    [ "${MIN_REVIEW_CONVERGENCE_ROUNDS}" -eq 3 ]
}

# --- build_issue_claude_md plan-first steps -----------------------------------

@test "build_issue_claude_md includes plan-check command" {
    run build_issue_claude_md 42 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Implementation Plan"* ]]
    [[ "${output}" == *'any(test("## Implementation Plan"'* ]]
}

@test "build_issue_claude_md instructs agent to post plan comment in correct format" {
    run build_issue_claude_md 42 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"### Files to change"* ]]
    [[ "${output}" == *"### Approach"* ]]
    [[ "${output}" == *"### Test strategy"* ]]
    [[ "${output}" == *"### Assumptions"* ]]
    [[ "${output}" == *"### Open questions"* ]]
}

@test "build_issue_claude_md describes plan mode and implementation mode" {
    run build_issue_claude_md 42 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Plan mode"* ]]
    [[ "${output}" == *"Implementation mode"* ]]
}

@test "build_issue_claude_md does not include WF section when _WF_PROJECT_ID is empty" {
    _WF_PROJECT_ID=""
    run build_issue_claude_md 42 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"WF_PROJECT_ID"* ]]
    [[ "${output}" != *"WF_PLANNING"* ]]
}

@test "build_issue_claude_md includes WF section when _WF_PROJECT_ID is set" {
    _WF_PROJECT_ID="PVT_test123"
    _WF_STATUS_FIELD_ID="PVTSSF_field456"
    _WF_OPTION_IDS[Planning]="opt_plan_id"
    _WF_OPTION_IDS[Development]="opt_dev_id"
    run build_issue_claude_md 42 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"WF_PROJECT_ID=PVT_test123"* ]]
    [[ "${output}" == *"WF_STATUS_FIELD_ID=PVTSSF_field456"* ]]
    [[ "${output}" == *"WF_PLANNING=opt_plan_id"* ]]
    [[ "${output}" == *"WF_DEVELOPMENT=opt_dev_id"* ]]
}

@test "build_issue_claude_md without board uses comment-based approval fallback" {
    _WF_PROJECT_ID=""
    run build_issue_claude_md 42 "/resolved/.ai-instructions" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"approved|go ahead|looks good|lgtm"* ]]
    [[ "${output}" != *"approved on the Workflow board"* ]]
}

@test "build_issue_claude_md without board bakes the current bot login and trusted logins into the printed approval-check jq, excluding the bot's own comments (#1286)" {
    _WF_PROJECT_ID=""
    _GH_ME="the-bot"
    run build_issue_claude_md 42 "/resolved/.ai-instructions" "" "false" '["credfeto"]'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'"the-bot"'* ]]
    [[ "${output}" == *'["credfeto"]'* ]]
    [[ "${output}" == *"your own prior comments never count"* ]]
}

@test "build_issue_claude_md with board and plan not approved shows board-pending text" {
    _WF_PROJECT_ID="PVT_test"
    run build_issue_claude_md 42 "/resolved/.ai-instructions" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Workflow board"* ]]
    [[ "${output}" != *"approved|go ahead"* ]]
}

@test "build_issue_claude_md with plan_approved=true shows board-approved text" {
    _WF_PROJECT_ID="PVT_test"
    run build_issue_claude_md 42 "/resolved/.ai-instructions" "" "true"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"approved on the Workflow board"* ]]
    [[ "${output}" == *"Implementation mode"* ]]
}

@test "build_issue_claude_md approval instruction mentions Workflow board when board is configured" {
    _WF_PROJECT_ID="PVT_test"
    run build_issue_claude_md 42 "/resolved/.ai-instructions" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'set the Workflow board status to "Approved"'* ]]
}

@test "build_issue_claude_md approval instruction mentions approval comment when no board" {
    _WF_PROJECT_ID=""
    run build_issue_claude_md 42 "/resolved/.ai-instructions" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"approval comment"* ]]
}

# --- fetch_board_approved_items unit tests ------------------------------------

@test "fetch_board_approved_items is a no-op when _WF_PROJECT_ID is empty" {
    _WF_PROJECT_ID=""
    make_stub gh 'printf "called\n"; exit 0'
    local call_count_file="${TEST_TMP}/gh_calls"
    make_stub gh "printf 'called\n' >> ${call_count_file}; exit 0"
    fetch_board_approved_items
    local count
    count=$(wc -l < "${call_count_file}" 2>/dev/null || printf '0\n')
    [ "${count}" -eq 0 ]
}

@test "fetch_board_approved_items populates _WF_APPROVED_ITEMS for Approved board items" {
    _WF_PROJECT_ID="PVT_test"
    _WF_OPTION_IDS[Approved]="opt_approved"
    local items_json='{"data":{"node":{"items":{"nodes":[{"content":{"number":42,"repository":{"nameWithOwner":"owner/repo"}},"fieldValues":{"nodes":[{"optionId":"opt_approved"}]}},{"content":{"number":99,"repository":{"nameWithOwner":"owner/repo"}},"fieldValues":{"nodes":[{"optionId":"opt_other"}]}}]}}}}'
    make_stub gh "printf '%s\n' '${items_json}'"
    fetch_board_approved_items
    [ "${_WF_APPROVED_ITEMS["owner/repo/42"]:-}" = "1" ]
    [ "${_WF_APPROVED_ITEMS["owner/repo/99"]:-}" != "1" ]
}

@test "fetch_board_approved_items caches per repo and does not re-call gh on second call" {
    _WF_PROJECT_ID="PVT_test"
    _WF_OPTION_IDS[Approved]="opt_approved"
    local call_count_file="${TEST_TMP}/gh_calls"
    local items_json='{"data":{"node":{"items":{"nodes":[]}}}}'
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
printf 'called\n' >> "${call_count_file}"
printf '%s\n' '${items_json}'
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    fetch_board_approved_items
    fetch_board_approved_items
    local count
    count=$(wc -l < "${call_count_file}" 2>/dev/null || printf '0\n')
    [ "${count}" -eq 1 ]
}

@test "fetch_board_approved_items handles gh failure gracefully and leaves items empty" {
    _WF_PROJECT_ID="PVT_test"
    _WF_OPTION_IDS[Approved]="opt_approved"
    make_stub gh 'exit 1'
    fetch_board_approved_items
    [ -z "${_WF_APPROVED_ITEMS[*]:-}" ]
}

@test "fetch_board_approved_items paginates and finds item on second page" {
    _WF_PROJECT_ID="PVT_test"
    _WF_OPTION_IDS[Approved]="opt_approved"
    local call_count_file="${TEST_TMP}/gh_calls"
    local page1='{"data":{"node":{"items":{"pageInfo":{"endCursor":"cursor_page2","hasNextPage":true},"nodes":[{"content":{"number":1,"repository":{"nameWithOwner":"owner/repo"}},"fieldValues":{"nodes":[{"optionId":"opt_approved"}]}}]}}}}'
    local page2='{"data":{"node":{"items":{"pageInfo":{"endCursor":null,"hasNextPage":false},"nodes":[{"content":{"number":2,"repository":{"nameWithOwner":"owner/repo"}},"fieldValues":{"nodes":[{"optionId":"opt_approved"}]}}]}}}}'
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
count=\$(wc -l < "${call_count_file}" 2>/dev/null || printf '0\n')
printf 'call\n' >> "${call_count_file}"
if [ "\${count}" -eq 0 ]; then
    printf '%s\n' '${page1}'
else
    printf '%s\n' '${page2}'
fi
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    fetch_board_approved_items
    [ "${_WF_APPROVED_ITEMS["owner/repo/1"]:-}" = "1" ]
    [ "${_WF_APPROVED_ITEMS["owner/repo/2"]:-}" = "1" ]
}

@test "fetch_board_approved_items forwards cursor to second-page request" {
    _WF_PROJECT_ID="PVT_test"
    _WF_OPTION_IDS[Approved]="opt_approved"
    local call_count_file="${TEST_TMP}/gh_calls"
    local args_file="${TEST_TMP}/gh_args"
    local page1='{"data":{"node":{"items":{"pageInfo":{"endCursor":"cursor_page2","hasNextPage":true},"nodes":[{"content":{"number":1,"repository":{"nameWithOwner":"owner/repo"}},"fieldValues":{"nodes":[{"optionId":"opt_approved"}]}}]}}}}'
    local page2='{"data":{"node":{"items":{"pageInfo":{"endCursor":null,"hasNextPage":false},"nodes":[]}}}}'
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
count=\$(wc -l < "${call_count_file}" 2>/dev/null || printf '0\n')
printf 'call\n' >> "${call_count_file}"
printf '%s\n' "\$*" >> "${args_file}"
if [ "\${count}" -eq 0 ]; then
    printf '%s\n' '${page1}'
else
    printf '%s\n' '${page2}'
fi
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    fetch_board_approved_items
    grep -q 'cursor=cursor_page2' "${args_file}"
}

@test "fetch_board_approved_items uses fieldValues(first:50) in the GraphQL query" {
    _WF_PROJECT_ID="PVT_test"
    _WF_OPTION_IDS[Approved]="opt_approved"
    local args_file="${TEST_TMP}/gh_args"
    local items_json='{"data":{"node":{"items":{"pageInfo":{"endCursor":null,"hasNextPage":false},"nodes":[]}}}}'
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${args_file}"
printf '%s\n' '${items_json}'
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    fetch_board_approved_items
    grep -q 'fieldValues(first:50)' "${args_file}"
}

@test "fetch_board_approved_items matches approved item when optionId is beyond tenth fieldValue" {
    _WF_PROJECT_ID="PVT_test"
    _WF_OPTION_IDS[Approved]="opt_approved"
    local fv
    fv='[{"optionId":"x"},{"optionId":"x"},{"optionId":"x"},{"optionId":"x"},{"optionId":"x"},{"optionId":"x"},{"optionId":"x"},{"optionId":"x"},{"optionId":"x"},{"optionId":"x"},{"optionId":"x"},{"optionId":"x"},{"optionId":"x"},{"optionId":"x"},{"optionId":"opt_approved"}]'
    local items_json
    items_json='{"data":{"node":{"items":{"pageInfo":{"endCursor":null,"hasNextPage":false},"nodes":[{"content":{"number":5,"repository":{"nameWithOwner":"owner/repo"}},"fieldValues":{"nodes":'"${fv}"'}}]}}}}'
    make_stub gh "printf '%s\n' '${items_json}'"
    fetch_board_approved_items
    [ "${_WF_APPROVED_ITEMS["owner/repo/5"]:-}" = "1" ]
}

@test "fetch_board_approved_items skips re-fetch for already-fetched repo while still fetching a new repo" {
    _WF_PROJECT_ID="PVT_test"
    _WF_OPTION_IDS[Approved]="opt_approved"
    local call_count_file="${TEST_TMP}/gh_calls"
    local items_a='{"data":{"node":{"items":{"pageInfo":{"endCursor":null,"hasNextPage":false},"nodes":[{"content":{"number":1,"repository":{"nameWithOwner":"owner/repo-a"}},"fieldValues":{"nodes":[{"optionId":"opt_approved"}]}}]}}}}'
    local items_b='{"data":{"node":{"items":{"pageInfo":{"endCursor":null,"hasNextPage":false},"nodes":[{"content":{"number":2,"repository":{"nameWithOwner":"owner/repo-b"}},"fieldValues":{"nodes":[{"optionId":"opt_approved"}]}}]}}}}'
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
count=\$(wc -l < "${call_count_file}" 2>/dev/null || printf '0\n')
printf 'call\n' >> "${call_count_file}"
if [ "\${count}" -eq 0 ]; then
    printf '%s\n' '${items_a}'
else
    printf '%s\n' '${items_b}'
fi
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    REPO_FULL="owner/repo-a"
    fetch_board_approved_items
    fetch_board_approved_items
    REPO_FULL="owner/repo-b"
    fetch_board_approved_items
    local count
    count=$(wc -l < "${call_count_file}" 2>/dev/null || printf '0\n')
    [ "${count}" -eq 2 ]
    [ "${_WF_APPROVED_ITEMS["owner/repo-a/1"]:-}" = "1" ]
    [ "${_WF_APPROVED_ITEMS["owner/repo-b/2"]:-}" = "1" ]
}

# --- fetch_board_item_statuses / board_substatus_for_item (#1136) --------------

@test "fetch_board_item_statuses is a no-op when _WF_PROJECT_ID is empty" {
    _WF_PROJECT_ID=""
    local call_count_file="${TEST_TMP}/gh_calls"
    make_stub gh "printf 'called\n' >> ${call_count_file}; exit 0"
    fetch_board_item_statuses
    local count
    count=$(wc -l < "${call_count_file}" 2>/dev/null || printf '0\n')
    [ "${count}" -eq 0 ]
}

@test "fetch_board_item_statuses populates option IDs for both Issues and PRs" {
    _WF_PROJECT_ID="PVT_test"
    local items_json='{"data":{"node":{"items":{"nodes":[
        {"content":{"number":42,"repository":{"nameWithOwner":"owner/repo"}},"fieldValues":{"nodes":[{"optionId":"opt_dev","field":{"name":"Workflow Status"}}]}},
        {"content":{"number":7,"repository":{"nameWithOwner":"owner/repo"}},"fieldValues":{"nodes":[{"optionId":"opt_review","field":{"name":"Workflow Status"}}]}}
    ]}}}}'
    make_stub gh "printf '%s\n' '${items_json}'"
    fetch_board_item_statuses
    [ "${_WF_ITEM_STATUS_OPTION_ID["owner/repo/42"]:-}" = "opt_dev" ]
    [ "${_WF_ITEM_STATUS_OPTION_ID["owner/repo/7"]:-}" = "opt_review" ]
}

@test "fetch_board_item_statuses ignores fieldValues for a field other than Workflow Status" {
    _WF_PROJECT_ID="PVT_test"
    local items_json='{"data":{"node":{"items":{"nodes":[
        {"content":{"number":42,"repository":{"nameWithOwner":"owner/repo"}},"fieldValues":{"nodes":[{"optionId":"opt_other","field":{"name":"Some Other Field"}}]}}
    ]}}}}'
    make_stub gh "printf '%s\n' '${items_json}'"
    fetch_board_item_statuses
    [ -z "${_WF_ITEM_STATUS_OPTION_ID["owner/repo/42"]:-}" ]
}

@test "fetch_board_item_statuses caches per repo and does not re-call gh on second call" {
    _WF_PROJECT_ID="PVT_test"
    local call_count_file="${TEST_TMP}/gh_calls"
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
printf 'called\n' >> "${call_count_file}"
printf '%s\n' '{"data":{"node":{"items":{"nodes":[]}}}}'
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    fetch_board_item_statuses
    fetch_board_item_statuses
    local count
    count=$(wc -l < "${call_count_file}" 2>/dev/null || printf '0\n')
    [ "${count}" -eq 1 ]
}

@test "workflow_status_name_for_option_id returns the matching status name" {
    _WF_OPTION_IDS[Development]="opt_dev"
    _WF_OPTION_IDS["Human Review"]="opt_review"
    run workflow_status_name_for_option_id "opt_dev"
    [ "${output}" = "Development" ]
}

@test "workflow_status_name_for_option_id returns empty for an unrecognised option ID" {
    _WF_OPTION_IDS[Development]="opt_dev"
    run workflow_status_name_for_option_id "opt_nonexistent"
    [ -z "${output}" ]
}

@test "workflow_status_name_for_option_id returns empty for an empty option ID" {
    run workflow_status_name_for_option_id ""
    [ -z "${output}" ]
}

@test "board_substatus_for_item returns Unknown when the board is not configured" {
    _WF_PROJECT_ID=""
    discover_or_create_workflow_project() { return 0; }
    run board_substatus_for_item 42
    [ "${output}" = "Unknown" ]
}

@test "board_substatus_for_item calls discover_or_create_workflow_project first (#1136 review)" {
    # Most notify_discord_blocked_item call sites fire before the per-item work block's own
    # discovery call ever runs — board_substatus_for_item must trigger discovery itself so it
    # doesn't always report Unknown for those.
    _WF_PROJECT_ID=""
    local call_log="${TEST_TMP}/discover_calls"
    discover_or_create_workflow_project() { printf 'called\n' >> "${call_log}"; }
    board_substatus_for_item 42
    [ -f "${call_log}" ]
}

@test "board_substatus_for_item returns the resolved status name for a known item" {
    set_repo_context "org/repo"
    # Simulates discovery having already resolved this repo's project — the fast-path guard
    # in discover_or_create_workflow_project (_WF_CACHED_REPO == REPO_FULL) makes it a no-op
    # so it does not overwrite the project ID set up below via a real (unstubbed) discovery.
    _WF_CACHED_REPO="org/repo"
    _WF_PROJECT_ID="PVT_test"
    _WF_OPTION_IDS[Development]="opt_dev"
    local items_json='{"data":{"node":{"items":{"nodes":[
        {"content":{"number":42,"repository":{"nameWithOwner":"org/repo"}},"fieldValues":{"nodes":[{"optionId":"opt_dev","field":{"name":"Workflow Status"}}]}}
    ]}}}}'
    make_stub gh "printf '%s\n' '${items_json}'"
    run board_substatus_for_item 42
    [ "${output}" = "Development" ]
}

@test "board_substatus_for_item returns Unknown for an item not yet on the board" {
    set_repo_context "org/repo"
    _WF_CACHED_REPO="org/repo"
    _WF_PROJECT_ID="PVT_test"
    make_stub gh 'printf "%s\n" "{\"data\":{\"node\":{\"items\":{\"nodes\":[]}}}}"'
    run board_substatus_for_item 999
    [ "${output}" = "Unknown" ]
}

@test "board_substatus_for_item re-resolves the project when REPO_FULL changes across repos (#1136 review)" {
    # Regression coverage for the multi-repo staleness bug: a stale _WF_PROJECT_ID left over
    # from a previously processed repo must not silently poison this repo's lookup.
    set_repo_context "repo-a/repo-a"
    _WF_CACHED_REPO="repo-a/repo-a"
    _WF_PROJECT_ID="PVT_stale_from_repo_a"
    discover_or_create_workflow_project() {
        _WF_PROJECT_ID="PVT_repo_b"
        _WF_CACHED_REPO="${REPO_FULL}"
    }
    local items_json='{"data":{"node":{"items":{"nodes":[
        {"content":{"number":7,"repository":{"nameWithOwner":"repo-b/repo-b"}},"fieldValues":{"nodes":[{"optionId":"opt_review","field":{"name":"Workflow Status"}}]}}
    ]}}}}'
    make_stub gh "printf '%s\n' '${items_json}'"
    set_repo_context "repo-b/repo-b"
    _WF_OPTION_IDS["Human Review"]="opt_review"
    run board_substatus_for_item 7
    [ "${output}" = "Human Review" ]
}

# --- _wf_status_ordinal (#1276) ---------------------------------------------

@test "_wf_status_ordinal returns the index of a known status name" {
    run _wf_status_ordinal "Not Started"
    [ "${output}" = "0" ]
    run _wf_status_ordinal "Development"
    [ "${output}" = "3" ]
    run _wf_status_ordinal "Complete"
    [ "${output}" = "9" ]
}

@test "_wf_status_ordinal returns empty for an unrecognised or blank status name" {
    run _wf_status_ordinal "Bogus"
    [ -z "${output}" ]
    run _wf_status_ordinal ""
    [ -z "${output}" ]
}

# --- issue_plan_approved_or_later (#1321) -------------------------------------

@test "issue_plan_approved_or_later returns true for a card exactly on Approved" {
    board_substatus_for_item() { printf 'Approved'; }
    run issue_plan_approved_or_later 42
    [ "${output}" = "true" ]
}

@test "issue_plan_approved_or_later returns true for a card that has progressed past Approved" {
    # Derived from the canonical column order (_WF_STATUS_ORDER, lib/globals) rather than a
    # hardcoded list, so this stays correct if a column is ever renamed/added/removed.
    local approved_idx status
    approved_idx=$(_wf_status_ordinal "Approved")
    for status in "${_WF_STATUS_ORDER[@]:$((approved_idx + 1))}"; do
        # shellcheck disable=SC2317 # invoked indirectly via issue_plan_approved_or_later
        board_substatus_for_item() { printf '%s' "${status}"; }
        run issue_plan_approved_or_later 42
        [ "${output}" = "true" ]
    done
}

@test "issue_plan_approved_or_later returns false for a card that has not reached Approved yet" {
    board_substatus_for_item() { printf 'Planning'; }
    run issue_plan_approved_or_later 42
    [ "${output}" = "false" ]

    board_substatus_for_item() { printf 'Not Started'; }
    run issue_plan_approved_or_later 42
    [ "${output}" = "false" ]
}

@test "issue_plan_approved_or_later returns false when the item is not on the board" {
    board_substatus_for_item() { printf 'Unknown'; }
    run issue_plan_approved_or_later 42
    [ "${output}" = "false" ]
}

@test "issue_plan_approved_or_later returns false when no board is configured" {
    _WF_PROJECT_ID=""
    discover_or_create_workflow_project() { return 0; }
    run issue_plan_approved_or_later 42
    [ "${output}" = "false" ]
}

# --- sync_pr_workflow_status_from_linked_issues (#1276) ----------------------

@test "sync_pr_workflow_status_from_linked_issues advances a PR whose linked issue is further along" {
    _WF_PROJECT_ID="PVT_test"
    board_substatus_for_item() {
        case "$1" in
            383) printf 'Development' ;;
            412) printf 'Unknown' ;;
        esac
    }
    local status_log="${TEST_TMP}/status_calls"
    update_workflow_status() { printf '%s %s %s\n' "$1" "$2" "$3" >> "${status_log}"; }
    make_stub gh 'printf "383\n"'

    sync_pr_workflow_status_from_linked_issues 412 "false"
    grep -q 'PullRequest 412 Development' "${status_log}"
}

@test "sync_pr_workflow_status_from_linked_issues never lowers a PR's card that is already ahead of its issue" {
    _WF_PROJECT_ID="PVT_test"
    board_substatus_for_item() {
        case "$1" in
            383) printf 'Development' ;;
            412) printf 'AI Review' ;;
        esac
    }
    local status_log="${TEST_TMP}/status_calls"
    update_workflow_status() { printf '%s %s %s\n' "$1" "$2" "$3" >> "${status_log}"; }
    make_stub gh 'printf "383\n"'

    sync_pr_workflow_status_from_linked_issues 412 "false"
    [ ! -f "${status_log}" ]
}

@test "sync_pr_workflow_status_from_linked_issues floors the mirrored status at Development even if the issue is only Approved" {
    _WF_PROJECT_ID="PVT_test"
    board_substatus_for_item() {
        case "$1" in
            383) printf 'Approved' ;;
            412) printf 'Unknown' ;;
        esac
    }
    local status_log="${TEST_TMP}/status_calls"
    update_workflow_status() { printf '%s %s %s\n' "$1" "$2" "$3" >> "${status_log}"; }
    make_stub gh 'printf "383\n"'

    sync_pr_workflow_status_from_linked_issues 412 "false"
    grep -q 'PullRequest 412 Development' "${status_log}"
}

@test "sync_pr_workflow_status_from_linked_issues falls back to first-touch Not Started when there is no linked issue" {
    _WF_PROJECT_ID="PVT_test"
    local status_log="${TEST_TMP}/status_calls"
    update_workflow_status() { printf '%s %s %s\n' "$1" "$2" "$3" >> "${status_log}"; }
    make_stub gh 'printf ""'

    sync_pr_workflow_status_from_linked_issues 500 "true"
    grep -q 'PullRequest 500 Not Started' "${status_log}"
}

@test "sync_pr_workflow_status_from_linked_issues with no linked issue and not first touch does nothing" {
    _WF_PROJECT_ID="PVT_test"
    local status_log="${TEST_TMP}/status_calls"
    update_workflow_status() { printf '%s %s %s\n' "$1" "$2" "$3" >> "${status_log}"; }
    make_stub gh 'printf ""'

    sync_pr_workflow_status_from_linked_issues 500 "false"
    [ ! -f "${status_log}" ]
}

@test "sync_pr_workflow_status_from_linked_issues is a no-op when the board is not configured" {
    _WF_PROJECT_ID=""
    local call_log="${TEST_TMP}/gh_calls"
    make_stub gh "printf 'called\n' >> ${call_log}"
    sync_pr_workflow_status_from_linked_issues 412 "false"
    [ ! -f "${call_log}" ]
}

# --- coarse_status_for_substatus (#1136) ----------------------------------------

@test "coarse_status_for_substatus maps Not Started and Planning to To Do" {
    run coarse_status_for_substatus "Not Started"
    [ "${output}" = "To Do" ]
    run coarse_status_for_substatus "Planning"
    [ "${output}" = "To Do" ]
}

@test "coarse_status_for_substatus maps the active phases to In Progress" {
    for phase in Approved Development "AI Simplify" "AI Review" "AI Security Review" "AI Coverage" "Human Review"; do
        run coarse_status_for_substatus "${phase}"
        [ "${output}" = "In Progress" ]
    done
}

@test "coarse_status_for_substatus maps Complete to Done" {
    run coarse_status_for_substatus "Complete"
    [ "${output}" = "Done" ]
}

@test "coarse_status_for_substatus maps an unrecognised sub-status to Unknown" {
    run coarse_status_for_substatus "Unknown"
    [ "${output}" = "Unknown" ]
    run coarse_status_for_substatus ""
    [ "${output}" = "Unknown" ]
}

# --- priority_for_labels (#1136) -------------------------------------------------

@test "priority_for_labels matches Security with highest precedence" {
    run priority_for_labels '[{"name":"Low"},{"name":"Urgent"},{"name":"Security"}]'
    [ "${output}" = "Security" ]
}

@test "priority_for_labels matches Urgent over High" {
    run priority_for_labels '[{"name":"High"},{"name":"Urgent"}]'
    [ "${output}" = "Urgent" ]
}

@test "priority_for_labels matches each single priority label correctly" {
    run priority_for_labels '[{"name":"High"}]'
    [ "${output}" = "High" ]
    run priority_for_labels '[{"name":"Medium"}]'
    [ "${output}" = "Medium" ]
    run priority_for_labels '[{"name":"Low"}]'
    [ "${output}" = "Low" ]
}

@test "priority_for_labels is case-insensitive" {
    run priority_for_labels '[{"name":"URGENT"}]'
    [ "${output}" = "Urgent" ]
}

@test "priority_for_labels returns Undefined when no priority label is present" {
    run priority_for_labels '[{"name":"AI-Work"},{"name":"bug"}]'
    [ "${output}" = "Undefined" ]
}

@test "priority_for_labels returns Undefined for an empty labels array" {
    run priority_for_labels '[]'
    [ "${output}" = "Undefined" ]
}

@test "priority_for_labels returns Undefined without dying on malformed JSON" {
    run priority_for_labels 'not json'
    [ "${status}" -eq 0 ]
    [ "${output}" = "Undefined" ]
}

# --- priority_name_for_rank (#1375) ----------------------------------------------

@test "priority_name_for_rank maps every defined rank to its name" {
    run priority_name_for_rank "0"
    [ "${output}" = "Default" ]
    run priority_name_for_rank "1"
    [ "${output}" = "Low" ]
    run priority_name_for_rank "2"
    [ "${output}" = "Medium" ]
    run priority_name_for_rank "3"
    [ "${output}" = "High" ]
    run priority_name_for_rank "4"
    [ "${output}" = "Urgent" ]
    run priority_name_for_rank "5"
    [ "${output}" = "Security" ]
}

@test "priority_name_for_rank returns Undefined for an out-of-range rank" {
    run priority_name_for_rank "6"
    [ "${output}" = "Undefined" ]
    run priority_name_for_rank "-1"
    [ "${output}" = "Undefined" ]
}

@test "priority_name_for_rank returns Undefined for a missing or non-numeric rank" {
    run priority_name_for_rank ""
    [ "${output}" = "Undefined" ]
    run priority_name_for_rank "abc"
    [ "${output}" = "Undefined" ]
}

# --- round-progress enrichment (#1375) ---------------------------------------

@test "_round_marker_and_cap_for_substatus returns the marker and cap for each bounded-loop phase" {
    run _round_marker_and_cap_for_substatus "AI Simplify"
    [[ "${output}" == "Simplify: applied cleanups"$'\t'"${MAX_SIMPLIFY_ITERATIONS}" ]]
    run _round_marker_and_cap_for_substatus "AI Review"
    [[ "${output}" == "Code review round:"$'\t'"${MAX_CODE_REVIEW_ITERATIONS}" ]]
    run _round_marker_and_cap_for_substatus "AI Security Review"
    [[ "${output}" == "Security review round:"$'\t'"${MAX_SECURITY_REVIEW_ITERATIONS}" ]]
    run _round_marker_and_cap_for_substatus "AI Coverage"
    [[ "${output}" == " - returning to Development"$'\t'"${MAX_COVERAGE_ITERATIONS}" ]]
}

@test "_round_marker_and_cap_for_substatus returns empty for a non-bounded-loop substatus" {
    run _round_marker_and_cap_for_substatus "Development"
    [ -z "${output}" ]
    run _round_marker_and_cap_for_substatus "Human Review"
    [ -z "${output}" ]
    run _round_marker_and_cap_for_substatus "Unknown"
    [ -z "${output}" ]
}

@test "count_pr_comments_matching counts only comments containing the marker" {
    set_repo_context "org/repo"
    make_stub gh 'printf "%s" "{\"comments\":[{\"body\":\"Code review round: fixed 2 findings\"},{\"body\":\"unrelated\"},{\"body\":\"Code review round: fixed 1 finding\"}]}"'
    run count_pr_comments_matching "5" "Code review round:"
    [ "${output}" = "2" ]
}

@test "count_pr_comments_matching returns 0 when nothing matches or the fetch fails" {
    set_repo_context "org/repo"
    make_stub gh 'printf "%s" "{\"comments\":[{\"body\":\"unrelated\"}]}"'
    run count_pr_comments_matching "5" "Code review round:"
    [ "${output}" = "0" ]

    make_stub gh 'exit 1'
    run count_pr_comments_matching "5" "Code review round:"
    [ "${output}" = "0" ]
}

@test "count_pr_comments_matching filters a given comments_json without fetching via gh (#1375)" {
    set_repo_context "org/repo"
    local gh_call_log="${TEST_TMP}/gh_calls"
    make_stub gh "printf 'called\n' >> '${gh_call_log}'"
    local comments_json='[{"body":"Code review round: fixed 2 findings"},{"body":"unrelated"}]'

    run count_pr_comments_matching "5" "Code review round:" "${comments_json}"
    [ "${output}" = "1" ]
    [ ! -f "${gh_call_log}" ]
}

@test "coverage_summary_for_branch reads Overall percentages from the branch's own COVERAGE.md via origin, not the working tree" {
    set_repo_context "org/repo"
    setup_local_git_remote >/dev/null
    git -C "${REPO_WORK_DIR}" checkout -b feature/cov >/dev/null 2>&1
    cat > "${REPO_WORK_DIR}/COVERAGE.md" <<'EOF'
# Coverage

## .NET
| Project | Line Coverage |
| --- | --- |
| Credfeto.Foo | 82.1% |
| **Overall (.NET)** | **82.1%** |

## Node
| Package | Line Coverage |
| --- | --- |
| **Overall (Node)** | **91.4%** |

## Shell

excluded
EOF
    git -C "${REPO_WORK_DIR}" add COVERAGE.md
    git -C "${REPO_WORK_DIR}" -c commit.gpgsign=false commit -q -m "coverage"
    git -C "${REPO_WORK_DIR}" push origin feature/cov >/dev/null 2>&1
    # The working tree is left checked out on feature/cov above, but the function must not rely
    # on that — switch back to main to prove it reads via origin/<branch>, not the working tree.
    git -C "${REPO_WORK_DIR}" checkout main >/dev/null 2>&1
    git -C "${REPO_WORK_DIR}" fetch origin >/dev/null 2>&1

    run coverage_summary_for_branch "feature/cov"
    [ "${output}" = ".NET 82.1%, Node 91.4%" ]
}

@test "coverage_summary_for_branch returns empty when COVERAGE.md does not exist on the branch" {
    set_repo_context "org/repo"
    setup_local_git_remote >/dev/null
    run coverage_summary_for_branch "main"
    [ -z "${output}" ]
}

@test "coverage_summary_for_branch returns empty for a missing branch name or repo checkout" {
    set_repo_context "org/repo"
    run coverage_summary_for_branch ""
    [ -z "${output}" ]

    REPO_WORK_DIR="${TEST_TMP}/nonexistent/repo"
    run coverage_summary_for_branch "main"
    [ -z "${output}" ]
}

@test "enrich_substatus_with_round_progress appends the round count for AI Review" {
    set_repo_context "org/repo"
    make_stub gh 'printf "%s" "{\"comments\":[{\"body\":\"Code review round: fixed 2 findings\"}]}"'
    run enrich_substatus_with_round_progress "5" "AI Review" ""
    [ "${output}" = "AI Review (round 1 of ${MAX_CODE_REVIEW_ITERATIONS})" ]
}

@test "enrich_substatus_with_round_progress appends round count and coverage percentages for AI Coverage" {
    set_repo_context "org/repo"
    setup_local_git_remote >/dev/null
    git -C "${REPO_WORK_DIR}" checkout -b feature/cov2 >/dev/null 2>&1
    printf '## .NET\n| **Overall (.NET)** | **75.0%%** |\n' > "${REPO_WORK_DIR}/COVERAGE.md"
    git -C "${REPO_WORK_DIR}" add COVERAGE.md
    git -C "${REPO_WORK_DIR}" -c commit.gpgsign=false commit -q -m "coverage"
    git -C "${REPO_WORK_DIR}" push origin feature/cov2 >/dev/null 2>&1
    git -C "${REPO_WORK_DIR}" fetch origin >/dev/null 2>&1

    make_stub gh 'printf "%s" "{\"comments\":[{\"body\":\".NET 75.0%% < main 80.0%% - returning to Development\"}]}"'
    run enrich_substatus_with_round_progress "5" "AI Coverage" "feature/cov2"
    [ "${output}" = "AI Coverage (round 1 of ${MAX_COVERAGE_ITERATIONS}, .NET 75.0%)" ]
}

@test "enrich_substatus_with_round_progress falls back to round count only when COVERAGE.md has no summary" {
    set_repo_context "org/repo"
    make_stub gh 'printf "%s" "{\"comments\":[]}"'
    run enrich_substatus_with_round_progress "5" "AI Coverage" ""
    [ "${output}" = "AI Coverage (round 0 of ${MAX_COVERAGE_ITERATIONS})" ]
}

@test "enrich_substatus_with_round_progress leaves a non-bounded-loop substatus unchanged" {
    set_repo_context "org/repo"
    run enrich_substatus_with_round_progress "5" "Human Review" ""
    [ "${output}" = "Human Review" ]
    run enrich_substatus_with_round_progress "5" "Unknown" ""
    [ "${output}" = "Unknown" ]
}

@test "enrich_substatus_with_round_progress uses a given comments_json without fetching via gh (#1375)" {
    set_repo_context "org/repo"
    local gh_call_log="${TEST_TMP}/gh_calls"
    make_stub gh "printf 'called\n' >> '${gh_call_log}'"
    local comments_json='[{"body":"Code review round: fixed 2 findings"}]'

    run enrich_substatus_with_round_progress "5" "AI Review" "" "${comments_json}"
    [ "${output}" = "AI Review (round 1 of ${MAX_CODE_REVIEW_ITERATIONS})" ]
    [ ! -f "${gh_call_log}" ]
}

# --- build_pr_claude_md review-loop steps ------------------------------------

@test "build_pr_claude_md includes code-review loop instructions" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"/code-review --comment"* ]]
    [[ "${output}" == *"AI Review"* ]]
}

@test "build_pr_claude_md includes security-review loop instructions" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"/security-review"* ]]
    [[ "${output}" == *"AI Security Review"* ]]
}

@test "build_pr_claude_md embeds MAX_CODE_REVIEW_ITERATIONS value in review guidance" {
    MAX_CODE_REVIEW_ITERATIONS=3
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"already run 3 code-review rounds"* ]]
}

@test "build_pr_claude_md embeds custom MAX_CODE_REVIEW_ITERATIONS when overridden" {
    MAX_CODE_REVIEW_ITERATIONS=5
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"already run 5 code-review rounds"* ]]
}

@test "build_pr_claude_md PHASE E self-detects non-convergence and advances without blocking" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"substantially repeating a prior round"* ]]
    [[ "${output}" == *"code review is not converging"* ]]
    [[ "${output}" == *'advance the board to "AI Security Review"'* ]]
    [[ "${output}" == *"Do NOT add the Blocked label"* ]]
}

@test "build_pr_claude_md PHASE E's non-convergence early exit requires MIN_REVIEW_CONVERGENCE_ROUNDS code-review rounds, not just a single repeat" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"AND at least 3 code-review rounds"* ]]
    [[ "${output}" == *"a repeat but fewer than 3 rounds have run so far, so one failed fix attempt is not yet enough evidence to give up"* ]]
}

@test "build_pr_claude_md PHASE F's non-convergence early exit requires MIN_REVIEW_CONVERGENCE_ROUNDS security-review rounds, not just a single repeat" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"AND at least 3 security-review rounds"* ]]
}

@test "build_pr_claude_md PHASE E checks the round cap before the fix-new-findings branch, so the cap is reachable even when findings keep being new" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false"
    [ "${status}" -eq 0 ]
    cap_line=$(printf '%s\n' "${output}" | grep -n "code-review rounds on this PR" | head -1 | cut -d: -f1)
    fix_line=$(printf '%s\n' "${output}" | grep -n "and the round cap has not been reached" | head -1 | cut -d: -f1)
    [ -n "${cap_line}" ]
    [ -n "${fix_line}" ]
    [ "${cap_line}" -lt "${fix_line}" ]
}

@test "build_pr_claude_md embeds MAX_SECURITY_REVIEW_ITERATIONS value in security-review guidance" {
    MAX_SECURITY_REVIEW_ITERATIONS=3
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"already run 3 security-review rounds"* ]]
}

@test "build_pr_claude_md embeds custom MAX_SECURITY_REVIEW_ITERATIONS when overridden" {
    MAX_SECURITY_REVIEW_ITERATIONS=5
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"already run 5 security-review rounds"* ]]
}

@test "build_pr_claude_md PHASE F self-detects non-convergence and advances without blocking" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"security review is not converging"* ]]
    [[ "${output}" == *'advance the board to "AI Coverage"'* ]]
}

@test "build_pr_claude_md PHASE F checks the round cap before the fix-new-findings branch, so the cap is reachable even when findings keep being new" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false"
    [ "${status}" -eq 0 ]
    # PHASE E's identical shared-template text appears earlier in the document than PHASE F's;
    # take the LAST occurrence of the (phase-agnostic) fix-branch phrase so this asserts PHASE F's
    # own ordering rather than accidentally comparing against PHASE E's.
    cap_line=$(printf '%s\n' "${output}" | grep -n "security-review rounds on this PR" | head -1 | cut -d: -f1)
    fix_line=$(printf '%s\n' "${output}" | grep -n "and the round cap has not been reached" | tail -1 | cut -d: -f1)
    [ -n "${cap_line}" ]
    [ -n "${fix_line}" ]
    [ "${cap_line}" -lt "${fix_line}" ]
}

@test "MAX_PR_TOTAL_INVOCATIONS's default recomputes when a per-phase budget is overridden, proving it isn't a separate stale literal" {
    export MAX_SIMPLIFY_ITERATIONS=20
    # setup()'s own source_oneshot already defaulted MAX_PR_TOTAL_INVOCATIONS to 57; unset it first
    # so this second source genuinely re-derives the default rather than short-circuiting on
    # "${MAX_PR_TOTAL_INVOCATIONS:-...}" already being non-empty from that first sourcing.
    unset MAX_PR_TOTAL_INVOCATIONS
    source_oneshot
    # 20 (overridden) + 15 (code-review) + 15 (security-review) + 6 (coverage) + 11 (headroom) = 67,
    # not the unoverridden default of 57: only reachable if lib/globals genuinely reuses the four
    # budgets above rather than a separately hardcoded literal that happens to equal 57.
    [ "${MAX_PR_TOTAL_INVOCATIONS}" -eq 67 ]
}

@test "MAX_PR_TOTAL_INVOCATIONS actually falls back to the computed default when given a non-numeric override" {
    export MAX_PR_TOTAL_INVOCATIONS="not-a-number"
    source_oneshot
    [ "${MAX_PR_TOTAL_INVOCATIONS}" -eq 57 ]
}

@test "MAX_PR_TOTAL_INVOCATIONS falls back to the computed default when given an 8-digit override, exceeding its 7-digit bound" {
    export MAX_PR_TOTAL_INVOCATIONS="10000000"
    source_oneshot
    [ "${MAX_PR_TOTAL_INVOCATIONS}" -eq 57 ]
}

@test "MAX_PR_TOTAL_INVOCATIONS's computed default self-validates when all four inputs are near their own 6-digit max" {
    export MAX_SIMPLIFY_ITERATIONS=999999
    export MAX_CODE_REVIEW_ITERATIONS=999999
    export MAX_SECURITY_REVIEW_ITERATIONS=999999
    export MAX_COVERAGE_ITERATIONS=999999
    unset MAX_PR_TOTAL_INVOCATIONS
    source_oneshot
    # 4 * 999999 + 11 = 4000007, a 7-digit number: this is the exact edge case the 7-digit bound
    # (one digit wider than its four inputs) exists to let through without falling back on itself.
    [ "${MAX_PR_TOTAL_INVOCATIONS}" -eq 4000007 ]
}

@test "build_pr_claude_md PHASE D runs /simplify and stops before code review" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PHASE D — Simplify"* ]]
    [[ "${output}" == *"Run /simplify against the diff"* ]]
    [[ "${output}" == *"Do NOT proceed to code review in this same session"* ]]
}

@test "build_pr_claude_md PHASE D gives up on thrashing without blocking the PR" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"3 or more simplify rounds have run"* ]]
    [[ "${output}" == *"simplify did not converge"* ]]
    [[ "${output}" == *"Do NOT add the Blocked label"* ]]
}

@test "build_pr_claude_md PHASE D embeds MAX_SIMPLIFY_ITERATIONS and SIMPLIFY_THRASH_LIMIT values" {
    MAX_SIMPLIFY_ITERATIONS=10
    SIMPLIFY_THRASH_LIMIT=3
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"3 or more simplify rounds have run"* ]]
    [[ "${output}" == *"once 10 simplify rounds have run"* ]]
}

@test "build_pr_claude_md PHASE D embeds custom MAX_SIMPLIFY_ITERATIONS and SIMPLIFY_THRASH_LIMIT when overridden" {
    MAX_SIMPLIFY_ITERATIONS=20
    SIMPLIFY_THRASH_LIMIT=5
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"5 or more simplify rounds have run"* ]]
    [[ "${output}" == *"once 20 simplify rounds have run"* ]]
}

@test "build_pr_claude_md PHASE D triggers on any pre-AI-Review board state, not just Development" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'the board is not yet at "AI Review" or later'* ]]
    [[ "${output}" != *'the board is at "Development"'* ]]
}

@test "build_pr_claude_md PHASE E (code review) only fires once the board is at AI Review" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PHASE E — Code review"* ]]
    [[ "${output}" == *'the board is at "AI Review"'* ]]
}

@test "build_pr_claude_md renumbers security review, coverage, and finalize to PHASE F, G, and H" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PHASE F — Security review"* ]]
    [[ "${output}" == *"PHASE G: Coverage"* ]]
    [[ "${output}" == *"PHASE H: Finalize"* ]]
}

@test "build_pr_claude_md PHASE F (security review) advances to AI Coverage, not Human Review, when clean" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'advance the board to "AI Coverage"'* ]]
}

@test "build_pr_claude_md PHASE G (coverage) only fires once the board is at AI Coverage" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'the board is at "AI Coverage"'* ]]
}

@test "build_pr_claude_md PHASE G runs the real coverage ratchet decision procedure" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"coverage-ratchet.instructions.md"* ]]
    [[ "${output}" == *"AI Coverage Phase Decision Procedure"* ]]
    [[ "${output}" != *"credfeto/cs-template#992"* ]]
}

@test "build_pr_claude_md PHASE G bootstraps and passes when COVERAGE.md does not exist on main yet" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"bootstrap case"* ]]
    [[ "${output}" == *"treat it as passed"* ]]
}

@test "build_pr_claude_md PHASE G skips measurement entirely for a non-code-only branch" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"non-code-only"* ]]
    [[ "${output}" == *"skip straight to the success step"* ]]
}

@test "build_pr_claude_md PHASE G lists workflow, SQL, shell, Docker, and docs-only changes as non-code" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"GitHub Actions workflow"* ]]
    [[ "${output}" == *"SQL/T-SQL"* ]]
    [[ "${output}" == *"shell script"* ]]
    [[ "${output}" == *"Dockerfile"* ]]
    [[ "${output}" == *"documentation-only change"* ]]
}

@test "build_pr_claude_md PHASE G commits COVERAGE.md on a passing ratchet, but not on a failing one" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"write/overwrite COVERAGE.md"* ]]
    [[ "${output}" == *"Do not touch COVERAGE.md in this case"* ]]
}

@test "build_pr_claude_md PHASE G restates 'do not touch COVERAGE.md' on all four failure-branch STOPs, not just the gap-closing one" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false"
    [ "${status}" -eq 0 ]
    count=$(printf '%s\n' "${output}" | grep -c "Do not touch COVERAGE.md in this case")
    [ "${count}" -eq 4 ]
}

@test "build_pr_claude_md PHASE G no longer looks for a PR comment" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"## Coverage Baseline (main)"* ]]
    [[ "${output}" == *"there isn't one"* ]]
}

@test "build_pr_claude_md PHASE G returns failing coverage to Development" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"returning to Development"* ]]
    [[ "${output}" == *"move the board back to \"Development\""* ]]
}

@test "build_pr_claude_md PHASE G advances to Human Review on a passing coverage ratchet" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Coverage ratchet passed - advancing to Human Review"* ]]
    [[ "${output}" == *'advance the board to "Human Review"'* ]]
}

@test "build_pr_claude_md PHASE G caps non-converging coverage rounds with Blocked" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"coverage rounds on this PR without the branch catching up"* ]]
    [[ "${output}" == *"still-failing languages and their gap"* ]]
}

@test "build_pr_claude_md PHASE G checks the round cap before the gap-closing/trend branches, so the cap is reachable regardless of trend" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false"
    [ "${status}" -eq 0 ]
    cap_line=$(printf '%s\n' "${output}" | grep -n "coverage rounds on this PR without the branch catching up" | head -1 | cut -d: -f1)
    gap_closing_line=$(printf '%s\n' "${output}" | grep -n "If the gap is closing" | head -1 | cut -d: -f1)
    [ -n "${cap_line}" ]
    [ -n "${gap_closing_line}" ]
    [ "${cap_line}" -lt "${gap_closing_line}" ]
}

@test "build_pr_claude_md PHASE G can bail early on a flat coverage trend, unlike PHASE E/F it blocks" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"trend is flat or worsening"* ]]
    [[ "${output}" == *"your specific reasoning for why you believe coverage cannot realistically be raised further"* ]]
    [[ "${output}" == *"Unlike Phase E/F's early exit, this one blocks"* ]]
    [[ "${output}" == *"a coverage round's pass/fail IS the ratchet's own verdict"* ]]
}

@test "build_pr_claude_md PHASE G treats a language failing for the first time on a later round as trending, not as breaking the gap-closing verdict" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Treat a language as trending, with nothing yet to compare, only when no prior comment mentions it at all, regardless of which round this is."* ]]
    [[ "${output}" == *"or is being treated as trending per the carve-out above because it has no previous round to compare against"* ]]
}

@test "build_pr_claude_md PHASE G's trend comparison targets the most recent comment mentioning a language, not necessarily the previous round" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"against its Overall in the most recent prior coverage comment that mentions that language by name"* ]]
    [[ "${output}" == *"this is not necessarily the immediately preceding round, since a language that passed in a round leaves no comment mentioning it for that round"* ]]
}

@test "build_pr_claude_md embeds MAX_COVERAGE_ITERATIONS value in coverage guidance" {
    MAX_COVERAGE_ITERATIONS=6
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"already run 6 coverage rounds"* ]]
    [[ "${output}" == *"fire before 6 is reached"* ]]
}

@test "build_pr_claude_md embeds custom MAX_COVERAGE_ITERATIONS when overridden" {
    MAX_COVERAGE_ITERATIONS=2
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"already run 2 coverage rounds"* ]]
    [[ "${output}" == *"fire before 2 is reached"* ]]
}

@test "build_pr_claude_md does not include WF section when _WF_PROJECT_ID is empty" {
    _WF_PROJECT_ID=""
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"WF_PROJECT_ID"* ]]
}

@test "build_pr_claude_md includes WF section when _WF_PROJECT_ID is set" {
    _WF_PROJECT_ID="PVT_pr_proj"
    _WF_STATUS_FIELD_ID="PVTSSF_pr_field"
    _WF_OPTION_IDS["AI Review"]="opt_air_id"
    _WF_OPTION_IDS["Human Review"]="opt_hr_id"
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"WF_PROJECT_ID=PVT_pr_proj"* ]]
    [[ "${output}" == *'WF_AI_REVIEW=opt_air_id'* ]]
    [[ "${output}" == *'WF_HUMAN_REVIEW=opt_hr_id'* ]]
}

# --- _build_wf_section unit tests ---------------------------------------------

@test "_build_wf_section outputs nothing when _WF_PROJECT_ID is empty" {
    _WF_PROJECT_ID=""
    run _build_wf_section
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "_build_wf_section outputs project ID and field ID when set" {
    _WF_PROJECT_ID="PVT_abc123"
    _WF_STATUS_FIELD_ID="PVTSSF_def456"
    run _build_wf_section
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"WF_PROJECT_ID=PVT_abc123"* ]]
    [[ "${output}" == *"WF_STATUS_FIELD_ID=PVTSSF_def456"* ]]
}

@test "_build_wf_section outputs all ten status option keys" {
    _WF_PROJECT_ID="PVT_test"
    _WF_STATUS_FIELD_ID="PVTSSF_test"
    _WF_OPTION_IDS["Not Started"]="opt1"
    _WF_OPTION_IDS[Planning]="opt2"
    _WF_OPTION_IDS[Approved]="opt3"
    _WF_OPTION_IDS[Development]="opt4"
    _WF_OPTION_IDS["AI Simplify"]="opt4b"
    _WF_OPTION_IDS["AI Review"]="opt5"
    _WF_OPTION_IDS["AI Security Review"]="opt6"
    _WF_OPTION_IDS["AI Coverage"]="opt6b"
    _WF_OPTION_IDS["Human Review"]="opt7"
    _WF_OPTION_IDS[Complete]="opt8"
    run _build_wf_section
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"WF_NOT_STARTED=opt1"* ]]
    [[ "${output}" == *"WF_PLANNING=opt2"* ]]
    [[ "${output}" == *"WF_APPROVED=opt3"* ]]
    [[ "${output}" == *"WF_DEVELOPMENT=opt4"* ]]
    [[ "${output}" == *"WF_AI_SIMPLIFY=opt4b"* ]]
    [[ "${output}" == *"WF_AI_REVIEW=opt5"* ]]
    [[ "${output}" == *"WF_AI_SECURITY_REVIEW=opt6"* ]]
    [[ "${output}" == *"WF_AI_COVERAGE=opt6b"* ]]
    [[ "${output}" == *"WF_HUMAN_REVIEW=opt7"* ]]
    [[ "${output}" == *"WF_COMPLETE=opt8"* ]]
}

@test "_build_wf_section emits WF_AI_COVERAGE between WF_AI_SECURITY_REVIEW and WF_HUMAN_REVIEW" {
    _WF_PROJECT_ID="PVT_test"
    _WF_STATUS_FIELD_ID="PVTSSF_test"
    _WF_OPTION_IDS["AI Security Review"]="opt6"
    _WF_OPTION_IDS["AI Coverage"]="opt6b"
    _WF_OPTION_IDS["Human Review"]="opt7"
    run _build_wf_section
    [ "${status}" -eq 0 ]
    local security_line coverage_line human_line
    security_line=$(grep -n "WF_AI_SECURITY_REVIEW=" <<< "${output}" | cut -d: -f1)
    coverage_line=$(grep -n "WF_AI_COVERAGE=" <<< "${output}" | cut -d: -f1)
    human_line=$(grep -n "WF_HUMAN_REVIEW=" <<< "${output}" | cut -d: -f1)
    [ "${security_line}" -lt "${coverage_line}" ]
    [ "${coverage_line}" -lt "${human_line}" ]
}

# --- project_cache_file_path / load_project_cache / save_project_cache / --------------
# --- invalidate_project_cache unit tests ------------------------------------------------

@test "project_cache_file_path returns a path under SESSION_BASE_DIR" {
    [ "$(project_cache_file_path)" = "${SESSION_BASE_DIR}/project-cache.json" ]
}

@test "load_project_cache returns 1 when no cache file exists" {
    run load_project_cache
    [ "${status}" -eq 1 ]
}

@test "load_project_cache returns 1 and does not populate globals for a stale (TTL-expired) entry" {
    local stale_at=$(( $(date +%s) - 7200 ))
    jq -n --arg repo "${REPO_FULL}" --argjson cached_at "${stale_at}" \
        '{repo: $repo, project_id: "PVT_stale", status_field_id: "PVTSSF_stale", option_ids: {"Planning":"oid1"}, cached_at: $cached_at}' \
        > "$(project_cache_file_path)"
    PROJECT_CACHE_TTL=3600
    run load_project_cache
    [ "${status}" -eq 1 ]
}

@test "load_project_cache returns 1 for a cache file belonging to a different repo" {
    jq -n --argjson cached_at "$(date +%s)" \
        '{repo: "other/repo", project_id: "PVT_other", status_field_id: "PVTSSF_other", option_ids: {}, cached_at: $cached_at}' \
        > "$(project_cache_file_path)"
    run load_project_cache
    [ "${status}" -eq 1 ]
}

@test "load_project_cache populates _WF_PROJECT_ID/_WF_STATUS_FIELD_ID/_WF_OPTION_IDS/_WF_CACHED_REPO on a fresh hit" {
    jq -n --arg repo "${REPO_FULL}" --argjson cached_at "$(date +%s)" \
        '{repo: $repo, project_id: "PVT_hit", status_field_id: "PVTSSF_hit", option_ids: {"Planning":"oid1","Development":"oid2"}, cached_at: $cached_at}' \
        > "$(project_cache_file_path)"
    run load_project_cache
    [ "${status}" -eq 0 ]
    load_project_cache
    [ "${_WF_PROJECT_ID}" = "PVT_hit" ]
    [ "${_WF_STATUS_FIELD_ID}" = "PVTSSF_hit" ]
    [ "${_WF_OPTION_IDS[Planning]}" = "oid1" ]
    [ "${_WF_OPTION_IDS[Development]}" = "oid2" ]
    [ "${_WF_CACHED_REPO}" = "${REPO_FULL}" ]
}

@test "save_project_cache writes a JSON file readable by load_project_cache" {
    _WF_PROJECT_ID="PVT_saved"
    _WF_STATUS_FIELD_ID="PVTSSF_saved"
    unset _WF_OPTION_IDS
    declare -gA _WF_OPTION_IDS
    _WF_OPTION_IDS["Planning"]="oid1"
    _WF_OPTION_IDS["Development"]="oid2"
    save_project_cache
    [ -f "$(project_cache_file_path)" ]
    run jq -r '.repo' "$(project_cache_file_path)"
    [ "${output}" = "${REPO_FULL}" ]
    run jq -r '.project_id' "$(project_cache_file_path)"
    [ "${output}" = "PVT_saved" ]

    _WF_PROJECT_ID=""
    _WF_STATUS_FIELD_ID=""
    unset _WF_OPTION_IDS
    declare -gA _WF_OPTION_IDS
    load_project_cache
    [ "${_WF_PROJECT_ID}" = "PVT_saved" ]
    [ "${_WF_STATUS_FIELD_ID}" = "PVTSSF_saved" ]
    [ "${_WF_OPTION_IDS[Planning]}" = "oid1" ]
    [ "${_WF_OPTION_IDS[Development]}" = "oid2" ]
}

@test "invalidate_project_cache removes the disk cache file and clears in-memory globals" {
    _WF_PROJECT_ID="PVT_saved"
    _WF_STATUS_FIELD_ID="PVTSSF_saved"
    unset _WF_OPTION_IDS
    declare -gA _WF_OPTION_IDS
    _WF_OPTION_IDS["Planning"]="oid1"
    save_project_cache
    _WF_CACHE["${REPO_FULL}:discovered"]="1"
    _WF_CACHE["${REPO_FULL}:project_id"]="PVT_saved"
    _WF_CACHE["${REPO_FULL}:field_id"]="PVTSSF_saved"
    _WF_CACHE["${REPO_FULL}:opt_names"]="Planning"$'\n'
    _WF_CACHE["${REPO_FULL}:opt:Planning"]="oid1"
    _WF_CACHED_REPO="${REPO_FULL}"

    invalidate_project_cache

    [ ! -f "$(project_cache_file_path)" ]
    [ -z "${_WF_CACHE["${REPO_FULL}:discovered"]:-}" ]
    [ -z "${_WF_CACHE["${REPO_FULL}:project_id"]:-}" ]
    [ -z "${_WF_CACHED_REPO}" ]
    [ -z "${_WF_PROJECT_ID}" ]
}

# --- discover_or_create_workflow_project unit tests ---------------------------

@test "discover_or_create_workflow_project leaves _WF_PROJECT_ID empty when gh graphql fails" {
    make_stub gh 'exit 1'
    discover_or_create_workflow_project
    [ -z "${_WF_PROJECT_ID}" ]
}

@test "discover_or_create_workflow_project warns with error content when gh graphql fails with stderr output" {
    make_stub gh 'printf "HTTP 422 Unprocessable Entity\n" >&2; exit 1'
    run discover_or_create_workflow_project
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"GraphQL query failed"* ]]
    [[ "${output}" == *"HTTP 422"* ]]
}

@test "discover_or_create_workflow_project warns with auth hint when gh graphql error mentions scope" {
    make_stub gh 'printf "Your token is missing the project scope\n" >&2; exit 1'
    run discover_or_create_workflow_project
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"gh auth refresh -s project"* ]]
}

@test "discover_or_create_workflow_project warns with auth hint when gh graphql error mentions permission" {
    make_stub gh 'printf "Insufficient permissions to access this resource\n" >&2; exit 1'
    run discover_or_create_workflow_project
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"gh auth refresh -s project"* ]]
}

@test "discover_or_create_workflow_project warns with auth hint when gh graphql error mentions authorization" {
    make_stub gh 'printf "Unauthorized: authorization required\n" >&2; exit 1'
    run discover_or_create_workflow_project
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"gh auth refresh -s project"* ]]
}

@test "discover_or_create_workflow_project populates _WF_PROJECT_ID from existing project" {
    local project_json='[{"id":"PVT_found","title":"Workflow","fields":{"nodes":[{"id":"PVTSSF_f1","name":"Workflow Status","options":[{"id":"oid1","name":"Planning"},{"id":"oid2","name":"Development"}]}]}}]'
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
if [[ "\$*" == *"projectsV2"* ]]; then
    printf '{"nodes":%s,"pageInfo":{"endCursor":null,"hasNextPage":false}}\n' '${project_json}'
    exit 0
fi
exit 1
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    discover_or_create_workflow_project
    [ "${_WF_PROJECT_ID}" = "PVT_found" ]
    [ "${_WF_STATUS_FIELD_ID}" = "PVTSSF_f1" ]
    [ "${_WF_OPTION_IDS[Planning]}" = "oid1" ]
    [ "${_WF_OPTION_IDS[Development]}" = "oid2" ]
}

@test "discover_or_create_workflow_project backfills the missing AI Simplify option onto a pre-existing board (#1169)" {
    local project_json='[{"id":"PVT_found","title":"Workflow","fields":{"nodes":[{"id":"PVTSSF_f1","name":"Workflow Status","options":[{"id":"oid1","name":"Development","color":"PURPLE","description":""}]}]}}]'
    local updated_field='{"id":"PVTSSF_f1","name":"Workflow Status","options":[{"id":"oid1","name":"Development","color":"PURPLE","description":""},{"id":"oid_new","name":"AI Simplify","color":"PURPLE","description":""}]}'
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
if [[ "\$*" == *"projectsV2"* ]]; then
    printf '{"nodes":%s,"pageInfo":{"endCursor":null,"hasNextPage":false}}\n' '${project_json}'
    exit 0
fi
if [[ "\$*" == *"--input"* ]]; then
    cat >/dev/null
    printf '{"data":{"updateProjectV2Field":{"projectV2Field":%s}}}\n' '${updated_field}'
    exit 0
fi
exit 1
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    discover_or_create_workflow_project
    [ "${_WF_PROJECT_ID}" = "PVT_found" ]
    [ "${_WF_OPTION_IDS[Development]}" = "oid1" ]
    [ "${_WF_OPTION_IDS["AI Simplify"]}" = "oid_new" ]
}

@test "discover_or_create_workflow_project does not call the field-option mutation when AI Simplify and AI Coverage are already present" {
    local project_json='[{"id":"PVT_found","title":"Workflow","fields":{"nodes":[{"id":"PVTSSF_f1","name":"Workflow Status","options":[{"id":"oid1","name":"Development","color":"PURPLE","description":""},{"id":"oid2","name":"AI Simplify","color":"PURPLE","description":""},{"id":"oid3","name":"AI Security Review","color":"RED","description":""},{"id":"oid4","name":"AI Coverage","color":"RED","description":""}]}]}}]'
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
if [[ "\$*" == *"projectsV2"* ]]; then
    printf '{"nodes":%s,"pageInfo":{"endCursor":null,"hasNextPage":false}}\n' '${project_json}'
    exit 0
fi
if [[ "\$*" == *"--input"* ]]; then
    echo "unexpected mutation call" >> "${TEST_TMP}/unexpected.log"
    cat >/dev/null
    printf '{}'
    exit 0
fi
exit 1
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    discover_or_create_workflow_project
    [ "${_WF_OPTION_IDS["AI Simplify"]}" = "oid2" ]
    [ "${_WF_OPTION_IDS["AI Coverage"]}" = "oid4" ]
    [ ! -f "${TEST_TMP}/unexpected.log" ]
}

@test "discover_or_create_workflow_project backfills the missing AI Coverage option onto a pre-existing board that already has AI Simplify (#1215)" {
    local project_json='[{"id":"PVT_found","title":"Workflow","fields":{"nodes":[{"id":"PVTSSF_f1","name":"Workflow Status","options":[{"id":"oid1","name":"Development","color":"PURPLE","description":""},{"id":"oid2","name":"AI Simplify","color":"PURPLE","description":""},{"id":"oid3","name":"AI Security Review","color":"RED","description":""},{"id":"oid5","name":"Human Review","color":"GREEN","description":""}]}]}}]'
    local updated_field='{"id":"PVTSSF_f1","name":"Workflow Status","options":[{"id":"oid1","name":"Development","color":"PURPLE","description":""},{"id":"oid2","name":"AI Simplify","color":"PURPLE","description":""},{"id":"oid3","name":"AI Security Review","color":"RED","description":""},{"id":"oid_new","name":"AI Coverage","color":"RED","description":""},{"id":"oid5","name":"Human Review","color":"GREEN","description":""}]}'
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
if [[ "\$*" == *"projectsV2"* ]]; then
    printf '{"nodes":%s,"pageInfo":{"endCursor":null,"hasNextPage":false}}\n' '${project_json}'
    exit 0
fi
if [[ "\$*" == *"--input"* ]]; then
    cat >/dev/null
    printf '{"data":{"updateProjectV2Field":{"projectV2Field":%s}}}\n' '${updated_field}'
    exit 0
fi
exit 1
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    discover_or_create_workflow_project
    [ "${_WF_OPTION_IDS["AI Security Review"]}" = "oid3" ]
    [ "${_WF_OPTION_IDS["AI Coverage"]}" = "oid_new" ]
    [ "${_WF_OPTION_IDS["Human Review"]}" = "oid5" ]
}

@test "discover_or_create_workflow_project persists a disk cache file after live discovery" {
    local project_json='[{"id":"PVT_found","title":"Workflow","fields":{"nodes":[{"id":"PVTSSF_f1","name":"Workflow Status","options":[{"id":"oid1","name":"Planning"}]}]}}]'
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
if [[ "\$*" == *"projectsV2"* ]]; then
    printf '{"nodes":%s,"pageInfo":{"endCursor":null,"hasNextPage":false}}\n' '${project_json}'
    exit 0
fi
exit 1
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    discover_or_create_workflow_project
    [ -f "$(project_cache_file_path)" ]
    run jq -r '.project_id' "$(project_cache_file_path)"
    [ "${output}" = "PVT_found" ]
    run jq -r '.repo' "$(project_cache_file_path)"
    [ "${output}" = "${REPO_FULL}" ]
}

@test "discover_or_create_workflow_project reads from disk cache without invoking gh when in-memory cache is empty" {
    jq -n --arg repo "${REPO_FULL}" --argjson cached_at "$(date +%s)" \
        '{repo: $repo, project_id: "PVT_disk", status_field_id: "PVTSSF_disk", option_ids: {"Planning":"oid1"}, cached_at: $cached_at}' \
        > "$(project_cache_file_path)"
    make_stub gh 'exit 1'
    discover_or_create_workflow_project
    [ "${_WF_PROJECT_ID}" = "PVT_disk" ]
    [ "${_WF_STATUS_FIELD_ID}" = "PVTSSF_disk" ]
    [ "${_WF_OPTION_IDS[Planning]}" = "oid1" ]
    [ "${_WF_CACHED_REPO}" = "${REPO_FULL}" ]
}

@test "discover_or_create_workflow_project returns immediately on second call for same repo when first succeeded" {
    local project_json='[{"id":"PVT_cache","title":"Workflow","fields":{"nodes":[{"id":"PVTSSF_c1","name":"Workflow Status","options":[{"id":"oid1","name":"Planning"}]}]}}]'
    local call_count_file="${TEST_TMP}/gh_calls"
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
printf 'called\n' >> "${call_count_file}"
if [[ "\$*" == *"projectsV2"* ]]; then
    printf '{"nodes":%s,"pageInfo":{"endCursor":null,"hasNextPage":false}}\n' '${project_json}'
    exit 0
fi
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    discover_or_create_workflow_project
    local count_after_first
    count_after_first=$(wc -l < "${call_count_file}" 2>/dev/null || printf '0\n')
    discover_or_create_workflow_project
    local count_after_second
    count_after_second=$(wc -l < "${call_count_file}" 2>/dev/null || printf '0\n')
    # Second call must not invoke gh at all (cache hit)
    [ "${count_after_second}" -eq "${count_after_first}" ]
}

@test "discover_or_create_workflow_project re-discovers when repo changes" {
    local call_count_file="${TEST_TMP}/gh_calls"
    make_stub gh "printf 'called\n' >> ${call_count_file}; exit 1"
    _WF_CACHED_REPO="other/repo"
    discover_or_create_workflow_project
    local count
    count=$(wc -l < "${call_count_file}" 2>/dev/null || printf '0\n')
    [ "${count}" -ge 1 ]
}

@test "discover_or_create_workflow_project restores cached globals without re-calling gh when switching back to a previously discovered repo" {
    local project_json='[{"id":"PVT_repo_a","title":"Workflow","fields":{"nodes":[{"id":"PVTSSF_a1","name":"Workflow Status","options":[{"id":"oid_planning","name":"Planning"},{"id":"oid_dev","name":"Development"}]}]}}]'
    local call_count_file="${TEST_TMP}/gh_calls"
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
printf 'called\n' >> "${call_count_file}"
if [[ "\$*" == *"projectsV2"* ]]; then
    printf '{"nodes":%s,"pageInfo":{"endCursor":null,"hasNextPage":false}}\n' '${project_json}'
    exit 0
fi
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    REPO_FULL="owner/repo-a"
    OWNER="owner"
    REPO="repo-a"
    discover_or_create_workflow_project
    REPO_FULL="owner/repo-b"
    OWNER="owner"
    REPO="repo-b"
    discover_or_create_workflow_project
    local count_after_b
    count_after_b=$(wc -l < "${call_count_file}" 2>/dev/null || printf '0\n')
    REPO_FULL="owner/repo-a"
    OWNER="owner"
    REPO="repo-a"
    discover_or_create_workflow_project
    local count_after_return
    count_after_return=$(wc -l < "${call_count_file}" 2>/dev/null || printf '0\n')
    [ "${count_after_return}" -eq "${count_after_b}" ]
    [ "${_WF_PROJECT_ID}" = "PVT_repo_a" ]
    [ "${_WF_STATUS_FIELD_ID}" = "PVTSSF_a1" ]
    [ "${_WF_OPTION_IDS[Planning]}" = "oid_planning" ]
    [ "${_WF_OPTION_IDS[Development]}" = "oid_dev" ]
}

@test "discover_or_create_workflow_project enables Projects when hasProjectsEnabled is false" {
    local project_json='[{"id":"PVT_found","title":"Workflow","fields":{"nodes":[{"id":"PVTSSF_f1","name":"Workflow Status","options":[{"id":"oid1","name":"Not Started"}]}]}}]'
    local gh_log="${TEST_TMP}/gh_calls"
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${gh_log}"
if [[ "\$*" == *"hasProjectsEnabled"* ]]; then printf 'false\n'; exit 0; fi
if [[ "\$*" == *"repo edit"* ]]; then exit 0; fi
if [[ "\$*" == *"projectsV2"* ]]; then printf '{"nodes":%s,"pageInfo":{"endCursor":null,"hasNextPage":false}}\n' '${project_json}'; exit 0; fi
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    discover_or_create_workflow_project
    grep -q 'enable-projects' "${gh_log}"
    [ "${_WF_PROJECT_ID}" = "PVT_found" ]
}

@test "discover_or_create_workflow_project finds project on the second page" {
    local project_json='[{"id":"PVT_page2","title":"Workflow","fields":{"nodes":[{"id":"PVTSSF_p2","name":"Workflow Status","options":[{"id":"opt1","name":"Planning"}]}]}}]'
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
if [[ "\$*" == *"projectsV2"* ]]; then
    if [[ "\$*" == *"cursor="* ]]; then
        printf '{"nodes":%s,"pageInfo":{"endCursor":null,"hasNextPage":false}}\n' '${project_json}'
    else
        printf '{"nodes":[],"pageInfo":{"endCursor":"cursor_page2","hasNextPage":true}}\n'
    fi
    exit 0
fi
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    discover_or_create_workflow_project
    [ "${_WF_PROJECT_ID}" = "PVT_page2" ]
    [ "${_WF_STATUS_FIELD_ID}" = "PVTSSF_p2" ]
    [ "${_WF_OPTION_IDS[Planning]}" = "opt1" ]
}

@test "discover_or_create_workflow_project stops pagination when hasNextPage is true but endCursor is absent" {
    local graphql_call_count_file="${TEST_TMP}/graphql_calls"
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
if [[ "\$*" == *"projectsV2"* ]]; then
    printf 'called\n' >> "${graphql_call_count_file}"
    printf '{"nodes":[],"pageInfo":{"endCursor":null,"hasNextPage":true}}\n'
    exit 0
fi
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    _wf_create_project() { return 1; }
    discover_or_create_workflow_project
    [ -z "${_WF_PROJECT_ID}" ]
    local count
    count=$(wc -l < "${graphql_call_count_file}" 2>/dev/null || printf '0\n')
    [ "${count}" -eq 1 ]
}

# --- _wf_create_project / _wf_invite_trusted_collaborators unit tests ---------

@test "_wf_create_project falls through to user query when org query exits non-zero" {
    local gh_log="${TEST_TMP}/gh_calls"
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${gh_log}"
if [[ "\$*" == *"organization"* ]]; then
    printf '{"data":{"organization":null},"errors":[{"message":"NOT_FOUND"}]}\n'
    exit 1
fi
if [[ "\$*" == *"user(login"* ]]; then
    printf 'U_abc123\n'
    exit 0
fi
if [[ "\$*" == *"repository(owner"* ]]; then
    printf 'R_repo123\n'
    exit 0
fi
if [[ "\$*" == *"createProjectV2"* ]]; then
    printf '{"data":{"createProjectV2":{"projectV2":{"id":"PVT_new"}}}}\n'
    exit 0
fi
printf '{}\n'; exit 0
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    get_trusted_logins() { printf '["testuser"]\n'; }
    _wf_invite_trusted_collaborators() { return 0; }
    _wf_create_project
    grep -q 'user(login' "${gh_log}"
    grep -q 'createProjectV2' "${gh_log}"
}

@test "_wf_create_project falls through to user query when org query outputs a JSON blob" {
    local gh_log="${TEST_TMP}/gh_calls"
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${gh_log}"
if [[ "\$*" == *"organization"* ]]; then
    printf '{"data":{"organization":null},"errors":[{"message":"NOT_FOUND"}]}\n'
    exit 0
fi
if [[ "\$*" == *"user(login"* ]]; then
    printf 'U_abc123\n'
    exit 0
fi
if [[ "\$*" == *"repository(owner"* ]]; then
    printf 'R_repo123\n'
    exit 0
fi
if [[ "\$*" == *"createProjectV2"* ]]; then
    printf '{"data":{"createProjectV2":{"projectV2":{"id":"PVT_new"}}}}\n'
    exit 0
fi
printf '{}\n'; exit 0
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    get_trusted_logins() { printf '["testuser"]\n'; }
    _wf_invite_trusted_collaborators() { return 0; }
    _wf_create_project
    grep -q 'user(login' "${gh_log}"
    grep -q 'createProjectV2' "${gh_log}"
}

@test "_wf_create_project warns and returns 1 when both org and user queries return nothing" {
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
if [[ "\$*" == *"organization"* ]] || [[ "\$*" == *"user(login"* ]]; then
    exit 1
fi
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    run _wf_create_project
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"cannot resolve owner node ID"* ]]
}

@test "_wf_create_project passes repositoryId to createProjectV2 for repo-scoped project" {
    local gh_log="${TEST_TMP}/gh_calls"
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${gh_log}"
if [[ "\$*" == *"organization"* ]]; then printf 'O_owner\n'; exit 0; fi
if [[ "\$*" == *"user(login"* ]]; then printf 'U_user\n'; exit 0; fi
if [[ "\$*" == *"repository(owner"* ]]; then printf 'R_repo\n'; exit 0; fi
if [[ "\$*" == *"createProjectV2"* ]]; then
    printf '{"data":{"createProjectV2":{"projectV2":{"id":"PVT_scoped"}}}}\n'; exit 0
fi
printf '{}\n'; exit 0
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    _wf_invite_trusted_collaborators() { return 0; }
    _wf_create_project
    grep -q 'repositoryId' "${gh_log}"
    run grep -q 'linkProjectV2ToRepository' "${gh_log}"
    [ "${status}" -ne 0 ]
}

@test "_wf_create_project warns and returns 1 when repo node ID cannot be resolved" {
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
if [[ "\$*" == *"organization"* ]]; then printf 'O_owner\n'; exit 0; fi
if [[ "\$*" == *"user(login"* ]]; then printf 'U_user\n'; exit 0; fi
if [[ "\$*" == *"repository(owner"* ]]; then exit 1; fi
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    run _wf_create_project
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"cannot resolve repo node ID"* ]]
}

@test "_wf_invite_trusted_collaborators skips copilot bot and invites real users" {
    local gh_log="${TEST_TMP}/gh_calls"
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${gh_log}"
if [[ "\$*" == *"user(login"* ]]; then
    printf '{"data":{"u0":{"id":"U_real"}}}\n'
    exit 0
fi
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    get_trusted_logins() { printf '["someuser","copilot-pull-request-reviewer"]\n'; }
    _wf_invite_trusted_collaborators "PVT_test"
    run grep -c 'user(login' "${gh_log}"
    [ "${output}" -eq 1 ]
    run grep -q 'copilot' "${gh_log}"
    [ "${status}" -ne 0 ]
}

@test "_wf_invite_trusted_collaborators is a no-op when no logins resolve to a node ID" {
    local gh_log="${TEST_TMP}/gh_calls"
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${gh_log}"
printf '{"data":{"u0":{"id":null}}}\n'; exit 0
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    get_trusted_logins() { printf '["ghost"]\n'; }
    run _wf_invite_trusted_collaborators "PVT_test"
    [ "${status}" -eq 0 ]
    run grep -q 'updateProjectV2Collaborators' "${gh_log}"
    [ "${status}" -ne 0 ]
}

@test "_wf_invite_trusted_collaborators warns and returns 0 when updateProjectV2Collaborators fails" {
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
if [[ "\$*" == *"user(login"* ]]; then
    printf '{"data":{"u0":{"id":"U_real"}}}\n'; exit 0
fi
exit 1
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    get_trusted_logins() { printf '["someuser"]\n'; }
    run _wf_invite_trusted_collaborators "PVT_test"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"updateProjectV2Collaborators failed"* ]]
}

@test "_wf_invite_trusted_collaborators batches multiple user lookups into a single gh call" {
    local gh_log="${TEST_TMP}/gh_calls"
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${gh_log}"
if [[ "\$*" == *"u0:user"* ]]; then
    printf '{"data":{"u0":{"id":"U_alice"},"u1":{"id":"U_bob"}}}\n'
    exit 0
fi
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    get_trusted_logins() { printf '["alice","bob"]\n'; }
    _wf_invite_trusted_collaborators "PVT_test"
    run grep -c 'u0:user' "${gh_log}"
    [ "${output}" -eq 1 ]
    run grep -q 'u1:user' "${gh_log}"
    [ "${status}" -eq 0 ]
    run grep -q -- '--input' "${gh_log}"
    [ "${status}" -eq 0 ]
}

# --- update_workflow_status unit tests ----------------------------------------

@test "update_workflow_status is a no-op when _WF_PROJECT_ID is empty" {
    _WF_PROJECT_ID=""
    local call_log="${TEST_TMP}/gh_calls"
    make_stub gh "printf 'called\n' >> ${call_log}; exit 0"
    run update_workflow_status "Issue" "42" "Planning"
    [ ! -f "${call_log}" ]
    [[ "${output}" != *"adding Issue #42 to board"* ]]
}

@test "update_workflow_status warns and returns 0 when status name is unknown" {
    _WF_PROJECT_ID="PVT_test"
    _WF_STATUS_FIELD_ID="PVTSSF_test"
    unset _WF_OPTION_IDS
    declare -A _WF_OPTION_IDS
    run update_workflow_status "Issue" "42" "NonExistentStatus"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"unknown status"* ]]
}

@test "update_workflow_status logs info when starting to add item to board" {
    _WF_PROJECT_ID="PVT_test"
    _WF_STATUS_FIELD_ID="PVTSSF_test"
    _WF_OPTION_IDS[Planning]="opt_planning"
    make_stub gh 'exit 1'
    run update_workflow_status "Issue" "99" "Planning"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"adding Issue #99 to board with status 'Planning'"* ]]
}

@test "update_workflow_status calls gh api to get node_id and update project" {
    _WF_PROJECT_ID="PVT_proj"
    _WF_STATUS_FIELD_ID="PVTSSF_field"
    _WF_OPTION_IDS[Planning]="opt_planning"
    local call_log="${TEST_TMP}/gh_calls"
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${call_log}"
if [[ "\$*" == *"node_id"* ]]; then
    printf 'NODE_abc\n'
    exit 0
fi
if [[ "\$*" == *"addProjectV2ItemById"* ]]; then
    printf '{"data":{"addProjectV2ItemById":{"item":{"id":"PVTI_item1"}}}}\n'
    exit 0
fi
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    update_workflow_status "Issue" "42" "Planning"
    grep -q 'node_id' "${call_log}"
    grep -q 'addProjectV2ItemById' "${call_log}"
    grep -q 'updateProjectV2ItemFieldValue' "${call_log}"
}

@test "update_workflow_status warns and returns 0 when node_id lookup fails" {
    _WF_PROJECT_ID="PVT_proj"
    _WF_STATUS_FIELD_ID="PVTSSF_field"
    _WF_OPTION_IDS[Planning]="opt_planning"
    make_stub gh 'exit 1'
    run update_workflow_status "Issue" "42" "Planning"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"failed to get node ID"* ]]
}

@test "update_workflow_status logs info after successfully adding item to board" {
    _WF_PROJECT_ID="PVT_proj"
    _WF_STATUS_FIELD_ID="PVTSSF_field"
    _WF_OPTION_IDS[Planning]="opt_planning"
    make_stub gh 'printf "PVTI_item1\n"; exit 0'
    run update_workflow_status "Issue" "42" "Planning"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"added to board with status 'Planning'"* ]]
}

@test "update_workflow_status warns with error content when addProjectV2ItemById fails" {
    _WF_PROJECT_ID="PVT_proj"
    _WF_STATUS_FIELD_ID="PVTSSF_field"
    _WF_OPTION_IDS[Planning]="opt_planning"
    cat > "${STUB_BIN}/gh" << 'STUBEOF'
#!/usr/bin/env bash
if [[ "$*" == *"addProjectV2ItemById"* ]]; then
    printf 'GraphQL error: project not found\n' >&2
    exit 1
fi
printf 'NODE_abc\n'
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    run update_workflow_status "Issue" "42" "Planning"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"failed to add Issue #42 to project"* ]]
    [[ "${output}" == *"project not found"* ]]
}

@test "update_workflow_status invalidates the disk project cache when addProjectV2ItemById fails" {
    _WF_PROJECT_ID="PVT_proj"
    _WF_STATUS_FIELD_ID="PVTSSF_field"
    _WF_OPTION_IDS[Planning]="opt_planning"
    save_project_cache
    [ -f "$(project_cache_file_path)" ]

    cat > "${STUB_BIN}/gh" << 'STUBEOF'
#!/usr/bin/env bash
if [[ "$*" == *"addProjectV2ItemById"* ]]; then
    printf 'GraphQL error: project not found\n' >&2
    exit 1
fi
printf 'NODE_abc\n'
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    run update_workflow_status "Issue" "42" "Planning"
    [ "${status}" -eq 0 ]
    [ ! -f "$(project_cache_file_path)" ]
}

# --- report_missing_workflow_project --------------------------------------

@test "report_missing_workflow_project files an issue when none is open" {
    export WF_CREATE_LOG="${TEST_TMP}/wf_create.log"
    : > "${WF_CREATE_LOG}"
    # shellcheck disable=SC2016  # stub body: $1/$2/$* must stay literal and expand at stub runtime
    make_stub gh '
case "$1 $2" in
    "issue list")   printf "" ;;
    "issue create") printf "%s\n" "$*" >> "${WF_CREATE_LOG}" ;;
    *)              ;;
esac'

    run report_missing_workflow_project
    [ "${status}" -eq 0 ]

    run cat "${WF_CREATE_LOG}"
    [[ "${output}" == *"--title ${WF_SETUP_ISSUE_TITLE}"* ]]
    [[ "${output}" == *"--label AI-Work"* ]]
    [[ "${output}" == *"create-project --repo ${REPO_FULL}"* ]]
}

@test "report_missing_workflow_project does not file when an open issue already exists" {
    export WF_CREATE_LOG="${TEST_TMP}/wf_create.log"
    : > "${WF_CREATE_LOG}"
    # shellcheck disable=SC2016  # stub body: $1/$2/$* must stay literal and expand at stub runtime
    make_stub gh '
case "$1 $2" in
    "issue list")   printf "7\n" ;;
    "issue create") printf "%s\n" "$*" >> "${WF_CREATE_LOG}" ;;
    *)              ;;
esac'

    run report_missing_workflow_project
    [ "${status}" -eq 0 ]

    run cat "${WF_CREATE_LOG}"
    [ -z "${output}" ]
}

@test "report_missing_workflow_project files at most once per repo within a run" {
    export WF_CREATE_LOG="${TEST_TMP}/wf_create.log"
    : > "${WF_CREATE_LOG}"
    # shellcheck disable=SC2016  # stub body: $1/$2/$* must stay literal and expand at stub runtime
    make_stub gh '
case "$1 $2" in
    "issue list")   printf "" ;;
    "issue create") printf "created\n" >> "${WF_CREATE_LOG}" ;;
    *)              ;;
esac'

    report_missing_workflow_project
    report_missing_workflow_project

    run grep -c created "${WF_CREATE_LOG}"
    [ "${output}" -eq 1 ]
}

@test "report_missing_workflow_project skips filing when gh issue list fails" {
    export WF_CREATE_LOG="${TEST_TMP}/wf_create.log"
    : > "${WF_CREATE_LOG}"
    # shellcheck disable=SC2016  # stub body: $1/$2/$* must stay literal and expand at stub runtime
    make_stub gh '
case "$1 $2" in
    "issue list")   exit 1 ;;
    "issue create") printf "%s\n" "$*" >> "${WF_CREATE_LOG}" ;;
    *)              ;;
esac'

    run report_missing_workflow_project
    [ "${status}" -eq 0 ]

    run cat "${WF_CREATE_LOG}"
    [ -z "${output}" ]
}

@test "report_missing_workflow_project retries filing when previous issue creation failed" {
    export WF_CREATE_LOG="${TEST_TMP}/wf_create.log"
    : > "${WF_CREATE_LOG}"
    # shellcheck disable=SC2016  # stub body: $1/$2/$* must stay literal and expand at stub runtime
    make_stub gh '
case "$1 $2" in
    "issue list")   printf "" ;;
    "issue create") printf "attempted\n" >> "${WF_CREATE_LOG}"; exit 1 ;;
    *)              ;;
esac'

    report_missing_workflow_project
    report_missing_workflow_project

    run grep -c attempted "${WF_CREATE_LOG}"
    [ "${output}" -eq 2 ]
}

@test "report_missing_workflow_project marks repo as reported when existing issue is found" {
    # shellcheck disable=SC2016  # stub body: $1/$2/$* must stay literal and expand at stub runtime
    make_stub gh '
case "$1 $2" in
    "issue list")   printf "7\n" ;;
    "issue create") exit 1 ;;
    *)              ;;
esac'

    _WF_REPORTED_REPOS=""
    report_missing_workflow_project
    [[ " ${_WF_REPORTED_REPOS} " == *" ${REPO_FULL} "* ]]
}

@test "discover_or_create_workflow_project sets _WF_CREATION_FAILED when project creation fails" {
    cat > "${STUB_BIN}/gh" << 'STUBEOF'
#!/usr/bin/env bash
if [[ "$*" == *"projectsV2"* ]]; then
    printf '{"nodes":[],"pageInfo":{"endCursor":null,"hasNextPage":false}}\n'
    exit 0
fi
if [[ "$*" == *"organization"* ]]; then
    exit 1
fi
if [[ "$*" == *"user(login"* ]]; then
    printf 'U_abc\n'
    exit 0
fi
if [[ "$*" == *"createProjectV2"* ]]; then
    printf 'Only users can create projects\n' >&2
    exit 1
fi
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    _WF_CREATION_FAILED=""
    discover_or_create_workflow_project
    [ -z "${_WF_PROJECT_ID}" ]
    [ -n "${_WF_CREATION_FAILED}" ]
}

# --- CI pending gate ---------------------------------------------------------

@test "pr_json_has_pending_ci_checks returns true when a required check has status IN_PROGRESS" {
    run pr_json_has_pending_ci_checks '{"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null,"isRequired":true}]}'
    [ "${status}" -eq 0 ]
}

@test "pr_json_has_pending_ci_checks returns true when a required check has status QUEUED" {
    run pr_json_has_pending_ci_checks '{"statusCheckRollup":[{"name":"ci","status":"QUEUED","conclusion":null,"isRequired":true}]}'
    [ "${status}" -eq 0 ]
}

@test "pr_json_has_pending_ci_checks returns true when one of many required checks is not COMPLETED" {
    run pr_json_has_pending_ci_checks '{"statusCheckRollup":[{"name":"tests","status":"COMPLETED","conclusion":"SUCCESS","isRequired":true},{"name":"lint","status":"IN_PROGRESS","conclusion":null,"isRequired":true}]}'
    [ "${status}" -eq 0 ]
}

@test "pr_json_has_pending_ci_checks returns false when all checks are COMPLETED" {
    run pr_json_has_pending_ci_checks '{"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS","isRequired":true}]}'
    [ "${status}" -ne 0 ]
}

@test "pr_json_has_pending_ci_checks returns false when a non-required check is pending" {
    run pr_json_has_pending_ci_checks '{"statusCheckRollup":[{"name":"badge","status":"IN_PROGRESS","conclusion":null,"isRequired":false}]}'
    [ "${status}" -ne 0 ]
}

@test "pr_json_has_pending_ci_checks returns true when a pending check has no isRequired field" {
    run pr_json_has_pending_ci_checks '{"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null}]}'
    [ "${status}" -eq 0 ]
}

@test "pr_json_has_pending_ci_checks returns false when statusCheckRollup is empty" {
    run pr_json_has_pending_ci_checks '{"statusCheckRollup":[]}'
    [ "${status}" -ne 0 ]
}

@test "pr_json_has_pending_ci_checks returns false when statusCheckRollup is absent" {
    run pr_json_has_pending_ci_checks '{}'
    [ "${status}" -ne 0 ]
}

@test "pr_json_has_pending_ci_checks returns false for a completed legacy StatusContext with no status field" {
    run pr_json_has_pending_ci_checks '{"statusCheckRollup":[{"name":"legacy","state":"SUCCESS"}]}'
    [ "${status}" -ne 0 ]
}

@test "pr_json_has_pending_ci_checks returns false for a failed legacy StatusContext with no status field" {
    run pr_json_has_pending_ci_checks '{"statusCheckRollup":[{"name":"legacy","state":"FAILURE"}]}'
    [ "${status}" -ne 0 ]
}

@test "pr_json_has_pending_ci_checks returns true for a legacy StatusContext with state PENDING" {
    run pr_json_has_pending_ci_checks '{"statusCheckRollup":[{"name":"legacy","state":"PENDING"}]}'
    [ "${status}" -eq 0 ]
}

@test "pr_json_has_pending_ci_checks returns true for a legacy StatusContext with state EXPECTED" {
    run pr_json_has_pending_ci_checks '{"statusCheckRollup":[{"name":"legacy","state":"EXPECTED"}]}'
    [ "${status}" -eq 0 ]
}

@test "pr_json_has_pending_ci_checks returns false when a failed required CheckRun is mixed with a completed legacy StatusContext" {
    run pr_json_has_pending_ci_checks '{"statusCheckRollup":[{"name":"tests","status":"COMPLETED","conclusion":"FAILURE","isRequired":true},{"name":"legacy","state":"SUCCESS"}]}'
    [ "${status}" -ne 0 ]
}

@test "clear_pr_ci_pending_state removes the state file when it exists" {
    save_pr_head_oid 42 "deadbeef" "1700000000"
    local state_file
    state_file=$(pr_head_oid_file_path 42)
    [ -f "${state_file}" ]
    clear_pr_ci_pending_state 42
    [ ! -f "${state_file}" ]
}

@test "clear_pr_ci_pending_state succeeds silently when no state file exists" {
    run clear_pr_ci_pending_state 99
    [ "${status}" -eq 0 ]
}

@test "load_pr_head_oid returns empty string when no state file exists" {
    run load_pr_head_oid 42
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "save_pr_head_oid and load_pr_head_oid round-trip the OID and timestamp" {
    save_pr_head_oid 42 "deadbeef" "1700000000"
    run load_pr_head_oid 42
    [ "${status}" -eq 0 ]
    [ "${output}" = "deadbeef 1700000000" ]
}

@test "load_pr_last_agent_comment_seen returns empty string when no state file exists (#1307)" {
    run load_pr_last_agent_comment_seen 42
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "save_pr_last_agent_comment_seen and load_pr_last_agent_comment_seen round-trip the timestamp (#1307)" {
    save_pr_last_agent_comment_seen 42 "2026-08-12T10:05:07Z"
    run load_pr_last_agent_comment_seen 42
    [ "${status}" -eq 0 ]
    [ "${output}" = "2026-08-12T10:05:07Z" ]
}

@test "compute_pr_last_agent_comment_seen fetches fresh PR state rather than reusing stale data (#1307 review)" {
    fetch_pr_json() { printf '{"comments":[{"author":{"login":"credfeto"},"updatedAt":"2026-08-12T10:05:07Z"}],"reviews":[]}\n'; }
    get_trusted_logins() { printf '["credfeto"]\n'; }
    fetch_pr_review_comments() { printf '[]\n'; }
    run compute_pr_last_agent_comment_seen 42
    [ "${status}" -eq 0 ]
    [ "${output}" = "2026-08-12T10:05:07Z" ]
}

@test "compute_pr_last_agent_comment_seen returns 1 when fetch_pr_json fails (#1307)" {
    fetch_pr_json() { return 1; }
    run compute_pr_last_agent_comment_seen 42
    [ "${status}" -eq 1 ]
}

@test "compute_pr_last_agent_comment_seen returns 1 when fetch_pr_review_comments fails (#1307 review)" {
    fetch_pr_json() { printf '{"comments":[]}\n'; }
    get_trusted_logins() { printf '["credfeto"]\n'; }
    fetch_pr_review_comments() { return 1; }
    run compute_pr_last_agent_comment_seen 42
    [ "${status}" -eq 1 ]
}

@test "ci_checks_timed_out returns false and writes state on first call for a new OID" {
    local pr_json='{"headRefOid":"abc123","statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null}]}'
    run ci_checks_timed_out 42 "${pr_json}"
    [ "${status}" -ne 0 ]
    local state_file
    state_file=$(pr_head_oid_file_path 42)
    [ -f "${state_file}" ]
    [[ "$(cat "${state_file}")" == "abc123 "* ]]
}

@test "ci_checks_timed_out returns false when elapsed time is below CI_CHECK_TIMEOUT_MINUTES" {
    local pr_json='{"headRefOid":"abc123","statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null}]}'
    local now
    now=$(date +%s)
    save_pr_head_oid 42 "abc123" "${now}"
    CI_CHECK_TIMEOUT_MINUTES=60
    run ci_checks_timed_out 42 "${pr_json}"
    [ "${status}" -ne 0 ]
}

@test "ci_checks_timed_out returns true when elapsed time exceeds CI_CHECK_TIMEOUT_MINUTES" {
    local pr_json='{"headRefOid":"abc123","statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null}]}'
    local old_time
    old_time=$(( $(date +%s) - 7200 ))
    save_pr_head_oid 42 "abc123" "${old_time}"
    CI_CHECK_TIMEOUT_MINUTES=60
    run ci_checks_timed_out 42 "${pr_json}"
    [ "${status}" -eq 0 ]
}

@test "ci_checks_timed_out resets the clock and returns false when the OID changes" {
    local pr_json='{"headRefOid":"new-oid","statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null}]}'
    local old_time
    old_time=$(( $(date +%s) - 7200 ))
    save_pr_head_oid 42 "old-oid" "${old_time}"
    CI_CHECK_TIMEOUT_MINUTES=60
    run ci_checks_timed_out 42 "${pr_json}"
    [ "${status}" -ne 0 ]
    local state_file
    state_file=$(pr_head_oid_file_path 42)
    [[ "$(cat "${state_file}")" == "new-oid "* ]]
}

@test "ci_checks_timed_out returns false and writes no state when headRefOid is absent" {
    local pr_json='{"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null}]}'
    run ci_checks_timed_out 42 "${pr_json}"
    [ "${status}" -ne 0 ]
    local state_file
    state_file=$(pr_head_oid_file_path 42)
    [ ! -f "${state_file}" ]
}

@test "ci_checks_timed_out returns false and resets state when state file has no space (corrupted)" {
    local pr_json='{"headRefOid":"abc123","statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null}]}'
    local state_file
    state_file=$(pr_head_oid_file_path 42)
    mkdir -p "${SESSION_BASE_DIR}"
    printf 'abc123' > "${state_file}"
    CI_CHECK_TIMEOUT_MINUTES=60
    run ci_checks_timed_out 42 "${pr_json}"
    [ "${status}" -ne 0 ]
    [[ "$(cat "${state_file}")" == "abc123 "* ]]
}

@test "main defers agent invocation when PR has pending CI checks within timeout" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null,"isRequired":true}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fingerprint_pr_json() { printf 'fp-new\n'; }
    load_pr_fingerprint()  { printf 'fp-old\n'; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }
    CI_CHECK_TIMEOUT_MINUTES=60

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"CI checks pending"* ]]
}

@test "main blocks PR and posts complaint when CI checks exceed timeout" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null,"isRequired":true}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fingerprint_pr_json() { printf 'fp-new\n'; }
    load_pr_fingerprint()  { printf 'fp-old\n'; }
    local old_time
    old_time=$(( $(date +%s) - 7200 ))
    save_pr_head_oid 5 "abc" "${old_time}"
    CI_CHECK_TIMEOUT_MINUTES=60
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"timeout"* ]]
    grep -q 'pr comment 5' "${GH_CALL_LOG}"
    grep -q 'Blocked' "${GH_CALL_LOG}"
}

@test "main skips (does not die on) a transient fetch_pr_json failure in the direct-PR path (#1090)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { return 1; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"Failed to fetch state for PR #5 in org/repo — skipping this item for now"* ]]
    [[ "${output}" == *"errors: 1"* ]]
}

@test "main invokes agent when PR CI checks are all COMPLETED" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fingerprint_pr_json() { printf 'fp-new\n'; }
    load_pr_fingerprint()  { printf 'fp-old\n'; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ -f "${TEST_TMP}/claude_log" ]
}

@test "main skips (does not die on, and does not hand off to agent for) a get_trusted_logins failure in the direct-PR path (#1094)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    get_trusted_logins() { return 1; }
    fingerprint_pr_json() { printf 'called\n' >> "${TEST_TMP}/fp_called"; printf 'fp-new\n'; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [ ! -f "${TEST_TMP}/fp_called" ]
    [[ "${output}" == *"Failed to fetch trusted collaborators for org/repo"* ]]
}

@test "main skips (does not die on, and does not hand off to agent for) a fetch_pr_review_comments failure in the direct-PR path (#1127)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fetch_pr_review_comments() { return 1; }
    fingerprint_pr_json() { printf 'called\n' >> "${TEST_TMP}/fp_called"; printf 'fp-new\n'; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [ ! -f "${TEST_TMP}/fp_called" ]
    [[ "${output}" == *"Failed to fetch review comments for PR #5 in org/repo — skipping this item for now"* ]]
    [[ "${output}" == *"errors: 1"* ]]
}

@test "main skips (does not die on, and does not hand off to agent for) a fetch_pr_review_comments failure in the Issue-to-PR pivot path (#1127)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf '99\n'; }
    fetch_issue_json()          { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    fetch_pr_json()             { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]}\n'; }
    pr_json_has_blocked_label() { return 1; }
    fetch_pr_review_comments()  { return 1; }
    fingerprint_pr_json()       { printf 'called\n' >> "${TEST_TMP}/fp_called"; printf 'fp-new\n'; }
    invoke_claude()             { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [ ! -f "${TEST_TMP}/fp_called" ]
    [[ "${output}" == *"Failed to fetch review comments for PR #99 in org/repo — skipping this item for now"* ]]
    [[ "${output}" == *"errors: 1"* ]]
}

@test "main blocks a PR and does not invoke claude when its invocation total is at the runaway cap (#1093)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fingerprint_pr_json() { printf 'fp-new\n'; }
    load_pr_fingerprint()  { printf 'fp-old\n'; }
    save_pr_invocation_counts 5 "${MAX_PR_TOTAL_INVOCATIONS}" 0
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    grep -q 'pr comment 5' "${GH_CALL_LOG}"
    grep -q 'Blocked' "${GH_CALL_LOG}"
    [[ "${output}" == *"used ${MAX_PR_TOTAL_INVOCATIONS} agent invocations without converging"* ]]
    [ -f "${SESSION_BASE_DIR}/PullRequest_5.runaway-blocked" ]
}

@test "main posts the PR-runaway reason as the comment body and to Discord when at the runaway cap (#1140 review)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fingerprint_pr_json() { printf 'fp-new\n'; }
    load_pr_fingerprint()  { printf 'fp-old\n'; }
    save_pr_invocation_counts 5 "${MAX_PR_TOTAL_INVOCATIONS}" 0
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }
    local _notif_log="${TEST_TMP}/discord_calls"
    notify_discord_blocked_item() { printf 'type=%s id=%s reason=%s\n' "$1" "$2" "$3" >> "${_notif_log}"; }

    run main
    [ "${status}" -eq 0 ]
    grep -q "pr comment 5 --repo org/repo --body This PR has been worked ${MAX_PR_TOTAL_INVOCATIONS} times by the automation without reaching a mergeable state" "${GH_CALL_LOG}"
    grep -q "type=PullRequest id=5 reason=This PR has been worked ${MAX_PR_TOTAL_INVOCATIONS} times by the automation without reaching a mergeable state" "${_notif_log}"
}

@test "main still blocks and warns loudly when the runaway-blocked marker cannot be written (#1093 review)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fingerprint_pr_json() { printf 'fp-new\n'; }
    load_pr_fingerprint()  { printf 'fp-old\n'; }
    save_pr_invocation_counts 5 "${MAX_PR_TOTAL_INVOCATIONS}" 0
    # Guard file already written above; now make the directory unwritable so the runaway-blocked
    # marker touch fails — the label/comment escalation (a gh call, unaffected by local fs
    # permissions) must still go through, and the failure must be surfaced via warn rather than
    # silently swallowed.
    chmod 555 "${SESSION_BASE_DIR}"
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    chmod 755 "${SESSION_BASE_DIR}"
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    grep -q 'pr comment 5' "${GH_CALL_LOG}"
    grep -q 'Blocked' "${GH_CALL_LOG}"
    [ ! -f "${SESSION_BASE_DIR}/PullRequest_5.runaway-blocked" ]
    [[ "${output}" == *"Failed to write runaway-blocked marker for PR #5"* ]]
}

@test "main resets a PR's invocation counter when observed un-blocked after hitting the runaway cap (#1093)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    # No Blocked label — a human has already cleared it — but the guard file still holds the
    # capped total, and the runaway-blocked marker from the prior blocking tick is still present,
    # exercising the reset-on-unblock path (#1093).
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fingerprint_pr_json() { printf 'fp-new\n'; }
    load_pr_fingerprint()  { printf 'fp-old\n'; }
    save_pr_invocation_counts 5 "${MAX_PR_TOTAL_INVOCATIONS}" 0
    mkdir -p "${SESSION_BASE_DIR}"
    touch "${SESSION_BASE_DIR}/PullRequest_5.runaway-blocked"
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ -f "${TEST_TMP}/claude_log" ]
    # Reset to 0/0 then bumped once for this invocation — proof the stale cap did not re-block it.
    [ "$(cat "${SESSION_BASE_DIR}/PullRequest_5.invocations")" = "1 0" ]
}

@test "main writes the runaway-blocked marker when observing a PR blocked by a non-backstop rule while at the cap (#1115 regression)" {
    # Reproduces the #116 bug's first half: a PR already carries the Blocked label (applied by
    # something other than oneshot's own backstop, e.g. the code-review workflow's "3+ rounds"
    # rule — hence no pre-existing marker) while its invocation total already sits at the cap.
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":116,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[{"name":"Blocked"}],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}\n'; }
    pr_json_has_blocked_label() { return 0; }
    save_pr_invocation_counts 116 "${MAX_PR_TOTAL_INVOCATIONS}" 0
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"PR #116 in org/repo is blocked — skipping (not counting as active work)"* ]]
    [ -f "${SESSION_BASE_DIR}/PullRequest_116.runaway-blocked" ]
    # The total is untouched by observing the block — only forgiven once a human clears the label.
    [ "$(cat "${SESSION_BASE_DIR}/PullRequest_116.invocations")" = "${MAX_PR_TOTAL_INVOCATIONS} 0" ]
}

@test "main resumes work on a capped PR across two ticks after a human clears a non-backstop Blocked label (#1115 regression)" {
    # End-to-end reproduction of #116: tick 1 observes the PR blocked by a non-backstop rule while
    # at the cap (writes the marker); a human then clears the label; tick 2 must reset the counter
    # and actually invoke the agent instead of instantly re-blocking with zero new activity.
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":116,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[{"name":"Blocked"}],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}\n'; }
    pr_json_has_blocked_label() { return 0; }
    save_pr_invocation_counts 116 "${MAX_PR_TOTAL_INVOCATIONS}" 0
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ -f "${SESSION_BASE_DIR}/PullRequest_116.runaway-blocked" ]

    # Human clears the label — simulate the next tick observing it unblocked.
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    pr_json_has_blocked_label() { return 1; }
    fingerprint_pr_json() { printf 'fp-new\n'; }
    load_pr_fingerprint()  { printf 'fp-old\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ -f "${TEST_TMP}/claude_log" ]
    [ "$(cat "${SESSION_BASE_DIR}/PullRequest_116.invocations")" = "1 0" ]
    [ ! -f "${SESSION_BASE_DIR}/PullRequest_116.runaway-blocked" ]
}

@test "main auto-clears Blocked on an environment-diagnosed PR once a newer agent image has been built (#1118)" {
    # Reproduces the funfair-server-code-analysis#463 case: the agent diagnosed a missing-tool
    # environment failure and blocked itself; the fix has since shipped (a new image was built);
    # oneshot must notice on its own, without a human clearing the label — no agent work happens
    # this tick, the PR is simply freed up for the next tick to pick up normally.
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":463,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[{"name":"Blocked"}],"headRefOid":"abc","comments":[{"body":"Missing pgrep in the container. <!-- orchestrator:env-block image-sha=abc1234 -->"}],"reviews":[],"statusCheckRollup":[]}\n'; }
    pr_json_has_blocked_label() { return 0; }
    make_stub podman 'printf "IMAGE_SHA_DEVELOPMENT_AGENT=def5678\n"'
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    grep -q 'pr edit 463 --repo org/repo --remove-label Blocked' "${GH_CALL_LOG}"
    grep -q 'pr comment 463' "${GH_CALL_LOG}"
    [ "$(cat "${SESSION_BASE_DIR}/PullRequest_463.env-unblocks")" = "1" ]
}

@test "main leaves an environment-diagnosed PR blocked when no newer agent image has been built (#1118)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":463,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[{"name":"Blocked"}],"headRefOid":"abc","comments":[{"body":"Missing pgrep in the container. <!-- orchestrator:env-block image-sha=abc1234 -->"}],"reviews":[],"statusCheckRollup":[]}\n'; }
    pr_json_has_blocked_label() { return 0; }
    make_stub podman 'printf "IMAGE_SHA_DEVELOPMENT_AGENT=abc1234\n"'
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"PR #463 in org/repo is blocked — skipping (not counting as active work)"* ]]
    [[ "$(cat "${GH_CALL_LOG}")" != *"remove-label Blocked"* ]]
}

@test "main stops auto-unblocking an environment-diagnosed PR once MAX_PR_ENV_AUTO_UNBLOCKS is reached (#1118)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":463,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[{"name":"Blocked"}],"headRefOid":"abc","comments":[{"body":"Missing pgrep in the container. <!-- orchestrator:env-block image-sha=abc1234 -->"}],"reviews":[],"statusCheckRollup":[]}\n'; }
    pr_json_has_blocked_label() { return 0; }
    save_env_unblock_attempts 463 "${MAX_PR_ENV_AUTO_UNBLOCKS}"
    make_stub podman 'printf "IMAGE_SHA_DEVELOPMENT_AGENT=def5678\n"'
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "$(cat "${GH_CALL_LOG}")" != *"remove-label Blocked"* ]]
    grep -q 'pr comment 463' "${GH_CALL_LOG}"
    [ -f "${SESSION_BASE_DIR}/PullRequest_463.env-unblock-cap-notified" ]
}

@test "main does not die and does not save when the post-run PR fingerprint compute fails (#1091)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fingerprint_pr_json() { printf 'fp-new\n'; }
    load_pr_fingerprint()  { printf 'fp-old\n'; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }
    compute_pr_fingerprint() { return 1; }
    save_pr_fingerprint() { printf 'saved\n' >> "${TEST_TMP}/save_log"; }

    run main
    [ "${status}" -eq 0 ]
    [ -f "${TEST_TMP}/claude_log" ]
    [ ! -f "${TEST_TMP}/save_log" ]
    [[ "${output}" == *"Failed to compute post-run fingerprint"* ]]
    [[ "${output}" == *"will re-evaluate next tick"* ]]
}

@test "main saves neither fingerprint when the PR succeeds but the linked issue's compute fails (atomicity, #1091)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf '5\n'; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fingerprint_pr_json() { printf 'fp-new\n'; }
    load_pr_fingerprint()  { printf 'fp-old\n'; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }
    compute_pr_fingerprint() { printf 'pr-fp-ok\n'; return 0; }
    compute_issue_fingerprint() { return 1; }
    save_pr_fingerprint() { printf 'saved-pr\n' >> "${TEST_TMP}/save_log"; }
    save_issue_fingerprint() { printf 'saved-issue\n' >> "${TEST_TMP}/save_log"; }

    run main
    [ "${status}" -eq 0 ]
    [ -f "${TEST_TMP}/claude_log" ]
    [ ! -f "${TEST_TMP}/save_log" ]
    [[ "${output}" == *"Failed to compute post-run fingerprint"* ]]
}

@test "main does not die and does not save when the post-run Issue fingerprint compute fails (#1091)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }
    compute_issue_fingerprint() { return 1; }
    save_issue_fingerprint() { printf 'saved\n' >> "${TEST_TMP}/save_log"; }

    run main
    [ "${status}" -eq 0 ]
    [ -f "${TEST_TMP}/claude_log" ]
    [ ! -f "${TEST_TMP}/save_log" ]
    [[ "${output}" == *"Failed to compute post-run fingerprint for Issue #10"* ]]
}

@test "main blocks an Issue and does not invoke claude when its invocation total is at the runaway cap (#1093)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    save_issue_invocation_counts 10 "${MAX_ISSUE_TOTAL_INVOCATIONS}" 0
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    grep -q 'issue comment 10' "${GH_CALL_LOG}"
    grep -q 'Blocked' "${GH_CALL_LOG}"
    [[ "${output}" == *"used ${MAX_ISSUE_TOTAL_INVOCATIONS} agent invocations without converging"* ]]
    [ -f "${SESSION_BASE_DIR}/Issue_10.runaway-blocked" ]
}

@test "main posts the Issue-runaway reason as the comment body and to Discord when at the runaway cap (#1140 review)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    save_issue_invocation_counts 10 "${MAX_ISSUE_TOTAL_INVOCATIONS}" 0
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }
    local _notif_log="${TEST_TMP}/discord_calls"
    notify_discord_blocked_item() { printf 'type=%s id=%s reason=%s\n' "$1" "$2" "$3" >> "${_notif_log}"; }

    run main
    [ "${status}" -eq 0 ]
    grep -q "issue comment 10 --repo org/repo --body This issue has been worked ${MAX_ISSUE_TOTAL_INVOCATIONS} times by the automation without producing a mergeable pull request" "${GH_CALL_LOG}"
    grep -q "type=Issue id=10 reason=This issue has been worked ${MAX_ISSUE_TOTAL_INVOCATIONS} times by the automation without producing a mergeable pull request" "${_notif_log}"
}

@test "main invokes agent and increments the invocation counter for an Issue below the runaway cap (#1093)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ -f "${TEST_TMP}/claude_log" ]
    [ -f "${SESSION_BASE_DIR}/Issue_10.invocations" ]
    [ "$(cat "${SESSION_BASE_DIR}/Issue_10.invocations")" = "1 0" ]
}

@test "main resets an Issue's invocation counter when observed un-blocked after hitting the runaway cap (#1093)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    # No Blocked label — a human has already cleared it — but the guard file still holds the
    # capped total, and the runaway-blocked marker from the prior blocking tick is still present,
    # exercising the reset-on-unblock path (#1093).
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    save_issue_invocation_counts 10 "${MAX_ISSUE_TOTAL_INVOCATIONS}" 0
    mkdir -p "${SESSION_BASE_DIR}"
    touch "${SESSION_BASE_DIR}/Issue_10.runaway-blocked"
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ -f "${TEST_TMP}/claude_log" ]
    # Reset to 0 then bumped once for this invocation — proof the stale cap did not re-block it.
    [ "$(cat "${SESSION_BASE_DIR}/Issue_10.invocations")" = "1 0" ]
}

@test "main skips (does not die on, and does not hand off to agent for) a transient repo-fetch failure (#1090)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fingerprint_pr_json() { printf 'fp-new\n'; }
    load_pr_fingerprint()  { printf 'fp-old\n'; }
    ensure_repo_current() { return 2; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" != *"handing off to agent"* ]]
    [[ "${output}" == *"errors: 1"* ]]
}

@test "main blocks unchanged PR when CI has been pending past timeout in direct-PR path" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null,"isRequired":true}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fingerprint_pr_json() { printf 'fp-same\n'; }
    load_pr_fingerprint()  { printf 'fp-same\n'; }
    local old_time
    old_time=$(( $(date +%s) - 7200 ))
    save_pr_head_oid 5 "abc" "${old_time}"
    CI_CHECK_TIMEOUT_MINUTES=60
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"timeout"* ]]
    grep -q 'pr comment 5' "${GH_CALL_LOG}"
    grep -q 'Blocked' "${GH_CALL_LOG}"
}

@test "main blocks unchanged PR with idle budget exhausted and a failed required check in direct-PR path" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"FAILURE","isRequired":true}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fingerprint_pr_json() { printf 'fp-same\n'; }
    load_pr_fingerprint()  { printf 'fp-same\n'; }
    save_pr_invocation_counts 5 4 "${MAX_PR_IDLE_INVOCATIONS}"
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    grep -q 'pr comment 5' "${GH_CALL_LOG}"
    grep -q 'Blocked' "${GH_CALL_LOG}"
}

@test "main blocks unchanged PR with idle budget exhausted and an unaddressed review request in direct-PR path (#1083)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"reviewDecision":"CHANGES_REQUESTED","statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS","isRequired":true}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fingerprint_pr_json() { printf 'fp-same\n'; }
    load_pr_fingerprint()  { printf 'fp-same\n'; }
    save_pr_invocation_counts 5 4 "${MAX_PR_IDLE_INVOCATIONS}"
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    grep -q 'pr comment 5' "${GH_CALL_LOG}"
    grep -q 'Blocked' "${GH_CALL_LOG}"
}

@test "main silently parks unchanged PR with idle budget exhausted but no failed required check (regression guard)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS","isRequired":true}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fingerprint_pr_json() { printf 'fp-same\n'; }
    load_pr_fingerprint()  { printf 'fp-same\n'; }
    save_pr_invocation_counts 5 4 "${MAX_PR_IDLE_INVOCATIONS}"
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    if [ -f "${GH_CALL_LOG}" ]; then
        ! grep -q 'Blocked' "${GH_CALL_LOG}"
        ! grep -q 'pr comment 5' "${GH_CALL_LOG}"
    fi
}

@test "main does not invoke the agent for a changed-fingerprint terminal PR (auto-merge armed, nothing failed/pending) (#1256)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","autoMergeRequest":{"enabledAt":"now"}}\n'; }
    fingerprint_pr_json() { printf 'fp-new\n'; }
    load_pr_fingerprint()  { printf 'fp-old\n'; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"PR #5 in org/repo: settled"* ]]
}

@test "main still performs non-agentic rebase for a BEHIND PR even with auto-merge armed (#1256 regression guard)" {
    # pr_json_is_terminal ignores mergeStateStatus entirely, so without the explicit BEHIND/DIRTY
    # guard on the new hoisted terminal check, a PR that's actually waiting on a rebase (not
    # genuinely settled) could be misclassified as "nothing to do".
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[],"mergeable":"MERGEABLE","mergeStateStatus":"BEHIND","autoMergeRequest":{"enabledAt":"now"}}\n'; }
    fingerprint_pr_json()  { printf 'fp-new\n'; }
    load_pr_fingerprint()  { printf 'fp-old\n'; }
    try_nonagentic_rebase() { return 0; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"rebased non-agentically"* ]]
    [[ "${output}" != *"settled"* ]]
    [ ! -f "${TEST_TMP}/claude_log" ]
}

@test "main invokes the agent for a terminal, fingerprint-unchanged PR with an unaddressed trusted comment (#1307)" {
    # Reproduces the live incident this bug was reported against (funfair-tech/funfair-treasury-
    # reporting#3622): a prior non-agentic rebase already folded a new trusted comment into the
    # saved general PR fingerprint, so it now reads as "unchanged" AND the PR looks terminal
    # (auto-merge armed, nothing failed/pending). Neither skip must win — the comment has never
    # actually been read by a real agent.
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[{"author":{"login":"credfeto"},"updatedAt":"2026-08-12T10:05:07Z"}],"reviews":[],"statusCheckRollup":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","autoMergeRequest":{"enabledAt":"now"}}\n'; }
    fingerprint_pr_json() { printf 'fp-same\n'; }
    load_pr_fingerprint()  { printf 'fp-same\n'; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" != *"settled"* ]]
    # Routed through the idle-tracked "re-invoking to advance" path (not a blanket bypass), so
    # the idle counter and failed-check/unaddressed-review-request escalation stay in force once
    # genuinely exhausted (#1307 review) — "unchanged" legitimately appears in that log line.
    [[ "${output}" == *"unchanged — re-invoking to advance the next workflow phase"* ]]
}

@test "main invokes the agent for a BEHIND PR with an unaddressed trusted comment instead of a non-agentic rebase (#1307)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[{"author":{"login":"credfeto"},"updatedAt":"2026-08-12T10:05:07Z"}],"reviews":[],"statusCheckRollup":[],"mergeable":"MERGEABLE","mergeStateStatus":"BEHIND"}\n'; }
    fingerprint_pr_json()  { printf 'fp-new\n'; }
    load_pr_fingerprint()  { printf 'fp-old\n'; }
    try_nonagentic_rebase() { printf 'rebase-attempted\n' >> "${TEST_TMP}/rebase_log"; return 0; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/rebase_log" ]
    [ -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" != *"rebased non-agentically"* ]]
}

@test "main still performs a non-agentic rebase for a BEHIND PR whose trusted comment was already seen by a prior agent invocation (#1307)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[{"author":{"login":"credfeto"},"updatedAt":"2026-08-12T07:26:12Z"}],"reviews":[],"statusCheckRollup":[],"mergeable":"MERGEABLE","mergeStateStatus":"BEHIND"}\n'; }
    fingerprint_pr_json()  { printf 'fp-new\n'; }
    load_pr_fingerprint()  { printf 'fp-old\n'; }
    load_pr_last_agent_comment_seen() { printf '2026-08-12T07:26:12Z\n'; }
    try_nonagentic_rebase() { return 0; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"rebased non-agentically"* ]]
    [ ! -f "${TEST_TMP}/claude_log" ]
}

@test "main does not record last-agent-comment-seen after a non-agentic rebase (#1307)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[],"mergeable":"MERGEABLE","mergeStateStatus":"BEHIND"}\n'; }
    fingerprint_pr_json()  { printf 'fp-new\n'; }
    load_pr_fingerprint()  { printf 'fp-old\n'; }
    try_nonagentic_rebase() { return 0; }
    save_pr_last_agent_comment_seen() { printf 'called\n' >> "${TEST_TMP}/comment_seen_log"; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"rebased non-agentically"* ]]
    [ ! -f "${TEST_TMP}/comment_seen_log" ]
    [ ! -f "${TEST_TMP}/claude_log" ]
}

@test "main does not record last-agent-comment-seen after a terminal settled skip (#1307)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","autoMergeRequest":{"enabledAt":"now"}}\n'; }
    fingerprint_pr_json() { printf 'fp-new\n'; }
    load_pr_fingerprint()  { printf 'fp-old\n'; }
    save_pr_last_agent_comment_seen() { printf 'called\n' >> "${TEST_TMP}/comment_seen_log"; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"settled"* ]]
    [ ! -f "${TEST_TMP}/comment_seen_log" ]
    [ ! -f "${TEST_TMP}/claude_log" ]
}

@test "main records last-agent-comment-seen after a genuine agent invocation (#1307)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fingerprint_pr_json() { printf 'fp-new\n'; }
    load_pr_fingerprint()  { printf 'fp-old\n'; }
    save_pr_last_agent_comment_seen() { printf 'called\n' >> "${TEST_TMP}/comment_seen_log"; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ -f "${TEST_TMP}/claude_log" ]
    [ -f "${TEST_TMP}/comment_seen_log" ]
}

@test "main still escalates a terminal PR with a failed required check and an unaddressed comment once idle budget is exhausted (#1307 review)" {
    # Regression guard: an unaddressed trusted comment must not permanently exempt a PR from the
    # idle-exhausted escalation checks — it may force one extra look, but once the idle budget is
    # genuinely spent the failed-check escalation must still fire, not silently churn forever.
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[{"author":{"login":"credfeto"},"updatedAt":"2026-08-12T10:05:07Z"}],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"FAILURE","isRequired":true}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","autoMergeRequest":{"enabledAt":"now"}}\n'; }
    fingerprint_pr_json() { printf 'fp-same\n'; }
    load_pr_fingerprint()  { printf 'fp-same\n'; }
    save_pr_invocation_counts 5 4 "${MAX_PR_IDLE_INVOCATIONS}"
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    grep -q 'pr comment 5' "${GH_CALL_LOG}"
    grep -q 'Blocked' "${GH_CALL_LOG}"
}

@test "main still sends the Discord review-approval nudge for a terminal PR even with an unaddressed comment (#1307 review)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[{"author":{"login":"credfeto"},"updatedAt":"2026-08-12T10:05:07Z"}],"reviews":[],"statusCheckRollup":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","autoMergeRequest":{"enabledAt":"now"},"reviewDecision":"REVIEW_REQUIRED"}\n'; }
    fingerprint_pr_json() { printf 'fp-new\n'; }
    load_pr_fingerprint()  { printf 'fp-old\n'; }
    notify_discord_pr_needs_approval() { printf 'called\n' >> "${TEST_TMP}/approval_notify_log"; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ -f "${TEST_TMP}/claude_log" ]
    [ -f "${TEST_TMP}/approval_notify_log" ]
}

@test "main blocks PR and posts complaint when CI checks exceed timeout in Issue-to-PR pivot path" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf '7\n'; }
    fetch_issue_json()         { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    issue_json_has_blocked_label() { return 1; }
    fetch_pr_json()            { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null,"isRequired":true}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    pr_json_has_blocked_label() { return 1; }
    fingerprint_pr_json()      { printf 'fp-same\n'; }
    load_pr_fingerprint()      { printf 'fp-same\n'; }
    local old_time
    old_time=$(( $(date +%s) - 7200 ))
    save_pr_head_oid 7 "abc" "${old_time}"
    CI_CHECK_TIMEOUT_MINUTES=60
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"timeout"* ]]
    grep -q 'pr comment 7' "${GH_CALL_LOG}"
    grep -q 'Blocked' "${GH_CALL_LOG}"
}

@test "main clears CI pending state file when direct-PR CI timeout fires" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null,"isRequired":true}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fingerprint_pr_json() { printf 'fp-same\n'; }
    load_pr_fingerprint()  { printf 'fp-same\n'; }
    local old_time
    old_time=$(( $(date +%s) - 7200 ))
    save_pr_head_oid 5 "abc" "${old_time}"
    CI_CHECK_TIMEOUT_MINUTES=60
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    local state_file
    state_file=$(pr_head_oid_file_path 5)
    [ ! -f "${state_file}" ]
}

@test "main preserves CI pending state file when the timeout escalation's label cannot be verified (#1092)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null,"isRequired":true}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fingerprint_pr_json() { printf 'fp-same\n'; }
    load_pr_fingerprint()  { printf 'fp-same\n'; }
    local old_time
    old_time=$(( $(date +%s) - 7200 ))
    save_pr_head_oid 5 "abc" "${old_time}"
    CI_CHECK_TIMEOUT_MINUTES=60
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; case "$*" in *"--json labels"*) printf "false\n" ;; esac; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    # Label was never confirmed present — the 24h timeout clock must NOT be re-armed, and the
    # explanatory comment must NOT be posted (both were the exact spam/lost-escalation bug).
    local state_file
    state_file=$(pr_head_oid_file_path 5)
    [ -f "${state_file}" ]
    run grep -q 'pr comment 5' "${GH_CALL_LOG}"
    [ "${status}" -ne 0 ]
}

@test "main clears CI pending state file when Issue-to-PR CI timeout fires" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf '7\n'; }
    fetch_issue_json()         { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    issue_json_has_blocked_label() { return 1; }
    fetch_pr_json()            { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null,"isRequired":true}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    pr_json_has_blocked_label() { return 1; }
    fingerprint_pr_json()      { printf 'fp-same\n'; }
    load_pr_fingerprint()      { printf 'fp-same\n'; }
    local old_time
    old_time=$(( $(date +%s) - 7200 ))
    save_pr_head_oid 7 "abc" "${old_time}"
    CI_CHECK_TIMEOUT_MINUTES=60
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    local state_file
    state_file=$(pr_head_oid_file_path 7)
    [ ! -f "${state_file}" ]
}

@test "main clears CI pending state file when direct-PR CI completes and fingerprint is unchanged" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    # Auto-merge enabled makes the unchanged, CI-green PR terminal so it is skipped (CI pending
    # state is still cleared) rather than being re-invoked to advance a phase.
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS","isRequired":true}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","autoMergeRequest":{"enabledAt":"now"}}\n'; }
    fingerprint_pr_json() { printf 'fp-same\n'; }
    load_pr_fingerprint()  { printf 'fp-same\n'; }
    local old_time
    old_time=$(( $(date +%s) - 30 ))
    save_pr_head_oid 5 "abc" "${old_time}"
    CI_CHECK_TIMEOUT_MINUTES=60
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    local state_file
    state_file=$(pr_head_oid_file_path 5)
    [ ! -f "${state_file}" ]
}

@test "main preserves CI pending state file when direct-PR is skipped while CI still pending" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null,"isRequired":true}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fingerprint_pr_json() { printf 'fp-same\n'; }
    load_pr_fingerprint()  { printf 'fp-same\n'; }
    CI_CHECK_TIMEOUT_MINUTES=60
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    local state_file
    state_file=$(pr_head_oid_file_path 5)
    [ -f "${state_file}" ]
}

@test "main preserves CI pending state file when Issue-to-PR pivot skips due to both FPs unchanged while CI still pending" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf '7\n'; }
    fetch_issue_json()         { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    issue_json_has_blocked_label() { return 1; }
    fetch_pr_json()            { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null,"isRequired":true}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    pr_json_has_blocked_label() { return 1; }
    fingerprint_pr_json()      { printf 'fp-same\n'; }
    load_pr_fingerprint()      { printf 'fp-same\n'; }
    fingerprint_issue_json()   { printf 'fp-same-issue\n'; }
    load_issue_fingerprint()   { printf 'fp-same-issue\n'; }
    CI_CHECK_TIMEOUT_MINUTES=60
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    local state_file
    state_file=$(pr_head_oid_file_path 7)
    [ -f "${state_file}" ]
}

@test "main clears CI pending state file when work-block CI timeout fires (fingerprint changed)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null,"isRequired":true}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    fingerprint_pr_json() { printf 'fp-new\n'; }
    load_pr_fingerprint()  { printf 'fp-old\n'; }
    local old_time
    old_time=$(( $(date +%s) - 7200 ))
    save_pr_head_oid 5 "abc" "${old_time}"
    CI_CHECK_TIMEOUT_MINUTES=60
    export GH_CALL_LOG="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${GH_CALL_LOG}"; case "$*" in *"--json labels"*) printf "true\n" ;; esac; exit 0'
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    grep -q 'Blocked' "${GH_CALL_LOG}"
    local state_file
    state_file=$(pr_head_oid_file_path 5)
    [ ! -f "${state_file}" ]
}

@test "main defers unchanged BEHIND PR without invoking agent while CI is pending (direct-PR path)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null,"isRequired":true}],"mergeable":"MERGEABLE","mergeStateStatus":"BEHIND"}\n'; }
    fingerprint_pr_json() { printf 'fp-same\n'; }
    load_pr_fingerprint()  { printf 'fp-same\n'; }
    CI_CHECK_TIMEOUT_MINUTES=60
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"CI checks pending"* ]]
}

@test "main defers unchanged draft PR in Issue-to-PR path without invoking agent while CI is pending" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf '7\n'; }
    fetch_issue_json()         { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    issue_json_has_blocked_label() { return 1; }
    fetch_pr_json()            { printf '{"state":"OPEN","title":"T","body":"","isDraft":true,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null,"isRequired":true}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'; }
    pr_json_has_blocked_label() { return 1; }
    fingerprint_pr_json()      { printf 'fp-same\n'; }
    load_pr_fingerprint()      { printf 'fp-same\n'; }
    CI_CHECK_TIMEOUT_MINUTES=60
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/claude_log" ]
    [[ "${output}" == *"CI checks pending"* ]]
}
