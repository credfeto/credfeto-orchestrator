#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped

load test_helper

SOURCE_HOOK="${REPO_ROOT}/containers/base/development-full/claude-hooks/enforce-allowed-dirs"

# The hook reads its allowlist from `allowed-dirs` (or `allowed-dirs.local`)
# next to its own file, so each test gets a private copy of the hook in a
# directory whose allowlist it controls, plus a directory tree to point that
# allowlist at: ROOT (allowed), ROOT/sub, ROOT/escape -> OUTSIDE (a symlink
# leading out of the root), and OUTSIDE (never allowed).
setup() {
    setup_isolated_env
    HOOK_DIR="${TEST_TMP}/hooks"
    HOOK="${HOOK_DIR}/enforce-allowed-dirs"
    ROOT="${TEST_TMP}/root"
    OUTSIDE="${TEST_TMP}/outside"
    mkdir -p "${HOOK_DIR}" "${ROOT}/sub" "${OUTSIDE}"
    cp "${SOURCE_HOOK}" "${HOOK}"
    ln -s "${OUTSIDE}" "${ROOT}/escape"
    printf '%s\n' "${ROOT}" > "${HOOK_DIR}/allowed-dirs"
}

teardown() {
    cleanup_stubs
}

# Pipes a hook payload for the command into the private hook copy, run with
# cwd = dir (default ROOT). Invoked via bash rather than directly: TEST_TMP
# lives under BATS_TEST_TMPDIR, which may be a noexec mount. status 0 =
# allowed, 2 = blocked.
run_hook_in() {
    local command="$1" dir="${2:-$ROOT}"
    local payload
    payload=$(hook_payload "$command")
    run bash -c 'cd "$3" && printf "%s" "$1" | bash "$2"' _ "$payload" "$HOOK" "${dir}"
}

# --- cd / pushd / popd -------------------------------------------------------

@test "cd to an absolute directory under a root is allowed" {
    run_hook_in "cd ${ROOT}/sub"
    [ "${status}" -eq 0 ]
}

@test "cd to a relative directory under a root is allowed" {
    run_hook_in "cd sub"
    [ "${status}" -eq 0 ]
}

@test "cd outside every root is blocked" {
    run_hook_in "cd /etc"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'outside the allowed directories'* ]]
}

@test "cd .. out of the root is blocked" {
    run_hook_in "cd .."
    [ "${status}" -eq 2 ]
}

@test "cd through a symlink that leaves the root is blocked" {
    run_hook_in "cd escape"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'outside the allowed directories'* ]]
}

@test "bare cd (to \$HOME) is blocked" {
    run_hook_in "cd"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'requires a directory'* ]]
}

@test "cd - is blocked as a flag" {
    run_hook_in "cd -"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'flags'* ]]
}

@test "cd with more than one argument is blocked" {
    run_hook_in "cd -P ${ROOT}"
    [ "${status}" -eq 2 ]
}

@test "popd is blocked - its target is invisible to static parsing" {
    run_hook_in "popd"
    [ "${status}" -eq 2 ]
}

@test "pushd is checked like cd" {
    run_hook_in "pushd /etc"
    [ "${status}" -eq 2 ]
    run_hook_in "pushd sub"
    [ "${status}" -eq 0 ]
}

@test "a leading cd sets the base for later relative paths" {
    run_hook_in "cd ${ROOT}/sub && rm -rf x"
    [ "${status}" -eq 0 ]
}

@test "a leading cd followed by a relative path that escapes the root is blocked" {
    run_hook_in "cd ${ROOT}/sub && rm -rf ../../outside/x"
    [ "${status}" -eq 2 ]
}

@test "two cds make later relative paths unknowable - blocked, absolute still works" {
    run_hook_in "cd ${ROOT}; cd sub && rm -rf x"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'unknowable'* ]]
    run_hook_in "cd ${ROOT}; cd ${ROOT}/sub && rm -rf ${ROOT}/sub/x"
    [ "${status}" -eq 0 ]
}

