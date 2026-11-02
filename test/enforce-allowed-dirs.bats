#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped

load test_helper

SOURCE_HOOK="${REPO_ROOT}/containers/base/development-full/claude-hooks/enforce-allowed-dirs"
SOURCE_HOOK_DIR="${REPO_ROOT}/containers/base/development-full/claude-hooks"

# The hook reads its allowlist from `allowed-dirs` (or `allowed-dirs.local`)
# and the command classifications from `command-allowlist`, both next to its
# own file, so each test gets a private copy of the hook in a directory whose
# data files it controls, plus a directory tree to point that allowlist at:
# ROOT (allowed), ROOT/sub, ROOT/escape -> OUTSIDE (a symlink leading out of
# the root), and OUTSIDE (never allowed). pushd is not on the shipped
# command-allowlist (reject-obfuscated-commands rejects it), so the private
# copy classifies it to keep the hook's own cd-family handling under test.
setup() {
    setup_isolated_env
    HOOK_DIR="${TEST_TMP}/hooks"
    HOOK="${HOOK_DIR}/enforce-allowed-dirs"
    ROOT="${TEST_TMP}/root"
    OUTSIDE="${TEST_TMP}/outside"
    mkdir -p "${HOOK_DIR}" "${ROOT}/sub" "${OUTSIDE}"
    cp "${SOURCE_HOOK}" "${HOOK}"
    cp "${SOURCE_HOOK_DIR}/command-allowlist" "${HOOK_DIR}/command-allowlist"
    printf '%s\n' 'pushd read-only' >> "${HOOK_DIR}/command-allowlist"
    ln -s "${OUTSIDE}" "${ROOT}/escape"
    printf '%s\n' "${ROOT}" > "${HOOK_DIR}/allowed-dirs"
}

teardown() {
    cleanup_stubs
}

# assert_allowed <command> [dir]      - hook exits 0 from dir (default ROOT)
# assert_blocked <command> [substring] [dir] - hook exits 2 from dir (default
# ROOT) and, when given, its message contains substring.
assert_allowed() {
    run_hook_in_dir "$1" "${2:-$ROOT}"
    [ "${status}" -eq 0 ]
}

assert_blocked() {
    run_hook_in_dir "$1" "${3:-$ROOT}"
    [ "${status}" -eq 2 ]
    [ -z "${2:-}" ] || [[ "${output}" == *"$2"* ]]
}

# --- cd / pushd / popd -------------------------------------------------------

@test "cd to an absolute or relative directory under a root is allowed" {
    assert_allowed "cd ${ROOT}/sub"
    assert_allowed "cd sub"
}

@test "cd outside every root, through .., or through a symlink leaving the root is blocked" {
    assert_blocked "cd /etc" 'outside the allowed directories'
    assert_blocked "cd .."
    assert_blocked "cd escape" 'outside the allowed directories'
}

@test "cd through a symlink leaving the root and back with .. is allowed, since bash's logical cd lands in the root" {
    assert_allowed "cd escape/.. && rm -rf x"
    assert_blocked "cd escape/.. && rm -rf ../x" 'outside the allowed directories'
}

@test "bare cd, cd -, and cd with more than one argument are blocked" {
    assert_blocked "cd" 'requires a directory'
    assert_blocked "cd -" 'flags'
    assert_blocked "cd -P ${ROOT}" 'exactly one argument'
}

@test "cd or pushd with an extra empty argument is blocked, since bash rejects it as too many arguments and stays put" {
    mkdir -p "${ROOT}/sub/deep"
    assert_blocked 'cd sub/deep ""; tee ../../x' 'exactly one argument'
    assert_blocked 'pushd sub/deep ""; tee ../../x' 'exactly one argument'
}

@test "cd or pushd to an empty directory name is blocked, since bash rejects a null directory" {
    assert_blocked 'cd ""' 'target is empty'
    assert_blocked 'pushd ""' 'target is empty'
}

@test "popd is blocked - its target is invisible to static parsing" {
    assert_blocked "popd"
}

@test "pushd is checked like cd" {
    assert_blocked "pushd /etc"
    assert_allowed "pushd sub"
}

@test "a leading cd sets the base for later relative paths" {
    assert_allowed "cd ${ROOT}/sub && rm -rf x"
    assert_blocked "cd ${ROOT}/sub && rm -rf ../../outside/x"
}

@test "a leading cd to an allowed dir makes a later relative path under it pass even when the hook's own cwd is outside every root" {
    assert_allowed "cd ${ROOT}/sub && rm -rf x" "${OUTSIDE}"
}

@test "two cds make later relative paths unknowable - blocked, absolute still works" {
    assert_blocked "cd ${ROOT}; cd sub && rm -rf x" 'unknowable'
    assert_allowed "cd ${ROOT}; cd ${ROOT}/sub && rm -rf ${ROOT}/sub/x"
}

