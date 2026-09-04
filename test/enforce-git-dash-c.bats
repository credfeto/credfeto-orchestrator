#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped

load test_helper

# shellcheck disable=SC2034  # read by run_hook_in_dir in test_helper.bash, not visible to shellcheck across `load`
HOOK="${REPO_ROOT}/containers/base/development-full/claude-hooks/enforce-git-dash-c"

setup() {
    setup_isolated_env
}

teardown() {
    cleanup_stubs
    # Restores write permission on any directory a test chmod'd read-only (the
    # not-writable auto-correction case) so TEST_TMP cleanup can remove it.
    if [ -n "${READONLY_TEST_DIR:-}" ]; then
        chmod u+w "${READONLY_TEST_DIR}" 2> /dev/null
    fi
}

# Tests below use test_helper.bash's shared run_hook_in_dir (promoted there in
# #1385 when a second hook needed it). Its dir argument defaults to TEST_TMP -
# confirmed, via direct testing before #1357's auto-correction feature was
# written, to always sit under BATS_TEST_TMPDIR, itself never nested inside
# this checkout's own git tree - so every test below keeps exercising the hook
# exactly as it behaved before #1357: bats itself is normally invoked from the
# repo root, which IS a real, writable git checkout, so without this every
# "bare git X is blocked" test here would silently start passing through the
# new auto-correct path instead of the block path they're named for. The
# auto-correction tests (#1357) pass a second argument instead - a real,
# writable git repository, which the hook's own $PWD needs to be for that
# path. Not the shared run_hook: that one runs from bats' own CWD (the repo
# root), which is exactly the always-auto-corrects case this default exists
# to avoid.

# Creates a fresh, writable git repository under TEST_TMP and echoes its path.
make_writable_repo() {
    local dir="${TEST_TMP}/autocorrect-repo-$$-${RANDOM}"
    mkdir -p "${dir}"
    git init -q "${dir}"
    printf '%s' "${dir}"
}

@test "bare git push is blocked" {
    run_hook_in_dir "git push"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'git -C <dir>'* ]]
}

@test "git alone with no subcommand is blocked" {
    run_hook_in_dir "git"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'must include a subcommand'* ]]
}

# Subcommand allowlist tests (#1387): git-subcommand-allowlist gates every
# git call before the existing -C/config/clone/auto-correct handling below.

@test "an allowed subcommand (worktree) is not blocked by the allowlist gate" {
    run_hook_in_dir "git -C . worktree list"
    [ "${status}" -eq 0 ]
}

@test "git checkout is allowed by the subcommand allowlist (mandated by git.instructions.md's branch-switch guidance)" {
    run_hook_in_dir "git -C . checkout some-branch"
    [ "${status}" -eq 0 ]
}

@test "git cherry-pick is allowed by the subcommand allowlist (#1411: confirmed live need, added back after #1394 dropped it)" {
    run_hook_in_dir "git -C . cherry-pick abc123"
    [ "${status}" -eq 0 ]
}

@test "git filter-branch is blocked by the subcommand allowlist even with -C present" {
    run_hook_in_dir "git -C . filter-branch --tag-name-filter cat -- --all"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"subcommand 'filter-branch' is not permitted"* ]]
}

@test "git daemon is blocked by the subcommand allowlist" {
    run_hook_in_dir "git -C . daemon"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"subcommand 'daemon' is not permitted"* ]]
}

@test "git instaweb is blocked by the subcommand allowlist" {
    run_hook_in_dir "git -C . instaweb"
    [ "${status}" -eq 2 ]
}

@test "git credential is blocked by the subcommand allowlist" {
    run_hook_in_dir "git -C . credential fill"
    [ "${status}" -eq 2 ]
}

@test "git submodule is blocked by the subcommand allowlist" {
    run_hook_in_dir "git -C . submodule update --init"
    [ "${status}" -eq 2 ]
}

# The following have no confirmed use in this repo's own instructions, unlike every entry
# actually on GIT_ALLOWED_SUBCOMMANDS - pinned as blocked so a future edit can't silently
# widen the list back to them without a deliberate, reviewed change.
@test "git am is blocked - no confirmed use in this repo" {
    run_hook_in_dir "git -C . am some.patch"
    [ "${status}" -eq 2 ]
}

@test "git mv is blocked - no confirmed use in this repo" {
    run_hook_in_dir "git -C . mv old new"
    [ "${status}" -eq 2 ]
}

@test "git remote is blocked - actively moved away from in favour of git config --local" {
    run_hook_in_dir "git -C . remote -v"
    [ "${status}" -eq 2 ]
}