@test "a cd that is not the first call disables relative paths after it" {
    run_hook_in "git -C ${ROOT} status && cd ${ROOT}/sub && rm -rf x"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'unknowable'* ]]
}

@test "a cd nested in a substitution does not become the base" {
    # shellcheck disable=SC2016  # literal $(...) - must reach the hook unexpanded
    run_hook_in '$(cd '"${OUTSIDE}"') ; rm -rf x'
    # Blocked either way: the cd itself is out of root. The point is the
    # outer call's cd never counts as "first" - guarded by the next test.
    [ "${status}" -eq 2 ]
}

@test "a cd nested in a substitution to an allowed dir still does not make relative paths resolve there" {
    # shellcheck disable=SC2016  # literal $(...) - must reach the hook unexpanded
    run_hook_in '$(cd '"${ROOT}/sub"') ; rm -rf x'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'unknowable'* ]]
}

# --- git -C --------------------------------------------------------------------

@test "git -C an absolute directory under a root is allowed" {
    run_hook_in "git -C ${ROOT}/sub status"
    [ "${status}" -eq 0 ]
}

@test "git -C a relative directory under a root is allowed" {
    run_hook_in "git -C sub status"
    [ "${status}" -eq 0 ]
}

@test "git -C . is allowed when cwd is under a root" {
    run_hook_in "git -C . status"
    [ "${status}" -eq 0 ]
}

@test "git -C . is blocked when cwd is outside every root" {
    run_hook_in "git -C . status" "${OUTSIDE}"
    [ "${status}" -eq 2 ]
}

@test "git -C .. out of the root is blocked" {
    run_hook_in "git -C .. status"
    [ "${status}" -eq 2 ]
}

@test "git -C a symlink leaving the root is blocked" {
    run_hook_in "git -C escape status"
    [ "${status}" -eq 2 ]
}

@test "git -C outside every root is blocked" {
    run_hook_in "git -C /etc status"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'outside the allowed directories'* ]]
}

@test "cumulative git -C is resolved relative to the previous -C, as git does" {
    run_hook_in "git -C ${ROOT} -C sub status"
    [ "${status}" -eq 0 ]
    run_hook_in "git -C ${ROOT} -C ../outside status"
    [ "${status}" -eq 2 ]
}

@test "git -C with a missing directory argument is blocked" {
    run_hook_in "git -C"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'requires a directory'* ]]
}

@test "git -c core.hooksPath injected next to -C is blocked" {
    run_hook_in "git -C ${ROOT} -c core.hooksPath=/evil status"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'makes git run an external program'* ]]
}

@test "git -c key matching is case-insensitive" {
    run_hook_in "git -C ${ROOT} -c CORE.HOOKSPATH=/evil status"
    [ "${status}" -eq 2 ]
}

@test "git -c with an inert key is allowed" {
    run_hook_in "git -C ${ROOT} -c commit.gpgsign=false status"
    [ "${status}" -eq 0 ]
}

@test "git -c alias.* is blocked (prefix match)" {
    run_hook_in "git -C ${ROOT} -c alias.st=!/evil st"
    [ "${status}" -eq 2 ]
}

@test "git --config-env with a code-exec key is blocked" {
    run_hook_in "git -C ${ROOT} --config-env core.sshCommand=EVIL status"
    [ "${status}" -eq 2 ]
    run_hook_in "git -C ${ROOT} --config-env=core.sshCommand=EVIL status"
    [ "${status}" -eq 2 ]
}

@test "git --exec-path is blocked in every form" {
    run_hook_in "git -C ${ROOT} --exec-path=/evil status"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'--exec-path'* ]]
    run_hook_in "git --exec-path /evil -C ${ROOT} status"
    [ "${status}" -eq 2 ]
}

@test "git --git-dir and --work-tree are blocked" {
    run_hook_in "git -C ${ROOT} --git-dir=/etc/x status"
    [ "${status}" -eq 2 ]
    run_hook_in "git -C ${ROOT} --work-tree=/etc status"
    [ "${status}" -eq 2 ]
}

