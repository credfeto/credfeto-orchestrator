#!/usr/bin/env bats
# shellcheck disable=SC2329  # functions in @test bodies are invoked indirectly via 'run'
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are used inside run() subshells where shellcheck cannot trace them

bats_require_minimum_version 1.5.0

load test_helper
load oneshot_helper

# lib/globals declares _WF_OPTION_IDS as an associative array. Repeating that declaration here
# lets _WF_OPTION_IDS[Planning] read as a key, as shellcheck does not follow bats `load` into lib/.
declare -gA _WF_OPTION_IDS

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
    [[ "${output}" != *"--label Blocked"* ]]
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
    [[ "${output}" != *"--label Blocked"* ]]
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
    [[ "${output}" == *"cfwf label add --repo ${REPO_FULL} --issue 42 --label Blocked"* ]]
    [[ "${output}" != *"--add-label Blocked"* ]]
    [[ "${output}" == *"Read AI instructions from /resolved/.ai-instructions"* ]]
}

@test "build_issue_claude_md posts the plan with cfwf comment add from a quoted heredoc" {
    run build_issue_claude_md 42 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"cfwf comment add --repo "*" --issue 42 --body-file - <<'PLAN'"* ]]
    [[ "${output}" == *"no --body, no Write, no temp file"* ]]
}

@test "build_issue_claude_md plan template is plain ASCII" {
    run build_issue_claude_md 42 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    template=$(printf '%s\n' "${output}" | sed -n '/^## Implementation Plan$/,/ready to proceed pending approval/p')
    [ -n "${template}" ]
    run bash -c 'printf "%s" "$1" | LC_ALL=C grep -q "[^ -~]"' _ "${template}"
    [ "${status}" -eq 1 ]
}

@test "build_issue_claude_md only blocks the issue once the plan is confirmed posted" {
    run build_issue_claude_md 42 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Only once the plan is confirmed posted"* ]]
    [[ "${output}" == *"If the plan could NOT be posted, do NOT add Blocked and do NOT move the board"* ]]
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

@test "build_issue_claude_md tells agents to wait with cfwf task wait and never to poll (#1710)" {
    run build_issue_claude_md 42 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"cfwf task wait --output <the output file named in the run_in_background result> --timeout 570, run in the foreground with the Bash tool's timeout set to 600000"* ]]
    [[ "${output}" == *"exit 4 means it is still running, so run the same call again"* ]]
    [[ "${output}" == *"Never wait by polling (ps or pgrep checks, or repeated Reads of the output file)"* ]]
    [[ "${output}" == *"Only if cfwf is unavailable, read the command's output file"* ]]
}

@test "build_issue_claude_md makes the Monitor tool optional and gives a Read fallback with no shell wait loops (#1656)" {
    run build_issue_claude_md 42 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"if the Monitor tool is available in this session"* ]]
    [[ "${output}" == *"The Monitor tool is often NOT available in these sessions"* ]]
    [[ "${output}" == *"do NOT fall back to a shell wait loop (until/while/for loops, sleep, timeout, pgrep)"* ]]
    [[ "${output}" == *"read the command's output file (its path is in the run_in_background result) with the Read tool"* ]]
    [[ "${output}" != *"poll with the Monitor tool for its completion string and WAIT"* ]]
    [[ "${output}" != *"then poll with the Monitor tool for the command's own completion string"* ]]
}

@test "build_pr_claude_md makes the Monitor tool optional and gives a Read fallback with no shell wait loops (#1656)" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"The Monitor tool is often NOT available in these sessions"* ]]
    [[ "${output}" == *"do NOT fall back to a shell wait loop"* ]]
    [[ "${output}" != *"then poll with the Monitor tool for the command's own completion string"* ]]
}

@test "the background-stall warning offers the Read fallback when Monitor is unavailable (#1656)" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "UNKNOWN" "" "${REPO_WORK_DIR}" "" "false" "" "true"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"with the Monitor tool if it is available in this session, otherwise by re-reading the command's output file with the Read tool"* ]]
    [[ "${output}" != *"you MUST poll for its own completion string with the Monitor tool"* ]]
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