@test "git restore is blocked - only mentioned as a destructive command to be careful with, not an instructed operation" {
    run_hook_in_dir "git -C . restore ."
    [ "${status}" -eq 2 ]
}

@test "git revert is blocked - no confirmed use in this repo" {
    run_hook_in_dir "git -C . revert abc123"
    [ "${status}" -eq 2 ]
}

@test "git rm is blocked - no confirmed use in this repo" {
    run_hook_in_dir "git -C . rm file"
    [ "${status}" -eq 2 ]
}

@test "git tag is blocked - no confirmed use in this repo" {
    run_hook_in_dir "git -C . tag v1.0.0"
    [ "${status}" -eq 2 ]
}

@test "a disallowed subcommand is blocked outright when -C is missing, not offered an auto-correct rewrite (#1387)" {
    local repo
    repo=$(make_writable_repo)
    run_hook_in_dir "git filter-branch --tag-name-filter cat -- --all" "${repo}"
    [ "${status}" -eq 2 ]
    [[ "${output}" != *'hookSpecificOutput'* ]]
}

@test "git -C . push is allowed" {
    run_hook_in_dir "git -C . push"
    [ "${status}" -eq 0 ]
}

@test "-c flags before -C are accepted as hardened" {
    run_hook_in_dir "git -c core.pager=cat -C . log"
    [ "${status}" -eq 0 ]
}

@test "a single bare pipe before git is blocked" {
    run_hook_in_dir "true | git push"
    [ "${status}" -eq 2 ]
}

@test "a double pipe (||) before git is blocked" {
    run_hook_in_dir "false || git push"
    [ "${status}" -eq 2 ]
}

@test "a hardened invocation followed by a bare invocation via && is blocked" {
    run_hook_in_dir "git -C . status && git push --force"
    [ "${status}" -eq 2 ]
}

@test "two hardened invocations chained with && are allowed" {
    run_hook_in_dir "git -C . status && git -C . push --force"
    [ "${status}" -eq 0 ]
}

@test "a hardened invocation followed by a bare invocation via ; is blocked" {
    run_hook_in_dir "git -C . status; git push --force"
    [ "${status}" -eq 2 ]
}

@test "command substitution without -C is blocked" {
    # shellcheck disable=SC2016  # literal $(...) — must reach the hook unexpanded
    run_hook_in_dir 'x=$(git rev-parse HEAD)'
    [ "${status}" -eq 2 ]
}

@test "command substitution with -C is allowed" {
    # shellcheck disable=SC2016  # literal $(...) — must reach the hook unexpanded
    run_hook_in_dir 'x=$(git -C . rev-parse HEAD)'
    [ "${status}" -eq 0 ]
}

@test "backtick command substitution without -C is blocked" {
    # shellcheck disable=SC2016  # literal `...` — must reach the hook unexpanded
    run_hook_in_dir 'x=`git push`'
    [ "${status}" -eq 2 ]
}

@test "backtick command substitution with -C is allowed" {
    # shellcheck disable=SC2016  # literal `...` — must reach the hook unexpanded
    run_hook_in_dir 'x=`git -C . push`'
    [ "${status}" -eq 0 ]
}

@test "a bare git backgrounded with a single & is blocked" {
    run_hook_in_dir "true & git push"
    [ "${status}" -eq 2 ]
}

@test "a bare git inside a brace group is blocked" {
    run_hook_in_dir "{ git push; }"
    [ "${status}" -eq 2 ]
}

@test "a command substitution inside double quotes is still checked" {
    # shellcheck disable=SC2016  # literal $(...) — must reach the hook unexpanded
    run_hook_in_dir 'echo "$(git push)"'
    [ "${status}" -eq 2 ]
}

@test "a hardened command substitution inside double quotes is allowed" {
    # shellcheck disable=SC2016  # literal $(...) — must reach the hook unexpanded
    run_hook_in_dir 'echo "$(git -C . push)"'
    [ "${status}" -eq 0 ]
}

@test "a bare git after a quoted close-paren inside a top-level command substitution is blocked" {
    # shellcheck disable=SC2016  # literal $(...) — must reach the hook unexpanded
    run_hook_in_dir '$(echo ")" && git push)'
    [ "${status}" -eq 2 ]
}

@test "a bare git after a quoted close-paren inside a top-level backtick substitution is blocked" {
    # shellcheck disable=SC2016  # literal backticks — must reach the hook unexpanded
    run_hook_in_dir 'echo `echo ")" && git push`'
    [ "${status}" -eq 2 ]
}

