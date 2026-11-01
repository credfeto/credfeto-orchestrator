#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped

load test_helper

SOURCE_HOOK_DIR="${REPO_ROOT}/containers/base/development-full/claude-hooks"

# The hook reads its patterns from `secret-files` (or `secret-files.local`)
# next to its own file, so each test gets a private copy of the hook and the
# shipped pattern list, plus a working directory ROOT holding real secret
# files to resolve against: ROOT/.env, ROOT/.database, ROOT/app.env,
# ROOT/innocent -> .env (a symlinked file), ROOT/cfg/.env with
# ROOT/linked -> cfg (a symlinked directory), and ROOT/.env.d (a directory
# whose name matches a pattern).
setup() {
    setup_isolated_env
    HOOK_DIR="${TEST_TMP}/hooks"
    HOOK="${HOOK_DIR}/block-secret-file-reads"
    ROOT="${TEST_TMP}/root"
    mkdir -p "${HOOK_DIR}" "${ROOT}/cfg" "${ROOT}/.env.d" "${ROOT}/src"
    cp "${SOURCE_HOOK_DIR}/block-secret-file-reads" "${HOOK}"
    cp "${SOURCE_HOOK_DIR}/secret-files" "${HOOK_DIR}/secret-files"
    printf 'TOKEN=x\n' > "${ROOT}/.env"
    printf 'TOKEN=x\n' > "${ROOT}/app.env"
    printf 'TOKEN=x\n' > "${ROOT}/cfg/.env"
    printf '{}\n' > "${ROOT}/.database"
    printf 'hello\n' > "${ROOT}/src/readme.txt"
    ln -s .env "${ROOT}/innocent"
    ln -s cfg "${ROOT}/linked"
}

teardown() {
    cleanup_stubs
}

assert_allowed() {
    run_hook_in_dir "$1" "${2:-$ROOT}"
    [ "${status}" -eq 0 ]
}

assert_blocked() {
    run_hook_in_dir "$1" "${3:-$ROOT}"
    [ "${status}" -eq 2 ]
    [ -z "${2:-}" ] || [[ "${output}" == *"$2"* ]]
}

# run_tool <tool_name> <payload-json-tool_input> - pipes a non-Bash payload.
run_tool() {
    local payload
    payload=$(jq -n --arg tool "$1" --argjson input "$2" '{tool_name: $tool, tool_input: $input}')
    run bash -c 'cd "$3" && printf "%s" "$1" | bash "$2"' _ "$payload" "$HOOK" "${ROOT}"
}

# --- Bash: plain operands ---------------------------------------------------

@test "any program naming a secret file is blocked, known or not" {
    assert_blocked "cat .env" "'.env' names a secret-bearing file"
    assert_blocked "some-unknown-tool --input .env"
    assert_blocked "less ${ROOT}/cfg/.env"
    assert_blocked "head app.env" "matches '*.env'"
}

@test "a secret file that does not exist yet is still blocked" {
    assert_blocked "cat missing/.env.production" "matches '.env.*'"
    assert_blocked "printf x > new.env"
}

@test "an example env file is blocked, since .env.* matches it" {
    assert_blocked "cat .env.example"
}

@test "a .database file is blocked and the message points at querydb" {
    assert_blocked "cat .database" "querydb"
}

@test "a ~/ path to a secret file is blocked" {
    assert_blocked "cat ~/.config/orchestrator/.env"
}

@test "a word concatenated from quoted and unquoted parts is joined before the check" {
    assert_blocked "cat \".e\"nv"
    assert_blocked "cat '.e'\"nv\""
    assert_blocked 'cat \.env'
}

@test "a command inside a command substitution is checked too" {
    # shellcheck disable=SC2016
    assert_blocked 'echo "$(cat .env)"'
    # shellcheck disable=SC2016
    assert_blocked 'cat $(echo x) .env'
}

@test "ordinary commands on ordinary files are allowed" {
    assert_allowed "cat src/readme.txt"
    assert_allowed "ls -la"
    assert_allowed "git status"
}

# --- Bash: redirections -----------------------------------------------------

@test "every redirection to or from a secret file is blocked" {
    assert_blocked "wc -l < .env"
    assert_blocked "printf x > .env"
    assert_blocked "printf x >> .env"
    assert_blocked "printf x 2> app.env"
    assert_blocked "cat <<< .env"
}

@test "a heredoc body mentioning a secret file is allowed" {
    assert_allowed "cat <<'EOF'
remember to never read .env
EOF"
}

# --- Bash: globs and symlinks -----------------------------------------------

