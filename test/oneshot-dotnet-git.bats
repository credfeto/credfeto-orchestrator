#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are read by the sourced oneshot functions, where shellcheck cannot trace them
# shellcheck disable=SC2016  # stub bodies are expanded by the stub, not here

# ORCHESTRATOR_DOTNET_GIT (#252): off by default; when on, the read-only lib/git queries ask ORCHESTRATOR_CMD git, take
# its answer when it gives one (exit 0, 1, 128 or 129) and run their bash version, with a warning, when it does not.
# test/oneshot-git-parity.bats checks what both sides print and return.

bats_require_minimum_version 1.5.0

load test_helper
load oneshot_helper

# A stand-in for the tool: appends its arguments to ${TEST_TMP}/cmd_args (one a line, then ---), writes "tool stderr"
# to stderr, prints ${TEST_TMP}/answer and exits with ${TEST_TMP}/status (0 when absent); answer-<query> and
# status-<query>, when present, are used for that query instead
make_git_cmd_stub() {
    make_stub_multiline fake-orchestrator \
        '{ printf "%s\n" "$@"; printf -- "---\n"; } >> "${TEST_TMP}/cmd_args"' \
        'printf "tool stderr\n" >&2' \
        'if [ -f "${TEST_TMP}/answer-$2" ]; then cat "${TEST_TMP}/answer-$2"; elif [ -f "${TEST_TMP}/answer" ]; then cat "${TEST_TMP}/answer"; fi' \
        'if [ -f "${TEST_TMP}/status-$2" ]; then exit "$(cat "${TEST_TMP}/status-$2")"; fi' \
        'if [ -f "${TEST_TMP}/status" ]; then exit "$(cat "${TEST_TMP}/status")"; fi' \
        'exit 0'
    export ORCHESTRATOR_CMD=fake-orchestrator
}

_tool_answers() {
    printf '%s' "$1" > "${TEST_TMP}/answer"
    printf '%s' "$2" > "${TEST_TMP}/status"
}

# The tool's answer ($2) and status ($3) for one query ($1) only
_tool_answers_query() {
    printf '%s' "$2" > "${TEST_TMP}/answer-$1"
    printf '%s' "$3" > "${TEST_TMP}/status-$1"
}

# Stashes a change to the checkout's file.txt with the message $1
_stash_with() {
    printf '%s\n' "$1" >> "${REPO_WORK_DIR}/file.txt"
    git -C "${REPO_WORK_DIR}" add file.txt
    git -C "${REPO_WORK_DIR}" stash push -q -m "$1"
}

# A real clone on main, pushed to a local origin, so the bash versions have something to answer from
_setup_git_checkout() {
    REPO_WORK_DIR="${TEST_TMP}/work/repo"
    REPO_FULL=org/repo
    setup_local_git_remote > /dev/null
}

@test "ORCHESTRATOR_DOTNET_GIT defaults to off (#252)" {
    run env -u ORCHESTRATOR_DOTNET_GIT bash -c 'source "'"${REPO_ROOT}"'/oneshot"; printf "%s" "${ORCHESTRATOR_DOTNET_GIT}"'
    [ "${status}" -eq 0 ]
    [ "${output}" = "0" ]
}

@test "the lib/git queries never run ORCHESTRATOR_CMD while ORCHESTRATOR_DOTNET_GIT is off (#252)" {
    make_git_cmd_stub
    _setup_git_checkout
    ORCHESTRATOR_DOTNET_GIT=0
    [ "$(checkout_current_branch)" = main ]
    run checkout_has_uncommitted_changes
    [ "${status}" -eq 1 ]
    origin_branch_exists main
    [ -n "$(checkout_head_sha)" ]
    [ "$(git_commits_behind "${REPO_WORK_DIR}" HEAD origin/main)" = 0 ]
    run find_stale_issue_branch 12
    [ "${status}" -eq 1 ]
    [ -z "$(checkout_porcelain_status)" ]
    [ "$(checkout_changed_file_count)" = 0 ]
    run checkout_stash_head
    [ "${status}" -eq 1 ]
    [ -z "$(autostashes_beyond_keep orchestrator-autostash 0)" ]
    [ ! -f "${TEST_TMP}/cmd_args" ]
}