# --- PHASE C board status only resets on a genuine commit (#1311) ---------------

@test "build_pr_claude_md PHASE C only resets the board to Development on a genuine commit, otherwise leaves it unchanged (#1311)" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false" ""
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'If this round pushes a genuine code commit'*'set the board status to "Development"'* ]]
    [[ "${output}" == *"only action is a reply, a label sync, a \`cfwf pr edit\` metadata change"*"or re-running a flaky check"*"with no commit pushed: leave the board status exactly as it currently is (do NOT reset it to \"Development\")"* ]]
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

@test "build_pr_claude_md tells the agent labels are already synced and prescribes no shell loop (#1657)" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"already synced onto this PR by the orchestrator before every session"* ]]
    [[ "${output}" == *"Do NOT sync labels yourself."* ]]
    [[ "${output}" != *"IFS="* ]]
    [[ "${output}" != *"while read"* ]]
    [[ "${output}" != *"labels are unsynced"* ]]
}

@test "build_pr_claude_md's dependency-PR prompt tells the agent labels are already synced and prescribes no shell loop (#1657)" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "true" ""
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"already synced onto this PR by the orchestrator before every session"* ]]
    [[ "${output}" != *"IFS="* ]]
    [[ "${output}" != *"while read"* ]]
}

@test "build_pr_claude_md never prescribes IFS= for any merge state or dirty-branch variant (#1657)" {
    local state dirty
    for state in CLEAN BEHIND DIRTY; do
        for dirty in "" "feat/x" "other"; do
            run build_pr_claude_md 7 "/resolved/.ai-instructions" "${state}" "feat/x" "" "${dirty}"
            [ "${status}" -eq 0 ]
            [[ "${output}" != *"IFS="* ]]
        done
    done
}

@test "build_pr_claude_md includes role, ai instructions, PR number, repo, work dir and steps" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Orchestrator agent"* ]]
    [[ "${output}" == *"pull request #7"* ]]
    [[ "${output}" == *"${REPO_FULL}"* ]]
    [[ "${output}" == *"${REPO_WORK_DIR}"* ]]
    [[ "${output}" == *"cfwf label add --repo ${REPO_FULL} --pr 7 --label Blocked"* ]]
    [[ "${output}" != *"--add-label Blocked"* ]]
    [[ "${output}" == *"Read AI instructions from /resolved/.ai-instructions"* ]]
    [[ "${output}" == *"cfwf pr hand-off --repo ${REPO_FULL} --pr 7"* ]]
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

@test "build_pr_claude_md hands regular PRs off with cfwf pr hand-off, never raw gh pr ready or merge (#1761)" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"cfwf pr hand-off --repo ${REPO_FULL} --pr 7 --title"*"--description-file - <<'DESCRIPTION'"* ]]
    # One call with the description on stdin: no review-record file to write first (#1775).
    [[ "${output}" != *"--body-file <review-record file>"* ]]
    [[ "${output}" == *"ONE Bash call"* ]]
    [[ "${output}" != *"gh pr merge --auto"* ]]
    [[ "${output}" != *"gh pr ready"* ]]
}

@test "build_pr_claude_md dependency PRs finalise with cfwf pr finalise-dependency, never a hand-off or raw gh (#1771)" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "true"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"cfwf pr finalise-dependency --repo ${REPO_FULL} --pr 7"* ]]
    [[ "${output}" != *"gh pr merge"* ]]
    [[ "${output}" != *"gh pr ready"* ]]
    [[ "${output}" != *"cfwf pr hand-off"* ]]
}

