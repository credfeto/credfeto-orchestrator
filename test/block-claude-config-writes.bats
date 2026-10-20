#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped

load test_helper

HOOK="${REPO_ROOT}/containers/base/development-full/claude-hooks/block-claude-config-writes"

setup() {
    setup_isolated_env
    mkdir -p "${TEST_TMP}/repo/sub"
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

assert_blocked_config_write() {
    [ "${status}" -eq 2 ] || { echo "expected a block, got status ${status}: ${output}" >&2; return 1; }
    [[ "${output}" == *'writing to Claude Code configuration'* ]] || { echo "wrong message: ${output}" >&2; return 1; }
    [[ "${output}" == *'command did not run'* ]] || { echo "missing 'command did not run': ${output}" >&2; return 1; }
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

@test "ordinary files and the tracked sources under containers/ are allowed" {
    local path
    for path in \
        "${TEST_TMP}/repo/src/Program.cs" \
        "${TEST_TMP}/repo/docs/claude.md" \
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

# --- Bash ---------------------------------------------------------------------

@test "each Bash write form into a protected file is blocked" {
    local cmd
    for cmd in \
        "sed -i 's/a/b/' .claude/settings.json" \
        "sed -ni 's/a/b/p' .mcp.json" \
        "sed --in-place=.bak 's/a/b/' .mcp.json" \
        "cp settings.json ${HOME}/.claude/settings.json" \
        "mv new.json .claude/settings.local.json" \
        "ln -sf /tmp/evil ${HOME}/.claude/hooks/enforce-git-dash-c" \
        "install -m 0644 x.json /etc/claude-code/managed-settings.json" \
        "echo '{}' | tee .mcp.json" \
        "echo '{}' > .claude/settings.json" \
        "echo '{}' >> ~/.claude.json" \
        "echo '{}' &> sub/.claude/settings.json" \
        "nice tee .claude/settings.json"; do
        run_hook_in_dir "${cmd}" "${TEST_TMP}/repo"
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
        "sort -o .claude/settings.local.json /tmp/x" \
        "uniq /tmp/x .claude/settings.local.json" \
        "awk '{print > \".claude/settings.local.json\"}' /tmp/x" \
        "awk -i inplace 1 .mcp.json" \
        "curl -sSo .claude/settings.local.json https://example.com/x" \
        "git -C . checkout main -- .claude/settings.json" \
        "git -C . restore --source=main .claude/settings.local.json" \
        "git mv notes.json .claude/settings.json" \
        "sed --in 's/a/b/' .claude/settings.json" \
        "sed --in-pl=.bak 's/a/b/' .mcp.json" \
        "sed -n 'w .claude/settings.json' /tmp/payload" \
        "sed 's/^//w .claude/skills/x/SKILL.md' /tmp/p" \
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
        "bats -o .claude/skills --report-formatter junit test"; do
        run_hook_in_dir "${cmd}" "${TEST_TMP}/repo"
        assert_blocked_config_write || { echo "did not block: ${cmd}" >&2; return 1; }
    done
}

@test "a sed or awk program that only mentions a protected name is blocked by design (use the Edit tool)" {
    local cmd
    for cmd in \
        "sed -i 's|~/.claude/hooks/|/etc/claude-code/hooks/|g' README.md" \
        "awk '{ sub(\"~/.claude.json\", \"x\"); print }' notes.txt"; do
        run_hook_in_dir "${cmd}" "${TEST_TMP}/repo"
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
        "chmod +x containers/base/development-full/claude-hooks/block-claude-config-writes" \
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
        "bats test/block-claude-config-writes.bats" \
        "ruff check ." \
        "mktemp -d" \
        "shfmt -w containers/base/development-full/claude-hooks/block-claude-config-writes" \
        "gh pr create --title fix --body 'blocks writes to .claude/settings.json'" \
        "gh issue comment 1 --body 'see ~/.claude/hooks'"; do
        run_hook_in_dir "${cmd}" "${TEST_TMP}/repo"
        [ "${status}" -eq 0 ] || { echo "did not allow: ${cmd}: ${output}" >&2; return 1; }
    done
}

@test "a copy, move or link whose destination is a .claude directory is blocked" {
    mkdir -p "${TEST_TMP}/repo/.claude"
    local cmd
    for cmd in \
        "cp /tmp/settings.local.json .claude/" \
        "cp /tmp/settings.local.json ${HOME}/.claude/" \
        "cp -t .claude /tmp/settings.local.json" \
        "install --target-directory=.claude /tmp/settings.local.json" \
        "mv /tmp/evil .claude" \
        "cp -r /tmp/evil sub/.claude" \
        "ln -s /tmp/fake .claude"; do
        run_hook_in_dir "${cmd}" "${TEST_TMP}/repo"
        assert_blocked_config_write || { echo "did not block: ${cmd}" >&2; return 1; }
    done
}

@test "a write into a protected directory reached through cd or pushd is blocked" {
    mkdir -p "${TEST_TMP}/repo/.claude" "${TEST_TMP}/etc/claude-code"
    local cmd
    for cmd in \
        "cd .claude && cp /tmp/x settings.local.json" \
        "pushd .claude && echo '{}' > settings.local.json" \
        "cd ~/.claude && tee settings.json" \
        "cd .cl* && cp /tmp/x settings.local.json" \
        "cd ${TEST_TMP}/repo/sub && cp /tmp/x ../.claude/settings.local.json"; do
        run_hook_in_dir "${cmd}" "${TEST_TMP}/repo"
        assert_blocked_config_write || { echo "did not block: ${cmd}" >&2; return 1; }
    done
}

@test "a relative write target is also resolved against each cd directory" {
    mkdir -p "${TEST_TMP}/elsewhere/.claude"
    ln -s "${TEST_TMP}/elsewhere/.claude" "${TEST_TMP}/elsewhere/innocent"
    run_hook_in_dir "cd ${TEST_TMP}/elsewhere && cp /tmp/x innocent/settings.json" "${TEST_TMP}/repo"
    assert_blocked_config_write
}

@test "a relative glob write target is also expanded in each cd directory" {
    mkdir -p "${TEST_TMP}/repo/sub/.claude"
    printf '{}' > "${TEST_TMP}/repo/sub/.claude/settings.local.json"
    run_hook_in_dir "cd sub && cp /tmp/x .cl*/settings.local.json" "${TEST_TMP}/repo"
    assert_blocked_config_write
}

@test "ANSI-C quoting in a write target is blocked, since it can spell a protected name in escapes" {
    local cmd
    # shellcheck disable=SC2016  # the $'...' is the command under test, not expanded here
    for cmd in "echo x > \$'.claude/settings.json'" "echo x > \$'\\x2e\\x63laude/settings.json'" "cp /tmp/x \$'out.txt'"; do
        run_hook_in_dir "${cmd}" "${TEST_TMP}/repo"
        [ "${status}" -eq 2 ] || { echo "did not block: ${cmd}: ${output}" >&2; return 1; }
        [[ "${output}" == *"quoting, which cannot be checked"* ]] || { echo "wrong message for ${cmd}: ${output}" >&2; return 1; }
    done
}

@test "cd into an ordinary directory, or into .claude without writing anything, is allowed" {
    mkdir -p "${TEST_TMP}/repo/.claude"
    local cmd
    for cmd in "cd sub && cp a.txt b.txt" "cd .claude && ls" "cd sub && echo x > out.txt"; do
        run_hook_in_dir "${cmd}" "${TEST_TMP}/repo"
        [ "${status}" -eq 0 ] || { echo "did not allow: ${cmd}: ${output}" >&2; return 1; }
    done
}

@test "a protected path named through a variable's literal suffix is blocked" {
    # shellcheck disable=SC2016  # the variable is expanded by the command under test, not here
    run_hook_in_dir 'echo x >> "$HOME/.claude/settings.local.json"' "${TEST_TMP}/repo"
    assert_blocked_config_write
}

@test "a protected path spelled with quote splices or backslashes is blocked" {
    local cmd
    for cmd in \
        'echo x > .cla"ude"/settings.json' \
        "echo x > .cla'ude'/settings.json" \
        'echo x > .cl\aude/settings.json'; do
        run_hook_in_dir "${cmd}" "${TEST_TMP}/repo"
        assert_blocked_config_write || { echo "did not block: ${cmd}" >&2; return 1; }
    done
}

@test "a relative Bash path that reaches a protected file once normalised or through a symlink is blocked" {
    mkdir -p "${TEST_TMP}/repo/.claude"
    printf '{}' > "${TEST_TMP}/repo/.claude/settings.json"
    ln -s "${TEST_TMP}/repo/.claude/settings.json" "${TEST_TMP}/repo/innocent.json"
    local cmd
    for cmd in "echo x > innocent.json" "cp x.json sub/../innocent.json" "echo x > .claude/./settings.json"; do
        run_hook_in_dir "${cmd}" "${TEST_TMP}/repo"
        assert_blocked_config_write || { echo "did not block: ${cmd}" >&2; return 1; }
    done
}

@test "an unquoted glob that matches a protected file is blocked" {
    mkdir -p "${TEST_TMP}/repo/.claude"
    printf '{}' > "${TEST_TMP}/repo/.claude/settings.json"
    run_hook_in_dir "sed -i 's/a/b/' .cl*/sett*" "${TEST_TMP}/repo"
    assert_blocked_config_write
}

@test "an unquoted brace expansion in a write target is blocked" {
    run_hook_in_dir "echo x > .claude/settings.{json,x}" "${TEST_TMP}/repo"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'brace expansion'* ]]
}

@test "ordinary writes, reads of config and non-write redirections are allowed" {
    local cmd
    for cmd in \
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
EOF'; do
        run_hook_in_dir "${cmd}" "${TEST_TMP}/repo"
        [ "${status}" -eq 0 ] || { echo "did not allow: ${cmd}: ${output}" >&2; return 1; }
    done
}

@test "a write target held in a variable whose literal parts name nothing protected is allowed" {
    # shellcheck disable=SC2016  # the variable is expanded by the command under test, not here
    run_hook_in_dir 'echo x > "$TMPDIR/out.txt"' "${TEST_TMP}/repo"
    [ "${status}" -eq 0 ]
}

@test "non-ASCII bytes in a command that writes a file are blocked" {
    run_hook_in_dir "echo x > ‘out.txt’" "${TEST_TMP}/repo"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'non-ASCII'* ]]
}

