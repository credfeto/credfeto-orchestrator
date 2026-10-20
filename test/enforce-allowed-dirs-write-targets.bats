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
    run bash -c 'printf "%s" "$1" | "$2"' _ "$1" "${HOOK}"
}

run_in_repo() {
    run_hook_in_dir "$1" "${TEST_TMP}/repo"
}

assert_blocked_config_write() {
    [ "${status}" -eq 2 ] || { echo "expected a block, got status ${status}: ${output}" >&2; return 1; }
    [[ "${output}" == *'writing to Claude Code configuration'* ]] || { echo "wrong message: ${output}" >&2; return 1; }
    [[ "${output}" == *'command did not run'* ]] || { echo "missing 'command did not run': ${output}" >&2; return 1; }
}

# assert_each <expected status> <message substring or ''> <command>... - runs each command in
# the sandbox repo and checks the status and, when given, the message.
assert_each() {
    local want="$1" message="$2" cmd
    shift 2
    for cmd in "$@"; do
        run_in_repo "${cmd}"
        [ "${status}" -eq "${want}" ] || { echo "status ${status}, want ${want}: ${cmd}: ${output}" >&2; return 1; }
        [ -z "${message}" ] || [[ "${output}" == *"${message}"* ]] || { echo "wrong message for ${cmd}: ${output}" >&2; return 1; }
    done
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
    local cmd
    for cmd in \
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
        "nice tee .claude/settings.json"; do
        run_in_repo "${cmd}"
        assert_blocked_config_write || { echo "did not block: ${cmd}" >&2; return 1; }
    done
}

@test "every other allowlisted command that writes a named file is blocked on a protected path" {
    local cmd
    for cmd in \
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
        "npm run build -- --outDir=.claude/skills"; do
        run_in_repo "${cmd}"
        assert_blocked_config_write || { echo "did not block: ${cmd}" >&2; return 1; }
    done
}

@test "a sed or awk program that only mentions a protected name is blocked by design (use the Edit tool)" {
    local cmd
    for cmd in \
        "sed -i 's|~/.claude/hooks/|/etc/claude-code/hooks/|g' README.md" \
        "awk '{ sub(\"~/.claude.json\", \"x\"); print }' notes.txt"; do
        run_in_repo "${cmd}"
        assert_blocked_config_write || { echo "did not block: ${cmd}" >&2; return 1; }
    done
    run_file_tool Edit "${TEST_TMP}/repo/README.md"
    [ "${status}" -eq 0 ]
}

@test "the same writing commands on ordinary paths are allowed" {
    local cmd
    for cmd in \
        "touch out.txt" \
        "rm -rf build" \
        "mkdir -p sub/dir" \
        "chmod +x containers/base/development-full/claude-hooks/enforce-allowed-dirs" \
        "sort -o sorted.txt in.txt" \
        "awk '{print \$1}' in.txt" \
        "curl -sSo out.json https://example.com/x" \
        "git -C . checkout main -- src/file.txt" \
        "git -C . log --oneline" \
        "git -C . clone https://github.com/x/y vendor/y" \
        "git -C . diff --output=changes.patch" \
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
        "dotnet changelog -f CHANGELOG.md -a Fixed -m 'blocks writes to ~/.claude/settings.json'" \
        "dotnet test --filter 'FullyQualifiedName~Foo' -p:CollectCoverage=true"; do
        run_in_repo "${cmd}"
        [ "${status}" -eq 0 ] || { echo "did not allow: ${cmd}: ${output}" >&2; return 1; }
    done
}

@test "a copy, move or link whose destination is a .claude directory is blocked" {
    mkdir -p "${TEST_TMP}/repo/.claude"
    local cmd
    for cmd in \
        "cp ${SRC}/settings.local.json .claude/" \
        "cp ${SRC}/settings.local.json ${HOME}/.claude/" \
        "cp -t .claude ${SRC}/settings.local.json" \
        "mv ${SRC}/evil .claude" \
        "cp -r ${SRC}/evil sub/.claude" \
        "ln -s ${SRC}/fake .claude" \
        "ln -s -t .claude ${SRC}/fake"; do
        run_in_repo "${cmd}"
        assert_blocked_config_write || { echo "did not block: ${cmd}" >&2; return 1; }
    done
}