@test "build_pr_claude_md PHASE H marks the PR ready before enabling auto-merge (#1651)" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false"
    [ "${status}" -eq 0 ]
    local phase_h="${output#*PHASE H: Finalize}"
    phase_h="${phase_h%%Otherwise, if auto-merge is already enabled*}"
    [[ "${phase_h}" == *"cfwf pr hand-off --repo ${REPO_FULL} --pr 7"* ]]
    [[ "${phase_h}" == *"marks it ready"*"enables auto-merge"* ]]
    [[ "${phase_h}" == *"keep every \"Closes #<issue>\" line"* ]]
    [[ "${phase_h}" == *"Exit 0"*"Exit 8"* ]]
    [[ "${phase_h}" != *"Exit 7"* ]]
    [[ "${phase_h}" == *"\"auto-merge not armed\" on a base branch that requires no check and no review"* ]]
    [[ "${phase_h}" == *"unavailable on the repository, which leaves the PR ready for a human to merge"* ]]
}

@test "build_pr_claude_md dependency PR is marked ready before auto-merge, in one finalise-dependency call (#1651, #1771)" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "true"
    [ "${status}" -eq 0 ]
    local step="${output#*Else if ALL required checks have passed}"
    step="${step%%Else (checks are still PENDING)*}"
    [[ "${step}" == *"marks it ready if it is still a draft and then enables auto-merge"* ]]
    [[ "${step}" == *"cfwf pr finalise-dependency --repo ${REPO_FULL} --pr 7"* ]]
    [[ "${step}" == *"leaves the PR ready without auto-merge"* ]]
    [[ "${step}" == *"Exit 0"*"Exit 8"* ]]
    [[ "${step}" != *"Exit 7"* ]]
    [[ "${step}" == *"\"auto-merge not armed\" on a base branch that requires no check and no review"* ]]
}

@test "build_pr_claude_md for dependency PR generates compact instructions without code-work steps" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "true"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"dependency update PR"* ]]
    [[ "${output}" == *"Do NOT make any code changes"* ]]
    [[ "${output}" == *"cfwf pr finalise-dependency --repo ${REPO_FULL} --pr 7"* ]]
    [[ "${output}" == *"If any required check has FAILED: stop without taking action"* ]]
    [[ "${output}" != *"mandatory rules from the AI instructions"* ]]
    [[ "${output}" != *"force-with-lease"* ]]
}

@test "build_pr_claude_md for dependency PR instructs agent to stop if CI is still pending" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "true"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PENDING"* ]]
    [[ "${output}" == *"stop without taking action"* ]]
}

@test "build_pr_claude_md PHASE C tells the agent to diagnose from error lines, fix pre-existing errors and treat warnings as non-causes" {
    run build_pr_claude_md 5 "/ai" "CLEAN" "feat/x" "/workspace/repo" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"printed \`##[error]\` or a non-zero exit code"* ]]
    [[ "${output}" == *"\`##[warning]\` lines, and downloads or retries the job recovered from, are NOT the cause"* ]]
    [[ "${output}" == *"Quote the exact error lines"* ]]
    [[ "${output}" == *"already exist on the base branch, or that are in files this PR does not touch, are fixed in this PR too"* ]]
    [[ "${output}" == *"never bypass the hook"* ]]
    [[ "${output}" == *"cfwf run rerun --repo ${REPO_FULL} --run <run-id>"* ]]
}

@test "build_pr_claude_md for dependency PR no longer tells the agent to block on a failed required check" {
    run build_pr_claude_md 5 "/ai" "CLEAN" "depends/x" "/workspace/repo" "" "true"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"If any required check has FAILED: stop without taking action"* ]]
    [[ "${output}" != *"then add the Blocked label and stop"* ]]
}

@test "build_pr_claude_md for dependency PR checks for a failed required check before treating auto-merge-enabled as done" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "true"
    [ "${status}" -eq 0 ]
    local before_failed="${output%%If any required check has FAILED*}"
    local before_automerge="${output%%Else if auto-merge is already enabled*}"
    [ "${#before_failed}" -lt "${#before_automerge}" ]
}

@test "build_pr_claude_md tells a BEHIND or DIRTY PR to continue the rebase with plain git -C rebase --continue" {
    for state in BEHIND DIRTY; do
        run build_pr_claude_md 7 "/workspace/rules/.ai-instructions" "${state}" "feat/my-branch" "/workspace/repo"
        [ "${status}" -eq 0 ]
        [[ "${output}" == *"git -C /workspace/repo rebase --continue as its own command"* ]]
        [[ "${output}" == *"do not set GIT_EDITOR or -c core.editor"* ]]
    done
}