@test "a cd that is not the first call disables relative paths after it, but not for the first call itself" {
    assert_blocked "git -C ${ROOT} status && cd ${ROOT}/sub && rm -rf x" 'unknowable'
    assert_allowed "git -C sub status && cd ${ROOT}/sub"
}

@test "a cd nested in a substitution never becomes the base" {
    # shellcheck disable=SC2016  # literal $(...) - must reach the hook unexpanded
    assert_blocked 'echo $(cd '"${ROOT}/sub"') ; rm -rf x' 'unknowable'
}

@test "a command name that is not a plain literal fails closed" {
    assert_blocked "\$(cd ${ROOT}/sub) ; rm -rf x" 'command name could not be verified'
}

@test "git -C does not leak its directory into a later call's relative paths (regression)" {
    # A later rm resolves against the hook's cwd (ROOT), not against sub -
    # so ../outside/x climbs out of ROOT and is blocked, where a leaked base
    # of sub would have resolved it to ROOT/outside/x and allowed it.
    assert_blocked "git -C sub status && rm -rf ../outside/x"
    assert_allowed "git -C sub status && rm -rf sub/x"
}

# --- git -C --------------------------------------------------------------------

@test "git -C absolute, relative, or . under a root is allowed" {
    assert_allowed "git -C ${ROOT}/sub status"
    assert_allowed "git -C sub status"
    assert_allowed "git -C . status"
    assert_allowed "git -C \"${ROOT}/sub\" status"
}

@test "git -C . is blocked when cwd is outside every root" {
    assert_blocked "git -C . status" '' "${OUTSIDE}"
}

@test "git -- ends the global options: the cwd is still checked when no -C was given" {
    assert_allowed "git -- status"
    assert_blocked "git -- status" 'implicit -C .' "${OUTSIDE}"
    assert_allowed "git -C ${ROOT} -- status" "${OUTSIDE}"
    assert_blocked "git -C /etc -- status" 'outside the allowed directories'
}

@test "git -C .., a symlink leaving the root, or a directory outside every root is blocked" {
    assert_blocked "git -C .. status"
    assert_blocked "git -C escape status"
    assert_blocked "git -C /etc status" 'outside the allowed directories'
}

@test "git -C written with a backslash bash removes is still checked as -C" {
    assert_blocked "git -\\C /etc status" 'outside the allowed directories'
}

@test "cumulative git -C is resolved relative to the previous -C, as git does" {
    assert_allowed "git -C ${ROOT} -C sub status"
    assert_blocked "git -C ${ROOT} -C ../outside status"
}

@test "git -C with a missing directory argument is blocked" {
    assert_blocked "git -C" 'requires a directory'
}

@test "git -c with a code-execution key is blocked, case-insensitively" {
    assert_blocked "git -C ${ROOT} -c core.hooksPath=/evil status" 'not permitted'
    assert_blocked "git -C ${ROOT} -c CORE.HOOKSPATH=/evil status"
    assert_blocked "git -C ${ROOT} -c alias.st=!/evil st"
}

@test "git -c with a quoted or split-quoted code-execution key is still blocked" {
    assert_blocked "git -C ${ROOT} -c \"core.sshCommand=x\" status"
    assert_blocked "git -C ${ROOT} -c core.\"sshCommand\"=x status"
}

@test "git --config-env is blocked in both spellings, before and after -C, even for an inert key" {
    assert_blocked "git -C ${ROOT} --config-env core.sshCommand=EVIL status" 'git --config-env is not permitted'
    assert_blocked "git -C ${ROOT} --config-env=core.sshCommand=EVIL status" 'git --config-env is not permitted'
    assert_blocked "git --config-env color.ui=ALWAYS -C ${ROOT} status" 'git --config-env is not permitted'
    assert_blocked "git --config-env=color.ui=ALWAYS -C ${ROOT} status" 'git --config-env is not permitted'
    assert_blocked "git -C ${ROOT} --config-env color.ui=ALWAYS status" 'git --config-env is not permitted'
}

@test "git -c core.pager with no = in its argument is blocked" {
    assert_blocked "git -C ${ROOT} -c core.pager log" 'git -c core.pager is not permitted'
}

@test "git -c with no argument at all is blocked" {
    assert_blocked "git -C ${ROOT} -c" 'requires a key=value argument'
}

@test "git -c matches the key case-insensitively but the value exactly" {
    assert_allowed "git -C ${ROOT} -c color.ui=Always status"
    assert_allowed "git -C ${ROOT} -c CORE.PAGER=cat log"
    assert_blocked "git -C ${ROOT} -c core.pager=CAT log"
}

@test "git -c is an allowlist: a key that would defeat another hook is blocked even though it runs nothing" {
    assert_blocked "git -C ${ROOT} -c commit.gpgsign=false commit -m x" 'read-only'
    assert_blocked "git -C ${ROOT} -c user.email=x@y commit -m x"
}