@test "options after the git subcommand are not treated as global options" {
    # -c here is `git commit -c` (reuse message), not the global config flag.
    run_hook_in "git -C ${ROOT} commit -c HEAD"
    [ "${status}" -eq 0 ]
}

@test "a non-literal git -C argument is blocked" {
    # shellcheck disable=SC2016  # literal $DIR - must reach the hook unexpanded
    run_hook_in 'git -C "$DIR" status'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'could not be verified'* ]]
}

@test "a quoted literal git -C argument is treated as literal" {
    run_hook_in "git -C \"${ROOT}/sub\" status"
    [ "${status}" -eq 0 ]
}

# --- npm --prefix ----------------------------------------------------------------

@test "npm --prefix under a root is allowed in both forms" {
    run_hook_in "npm --prefix ${ROOT} ci"
    [ "${status}" -eq 0 ]
    run_hook_in "npm --prefix=${ROOT}/sub run build"
    [ "${status}" -eq 0 ]
}

@test "npm --prefix outside every root is blocked" {
    run_hook_in "npm --prefix /etc ci"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'outside the allowed directories'* ]]
}

@test "npm --script-shell is blocked wherever it appears" {
    run_hook_in "npm --prefix=${ROOT} --script-shell=/evil run x"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'--script-shell'* ]]
    run_hook_in "npm run x --script-shell /evil"
    [ "${status}" -eq 2 ]
}

@test "npm --userconfig and --globalconfig are blocked" {
    run_hook_in "npm ci --userconfig /evil/.npmrc"
    [ "${status}" -eq 2 ]
    run_hook_in "npm ci --globalconfig=/evil/npmrc"
    [ "${status}" -eq 2 ]
}

@test "npm without --prefix is allowed untouched" {
    run_hook_in "npm ci"
    [ "${status}" -eq 0 ]
}

# --- find ------------------------------------------------------------------------

@test "find with an explicit starting point under a root is allowed" {
    run_hook_in "find ${ROOT}/sub -type f -name '*.cs'"
    [ "${status}" -eq 0 ]
}

@test "find . resolves against cwd" {
    run_hook_in "find . -name x"
    [ "${status}" -eq 0 ]
    run_hook_in "find . -name x" "${OUTSIDE}"
    [ "${status}" -eq 2 ]
}

@test "find with no starting point is treated as find ." {
    run_hook_in "find -name x"
    [ "${status}" -eq 0 ]
    run_hook_in "find -name x" "${OUTSIDE}"
    [ "${status}" -eq 2 ]
}

@test "find with a starting point outside every root is blocked" {
    run_hook_in "find / -name x"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'outside the allowed directories'* ]]
}

@test "find with one allowed and one disallowed starting point is blocked" {
    run_hook_in "find ${ROOT} /etc -name x"
    [ "${status}" -eq 2 ]
}

@test "find -H/-L/-P before the starting point are skipped, not treated as paths" {
    run_hook_in "find -L ${ROOT}/sub -name x"
    [ "${status}" -eq 0 ]
}

@test "find -exec is blocked" {
    run_hook_in "find ${ROOT} -name x -exec rm {} \\;"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'-exec'* ]]
}

@test "find -execdir, -ok, -okdir, -delete, -fprint, -fls are blocked" {
    for action in -execdir -ok -okdir -delete -fprint -fprint0 -fprintf -fls; do
        run_hook_in "find ${ROOT} -name x ${action} /x"
        [ "${status}" -eq 2 ]
    done
}

@test "find -exec cat is blocked too - the removed allow rule is not quietly re-permitted" {
    run_hook_in "find ${ROOT} -name '*.md' -exec cat {} +"
    [ "${status}" -eq 2 ]
}

# --- rm / mv / cp ---------------------------------------------------------------

@test "rm of relative paths under the root is allowed, including globs" {
    run_hook_in "rm -rf bin/* obj/*"
    [ "${status}" -eq 0 ]
}

@test "rm -rf / is blocked" {
    run_hook_in "rm -rf /"
    [ "${status}" -eq 2 ]
}

@test "rm of an allowed root itself is blocked" {
    run_hook_in "rm -rf ${ROOT}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'may not target an allowed root'* ]]
}