@test "build_pr_claude_md names the rebase-continue rule in every dirty-tree rebase variant" {
    run build_pr_claude_md 7 "/workspace/rules/.ai-instructions" "BEHIND" "feat/my-branch" "/workspace/repo" "feat/my-branch"
    [[ "${output}" == *"rebase --continue as its own command"* ]]
    run build_pr_claude_md 7 "/workspace/rules/.ai-instructions" "DIRTY" "feat/my-branch" "/workspace/repo" "other/branch"
    [[ "${output}" == *"rebase --continue as its own command"* ]]
}

@test "build_pr_claude_md omits the rebase-continue rule when no rebase is needed" {
    run build_pr_claude_md 7 "/workspace/rules/.ai-instructions" "CLEAN" "feat/my-branch" "/workspace/repo"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"rebase --continue as its own command"* ]]
}

@test "build_pr_claude_md for dependency PR skips rebase steps even when merge state is BEHIND" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "BEHIND" "feat/my-branch" "" "" "true"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"force-with-lease"* ]]
    [[ "${output}" != *"rebase origin/main"* ]]
}

@test "build_issue_claude_md says a permission denial refuses only one command and Bash is still available" {
    run build_issue_claude_md 42 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"refuses only the one command"* ]]
    [[ "${output}" == *"Bash is still available"* ]]
    [[ "${output}" == *"the mandated exclusions on any"* ]]
    [[ "${output}" == *"credfeto/credfeto-orchestrator#1167 (check it is not already listed first) giving only the denied command's name"* ]]
    [[ "${output}" == *"never include the command's arguments, paths, search patterns, heredoc or body content or literal values, and never name the source repository if it is private."* ]]
    [[ "${output}" == *"if we've opened one (the one exception is the denied-command report on credfeto/credfeto-orchestrator#1167 in step 10)."* ]]
}

@test "build_pr_claude_md says a permission denial refuses only one command and Bash is still available" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"refuses only the one command"* ]]
    [[ "${output}" == *"Bash is still available"* ]]
    [[ "${output}" == *"the mandated exclusions on any"* ]]
    [[ "${output}" == *"credfeto/credfeto-orchestrator#1167 (check it is not already listed first) giving only the denied command's name"* ]]
    [[ "${output}" == *"never include the command's arguments, paths, search patterns, heredoc or body content or literal values, and never name the source repository if it is private."* ]]
    [[ "${output}" == *"comment to the pull request (the one exception is the denied-command report on credfeto/credfeto-orchestrator#1167 in the permission-denial rule below)."* ]]
}

@test "build_pr_claude_md for dependency PR says a permission denial refuses only one command and Bash is still available" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "true"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"dependency update PR"* ]]
    [[ "${output}" == *"refuses only the one command"* ]]
    [[ "${output}" == *"Bash is still available"* ]]
    [[ "${output}" == *"the mandated exclusions on any"* ]]
    [[ "${output}" == *"credfeto/credfeto-orchestrator#1167 (check it is not already listed first) giving only the denied command's name"* ]]
    [[ "${output}" == *"never include the command's arguments, paths, search patterns, heredoc or body content or literal values, and never name the source repository if it is private."* ]]
    [[ "${output}" == *"comment to the pull request (the one exception is the denied-command report on credfeto/credfeto-orchestrator#1167 in step 5). Do NOT open issues."* ]]
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

@test "main resets the PR idle counter but keeps the total after a successful non-agentic rebase (#1664)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json()        { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[],"mergeable":"MERGEABLE","mergeStateStatus":"BEHIND"}\n'; }
    fingerprint_pr_json()  { printf 'fp-new\n'; }
    load_pr_fingerprint()  { printf 'fp-old\n'; }
    try_nonagentic_rebase() { return 0; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }
    save_pr_invocation_counts 5 7 3

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PR #5 in org/repo rebased non-agentically — idle budget reset"* ]]
    [ ! -f "${TEST_TMP}/claude_log" ]

    load_pr_invocation_counts 5
    [ "${PR_INVOCATION_TOTAL}" -eq 7 ]
    [ "${PR_INVOCATION_IDLE}" -eq 0 ]
}