@test "git -c with an inert display/behaviour key is allowed" {
    assert_allowed "git -C ${ROOT} -c color.ui=false status"
    assert_allowed "git -C ${ROOT} -c core.pager=cat log"
    assert_allowed "git -C ${ROOT} -c pull.rebase=true pull"
    assert_allowed "git -C ${ROOT} -c advice.detachedHead=false checkout x"
}

@test "git -c core.pager with any value other than cat is blocked" {
    assert_blocked "git -C ${ROOT} -c core.pager=/evil log"
}

@test "git --exec-path, --git-dir, --work-tree, --namespace and --super-prefix are blocked in every form" {
    assert_blocked "git -C ${ROOT} --exec-path=/evil status" '--exec-path'
    assert_blocked "git --exec-path /evil -C ${ROOT} status"
    assert_blocked "git -C ${ROOT} --git-dir=/etc/x status"
    assert_blocked "git -C ${ROOT} --work-tree=/etc status"
    assert_blocked "git -C ${ROOT} --namespace=x status"
    assert_blocked "git -C ${ROOT} --super-prefix=x status"
}

@test "options after the git subcommand are not treated as global options" {
    # -c here is `git commit -c` (reuse message), not the global config flag.
    assert_allowed "git -C ${ROOT} commit -c HEAD"
}

@test "a non-literal git -C argument is blocked" {
    # shellcheck disable=SC2016  # literal $DIR - must reach the hook unexpanded
    assert_blocked 'git -C "$DIR" status' 'could not be verified'
}

# --- npm --prefix ----------------------------------------------------------------

@test "npm --prefix under a root is allowed in both forms" {
    assert_allowed "npm --prefix ${ROOT} ci"
    assert_allowed "npm --prefix=${ROOT}/sub run build"
}

@test "npm --prefix outside every root is blocked" {
    assert_blocked "npm --prefix /etc ci" 'outside the allowed directories'
}

@test "npm --script-shell, --userconfig and --globalconfig are blocked wherever they appear" {
    assert_blocked "npm --prefix=${ROOT} --script-shell=/evil run x" '--script-shell'
    assert_blocked "npm run x --script-shell /evil"
    assert_blocked "npm ci --userconfig /evil/.npmrc"
    assert_blocked "npm ci --globalconfig=/evil/npmrc"
}

@test "npm without --prefix is allowed untouched" {
    assert_allowed "npm ci"
}

# --- node ------------------------------------------------------------------------

@test "node running a script under .github/actions is allowed, with an optional leading --check and script arguments" {
    mkdir -p "${ROOT}/.github/actions/x"
    assert_allowed "node .github/actions/x/a.js"
    assert_allowed "node ./.github/actions/x/a.js"
    assert_allowed "node --check .github/actions/x/a.js"
    assert_allowed "node .github/actions/x/a.js --flag y -r z"
    assert_allowed "node ${ROOT}/.github/actions/x/a.js"
}

@test "node allows a script name containing .. that is not a path component" {
    mkdir -p "${ROOT}/.github/actions/x"
    assert_allowed "node .github/actions/x/build..min.js"
}

@test "node resolves .github/actions against the directory a leading cd moves to" {
    mkdir -p "${ROOT}/sub/.github/actions/x" "${ROOT}/.github/actions/x"
    assert_allowed "cd sub && node .github/actions/x/a.js"
    assert_blocked "cd sub && node ../.github/actions/x/a.js" 'not under .github/actions'
}

@test "node with a script outside .github/actions or outside every root is blocked" {
    mkdir -p "${ROOT}/.github/actions/x"
    assert_blocked "node sub/a.js" 'not under .github/actions'
    assert_blocked "node .github/actions.js" 'not under .github/actions'
    assert_blocked "node ../x.js" 'outside the allowed directories'
    assert_blocked "node .github/actions/../../x.js" 'not under .github/actions'
    assert_blocked "node .github/actions/../../../x.js" 'outside the allowed directories'
    assert_blocked "node .github/actions/../a.js" 'not under .github/actions'
    assert_blocked "node /etc/x.js" 'outside the allowed directories'
}

@test "node with a script that is a symlink leading out of the root is blocked" {
    mkdir -p "${ROOT}/.github/actions/x"
    : > "${OUTSIDE}/x.js"
    ln -s "${OUTSIDE}/x.js" "${ROOT}/.github/actions/x/evil.js"
    assert_blocked "node .github/actions/x/evil.js" 'outside the allowed directories'
}