@test "each lib/git query hands its query and options to ORCHESTRATOR_CMD git when switched on (#252)" {
    make_git_cmd_stub
    _tool_answers "" 1
    REPO_WORK_DIR=/work/repo
    ORCHESTRATOR_DOTNET_GIT=1
    checkout_head_sha 2> /dev/null || true
    checkout_current_branch 2> /dev/null || true
    checkout_has_uncommitted_changes 2> /dev/null || true
    origin_branch_exists "feat/1 x" 2> /dev/null || true
    git_commits_behind /other HEAD origin/main 2> /dev/null || true
    mkdir -p "${TEST_TMP}/stale/.git"
    REPO_WORK_DIR="${TEST_TMP}/stale"
    find_stale_issue_branch 12 2> /dev/null || true
    REPO_WORK_DIR=/work/repo
    checkout_porcelain_status 2> /dev/null || true
    checkout_changed_file_count 2> /dev/null || true
    checkout_stash_head 2> /dev/null || true
    autostashes_beyond_keep "a prefix" 20 2> /dev/null || true
    [ "$(cat "${TEST_TMP}/cmd_args")" = "git
head-sha
--repo
/work/repo
---
git
current-branch
--repo
/work/repo
---
git
uncommitted-changes
--repo
/work/repo
---
git
origin-branch-exists
--repo
/work/repo
--branch
feat/1 x
---
git
commits-behind
--repo
/other
--ref
HEAD
--upstream
origin/main
---
git
stale-issue-branch
--repo
${TEST_TMP}/stale
--issue
12
---
git
porcelain-status
--repo
/work/repo
---
git
changed-file-count
--repo
/work/repo
---
git
stash-head
--repo
/work/repo
---
git
autostashes-beyond-keep
--repo
/work/repo
--prefix
a prefix
--keep
20
---" ]
}

@test "a query prints the tool's answer byte for byte, trailing newlines kept, and returns its status (#252)" {
    make_git_cmd_stub
    REPO_WORK_DIR=/work/repo
    ORCHESTRATOR_DOTNET_GIT=1
    local text status
    _tool_answers $'feat/1\n\n' 0
    text=$(
        checkout_current_branch 2> /dev/null
        printf x
    )
    [ "${text}" = $'feat/1\n\nx' ]
    _tool_answers "" 128
    run --separate-stderr checkout_head_sha
    [ "${status}" -eq 128 ]
    [ "${output}" = "" ]
    _tool_answers "" 129
    run --separate-stderr origin_branch_exists main
    [ "${status}" -eq 129 ]
    _tool_answers "" 0
    run --separate-stderr checkout_has_uncommitted_changes
    [ "${status}" -eq 0 ]
    _tool_answers "3" 0
    [ "$(git_commits_behind /r HEAD origin/main 2> /dev/null)" = 3 ]
}

@test "the quiet queries hide the tool's stderr, as their git stderr is hidden, and the others pass it through (#252)" {
    make_git_cmd_stub
    REPO_WORK_DIR=/work/repo
    ORCHESTRATOR_DOTNET_GIT=1
    _tool_answers "x" 0
    run --separate-stderr checkout_head_sha
    [ "${stderr}" = "" ]
    run --separate-stderr origin_branch_exists main
    [ "${stderr}" = "" ]
    run --separate-stderr git_commits_behind /r HEAD origin/main
    [ "${stderr}" = "" ]
    run --separate-stderr checkout_porcelain_status
    [ "${stderr}" = "" ]
    run --separate-stderr checkout_changed_file_count
    [ "${stderr}" = "" ]
    run --separate-stderr checkout_stash_head
    [ "${stderr}" = "" ]
    run --separate-stderr autostashes_beyond_keep orchestrator-autostash 20
    [ "${stderr}" = "" ]
    run --separate-stderr checkout_current_branch
    [ "${stderr}" = "tool stderr" ]
    run --separate-stderr checkout_has_uncommitted_changes
    [ "${stderr}" = "tool stderr" ]
}

@test "a query answers in bash, with a warning, when ORCHESTRATOR_CMD refuses, fails or is missing (#252)" {
    make_git_cmd_stub
    _setup_git_checkout
    ORCHESTRATOR_DOTNET_GIT=1
    local exit_code expected_head
    expected_head="$(git -C "${REPO_WORK_DIR}" rev-parse HEAD)"
    for exit_code in 2 3 125 130 143; do
        _tool_answers "wrong" "${exit_code}"
        run --separate-stderr checkout_current_branch
        [ "${status}" -eq 0 ]
        [ "${output}" = main ]
        [[ "${stderr}" == *"fake-orchestrator git current-branch failed (exit ${exit_code}); running git in bash instead"* ]]
        run --separate-stderr checkout_head_sha
        [ "${output}" = "${expected_head}" ]
        run --separate-stderr find_stale_issue_branch 12
        [ "${status}" -eq 1 ]
        [ "${output}" = "" ]
        [[ "${stderr}" == *"git stale-issue-branch failed (exit ${exit_code})"* ]]
    done
    ORCHESTRATOR_CMD="${TEST_TMP}/no-such-tool"
    run --separate-stderr git_commits_behind "${REPO_WORK_DIR}" HEAD origin/main
    [ "${status}" -eq 0 ]
    [ "${output}" = 0 ]
    [[ "${stderr}" == *"no-such-tool git commits-behind failed (exit 127); running git in bash instead"* ]]
}

@test "checkout_item_branch takes the tool's current branch and origin branch answers when switched on (#252)" {
    make_git_cmd_stub
    _setup_git_checkout
    git -C "${REPO_WORK_DIR}" checkout -q -b other
    ORCHESTRATOR_DOTNET_GIT=1
    _tool_answers $'main\n' 0
    # The tool says the checkout is on main, so no checkout is made
    checkout_item_branch main 2> /dev/null
    [ "$(git -C "${REPO_WORK_DIR}" branch --show-current)" = other ]
    # The tool says origin has no such branch, so the item is skipped
    _tool_answers "" 1
    run checkout_item_branch main-copy
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Branch 'main-copy' does not exist on origin"* ]]
    grep -q '^origin-branch-exists$' "${TEST_TMP}/cmd_args"
}

@test "the status and stash queries answer in bash, with a warning, when ORCHESTRATOR_CMD refuses or fails (#252)" {
    make_git_cmd_stub
    _setup_git_checkout
    ORCHESTRATOR_DOTNET_GIT=1
    _stash_with "orchestrator-autostash main old: dirty tree on unowned branch"
    _stash_with "orchestrator-autostash main new: dirty tree on unowned branch"
    printf 'new\n' > "${REPO_WORK_DIR}/new.txt"
    local exit_code
    for exit_code in 2 3 125; do
        _tool_answers "wrong" "${exit_code}"
        run --separate-stderr checkout_porcelain_status
        [ "${status}" -eq 0 ]
        [ "${output}" = "?? new.txt" ]
        [[ "${stderr}" == *"fake-orchestrator git porcelain-status failed (exit ${exit_code}); running git in bash instead"* ]]
        run --separate-stderr checkout_changed_file_count
        [ "${output}" = 1 ]
        [[ "${stderr}" == *"git changed-file-count failed (exit ${exit_code})"* ]]
        run --separate-stderr checkout_stash_head
        [ "${output}" = "$(git -C "${REPO_WORK_DIR}" rev-parse refs/stash)" ]
        [[ "${stderr}" == *"git stash-head failed (exit ${exit_code})"* ]]
        run --separate-stderr autostashes_beyond_keep orchestrator-autostash 1
        [ "${output}" = $'stash@{1}\tOn main: orchestrator-autostash main old: dirty tree on unowned branch' ]
        [[ "${stderr}" == *"git autostashes-beyond-keep failed (exit ${exit_code})"* ]]
    done
}

@test "prune_autostashes drops what the tool lists, in the tool's order, when switched on (#252)" {
    make_git_cmd_stub
    _setup_git_checkout
    local i
    for i in 1 2 3; do
        _stash_with "orchestrator-autostash main ${i}: dirty tree on unowned branch"
    done
    ORCHESTRATOR_DOTNET_GIT=1
    AUTOSTASH_KEEP=7
    _tool_answers $'stash@{2}\tOn main: from the tool a\nstash@{1}\tOn main: from the tool b\n' 0
    run prune_autostashes
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Dropped old autostash stash@{2} for org/repo (keeping the newest 7): from the tool a"* ]]
    [[ "${output}" == *"Dropped old autostash stash@{1} for org/repo (keeping the newest 7): from the tool b"* ]]
    [ "$(git -C "${REPO_WORK_DIR}" stash list --format=%gs)" = "On main: orchestrator-autostash main 3: dirty tree on unowned branch" ]
    grep -q '^autostashes-beyond-keep$' "${TEST_TMP}/cmd_args"
    grep -qx -- '--keep' "${TEST_TMP}/cmd_args"
    grep -qx 7 "${TEST_TMP}/cmd_args"
}

@test "autostash_dirty_checkout reports the tool's file count when switched on (#252)" {
    make_git_cmd_stub
    _setup_git_checkout
    printf 'new\n' > "${REPO_WORK_DIR}/new.txt"
    ORCHESTRATOR_DOTNET_GIT=1
    _tool_answers_query changed-file-count $'7\n' 0
    _tool_answers_query stash-head "" 3
    _tool_answers_query autostashes-beyond-keep "" 0
    run autostash_dirty_checkout main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Stashed 7 uncommitted file(s) on 'main'"* ]]
    [ -z "$(git -C "${REPO_WORK_DIR}" status --porcelain)" ]
}

@test "recover_orphaned_branch lists the tool's porcelain status before discarding an orphaned branch (#252)" {
    make_git_cmd_stub
    _setup_git_checkout
    git -C "${REPO_WORK_DIR}" checkout -q -b gone
    printf 'dirty\n' > "${REPO_WORK_DIR}/dirty.txt"
    ORCHESTRATOR_DOTNET_GIT=1
    _tool_answers_query current-branch $'gone\n' 0
    _tool_answers_query origin-branch-exists "" 1
    _tool_answers_query porcelain-status $' M from-the-tool.txt\n\n' 0
    run recover_orphaned_branch
    [ "${status}" -eq 0 ]
    [[ "${output}" == *$'Files affected:\n M from-the-tool.txt'* ]]
    [ "$(git -C "${REPO_WORK_DIR}" branch --show-current)" = main ]
    grep -q '^porcelain-status$' "${TEST_TMP}/cmd_args"
}