@test "main leaves the PR invocation counters alone when the non-agentic rebase conflicts (#1664)" {
    setup_main_mocks
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    fetch_pr_json()        { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","headRefName":"feat/test","comments":[],"reviews":[],"statusCheckRollup":[],"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY"}\n'; }
    fingerprint_pr_json()  { printf 'fp-new\n'; }
    load_pr_fingerprint()  { printf 'fp-old\n'; }
    try_nonagentic_rebase() { return 1; }
    # Stop at the rate-limit gate straight after the hand-off, so no agent session runs and any
    # change to the counters could only have come from the rebase path itself.
    is_owner_rate_limited() { return 0; }
    invoke_claude() { printf 'called\n' >> "${TEST_TMP}/claude_log"; printf '12345678-1234-1234-1234-123456789abc\n'; }
    save_pr_invocation_counts 5 7 3

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Non-agentic rebase of PR #5 in org/repo had conflicts — handing off to agent"* ]]
    [[ "${output}" != *"idle budget reset"* ]]
    [ ! -f "${TEST_TMP}/claude_log" ]

    load_pr_invocation_counts 5
    [ "${PR_INVOCATION_TOTAL}" -eq 7 ]
    [ "${PR_INVOCATION_IDLE}" -eq 3 ]
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

# --- build_issue_claude_md plan-first steps -----------------------------------

@test "build_issue_claude_md includes plan-check command" {
    run build_issue_claude_md 42 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Implementation Plan"* ]]
    [[ "${output}" == *"cfwf issue plan-status --repo ${REPO_FULL} --issue 42"* ]]
    [[ "${output}" == *'"plan<TAB>yes" or "plan<TAB>no"'* ]]
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
    [[ "${output}" != *"Workflow board: this repository has a Workflow board"* ]]
}

@test "build_issue_claude_md includes WF section with the cfwf commands and no raw board ids when _WF_PROJECT_ID is set (#1650)" {
    _WF_PROJECT_ID="PVT_test123"
    _WF_STATUS_FIELD_ID="PVTSSF_field456"
    _WF_OPTION_IDS[Planning]="opt_plan_id"
    _WF_OPTION_IDS[Development]="opt_dev_id"
    run build_issue_claude_md 42 "/resolved/.ai-instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Its Status values, in order: Not Started, Planning, Approved, Development, AI Simplify, AI Review, AI Security Review, AI Coverage, Human Review, Complete."* ]]
    [[ "${output}" == *"Set this issue's status:  cfwf workflow-status --set --repo ${REPO_FULL} --issue 42 --status \"<Status>\""* ]]
    [[ "${output}" == *"Read this issue's status: cfwf workflow-status --check --repo ${REPO_FULL} --issue 42"* ]]
    [[ "${output}" == *"Never update the board with gh project or gh api graphql; they are denied."* ]]
    [[ "${output}" != *"PVT_"* ]]
    [[ "${output}" != *"PVTSSF_"* ]]
    [[ "${output}" != *"opt_plan_id"* ]]
    [[ "${output}" != *"opt_dev_id"* ]]
    [[ "${output}" != *"WF_PROJECT_ID"* ]]
    [[ "${output}" != *"--pr 42"* ]]
}

@test "build_issue_claude_md without board uses the comment-based approval check, cfwf issue plan-status --approval (#1772)" {
    _WF_PROJECT_ID=""
    run build_issue_claude_md 42 "/resolved/.ai-instructions" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"cfwf issue plan-status --repo ${REPO_FULL} --issue 42 --approval"* ]]
    [[ "${output}" == *'"approved<TAB>yes"'* ]]
    [[ "${output}" != *"approved on the Workflow board"* ]]
    [[ "${output}" != *"go ahead"* && "${output}" != *"looks good"* ]]
    [[ "${output}" != *"gh issue view 42"* ]]
}