@test "node options that load code from outside the script are blocked in every spelling" {
    mkdir -p "${ROOT}/.github/actions/x"
    local opt
    for opt in "-r x" "--require x" "--require=x" "--req x" "--import x" "--import=x" "--loader x" \
        "--experimental-loader x" "--experimental_loader x" "--inspect" "--inspect-brk" "--env-file=.env"; do
        assert_blocked "node ${opt} .github/actions/x/a.js" 'not permitted'
        assert_blocked "node --check ${opt} .github/actions/x/a.js" 'not permitted'
    done
}

@test "node --check is permitted only as the first argument" {
    mkdir -p "${ROOT}/.github/actions/x"
    assert_blocked "node --check --check .github/actions/x/a.js" 'only as the first argument'
}

@test "node without a script, or reading its program from stdin, is blocked" {
    assert_blocked "node" 'requires a script path'
    assert_blocked "node --check" 'requires a script path'
    assert_blocked "node -" 'stdin'
    assert_blocked "node --check -" 'stdin'
}

@test "node with a non-literal or globbed script, or a relative script after an unknowable cd, is blocked" {
    mkdir -p "${ROOT}/.github/actions/x"
    # shellcheck disable=SC2016  # literal $X must reach the hook unexpanded
    assert_blocked 'node "$X"' 'non-literal'
    # shellcheck disable=SC2016  # literal $X must reach the hook unexpanded
    assert_blocked 'node "$X" .github/actions/x/a.js' 'non-literal'
    assert_blocked "node .github/actions/x/*.js" 'glob'
    assert_blocked "cd sub && cd .. && node .github/actions/x/a.js" 'relative'
}

# --- find ------------------------------------------------------------------------

@test "find with an explicit starting point under a root is allowed" {
    assert_allowed "find ${ROOT}/sub -type f -name '*.cs'"
}

@test "find . and find with no starting point both resolve against cwd" {
    assert_allowed "find . -name x"
    assert_blocked "find . -name x" '' "${OUTSIDE}"
    assert_allowed "find -name x"
    assert_blocked "find -name x" '' "${OUTSIDE}"
}

@test "find with any starting point outside every root is blocked" {
    assert_blocked "find / -name x" 'outside the allowed directories'
    assert_blocked "find ${ROOT} /etc -name x"
}

@test "find -H/-L/-P before the starting point are skipped, not treated as paths" {
    for opt in -H -L -P; do
        assert_allowed "find ${opt} ${ROOT}/sub -name x"
    done
}

@test "find -D and -O are blocked - they take arguments that would hide where the starting points begin" {
    assert_blocked "find -D search /etc -name x" '-D'
    assert_blocked "find -O2 /etc -name x"
}

@test "find -exec and every other program-running or writing action is blocked" {
    assert_blocked "find ${ROOT} -name x -exec rm {} \\;" '-exec'
    assert_blocked "find ${ROOT} -name '*.md' -exec cat {} +"
    for action in -execdir -ok -okdir -delete -fprint -fprint0 -fprintf -fls; do
        assert_blocked "find ${ROOT} -name x ${action} /x"
    done
}

@test "a find action written with a backslash bash removes is still blocked" {
    assert_blocked "find ${ROOT} -name x -\\exec rm {} \\;" '-exec'
    assert_blocked "find ${ROOT} -name x -\\delete" '-delete'
}

# --- rm / mv / cp ---------------------------------------------------------------

@test "rm of relative paths under the root is allowed, including globs" {
    assert_allowed "rm -rf bin/* obj/*"
}

@test "rm -rf /, rm of an allowed root itself, and rm --no-preserve-root are blocked" {
    assert_blocked "rm -rf /"
    assert_blocked "rm -rf ${ROOT}" 'may not target an allowed root'
    assert_blocked "rm -rf --no-preserve-root sub"
}

@test "rm of a path that climbs out of the root is blocked, plain or as a glob" {
    assert_blocked "rm -rf ../outside/x"
    assert_blocked "rm -rf ../*"
    assert_blocked "rm -rf /etc/*"
}

@test "rm with tilde, brace or backslash in an operand is blocked" {
    assert_blocked "rm -rf ~/x" 'brace, tilde or backslash'
    assert_blocked "rm -rf {..,x}"
    assert_blocked 'rm -rf su\b'
}

@test "rm of a non-literal operand is blocked" {
    # shellcheck disable=SC2016  # literal $DIR - must reach the hook unexpanded
    assert_blocked 'rm -rf $DIR' 'could not be verified'
}

@test "rm -- treats everything after as operands, including dash-prefixed names" {
    assert_allowed "rm -- -weird-name"
    assert_blocked "rm -- /etc/x"
}

@test "a bare - is an rm/mv/cp operand (a file name in the working directory), not an option" {
    assert_blocked "rm -" 'outside the allowed directories' "${OUTSIDE}"
    assert_blocked "mv ${ROOT}/a -" 'outside the allowed directories' "${OUTSIDE}"
    assert_blocked "cp ${ROOT}/a -" 'outside the allowed directories' "${OUTSIDE}"
    assert_allowed "rm -"
    assert_allowed "mv ${ROOT}/a -"
    assert_allowed "cp ${ROOT}/a -"
}