@test "rm --no-preserve-root is blocked" {
    run_hook_in "rm -rf --no-preserve-root sub"
    [ "${status}" -eq 2 ]
}

@test "rm of a path that climbs out of the root is blocked" {
    run_hook_in "rm -rf ../outside/x"
    [ "${status}" -eq 2 ]
}

@test "rm ~/x is blocked - tilde could expand anywhere" {
    run_hook_in "rm -rf ~/x"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'brace, tilde or backslash'* ]]
}

@test "rm with a brace expansion is blocked - it could expand to .." {
    run_hook_in "rm -rf {..,x}"
    [ "${status}" -eq 2 ]
}

@test "rm with a backslash escape is blocked" {
    run_hook_in 'rm -rf su\b'
    [ "${status}" -eq 2 ]
}

@test "rm of a non-literal operand is blocked" {
    # shellcheck disable=SC2016  # literal $DIR - must reach the hook unexpanded
    run_hook_in 'rm -rf $DIR'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'could not be verified'* ]]
}

@test "rm -- treats everything after as operands, including dash-prefixed names" {
    run_hook_in "rm -- -weird-name"
    [ "${status}" -eq 0 ]
    run_hook_in "rm -- /etc/x"
    [ "${status}" -eq 2 ]
}

@test "a glob rooted outside the allowed roots is blocked" {
    run_hook_in "rm -rf /etc/*"
    [ "${status}" -eq 2 ]
}

@test "a glob with a leading .. component is blocked" {
    run_hook_in "rm -rf ../*"
    [ "${status}" -eq 2 ]
}

@test "mv within the root is allowed, out of it is blocked" {
    run_hook_in "mv sub/a sub/b"
    [ "${status}" -eq 0 ]
    run_hook_in "mv sub ${OUTSIDE}/sub"
    [ "${status}" -eq 2 ]
}

@test "mv of an allowed root itself is blocked" {
    run_hook_in "mv ${ROOT} ${ROOT}-old"
    [ "${status}" -eq 2 ]
}

@test "cp within the root is allowed, to outside is blocked" {
    run_hook_in "cp a.txt sub/b.txt"
    [ "${status}" -eq 0 ]
    run_hook_in "cp a.txt /tmp/b.txt"
    [ "${status}" -eq 2 ]
}

@test "cp from a root itself (copying the whole tree) is allowed" {
    run_hook_in "cp -r ${ROOT} ${ROOT}/sub/copy"
    [ "${status}" -eq 0 ]
}

@test "an operand containing a real newline is blocked" {
    run_hook_in $'rm -rf \'sub\nx\''
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'control character'* ]]
}

# --- command-name matching ------------------------------------------------------

@test "a path-qualified command is still checked" {
    run_hook_in "/usr/bin/find /etc -name x"
    [ "${status}" -eq 2 ]
    run_hook_in "/bin/rm -rf /etc/x"
    [ "${status}" -eq 2 ]
}

@test "a checked command behind a wrapper is still checked (defense in depth)" {
    run_hook_in "sudo rm -rf /etc/x"
    [ "${status}" -eq 2 ]
    run_hook_in "sudo rm -rf sub/x"
    [ "${status}" -eq 0 ]
}

@test "a checked command name appearing as an argument is not an invocation" {
    run_hook_in "grep -r 'rm -rf /' ."
    [ "${status}" -eq 0 ]
    run_hook_in "echo cd /etc"
    [ "${status}" -eq 0 ]
}

@test "a checked call later in a compound command is still checked" {
    run_hook_in "ls && rm -rf /etc/x"
    [ "${status}" -eq 2 ]
    run_hook_in "ls | xargs rm -rf /etc/x"
    [ "${status}" -eq 0 ]
}

@test "a checked call inside a substitution is still checked" {
    # shellcheck disable=SC2016  # literal $(...) - must reach the hook unexpanded
    run_hook_in 'echo $(find /etc -name x)'
    [ "${status}" -eq 2 ]
}