@test "build_issue_claude_md without board leaves the approval decision to cfwf, with no login or keyword list of its own (#1286, #1772)" {
    _WF_PROJECT_ID=""
    _GH_ME="the-bot"
    run build_issue_claude_md 42 "/resolved/.ai-instructions" "" "false" '["credfeto"]'
    [ "${status}" -eq 0 ]
    [[ "${output}" != *'"the-bot"'* ]]
    [[ "${output}" != *'["credfeto"]'* ]]
    [[ "${output}" == *"your own prior comments never count"* ]]
    [[ "${output}" == *"never judge the comments yourself"* ]]
}

@test "build_issue_claude_md with board and plan not approved shows board-pending text" {
    _WF_PROJECT_ID="PVT_test"
    run build_issue_claude_md 42 "/resolved/.ai-instructions" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Workflow board"* ]]
    [[ "${output}" != *"--approval"* ]]
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

# --- cfwf board commands in the generated prompts (#1650) ----------------------

@test "build_issue_claude_md gives the cfwf command where it moves the board to Planning and to Development (#1650)" {
    _WF_PROJECT_ID="PVT_test123"
    run build_issue_claude_md 42 "/resolved/.ai-instructions" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'update the Workflow board status to "Planning" with `cfwf workflow-status --set --repo '"${REPO_FULL}"' --issue 42 --status "Planning"`'* ]]
    [[ "${output}" == *'update the Workflow board status to "Development" with `cfwf workflow-status --set --repo '"${REPO_FULL}"' --issue 42 --status "Development"`'* ]]
}

@test "build_pr_claude_md gives the matching cfwf command on every line that sets, advances or moves the board (#1650)" {
    _WF_PROJECT_ID="PVT_test123"
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false" ""
    [ "${status}" -eq 0 ]
    local line target checked=0
    while IFS= read -r line; do
        while IFS= read -r target; do
            [ -n "${target}" ] || continue
            if [[ "${line}" != *"to \"${target}\" with \`cfwf workflow-status --set --repo ${REPO_FULL} --pr 7 --status \"${target}\"\`"* ]]; then
                printf 'board move to %s without its cfwf command: %s\n' "${target}" "${line}"
                return 1
            fi
            checked=$((checked + 1))
        done < <(grep -oiE '(set|advance|move) the board( status)?( back)? to "[^"]+"' <<< "${line}" | sed -E 's/.*to "([^"]+)"$/\1/')
    done <<< "${output}"
    # PHASE C, D (three), E (two), F (two) and G (three).
    [ "${checked}" -ge 11 ]
}

@test "prompts for a repository without a board contain no cfwf board command (#1650)" {
    _WF_PROJECT_ID=""
    run build_issue_claude_md 42 "/resolved/.ai-instructions" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"cfwf workflow-status"* ]]
    [[ "${output}" != *"If a Workflow board update is denied"* ]]
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "false" ""
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"cfwf workflow-status"* ]]
    [[ "${output}" != *"If a Workflow board update is denied"* ]]
    [[ "${output}" == *'advance the board to "AI Review", post a one-line status comment'* ]]
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "true" ""
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"cfwf workflow-status"* ]]
}

@test "the permission-denial rule says to retry a denied board update once with cfwf when there is a board (#1650)" {
    _WF_PROJECT_ID="PVT_test123"
    run build_issue_claude_md 42 "/resolved/.ai-instructions" "" "false"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'whole state. If a Workflow board update is denied, retry it once as `cfwf workflow-status --set --repo '"${REPO_FULL}"' --issue 42 --status "<Status>"`; never hand-write GraphQL. If that form is also denied'* ]]
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "" "" "" "true" ""
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'If a Workflow board update is denied, retry it once as `cfwf workflow-status --set --repo '"${REPO_FULL}"' --pr 7 --status "<Status>"`; never hand-write GraphQL.'* ]]
}