@test "mv within the root is allowed, out of it or of a root itself is blocked" {
    assert_allowed "mv sub/a sub/b"
    assert_blocked "mv sub ${OUTSIDE}/sub"
    assert_blocked "mv ${ROOT} ${ROOT}-old"
}

@test "cp within the root is allowed, to outside is blocked, and copying a root itself is allowed" {
    assert_allowed "cp a.txt sub/b.txt"
    assert_blocked "cp a.txt /tmp/b.txt"
    assert_allowed "cp -r ${ROOT} ${ROOT}/sub/copy"
}

@test "an operand containing a real newline is blocked" {
    assert_blocked $'rm -rf \'sub\nx\'' 'control character'
}

# --- command-name matching ------------------------------------------------------

@test "a path-qualified command is still checked" {
    assert_blocked "/usr/bin/find /etc -name x"
    assert_blocked "/bin/rm -rf /etc/x"
}

@test "a checked command behind a wrapper is still checked (defense in depth)" {
    assert_blocked "sudo rm -rf /etc/x"
    assert_allowed "sudo rm -rf sub/x"
}

@test "a checked command name appearing as an argument is not an invocation" {
    assert_allowed "grep -r 'rm -rf /' ."
    assert_allowed "echo cd /etc"
}

@test "a checked call later in a compound command, or inside a substitution, is still checked" {
    assert_blocked "ls && rm -rf /etc/x"
    # shellcheck disable=SC2016  # literal $(...) - must reach the hook unexpanded
    assert_blocked 'echo $(find /etc -name x)'
}

@test "a checked name as a read-only command's argument is not checked" {
    assert_allowed "ls | grep rm -rf /etc/x"
}

@test "a read-only command with no checked call is allowed untouched, without reading allowed-dirs at all" {
    rm -f "${HOOK_DIR}/allowed-dirs"
    assert_allowed "echo hello"
    assert_allowed "ls -la /etc"
    assert_allowed ""
}

# --- allowlist file handling -----------------------------------------------------

@test "a missing or comment-only allowed-dirs file fails closed for checked calls" {
    rm -f "${HOOK_DIR}/allowed-dirs"
    assert_blocked "git -C ${ROOT} status" 'no allowed directories are configured'
    printf '%s\n' '# nothing here' '' '   ' > "${HOOK_DIR}/allowed-dirs"
    assert_blocked "git -C ${ROOT} status" 'no allowed directories are configured'
}

@test "allowed-dirs.local takes precedence over allowed-dirs when present" {
    printf '%s\n' "${OUTSIDE}" > "${HOOK_DIR}/allowed-dirs.local"
    assert_allowed "git -C ${OUTSIDE} status"
    assert_blocked "git -C ${ROOT} status"
}

@test "a leading ~ in allowed-dirs expands to HOME" {
    mkdir -p "${HOME}/work"
    # shellcheck disable=SC2088  # literal ~ - the hook, not this shell, expands it
    printf '%s\n' '~/work' > "${HOOK_DIR}/allowed-dirs"
    assert_allowed "git -C ${HOME}/work status"
}

@test "a leading \$NAME in allowed-dirs expands to that variable, and an unset one is skipped" {
    export MY_ROOT="${OUTSIDE}"
    # shellcheck disable=SC2016  # literal $NAME - the hook, not this shell, expands it
    printf '%s\n' '$MY_ROOT' '$UNSET_ROOT_XYZ/anything' > "${HOOK_DIR}/allowed-dirs"
    assert_allowed "git -C ${OUTSIDE} status"
    unset MY_ROOT
    assert_blocked "git -C ${OUTSIDE} status" 'no allowed directories are configured'
}

@test "a relative allowed-dirs line is ignored; comments, whitespace, trailing slashes and .. are normalised" {
    printf '%s\n' 'sub' > "${HOOK_DIR}/allowed-dirs"
    assert_blocked "git -C ${ROOT}/sub status"
    printf '%s\n' "  ${ROOT}/sub/../   # the workspace" > "${HOOK_DIR}/allowed-dirs"
    assert_allowed "git -C ${ROOT}/sub status"
}

@test "the shipped allowed-dirs permits the agent container's three mounts through the real hook" {
    # The hook resolves its data file relative to its own location, so
    # running the checked-in script directly reads the checked-in list.
    # realpath -m does not need the /workspace paths to exist on this host.
    HOOK="${SOURCE_HOOK}"
    [ ! -e "${SOURCE_HOOK_DIR}/allowed-dirs.local" ]
    for d in /workspace/repo /workspace/rules /workspace/tmp; do
        assert_allowed "git -C ${d} status"
    done
    assert_blocked "git -C /workspace status"
    assert_blocked "git -C ${ROOT} status"
}