@test "a glob that expands to a secret file is blocked" {
    assert_blocked "cat .e*" "'.env' names"
    assert_blocked "head .en?" "'.env' names"
    assert_blocked "cat .env.[dx]*" "'.env.[dx]*' names"
    assert_blocked "cat *.env"
}

@test "a glob that matches no secret file is allowed" {
    assert_allowed "cat src/*.txt"
}

@test "a symlink that resolves to a secret file is blocked" {
    assert_blocked "cat innocent" "'innocent' names"
}

@test "a secret file reached through a symlinked directory is blocked" {
    assert_blocked "cat linked/.env"
}

# --- Bash: directories and exclusions ---------------------------------------

@test "a directory operand passes even when its name matches a pattern" {
    assert_allowed "ls .env.d"
    assert_allowed "ls .env.d/"
    assert_allowed "ls linked"
}

@test "every documented exclusion option passes as a separate word" {
    assert_allowed "grep -rn foo --exclude .env --exclude-dir .env.d --include '*.env' ."
    assert_allowed "find . -not -name '.env*' -not -name '*.env' -not -name '.database' -not -path '*/.env' -iname x -ipath y"
    assert_allowed "rg foo -g '!.env*' -g '!*.env' --glob '!.database' --ignore .env"
}

@test "every documented exclusion option passes in --option=value form" {
    assert_allowed "grep -rn foo --exclude='.env' --exclude='.env.*' --exclude='*.env' --exclude='.database' --exclude-dir='.claude' ."
    assert_allowed "grep -rn foo --include=*.env --glob=.env --ignore=.database ."
}

@test "an exclusion option only skips its own value, not the next operand" {
    assert_blocked "grep foo --exclude x .env"
}

# --- Bash: prose and non-literal words --------------------------------------

@test "a word containing whitespace that is not a file is treated as prose and allowed" {
    assert_allowed 'git commit -m "Ignore .env files"'
    assert_allowed "gh pr comment 1 --body 'never read *.env'"
}

@test "a word containing whitespace that names an existing secret file is blocked" {
    printf 'x\n' > "${ROOT}/my secrets.env"
    assert_blocked 'cat "my secrets.env"'
}

@test "a word that is not fully literal is not checked (accepted gap)" {
    # shellcheck disable=SC2016
    assert_allowed 'cat "$FILE"'
    # shellcheck disable=SC2016
    assert_allowed 'cat $(printf x)'
}

@test "an empty command is allowed" {
    assert_allowed ""
}

@test "a command that cannot be parsed fails closed" {
    assert_blocked "cat 'unterminated" "could not be parsed"
}

# --- file tools -------------------------------------------------------------

@test "Read, Edit, Write and NotebookEdit on a secret file are blocked" {
    run_tool Read '{"file_path": ".env"}'
    [ "${status}" -eq 2 ]
    run_tool Edit "{\"file_path\": \"${ROOT}/cfg/.env\"}"
    [ "${status}" -eq 2 ]
    run_tool Write '{"file_path": "new.env", "content": "x"}'
    [ "${status}" -eq 2 ]
    run_tool NotebookEdit '{"notebook_path": ".database"}'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *querydb* ]]
}

@test "a file tool reaching a secret file through a symlink is blocked" {
    run_tool Read '{"file_path": "innocent"}'
    [ "${status}" -eq 2 ]
}

@test "a file tool on a ~/ secret path is blocked" {
    run_tool Read '{"file_path": "~/.config/orchestrator/.env"}'
    [ "${status}" -eq 2 ]
}

@test "file tools on ordinary files are allowed" {
    run_tool Read '{"file_path": "src/readme.txt"}'
    [ "${status}" -eq 0 ]
    run_tool Write "{\"file_path\": \"${ROOT}/src/new.txt\", \"content\": \"x\"}"
    [ "${status}" -eq 0 ]
}

@test "a file tool payload with no path fails closed" {
    run_tool Read '{}'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"no file path"* ]]
}

@test "an unrecognised tool name fails closed" {
    run_tool Glob '{"pattern": "*"}'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"unrecognised tool_name"* ]]
}

# --- pattern list -----------------------------------------------------------

@test "secret-files.local takes precedence over secret-files" {
    printf '%s\n' '# local only' '' '  *.secret  ' > "${HOOK_DIR}/secret-files.local"
    assert_allowed "cat .env"
    assert_blocked "cat x.secret" "matches '*.secret'"
}

@test "a missing pattern list fails closed" {
    rm "${HOOK_DIR}/secret-files"
    assert_blocked "cat src/readme.txt" "failing closed"
}

@test "a pattern list with no pattern fails closed" {
    printf '# nothing\n\n' > "${HOOK_DIR}/secret-files"
    assert_blocked "cat src/readme.txt" "lists no pattern"
}