# --- fail closed ------------------------------------------------------------

@test "an unrecognised tool_name is blocked (fail closed)" {
    run_payload '{"tool_name":"SomethingElse","tool_input":{"command":"ls"}}'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"unrecognised tool_name 'SomethingElse'"* ]]
}

@test "an empty command is blocked (fail closed)" {
    run_payload '{"tool_name":"Bash","tool_input":{"command":""}}'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'no command to inspect'* ]]
}

@test "a payload with no tool_name and no command is blocked (fail closed)" {
    run_payload '{}'
    [ "${status}" -eq 2 ]
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
    make_stub jq "[ \"\$1\" = '-j' ] && exit 1; exec '${real_jq}' \"\$@\""
    run_hook "echo hi > out.txt"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'command structure could not be analysed'* ]]
}

@test "a command shfmt cannot parse is blocked (fail closed)" {
    make_stub shfmt 'exit 1'
    run_hook "echo hi > out.txt"
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
    run_hook_in_dir "sed -i 's/a/b/' src/*.txt" "${TEST_TMP}/repo"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'could not be resolved - failing closed'* ]]
}

@test "an unquoted glob over many ordinary files is allowed" {
    mkdir -p "${TEST_TMP}/repo/src"
    local i
    for i in 1 2 3 4 5; do : > "${TEST_TMP}/repo/src/f${i}.txt"; done
    run_hook_in_dir "sed -i 's/a/b/' src/*.txt" "${TEST_TMP}/repo"
    [ "${status}" -eq 0 ]
}

@test "missing jq is blocked (fail closed)" {
    mkdir -p "${STUB_BIN}/nojq"
    ln -s "$(command -v cat)" "${STUB_BIN}/nojq/cat"
    run bash -c 'printf "%s" "{}" | PATH="$1" "$(command -v bash)" "$2"' _ "${STUB_BIN}/nojq" "${HOOK}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'jq is not available'* ]]
}