# --- code-review round 1 (#1386) ------------------------------------------------------

@test "a curly-quoted path word fails closed here even though reject-obfuscated-commands would normalise it (parallel hooks see the original)" {
    assert_blocked $'rm -rf \xe2\x80\x98/etc/x\xe2\x80\x99' 'plain ASCII'
}

@test "non-ASCII in a command with no checked call is left to reject-obfuscated-commands" {
    assert_allowed $'echo \xe2\x80\x94'
}

# --- non-ASCII in quoted heredoc bodies (#1658) -------------------------------------

@test "non-ASCII in the body of a quoted-delimiter heredoc is allowed with a writer command" {
    assert_allowed $'cfwf comment add --repo o/r --issue 5 --body-file - <<\'PLAN\'\n## Plan \xe2\x80\x94 with an em dash\nPLAN'
    assert_allowed $'tee sub/out <<"EOF"\ncaf\xc3\xa9 \xe2\x80\x98quoted\xe2\x80\x99\nEOF'
    assert_allowed $'tee sub/out <<\\EOF\n\xe2\x86\x92 arrow\nEOF'
    assert_allowed $'cat > sub/out <<\'EOF\'\n\xe2\x80\x9cx\xe2\x80\x9d\nEOF\ntee sub/two <<\'B2\'\n\xe2\x80\xa6\nB2'
}

@test "non-ASCII in the body of a <<- quoted-delimiter heredoc is allowed" {
    assert_allowed $'tee sub/out <<-\'EOF\'\n\t\xe2\x80\x94 indented\n\tEOF'
    assert_allowed $'tee sub/out <<-"EOF"\n\t\xc3\xa9\n\tEOF'
}

@test "non-ASCII in the body of an unquoted-delimiter heredoc still blocks" {
    assert_blocked $'tee sub/out <<EOF\n\xe2\x80\x94\nEOF' 'plain ASCII'
    assert_blocked $'tee sub/out <<-EOF\n\t\xe2\x80\x98$(id)\xe2\x80\x99\n\tEOF' 'plain ASCII'
}

@test "non-ASCII outside a quoted heredoc body still blocks alongside one" {
    assert_blocked $'tee sub/caf\xc3\xa9 <<\'EOF\'\nx\nEOF' 'plain ASCII'
    assert_blocked $'tee sub/out <<\'EOF\' > \xe2\x80\x98/etc/x\xe2\x80\x99\n\xe2\x80\x94\nEOF' 'plain ASCII'
    assert_blocked $'cfwf comment add --body \xe2\x80\x94 --body-file - <<\'EOF\'\n\xe2\x80\x94\nEOF' 'plain ASCII'
    assert_blocked $'tee sub/out <<\'EOF\'\n\xe2\x80\x94\nEOF\nrm -rf \xe2\x80\x98/etc/x\xe2\x80\x99' 'plain ASCII'
    assert_blocked $'tee\xc2\xa0sub/out <<\'EOF\'\nx\nEOF'
}

@test "a non-ASCII heredoc delimiter still blocks" {
    assert_blocked $'tee sub/out <<\'E\xc3\x89F\'\nx\nE\xc3\x89F' 'plain ASCII'
    assert_blocked $'tee sub/out <<\'E\xe2\x80\x94F\'\n\xe2\x80\x94\nE\xe2\x80\x94F' 'plain ASCII'
}

@test "two heredocs where the unquoted one holds non-ASCII still block" {
    assert_blocked $'tee sub/a <<\'A\' && tee sub/b <<B\n\xe2\x80\x94\nA\n\xe2\x80\x94\nB' 'plain ASCII'
    assert_blocked $'tee sub/a <<\'A\' && tee sub/b <<B\nfine\nA\n\xe2\x80\x94\nB' 'plain ASCII'
    assert_allowed $'tee sub/a <<\'A\' && tee sub/b <<B\n\xe2\x80\x94\nA\nascii\nB'
}

@test "a quoted delimiter that Layer 0 rewriting could forge keeps the full non-ASCII rule" {
    # reject-obfuscated-commands would rewrite the em dash line to END-X,
    # ending the heredoc early and running the rm this hook saw as data.
    assert_blocked $'tee sub/out <<\'END-X\'\nEND\xe2\x80\x94X\nrm -rf /etc/x\nEND-X' 'plain ASCII'
    assert_blocked $'tee sub/out <<\'A B\'\nA\xc2\xa0B\nA B' 'plain ASCII'
    assert_blocked $'tee sub/out <<E\'O\'F\n\xe2\x80\x94\nEOF' 'plain ASCII'
    assert_blocked $'tee sub/out <<$\'EOF\'\n\xe2\x80\x94\nEOF' 'plain ASCII'
}