@test "a hardened git after a quoted close-paren inside a top-level command substitution is allowed" {
    # shellcheck disable=SC2016  # literal $(...) — must reach the hook unexpanded
    run_hook_in_dir '$(echo ")" && git -C . push)'
    [ "${status}" -eq 0 ]
}

@test "a hardened invocation with parens inside a quoted grep pattern is not falsely blocked" {
    run_hook_in_dir 'git -C . log --grep="(WIP) git stuff"'
    [ "${status}" -eq 0 ]
}

@test "a hardened invocation with a semicolon inside a quoted grep pattern is not falsely blocked" {
    run_hook_in_dir 'git -C . log --grep="fix a; git push later"'
    [ "${status}" -eq 0 ]
}

@test "a hardened invocation with an ampersand inside a quoted grep pattern is not falsely blocked" {
    run_hook_in_dir 'git -C . log --grep="wip & git gc"'
    [ "${status}" -eq 0 ]
}

@test "a hardened invocation with braces inside a quoted commit message is not falsely blocked" {
    run_hook_in_dir 'git -C . commit -m "wip {git}"'
    [ "${status}" -eq 0 ]
}

@test "a single-quoted commit message containing an ampersand is not falsely blocked" {
    run_hook_in_dir "git -C . commit -m 'stuff & things'"
    [ "${status}" -eq 0 ]
}

@test "a non-git command containing parens in a quoted argument is not falsely blocked" {
    run_hook_in_dir 'echo "(git is great)"'
    [ "${status}" -eq 0 ]
}

@test "git -C . config --global write is blocked (config is read-only)" {
    run_hook_in_dir "git -C . config --global user.email test@example.com"
    [ "${status}" -eq 2 ]
}

@test "bare git clone is exempted from -C" {
    run_hook_in_dir "git clone https://example.com/repo.git /tmp/repo"
    [ "${status}" -eq 0 ]
}

@test "bare git clone with flags before the url is exempted from -C" {
    run_hook_in_dir "git clone --depth 1 https://example.com/repo.git"
    [ "${status}" -eq 0 ]
}

@test "bare git config --global --get is exempted from -C" {
    run_hook_in_dir "git config --global --get user.email"
    [ "${status}" -eq 0 ]
}

@test "bare git config --get --global (flags reversed) is exempted from -C" {
    run_hook_in_dir "git config --get --global user.email"
    [ "${status}" -eq 0 ]
}

@test "bare git config --system --get-all is exempted from -C" {
    run_hook_in_dir "git config --system --get-all safe.directory"
    [ "${status}" -eq 0 ]
}

@test "bare git config --global --get-regexp is exempted from -C" {
    run_hook_in_dir 'git config --global --get-regexp "^user\."'
    [ "${status}" -eq 0 ]
}

@test "bare git config --global --list is exempted from -C" {
    run_hook_in_dir "git config --global --list"
    [ "${status}" -eq 0 ]
}

@test "bare git config --global with no read/write flag is still blocked" {
    run_hook_in_dir "git config --global user.email"
    [ "${status}" -eq 2 ]
}

@test "bare git config --global write (set) is still blocked" {
    run_hook_in_dir "git config --global user.email test@example.com"
    [ "${status}" -eq 2 ]
}

@test "bare git config --global --add is still blocked" {
    run_hook_in_dir "git config --global --add safe.directory /x"
    [ "${status}" -eq 2 ]
}

@test "bare git config --global --unset is still blocked" {
    run_hook_in_dir "git config --global --unset user.email"
    [ "${status}" -eq 2 ]
}

@test "bare git config --get without --global/--system is still blocked" {
    run_hook_in_dir "git config --get user.email"
    [ "${status}" -eq 2 ]
}

@test "bare git config --list without --global/--system is still blocked" {
    run_hook_in_dir "git config --list"
    [ "${status}" -eq 2 ]
}

@test "bare git config plain (no scope, no action) is still blocked" {
    run_hook_in_dir "git config user.email"
    [ "${status}" -eq 2 ]
}

@test "git -C . config plain set (local write) is blocked" {
    run_hook_in_dir "git -C . config pull.rebase false"
    [ "${status}" -eq 2 ]
}

@test "git -C . config --add (local write) is blocked" {
    run_hook_in_dir "git -C . config --add safe.directory /x"
    [ "${status}" -eq 2 ]
}

@test "git -C . config --unset (local write) is blocked" {
    run_hook_in_dir "git -C . config --unset user.email"
    [ "${status}" -eq 2 ]
}

@test "git -C . config --get read is allowed" {
    run_hook_in_dir "git -C . config --get user.email"
    [ "${status}" -eq 0 ]
}