@test "a write into a protected directory reached through a leading cd or pushd is blocked" {
    mkdir -p "${TEST_TMP}/repo/.claude"
    local cmd
    for cmd in \
        "cd .claude && cp ${SRC}/x settings.local.json" \
        "pushd .claude && echo '{}' > settings.local.json" \
        "cd ${TEST_TMP}/repo/sub && cp ${SRC}/x ../.claude/settings.local.json"; do
        run_in_repo "${cmd}"
        assert_blocked_config_write || { echo "did not block: ${cmd}" >&2; return 1; }
    done
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

@test "git clone with no directory is checked against the directory git names after the repository" {
    local cmd
    for cmd in \
        "git -C . clone https://github.com/x/.claude.git" \
        "git -C . clone https://github.com/x/.claude/" \
        "git -C . clone https://github.com/x/.claude/.git" \
        "git -C . clone git@github.com:x/.claude.git" \
        "git -C . clone host:.mcp.json.git" \
        "git -C . clone --depth 1 https://github.com/x/.claude.bundle"; do
        run_in_repo "${cmd}"
        assert_blocked_config_write || { echo "did not block: ${cmd}" >&2; return 1; }
    done
    assert_each 0 '' "git -C . clone https://github.com/x/y.git" "git -C . clone git@github.com:x/y"
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
        "echo x > .cla'ude'/settings.json"
    assert_each 2 'brace, tilde or backslash' 'echo x > .cl\aude/settings.json'
}

@test "a relative Bash path that reaches a protected file once normalised or through a symlink is blocked" {
    mkdir -p "${TEST_TMP}/repo/.claude"
    printf '{}' > "${TEST_TMP}/repo/.claude/settings.json"
    ln -s "${TEST_TMP}/repo/.claude/settings.json" "${TEST_TMP}/repo/innocent.json"
    local cmd
    for cmd in "echo x > innocent.json" "cp x.json sub/../innocent.json" "echo x > .claude/./settings.json"; do
        run_in_repo "${cmd}"
        assert_blocked_config_write || { echo "did not block: ${cmd}" >&2; return 1; }
    done
}

@test "an unquoted glob that matches a protected file is blocked" {
    mkdir -p "${TEST_TMP}/repo/.claude"
    printf '{}' > "${TEST_TMP}/repo/.claude/settings.json"
    run_in_repo "sed -i 's/a/b/' .cl*/sett*"
    assert_blocked_config_write
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

@test "/dev/null, /dev/stdout and /dev/stderr are always allowed write targets" {
    assert_each 0 '' "ls > /dev/null 2>&1" "echo x 2>/dev/null" "echo x | tee /dev/stderr" "cat x > /dev/stdout"
}

@test "a write target that is relative after an untrackable cd is blocked" {
    assert_each 2 'unknowable' "ls && cd sub && echo x > out.txt"
}

@test "git path writers resolve relative to the last -C, not the hook's cwd" {
    mkdir -p "${TEST_TMP}/repo/sub/.claude"
    run_in_repo "git -C sub checkout main -- .claude/settings.json"
    assert_blocked_config_write
    assert_each 0 '' "git -C sub checkout main -- src/x" "git -C sub checkout main -- ../x"
    assert_each 2 'outside the allowed directories' "git -C sub checkout main -- ../../x"
}

@test "ln -s may point outside the roots, but the link it creates and any hard link may not" {
    assert_each 0 '' "ln -s ${TEST_TMP}/outside/x link" "ln -sf /etc/hosts sub/hosts"
    assert_each 2 'outside the allowed directories' \
        "ln -s x ${TEST_TMP}/outside/link" \
        "ln -s -t ${TEST_TMP}/outside x" \
        "ln ${TEST_TMP}/outside/x link"
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

@test "mktemp -t, --tmpdir and -p DIR also write into TMPDIR, and -p's directory is checked" {
    printf '%s\n' "${TEST_TMP}/repo" > "${HOOK_DIR}/allowed-dirs"
    assert_each 2 "implicit \$TMPDIR" "mktemp -t x.XXXXXX" "mktemp --tmpdir x.XXXXXX" "mktemp -p sub"
    printf '%s\n' "${TEST_TMP}/repo" "${TMPDIR}" > "${HOOK_DIR}/allowed-dirs"
    assert_each 0 '' "mktemp -t x.XXXXXX" "mktemp --tmpdir x.XXXXXX" "mktemp -p sub"
    assert_each 2 'outside the allowed directories' "mktemp -p ${TEST_TMP}/outside"
}

@test "ln option forms: --, long options, --target-directory=, a missing -t directory, no or one operand" {
    assert_each 2 'outside the allowed directories' \
        "ln -s -- x ${TEST_TMP}/outside/link" \
        "ln --force -s x ${TEST_TMP}/outside/link" \
        "ln -s --target-directory=${TEST_TMP}/outside x" \
        "ln --symbolic -t ${TEST_TMP}/outside -- x"
    assert_each 2 'requires a directory' "ln -s x -t"
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

@test "awk -l/--load/--include in every spelling makes the operands write targets, and -F and other options are skipped" {
    local opt
    for opt in "-l x" "--load x" "--include x" "-linplace" "--load=x" "--include=inplace" "-iinplace"; do
        assert_each 2 'outside the allowed directories' "awk ${opt} '{print}' ${TEST_TMP}/outside/x"
    done
    assert_each 0 '' "awk -i inplace -F x '/etc/' f.txt" "awk -F, '{print}' /etc/hosts"
    assert_each 2 'outside the allowed directories' "awk --posix -i inplace '{print}' ${TEST_TMP}/outside/x"
}

@test "an awk option outside the known non-writing set makes every argument a write target" {
    local cmd
    for cmd in \
        "awk --dump-variables=.claude/settings.json 1 /dev/null" \
        "awk -d.claude/settings.json 1 /dev/null" \
        "awk -o.claude/hooks/x '{print}' /dev/null" \
        "awk --pretty-print=.claude/hooks/x '{print}' /dev/null" \
        "awk -p.claude/agents/x '{print}' /dev/null" \
        "awk --profile=.claude/skills/x '{print}' /dev/null" \
        "awk --inc inplace '{print}' .claude/settings.json" \
        "awk -W include=inplace '{print}' .claude/settings.json" \
        "awk -W dump-variables=.claude/settings.json 1 /dev/null"; do
        run_in_repo "${cmd}"
        assert_blocked_config_write || { echo "did not block: ${cmd}" >&2; return 1; }
    done
    assert_each 2 'outside the allowed directories' "awk -D '{print}' ${TEST_TMP}/outside/x"
    assert_each 0 '' "awk --posix '{print}' /etc/hosts" "awk -P -F: '{print \$1}' /etc/passwd" "awk --field-separator=: '{print}' /etc/hosts"
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

@test "a writer's bare - operand (stdin or stdout) is not a path" {
    assert_each 0 '' "cp a.txt b.txt && tee -"
}

@test "ln -t with a glued value starting with s is a hard link, not a symbolic one" {
    assert_each 2 'outside the allowed directories' "ln -tsub ${TEST_TMP}/outside/x"
    assert_each 0 '' "ln -stsub ${TEST_TMP}/outside/x"
}

@test "ln -S takes the rest of its word: an s after it is not -s, and a t after it is not -t" {
    local cmd
    for cmd in "ln -Sxs .claude/settings.json evil" "ln -fSs .claude/settings.json evil" "ln -sSt x .claude/settings.json"; do
        run_in_repo "${cmd}"
        assert_blocked_config_write || { echo "did not block: ${cmd}" >&2; return 1; }
    done
    assert_each 0 '' "ln -sS.bak ${TEST_TMP}/outside/x link"
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
    run bash -c 'printf "%s" "$1" | PATH="$2" "$(command -v bash)" "$3"' _ "$1" "$2" "${HOOK}"
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

@test "missing jq is blocked (fail closed)" {
    run_payload_with_path '{}' "$(path_with_only)"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'jq is not available'* ]]
}