@test "a quoted heredoc inside a command substitution keeps the full non-ASCII rule" {
    assert_blocked $'tee sub/out <<\'A\'\nx\nA\necho "$(cat <<\'B\'\n\xe2\x80\x94\nB\n)"' 'plain ASCII'
    assert_blocked $'tee sub/out <<A\n$(cat <<\'B\'\n\xe2\x80\x94\nB\n)\nA' 'plain ASCII'
}

# --- plain-ASCII heredocs and the offending-byte report (#1677) ---------------------

@test "a plain-ASCII python3 heredoc after cd is allowed with quoted and unquoted delimiters" {
    assert_allowed "cd ${ROOT} && python3 - <<'PLAN'"$'\nimport sys\n\nfor arg in sys.argv:\n\tprint(arg)  # ~!@#$%^&*()[]{}|;:,.<>?/\\\n'"PLAN"
    assert_allowed "cd ${ROOT} && python3 - <<EOF"$'\nprint("a" * 3)\n\tprint(1)\nEOF'
    assert_allowed "cd ${ROOT} && python3 - <<-'EOF'"$'\n\tprint(1)\n\tEOF'
}

@test "a plain-ASCII heredoc body with CRLF line endings is allowed" {
    assert_allowed "cd ${ROOT} && python3 - <<EOF"$'\nprint(1)\r\nprint(2)\r\nEOF'
    assert_allowed "cd ${ROOT} && python3 - <<'EOF'"$'\nprint(1)\r\nEOF'
}

@test "a long plain-ASCII heredoc body is allowed" {
    local body="" n
    for n in $(seq 1 500); do
        body+=$'\tprint("line '"${n}"$' of a long body")\n'
    done
    assert_allowed "cd ${ROOT} && python3 - <<'EOF'"$'\n'"${body}EOF"
    assert_allowed "cd ${ROOT} && python3 - <<EOF"$'\n'"${body}EOF"
}

@test "a control byte reports its hex value and byte offset" {
    local prefix="cd ${ROOT}"
    assert_blocked "${prefix}"$'\f && python3 -' "first offending byte 0x0c at offset ${#prefix}"
    local before_body="${prefix} && python3 - <<EOF"$'\nprint(1)'
    assert_blocked "${before_body}"$'\x01\nEOF' "first offending byte 0x01 at offset ${#before_body}"
    assert_blocked $'tee sub/out\x7f' 'first offending byte 0x7f at offset 11'
}

@test "a non-ASCII byte reports the offset of its first byte in the original command" {
    assert_blocked $'tee sub/out <<EOF\n\xe2\x80\x94\nEOF' 'first offending byte 0xe2 at offset 18'
    assert_blocked $'tee sub/caf\xc3\xa9 <<\'EOF\'\nx\nEOF' 'first offending byte 0xc3 at offset 11'
    # The exempt body before the offending byte is skipped when checking but
    # still counted in the reported offset.
    assert_blocked $'tee sub/out <<\'EOF\'\n\xe2\x80\x94\nEOF\nrm -rf \xe2\x80\x98/etc/x' 'first offending byte 0xe2 at offset 35'
    assert_blocked $'tee sub/a <<\'A\' && tee sub/b <<B\n\xe2\x80\x94\nA\n\xc2\xa0\nB' 'first offending byte 0xc2 at offset 39'
}

@test "cp/mv --target-directory and -t are validated in every spelling" {
    assert_blocked "cp x --target-directory=${OUTSIDE}" '--target-directory'
    assert_blocked "cp x --target-directory ${OUTSIDE}"
    assert_blocked "cp x -t ${OUTSIDE}"
    assert_blocked "cp x -t${OUTSIDE}"
    assert_blocked "mv --target-directory=${OUTSIDE} x"
    assert_allowed "cp x -t sub"
}

@test "git -c init.templateDir is blocked - init.* is not inert" {
    assert_blocked "git -C ${ROOT} -c init.templateDir=${OUTSIDE}/tpl init"
    assert_allowed "git -C ${ROOT} -c init.defaultBranch=main init"
}

@test "npm -C and nopt abbreviations of --prefix/--script-shell are handled like the full option" {
    assert_blocked "npm -C ${OUTSIDE} ci"
    assert_allowed "npm -C sub ci"
    assert_blocked "npm --prefi=${OUTSIDE} ci"
    assert_blocked "npm --script-shel=/evil run x" '--script-shell'
    assert_blocked "npm run x --userconf /evil"
}

@test "a leading cd to a directory that does not exist is blocked - a failed cd leaves the cwd unknown" {
    assert_blocked "cd ${ROOT}/nope; rm -rf ../../outside/y" 'does not exist'
}