@test "git -C . config single-key read (no action flag) is allowed" {
    run_hook_in_dir "git -C . config user.email"
    [ "${status}" -eq 0 ]
}

@test "a quoted variable value cannot disguise a local write as a single-key read" {
    # shellcheck disable=SC2016  # the variable must reach the hook unexpanded
    run_hook_in_dir 'git -C . config user.email "$EVIL"'
    [ "${status}" -eq 2 ]
}

@test "git config --edit is blocked outright" {
    run_hook_in_dir "git -C . config --edit"
    [ "${status}" -eq 2 ]
}

@test "git config --file is blocked outright" {
    run_hook_in_dir "git -C . config --file /tmp/x --get user.email"
    [ "${status}" -eq 2 ]
}

@test "a non-git command is allowed" {
    run_hook_in_dir "ls -la"
    [ "${status}" -eq 0 ]
}

@test "heredoc body text that merely looks like a bare git command is not blocked" {
    run_hook_in_dir "$(printf 'cat <<EOF\ngit push\nEOF')"
    [ "${status}" -eq 0 ]
}

@test "a bare git negated with ! is blocked" {
    run_hook_in_dir "! git push"
    [ "${status}" -eq 2 ]
}

@test "a hardened git negated with ! is allowed" {
    run_hook_in_dir "! git -C . push"
    [ "${status}" -eq 0 ]
}

@test "a bare git prefixed with sudo is blocked" {
    run_hook_in_dir "sudo git push"
    [ "${status}" -eq 2 ]
}

@test "a hardened git prefixed with sudo is allowed" {
    run_hook_in_dir "sudo git -C . push"
    [ "${status}" -eq 0 ]
}

@test "a bare git prefixed with env is blocked" {
    run_hook_in_dir "env git push"
    [ "${status}" -eq 2 ]
}

@test "a bare git prefixed with exec is blocked" {
    run_hook_in_dir "exec git push"
    [ "${status}" -eq 2 ]
}

@test "a bare git prefixed with command is blocked" {
    run_hook_in_dir "command git push"
    [ "${status}" -eq 2 ]
}

@test "a bare git prefixed with time is blocked" {
    run_hook_in_dir "time git push"
    [ "${status}" -eq 2 ]
}

@test "a bare git inside a for-loop do body is blocked" {
    run_hook_in_dir "for i in 1; do git push; done"
    [ "${status}" -eq 2 ]
}

@test "a hardened git inside a for-loop do body is allowed" {
    run_hook_in_dir "for i in 1; do git -C . push; done"
    [ "${status}" -eq 0 ]
}

@test "a bare git inside an if/then body is blocked" {
    run_hook_in_dir "if true; then git push; fi"
    [ "${status}" -eq 2 ]
}

@test "a bare git inside an if/else body is blocked" {
    run_hook_in_dir "if false; then true; else git push; fi"
    [ "${status}" -eq 2 ]
}

@test "eval with a double-quoted git command is blocked" {
    run_hook_in_dir 'eval "git push"'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'cannot be verified inside eval'* ]]
}

@test "eval with a single-quoted git command is blocked" {
    run_hook_in_dir "eval 'git push'"
    [ "${status}" -eq 2 ]
}

@test "source is blocked outright" {
    run_hook_in_dir "source ./setup.sh"
    [ "${status}" -eq 2 ]
}

@test "a path-qualified bare git invocation is blocked" {
    run_hook_in_dir "/usr/bin/git push"
    [ "${status}" -eq 2 ]
}

@test "a path-qualified hardened git invocation is allowed" {
    run_hook_in_dir "/usr/bin/git -C . push"
    [ "${status}" -eq 0 ]
}

@test "a relative-path bare git invocation is blocked" {
    run_hook_in_dir "./git push"
    [ "${status}" -eq 2 ]
}

@test "a command that does not parse as shell is blocked (fail closed)" {
    run_hook_in_dir "if true; then git push"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'could not be parsed'* ]]
}

@test "an obfuscated git name is opaque to this hook (reject-obfuscated-commands blocks it upstream)" {
    run_hook_in_dir '"g""it" push'
    [ "${status}" -eq 0 ]
}

@test "the denial message states the command never ran (#1281)" {
    run_hook_in_dir "git push"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'command did not run'* ]]
}

# Auto-correction tests (#1357): a missing -C is rewritten instead of blocked when the
# hook's own $PWD resolves via `git rev-parse --show-toplevel` to a writable directory and
# no `cd` appears anywhere in the command. See run_hook_in_dir (dir argument)/make_writable_repo above.