@test "a command with no checked call is allowed untouched" {
    run_hook_in "echo hello"
    [ "${status}" -eq 0 ]
    run_hook_in "ls -la /etc"
    [ "${status}" -eq 0 ]
}

@test "empty command is allowed" {
    run_hook_in ""
    [ "${status}" -eq 0 ]
}

# --- allowlist file handling -----------------------------------------------------

@test "a missing allowed-dirs file fails closed for checked calls only" {
    rm -f "${HOOK_DIR}/allowed-dirs"
    run_hook_in "git -C ${ROOT} status"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'no allowed directories are configured'* ]]
    run_hook_in "echo hello"
    [ "${status}" -eq 0 ]
}

@test "an allowed-dirs file with only comments and blanks fails closed" {
    printf '%s\n' '# nothing here' '' '   ' > "${HOOK_DIR}/allowed-dirs"
    run_hook_in "git -C ${ROOT} status"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'no allowed directories are configured'* ]]
}

@test "allowed-dirs.local takes precedence over allowed-dirs when present" {
    printf '%s\n' "${OUTSIDE}" > "${HOOK_DIR}/allowed-dirs.local"
    run_hook_in "git -C ${OUTSIDE} status"
    [ "${status}" -eq 0 ]
    run_hook_in "git -C ${ROOT} status"
    [ "${status}" -eq 2 ]
}

@test "a leading ~ in allowed-dirs expands to HOME" {
    mkdir -p "${HOME}/work"
    # shellcheck disable=SC2088  # literal ~ - the hook, not this shell, expands it
    printf '%s\n' '~/work' > "${HOOK_DIR}/allowed-dirs"
    run_hook_in "git -C ${HOME}/work status"
    [ "${status}" -eq 0 ]
}

@test "a leading \$NAME in allowed-dirs expands to that variable, and an unset one is skipped" {
    export MY_ROOT="${OUTSIDE}"
    # shellcheck disable=SC2016  # literal $NAME - the hook, not this shell, expands it
    printf '%s\n' '$MY_ROOT' '$UNSET_ROOT_XYZ/anything' > "${HOOK_DIR}/allowed-dirs"
    run_hook_in "git -C ${OUTSIDE} status"
    [ "${status}" -eq 0 ]
    unset MY_ROOT
    run_hook_in "git -C ${OUTSIDE} status"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'no allowed directories are configured'* ]]
}

@test "a relative line in allowed-dirs is ignored, not treated as cwd-relative" {
    printf '%s\n' 'sub' > "${HOOK_DIR}/allowed-dirs"
    run_hook_in "git -C ${ROOT}/sub status"
    [ "${status}" -eq 2 ]
}

@test "an inline comment and surrounding whitespace on an allowed-dirs line are stripped" {
    printf '%s\n' "  ${ROOT}   # the workspace" > "${HOOK_DIR}/allowed-dirs"
    run_hook_in "git -C ${ROOT} status"
    [ "${status}" -eq 0 ]
}

@test "a root given with a trailing slash or .. component is canonicalised" {
    printf '%s\n' "${ROOT}/sub/../" > "${HOOK_DIR}/allowed-dirs"
    run_hook_in "git -C ${ROOT}/sub status"
    [ "${status}" -eq 0 ]
}

# --- fail-closed infrastructure -----------------------------------------------------

@test "a failing jq fails closed" {
    make_stub jq 'exit 1'
    run bash -c 'printf "%s" "$1" | bash "$2"' _ '{"tool_input":{"command":"git -C /x status"}}' "$HOOK"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'could not be parsed by jq'* ]]
}

@test "a failing shfmt fails closed" {
    make_stub shfmt 'exit 127'
    run_hook_in "git -C ${ROOT} status"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'could not be parsed as shell'* ]]
}

@test "unparseable shell input fails closed" {
    run_hook_in "git -C ${ROOT} status ("
    [ "${status}" -eq 2 ]
}

@test "a failing realpath fails closed" {
    make_stub realpath 'exit 1'
    run_hook_in "git -C ${ROOT} status"
    [ "${status}" -eq 2 ]
}