@test "rm of a glob under a root, and mv into a root, are allowed; mv of a root away is blocked" {
    assert_allowed "rm -rf ${ROOT}/*"
    assert_allowed "rm -rf ./*"
    assert_allowed "mv sub/x ${ROOT}"
    assert_blocked "mv ${ROOT} ${ROOT}/sub/moved" 'may not target an allowed root'
}

@test "an mv source repeating the destination operand is still checked as a source" {
    assert_blocked "mv ${ROOT} sub/x ${ROOT}" 'may not target an allowed root'
    assert_allowed "mv sub/a sub/b sub/a"
}

@test "find -files0-from is blocked - it supplies starting points this hook cannot see" {
    assert_blocked "find -files0-from ${OUTSIDE}/list -name x" '-files0-from'
    assert_blocked "find ${ROOT} -files0-from ${OUTSIDE}/list"
}

@test "a git call with no -C is checked against the hook's cwd, since enforce-git-policy auto-corrects it to -C \$PWD" {
    assert_allowed "git status"
    assert_blocked "git status" 'implicit -C' "${OUTSIDE}"
    assert_blocked "git -c color.ui=false log" '' "${OUTSIDE}"
}

# --- security-review round 1 (#1386) ---------------------------------------------------

@test "a glob word with a .. component after the glob is blocked - bash expands the .. literally" {
    assert_blocked "rm -rf su*/../../outside/x" 'glob with a .. component'
    assert_blocked "cp x su*/../../outside/"
    assert_blocked "rm -rf ${ROOT}/*/../../outside/x"
    assert_blocked "git -C 'su*/../../outside' status"
    assert_blocked "find su*/../.. -name x"
    assert_allowed "rm -rf sub/*/bin"
}

@test "a path that does not exist yet is blocked when an earlier call in the same command can create a symlink" {
    assert_blocked "ln -s ${OUTSIDE} ${ROOT}/l && rm -rf ${ROOT}/l/*" 'can create symlinks'
    assert_blocked "ln -s ${OUTSIDE} ${ROOT}/l && cp -r x ${ROOT}/l/y"
    assert_blocked "git -C ${ROOT} checkout evil && rm -rf ${ROOT}/newlink/x"
    assert_allowed "ln -s ${OUTSIDE} ${ROOT}/l && rm -rf ${ROOT}/sub"
    assert_allowed "mkdir -p ${ROOT}/a/b && cp x ${ROOT}/a/b/"
    assert_allowed "rm -rf ${ROOT}/new/x && ln -s ${ROOT}/sub ${ROOT}/l"
}

@test "cp/mv --target-directory abbreviations and bundled -t clusters are validated" {
    assert_blocked "cp -rt${OUTSIDE} payload"
    assert_blocked "cp -rt ${OUTSIDE} payload"
    assert_blocked "cp -r --target=${OUTSIDE} payload"
    assert_blocked "cp -r --t=${OUTSIDE} payload"
    assert_blocked "mv -ft${OUTSIDE} sub"
    assert_allowed "cp -rt sub payload"
    assert_allowed "cp -r --target=sub payload"
}

@test "an explicitly empty --target-directory= value is blocked rather than taking the next word" {
    assert_blocked "cp --target-directory= sub payload" 'empty target directory'
    assert_blocked "mv --t= sub payload" 'empty target directory'
    assert_blocked "ln -s --target-directory= sub payload" 'empty target directory'
    assert_allowed "cp -t sub payload"
    assert_allowed "ln -s -t sub ${ROOT}/payload"
}

@test "a --target-directory that is a multi-match glob is blocked for cp, mv and ln (SEC-R7-2)" {
    mkdir -p "${ROOT}/sub/da" "${ROOT}/sub/db"
    assert_blocked "cp -t sub/d* payload" 'glob that matches 2 names'
    assert_blocked "cp --target-directory=sub/d* payload" 'glob that matches 2 names'
    assert_blocked "mv -t sub/d* payload" 'glob that matches 2 names'
    assert_blocked "ln -t sub/d* payload" 'glob that matches 2 names'
    assert_blocked "ln -s -t sub/d* payload" 'glob that matches 2 names'
    assert_allowed "cp -t sub/da* payload"
    assert_allowed "cp -t sub/da payload"
}

@test "npm single-dash long options are treated as the long option (nopt strips all leading dashes)" {
    assert_blocked "npm -script-shell /evil run build" '--script-shell'
    assert_blocked "npm -prefix ${OUTSIDE} prefix"
    assert_blocked "npm -userconf /evil ci"
    assert_allowed "npm -prefix sub ci"
    assert_allowed "npm -g ls"
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
    assert_blocked "git -C ${ROOT} status" 'could not be parsed as shell'
}

@test "unparseable shell input fails closed" {
    assert_blocked "git -C ${ROOT} status ("
}

@test "a failing realpath fails closed" {
    make_stub realpath 'exit 1'
    assert_blocked "git -C ${ROOT} status"
}