@test "a bare git status auto-corrects to git -C <toplevel> status when run from inside a writable repo (#1357)" {
    local repo
    repo=$(make_writable_repo)
    run_hook_in_dir "git status" "${repo}"
    [ "${status}" -eq 0 ]
    local rewritten
    rewritten=$(printf '%s' "${output}" | jq -r '.hookSpecificOutput.updatedInput.command')
    [[ "${rewritten}" == "git -C ${repo} status" ]]
}

@test "auto-correction preserves run_in_background from the original tool_input (#1367)" {
    local repo
    repo=$(make_writable_repo)
    run_hook_in_dir "git status" "${repo}" "true"
    [ "${status}" -eq 0 ]
    local rewritten bg
    rewritten=$(printf '%s' "${output}" | jq -r '.hookSpecificOutput.updatedInput.command')
    bg=$(printf '%s' "${output}" | jq -r '.hookSpecificOutput.updatedInput.run_in_background')
    [[ "${rewritten}" == "git -C ${repo} status" ]]
    [ "${bg}" = "true" ]
}

@test "a compound command with two bare git calls gets both auto-corrected (#1357)" {
    local repo
    repo=$(make_writable_repo)
    run_hook_in_dir "git status && git branch --show-current" "${repo}"
    [ "${status}" -eq 0 ]
    local rewritten
    rewritten=$(printf '%s' "${output}" | jq -r '.hookSpecificOutput.updatedInput.command')
    [[ "${rewritten}" == "git -C ${repo} status && git -C ${repo} branch --show-current" ]]
}

@test "-C is inserted right after git, not after existing -c pairs, when auto-correcting (#1357)" {
    local repo
    repo=$(make_writable_repo)
    run_hook_in_dir "git -c core.pager=cat status" "${repo}"
    [ "${status}" -eq 0 ]
    local rewritten
    rewritten=$(printf '%s' "${output}" | jq -r '.hookSpecificOutput.updatedInput.command')
    [[ "${rewritten}" == "git -C ${repo} -c core.pager=cat status" ]]
}

@test "auto-correction is skipped (falls back to block) when cd appears anywhere in the command (#1357)" {
    local repo
    repo=$(make_writable_repo)
    run_hook_in_dir "cd ${repo} && git status" "${repo}"
    [ "${status}" -eq 2 ]
}

@test "bare git is still blocked, not auto-corrected, when there is no enclosing git repository (#1357)" {
    run_hook_in_dir "git status"
    [ "${status}" -eq 2 ]
}

@test "auto-correction falls back to block when the resolved toplevel is not writable (#1357)" {
    local repo
    repo=$(make_writable_repo)
    READONLY_TEST_DIR="${repo}"
    chmod u-w "${repo}"
    run_hook_in_dir "git status" "${repo}"
    [ "${status}" -eq 2 ]
}

@test "a hardened invocation (already has -C) is not touched by auto-correction (#1357)" {
    local repo
    repo=$(make_writable_repo)
    run_hook_in_dir "git -C ${repo} status" "${repo}"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *'hookSpecificOutput'* ]]
}

@test "auto-correction injects the hook's own \$PWD, not the resolved repo toplevel, when run from a subdirectory (#1357)" {
    local repo subdir
    repo=$(make_writable_repo)
    subdir="${repo}/sub"
    mkdir -p "${subdir}"
    run_hook_in_dir "git status" "${subdir}"
    [ "${status}" -eq 0 ]
    local rewritten
    rewritten=$(printf '%s' "${output}" | jq -r '.hookSpecificOutput.updatedInput.command')
    [[ "${rewritten}" == "git -C ${subdir} status" ]]
}

@test "auto-correction is skipped (falls back to block) when pushd appears anywhere in the command (#1357)" {
    local repo
    repo=$(make_writable_repo)
    run_hook_in_dir "pushd ${repo} && git status" "${repo}"
    [ "${status}" -eq 2 ]
}

@test "auto-correction is skipped (falls back to block) when a wrapped cd (command cd) appears anywhere in the command (#1357)" {
    local repo
    repo=$(make_writable_repo)
    run_hook_in_dir "command cd ${repo} && git status" "${repo}"
    [ "${status}" -eq 2 ]
}

@test "auto-correction is skipped (falls back to block) when a backslash-escaped cd appears anywhere in the command (#1357)" {
    local repo
    repo=$(make_writable_repo)
    run_hook_in_dir '\cd '"${repo}"' && git status' "${repo}"
    [ "${status}" -eq 2 ]
}
