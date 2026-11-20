#!/usr/bin/env bats
# shellcheck disable=SC2154  # stderr is set by run --separate-stderr

bats_require_minimum_version 1.5.0

load test_helper
load cfwf_helper

# --- issue create --------------------------------------------------------------

NEW_ISSUE_URL="https://github.com/credfeto/credfeto-orchestrator/issues/1600"

# The fixtures "issue create" needs on top of setup: a body file, the labels the repo already has,
# and the URL gh prints for a new issue. The default board is converted, so Not Started is st_1.
prepare_issue_create() {
    printf 'The body of the issue.\n\nWith a second paragraph and a trailing line.\n' > "${TEST_TMP}/body.md"
    jq -n '[{name: "High"}, {name: "cfwf"}]' > "${GH_FIXTURES}/label-list.json"
    printf '%s\n' "${NEW_ISSUE_URL}" > "${GH_FIXTURES}/issue-create.out"
}

create_args() {
    CREATE_ARGS=(issue create --repo "${REPO}" --priority "${1:-High}" --title "repo: A new issue" --body-file "${TEST_TMP}/body.md")
}

# Nothing was written: no label, no issue and no board item.
assert_nothing_created() {
    [ "$(gh_call_count "label create")" -eq 0 ]
    [ "$(gh_call_count "issue create")" -eq 0 ]
    [ "$(gh_call_count "project item-add")" -eq 0 ]
    [ "$(gh_call_count "project item-edit")" -eq 0 ]
}

@test "issue needs a subcommand, and an unknown one is refused" {
    run "${SCRIPT}" issue
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"issue needs a subcommand (create, edit, view, plan-status, list, search, label-history, reopen, close, post-plan, block, unblock, approve, comments, add-sub-issue, comment)"* ]]

    run "${SCRIPT}" issue frobnicate
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"unknown issue subcommand (argument 2; its value is not shown)"* && "${output}" != *frobnicate* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "issue --help and issue create --help print the usage without calling gh" {
    run "${SCRIPT}" issue --help
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Usage: cfwf issue create"* ]]

    run "${SCRIPT}" issue create --help
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Usage: cfwf issue create"* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "issue create needs --repo, --priority, --title and --body-file, and never calls gh without them" {
    prepare_issue_create
    run "${SCRIPT}" issue create --priority High --title "repo: T" --body-file "${TEST_TMP}/body.md"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"missing required option --repo"* ]]

    run "${SCRIPT}" issue create --repo "${REPO}" --title "repo: T" --body-file "${TEST_TMP}/body.md"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"--priority is required (Security, Urgent, High, Medium or Low)"* ]]

    run "${SCRIPT}" issue create --repo "${REPO}" --priority High --body-file "${TEST_TMP}/body.md"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"missing required option --title"* ]]

    run "${SCRIPT}" issue create --repo "${REPO}" --priority High --title "repo: T"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"missing required option --body-file"* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "issue create creates a label whose name starts with a dash without gh reading it as a flag" {
    prepare_issue_create
    create_args
    run "${SCRIPT}" "${CREATE_ARGS[@]}" --label -wip
    [ "${status}" -eq 0 ]
    grep -qxF "label create --repo ${REPO} -- -wip" "${GH_LOG}"
    issue_create_called_with "issue create --repo ${REPO} --title repo: A new issue --body-file BODY --label High --label -wip"
}

@test "issue create refuses --title given twice, like --priority and --body-file" {
    prepare_issue_create
    create_args
    run "${SCRIPT}" "${CREATE_ARGS[@]}" --title "Another"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"--title can only be given once"* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "issue create rejects a blank or over-long title or label, without calling gh" {
    prepare_issue_create
    create_args
    run "${SCRIPT}" issue create --repo "${REPO}" --priority High --title "   " --body-file "${TEST_TMP}/body.md"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"invalid value for --title: it must not be blank or longer than 256 characters"* ]]

    run "${SCRIPT}" issue create --repo "${REPO}" --priority High --title "repo: $(printf 'x%.0s' {1..251})" --body-file "${TEST_TMP}/body.md"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"invalid value for --title: it must not be blank or longer than 256 characters"* ]]

    run "${SCRIPT}" "${CREATE_ARGS[@]}" --label " "
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"invalid value for --label: it must not be blank or longer than 50 characters"* ]]

    run "${SCRIPT}" "${CREATE_ARGS[@]}" --label "$(printf 'x%.0s' {1..51})"
    [ "${status}" -eq 2 ]
    [ ! -f "${GH_LOG}" ]

    run "${SCRIPT}" issue create --repo "${REPO}" --priority High --title "repo: $(printf 'x%.0s' {1..250})" --body-file "${TEST_TMP}/body.md" --label "$(printf 'y%.0s' {1..50})"
    [ "${status}" -eq 0 ]
}

@test "issue create counts characters, not bytes, against the title and label limits, in any locale" {
    prepare_issue_create
    local accented
    accented=$(printf '\303\251%.0s' {1..200})
    LC_ALL=C.UTF-8 bash -c 'v=$(printf "\303\251"); [ "${#v}" -eq 1 ]' || skip "no C.UTF-8 locale on this host"
    LC_ALL=C run "${SCRIPT}" issue create --repo "${REPO}" --priority High --title "repo: ${accented}" --body-file "${TEST_TMP}/body.md" --label "$(printf '\303\251%.0s' {1..50})"
    [ "${status}" -eq 0 ]
}

# --- issue create: the title shape ---------------------------------------------

TITLE_SHAPE_ERROR='cfwf: invalid value for --title: it must be "prefix: text" or "prefix(name): text" with a lower-case prefix, for example "oneshot: ..." or "tool(cfwf): ..."'

# Runs issue create for the repository $1 with the title $2 and any further arguments.
run_titled_create() {
    local repository="$1" title="$2"
    shift 2
    run --separate-stderr "${SCRIPT}" issue create --repo "${repository}" --priority High --title "${title}" --body-file "${TEST_TMP}/body.md" "$@"
}

# Given a run's status, stdout and stderr: it was refused for the title's shape, with exit 2, the
# rule and the usage on stderr, nothing on stdout and no gh call.
assert_title_shape_refused() {
    [ "$1" -eq 2 ] \
        && [ -z "$2" ] \
        && [[ "$3" == "${TITLE_SHAPE_ERROR}"$'\n\n'"Usage: cfwf issue create"* ]] \
        && [ ! -f "${GH_LOG}" ]
}

@test "issue create accepts a title of the shape prefix: text or prefix(name): text with a lower-case prefix" {
    prepare_issue_create
    local title
    for title in "oneshot: X" "create-project: X" "tool(cfwf): X" "hook(enforce-curl-host): X" "fix: x" "fix(oneshot): x" \
        "learning: x" "audit: x" "py3: x" "tool(Some Name): x" "tool(a b): x" "repo: lower case text" "repo: --flag first" \
        "repo: $(printf '\303\251') first" "repo:   three spaces" "tool(a): x" "pre-commit-check: x"; do
        run_titled_create "${REPO}" "${title}"
        [ "${status}" -eq 0 ] || { echo "'${title}' was refused: ${stderr}" >&2; return 1; }
        [ "${output}" = "${NEW_ISSUE_URL}" ]
    done
}

@test "issue create refuses, with exit 2 and before any gh call, a title without a lower-case prefix, a colon and a space" {
    prepare_issue_create
    local title
    for title in "Add a thing" "Audit: x" "fIx: x" "3d: x" "-fix: x" "fix_it: x" "fix.it: x" "fix:x" "fix:" "fix:   " \
        "tool(): x" "tool( a): x" "tool(a(b)): x" "tool(a: x" "tool(a)(b): x" "fix (a): x" "fix : x" " fix: x" \
        "Fix the thing: now" "feat!: x" ": x" "a-: x" "fix-: x" "a--b: x" "tool(a ): x" "tool(a: b): x" "tool(a:b): x" \
        "tool(a)): x"; do
        run_titled_create "${REPO}" "${title}"
        assert_title_shape_refused "${status}" "${output}" "${stderr}" || { echo "'${title}' was not refused for its shape" >&2; return 1; }
    done
}

@test "issue create refuses a title whose text after the prefix is only multi-byte spaces, such as U+3000 or U+00A0, and never echoes it" {
    prepare_issue_create
    local title
    # U+3000, U+00A0, U+202F, U+2007, and a mix of them with ASCII spaces.
    for title in $'fix: \343\200\200' $'fix: \302\240' $'fix: \342\200\257' $'fix: \342\200\207' \
        $'tool(cfwf):  \343\200\200 \302\240 '; do
        run_titled_create "${REPO}" "${title}"
        assert_title_shape_refused "${status}" "${output}" "${stderr}" || { echo "'${title}' was not refused for its shape" >&2; return 1; }
        [[ "${stderr}" != *"${title}"* ]]
    done
}

@test "issue create refuses a title whose text after the prefix is only zero-width or blank-looking characters, and never echoes it" {
    prepare_issue_create
    local title
    # U+200B, U+200C, U+200D, U+2060, U+FEFF, U+3164, U+2800, U+115F, U+1160, U+FFA0, U+00AD,
    # U+034F, U+061C, U+17B4, U+17B5, U+180E, U+200E, U+202A, U+202E, U+206F, U+FE00, U+FE0F,
    # U+FFF0, U+FFF8, U+1BCA0, U+1D173, U+1D17A, U+E0001 and U+E007F, then a mix of them with
    # ASCII spaces, U+3000 and U+00A0.
    for title in $'fix: \342\200\213' $'fix: \342\200\214' $'fix: \342\200\215' $'fix: \342\201\240' \
        $'fix: \357\273\277' $'fix: \343\205\244' $'fix: \342\240\200' $'fix: \341\205\237' $'fix: \341\205\240' \
        $'fix: \357\276\240' $'fix: \302\255' $'fix: \315\217' $'fix: \330\234' $'fix: \341\236\264' \
        $'fix: \341\236\265' $'fix: \341\240\216' $'fix: \342\200\216' $'fix: \342\200\252' $'fix: \342\200\256' \
        $'fix: \342\201\257' $'fix: \357\270\200' $'fix: \357\270\217' $'fix: \357\277\260' $'fix: \357\277\270' \
        $'fix: \360\233\262\240' $'fix: \360\235\205\263' $'fix: \360\235\205\272' $'fix: \363\240\200\201' \
        $'fix: \363\240\201\277' $'tool(cfwf): \342\200\213 \343\200\200\357\273\277\302\240\342\200\213\342\240\200 '; do
        run_titled_create "${REPO}" "${title}"
        assert_title_shape_refused "${status}" "${output}" "${stderr}" || { echo "'${title}' was not refused for its shape" >&2; return 1; }
        [[ "${stderr}" != *"${title}"* ]]
    done
}

@test "issue create refuses, as blank, a label or a title made only of invisible characters, even for an owner the title shape does not apply to, and never echoes it" {
    prepare_issue_create
    create_args
    local value
    invisible_only_values
    for value in "${INVISIBLE_ONLY_VALUES[@]}"; do
        run --separate-stderr "${SCRIPT}" "${CREATE_ARGS[@]}" --label "${value}"
        assert_refused_as_blank "${status}" "${output}" "${stderr}" --label 50 "${value}" \
            || { echo "the label '${value}' was not refused as blank" >&2; return 1; }

        run_titled_create someone-else/x "${value}"
        assert_refused_as_blank "${status}" "${output}" "${stderr}" --title 256 "${value}" \
            || { echo "the title '${value}' was not refused as blank" >&2; return 1; }
    done
}

@test "issue create accepts a title whose text after the prefix holds a letter beside zero-width characters, or a character just outside their ranges" {
    prepare_issue_create
    local title
    # A letter after U+200B, e-acute between U+200C and U+200D, a letter after U+2800 and U+FEFF,
    # then U+2010 (hyphen, just after U+200B-U+200F) and U+2030 (per mille, just after U+202A-U+202F).
    for title in $'fix: \342\200\213x' $'fix: \342\200\214\303\251\342\200\215' $'fix(a): \342\240\200\357\273\277x' \
        $'fix: \342\200\220' $'fix: \342\200\260'; do
        run_titled_create "${REPO}" "${title}"
        [ "${status}" -eq 0 ] || { echo "'${title}' was refused: ${stderr}" >&2; return 1; }
        [ "${output}" = "${NEW_ISSUE_URL}" ]
    done
}

@test "issue create accepts a title whose text after the prefix starts with a non-ASCII letter or follows a multi-byte space" {
    prepare_issue_create
    local title
    # e-acute, a CJK ideograph, and a letter after U+3000 and after U+00A0.
    for title in $'fix: \303\251t\303\251' $'fix: \346\274\242\345\255\227' $'fix: \343\200\200x' $'fix(a): \302\240x'; do
        run_titled_create "${REPO}" "${title}"
        [ "${status}" -eq 0 ] || { echo "'${title}' was refused: ${stderr}" >&2; return 1; }
        [ "${output}" = "${NEW_ISSUE_URL}" ]
    done
}

@test "issue create refuses for its shape a title whose text after the prefix is only invalid UTF-8, and leaves mixed text to the leak check" {
    prepare_issue_create
    local title
    # In C.UTF-8 a byte that is not valid UTF-8 is not a character, so it is not visible text either.
    for title in $'fix: \377' $'fix: \200' $'tool(cfwf):  \300 \377 ' $'fix: \377\342\200\213'; do
        run_titled_create "${REPO}" "${title}"
        assert_title_shape_refused "${status}" "${output}" "${stderr}" || { echo "'${title}' was not refused for its shape" >&2; return 1; }
        [[ "${stderr}" != *"${title}"* ]]
    done

    # A visible character beside the invalid byte passes the shape check and is refused by the leak check.
    # e-acute and a CJK ideograph beside an invalid byte and a zero-width space stay visible.
    for title in $'fix: \200x' $'fix: x\377' $'fix: \377 \303\251' $'fix: \342\200\213\377\346\274\242'; do
        run_titled_create "${REPO}" "${title}"
        [ "${status}" -eq 8 ] || { echo "'${title}' exited ${status}: ${stderr}" >&2; return 1; }
        [ "${stderr}" = "cfwf: title refused: invalid UTF-8" ]
        [ -z "${output}" ]
        [ ! -f "${GH_LOG}" ]
    done
}

@test "a title refused for its shape is never echoed, wherever --repo is given, since a usage error comes before the leak check" {
    prepare_issue_create
    local secret="ghp_${RANDOM}abcdefghijklmnopqrstuvwxyz0123456789"
    run_titled_create "${REPO}" "Rotate ${secret} now"
    assert_title_shape_refused "${status}" "${output}" "${stderr}"
    [[ "${stderr}" != *"${secret}"* ]]

    run --separate-stderr "${SCRIPT}" issue create --priority High --title "Add a thing" --body-file "${TEST_TMP}/body.md" --repo "${REPO}"
    assert_title_shape_refused "${status}" "${output}" "${stderr}"
}

@test "issue create checks the title's shape before the body's leak check, and a prefixed title still goes to the leak check" {
    prepare_issue_create
    printf 'a path /tmp/out\n' > "${TEST_TMP}/body.md"
    run_titled_create "${REPO}" "Add a thing"
    assert_title_shape_refused "${status}" "${output}" "${stderr}"

    prepare_issue_create
    run_titled_create "${REPO}" "repo: see /tmp/x"
    [ "${status}" -eq 8 ]
    [ "${stderr}" = "cfwf: title refused: host path" ]
    [ ! -f "${GH_LOG}" ]
}

@test "the title shape applies to every repository of credfeto and funfair-tech, in any case, and to no other owner" {
    prepare_issue_create
    local repository
    for repository in credfeto/x funfair-tech/x Credfeto/x FUNFAIR-TECH/x; do
        run_titled_create "${repository}" "Add a thing"
        assert_title_shape_refused "${status}" "${output}" "${stderr}" || { echo "the title was not refused for ${repository}" >&2; return 1; }
    done

    for repository in someone-else/x credfeto-other/x notcredfeto/x funfair/x; do
        run_titled_create "${repository}" "Add a thing"
        [ "${status}" -eq 0 ] || { echo "the title was refused for ${repository}: ${stderr}" >&2; return 1; }
        [ "${output}" = "${NEW_ISSUE_URL}" ]
        issue_create_called_with "issue create --repo ${repository} --title Add a thing --body-file BODY --label High"
    done
}

@test "the title shape check has no way round it: no option skips it and the owner list is not read from the environment" {
    prepare_issue_create
    local flag
    for flag in --no-title-check --force; do
        run_titled_create "${REPO}" "Add a thing" "${flag}"
        [ "${status}" -eq 2 ]
        [[ "${stderr}" == "cfwf: unknown option (argument 11; its value is not shown)"* ]]
    done

    TITLE_CHECK_OWNERS=someone-else run_titled_create "${REPO}" "Add a thing"
    assert_title_shape_refused "${status}" "${output}" "${stderr}"
}

@test "issue create help states the title shape, the lower-case prefix, the owners and that it cannot be skipped, and calls no gh" {
    local args
    for args in "issue create --help" "help issue"; do
        # shellcheck disable=SC2086  # each row is the words of one command line
        run "${SCRIPT}" ${args}
        [ "${status}" -eq 0 ]
        [[ "${output}" == *'"prefix: text" or "prefix(name): text" with a lower-case prefix'* ]]
        [[ "${output}" == *"credfeto or funfair-tech"* ]]
        [[ "${output}" == *"usage error (exit 2), and there is no option to skip it"* ]]
    done
    [ ! -f "${GH_LOG}" ]
}

@test "issue create refuses to count a title, a label or a body when the C.UTF-8 locale is not installed" {
    run bash -c 'source "$1"; utf8_locale_available() { return 1; }; CURRENT_COMMAND=issue; parse_issue_options --title T' _ "${SCRIPT}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"the C.UTF-8 locale is not installed"* ]]

    run bash -c 'source "$1"; utf8_locale_available() { return 1; }; CURRENT_COMMAND=issue; parse_issue_options --label bug' _ "${SCRIPT}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"the C.UTF-8 locale is not installed"* ]]

    printf 'body\n' > "${TEST_TMP}/body.md"
    run bash -c 'source "$1"; utf8_locale_available() { return 1; }; check_body_for_leaks "$2" credfeto/repo' _ "${SCRIPT}" "${TEST_TMP}/body.md"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"the C.UTF-8 locale is not installed"* ]]
}

@test "issue create --help and a usage error do not need the C.UTF-8 locale" {
    run bash -c 'source "$1"; utf8_locale_available() { return 1; }; CURRENT_COMMAND=issue; parse_issue_options --help' _ "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == "Usage: cfwf issue create"* ]]

    run bash -c 'source "$1"; utf8_locale_available() { return 1; }; CURRENT_COMMAND=issue; parse_issue_options --bogus' _ "${SCRIPT}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"unknown option ("* ]]
}

@test "the C.UTF-8 locale check passes where the locale is installed" {
    LC_ALL=C.UTF-8 bash -c 'v=$(printf "\303\251"); [ "${#v}" -eq 1 ]' || skip "no C.UTF-8 locale on this host"
    run bash -c 'source "$1"; utf8_locale_available' _ "${SCRIPT}"
    [ "${status}" -eq 0 ]
}

@test "issue create refuses a body over GitHub's 65536 characters with exit 8 before calling gh, and accepts exactly that many" {
    prepare_issue_create
    head -c 65537 /dev/zero | tr '\0' 'x' > "${TEST_TMP}/long.md"
    run --separate-stderr "${SCRIPT}" issue create --repo "${REPO}" --priority High --title "repo: T" --body-file "${TEST_TMP}/long.md"
    [ "${status}" -eq 8 ]
    [ "${stderr}" = "cfwf: body refused: too long" ]
    [ ! -f "${GH_LOG}" ]

    head -c 65536 /dev/zero | tr '\0' 'x' > "${TEST_TMP}/limit.md"
    run "${SCRIPT}" issue create --repo "${REPO}" --priority High --title "repo: T" --body-file "${TEST_TMP}/limit.md"
    [ "${status}" -eq 0 ]
}

@test "a character count that fails or is not a number is a runtime failure (exit 1), never too long or a pass" {
    printf 'A short body.\n' > "${TEST_TMP}/leak.md"
    local real_wc failure
    real_wc=$(command -v wc)
    # Each pass makes the character count (wc -m) fail one way: an error status, then garbage on
    # stdout with status 0. Every other wc is the real one.
    for failure in "echo 'wc: read error' >&2; exit 1" "echo 'not a count'; exit 0"; do
        make_stub_multiline wc \
            "case \" \$* \" in *\" -m \"*) ${failure} ;; esac" \
            "exec ${real_wc} \"\$@\""
        run_body_check
        [ "${status}" -eq 1 ]
        [ "${stderr##*$'\n'}" = "cfwf: could not count the characters of the body" ]
        [ ! -f "${GH_LOG}" ]
    done
}

@test "issue create refuses --repo given twice, so a second one can never redirect the issue" {
    prepare_issue_create
    create_args
    run "${SCRIPT}" "${CREATE_ARGS[@]}" --repo credfeto/other-repo
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"--repo can only be given once"* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "issue create rejects a --repo that is not owner/repo, without calling gh" {
    prepare_issue_create
    local bad
    for bad in "no-slash" "a/b/c" "a b/c" 'a/b;rm' "" "../.." "./x" "x/." "x/.." "../repo"; do
        run "${SCRIPT}" issue create --repo "${bad}" --priority High --title "repo: T" --body-file "${TEST_TMP}/body.md"
        [ "${status}" -eq 2 ] || { echo "--repo '${bad}' was accepted" >&2; return 1; }
        [[ "${output}" == *"invalid value for --repo"* ]]
    done
    [ ! -f "${GH_LOG}" ]
}

@test "issue create rejects an unknown priority and lists the valid ones, without calling gh" {
    prepare_issue_create
    create_args Critical
    run "${SCRIPT}" "${CREATE_ARGS[@]}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"unknown --priority (expected Security, Urgent, High, Medium or Low)"* && "${output}" != *Critical* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "the priority list the help and error texts name is PRIORITIES, comma-separated with or before the last, and both helps print it" {
    run bash -c 'source "$1"; [ "${#PRIORITIES[@]}" -gt 1 ] || exit 2; expected="${PRIORITIES[0]}"; for p in "${PRIORITIES[@]:1:${#PRIORITIES[@]}-2}"; do expected+=", ${p}"; done; expected+=" or ${PRIORITIES[-1]}"; [ "${PRIORITY_LIST}" = "${expected}" ] || { printf "%s\n%s\n" "${PRIORITY_LIST}" "${expected}" >&2; exit 1; }' _ "${SCRIPT}"
    [ "${status}" -eq 0 ] || { echo "${output}" >&2; return 1; }
    run "${SCRIPT}" help issue create
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"exactly once: Security, Urgent, High, Medium or Low (matched"* ]]
    run "${SCRIPT}" help issue list
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"in its own spelling: Security, Urgent, High, Medium or Low, in that order"* ]]
}

@test "issue create refuses --priority given twice, because an issue has one priority" {
    prepare_issue_create
    create_args
    run "${SCRIPT}" "${CREATE_ARGS[@]}" --priority Low
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"--priority can only be given once"* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "issue create accepts each of the five priorities in any case and applies the canonical label" {
    prepare_issue_create
    local given canonical
    for row in "security|Security" "URGENT|Urgent" "High|High" "mEdIuM|Medium" "low|Low"; do
        given="${row%|*}"
        canonical="${row#*|}"
        : > "${GH_LOG}"
        create_args "${given}"
        run "${SCRIPT}" "${CREATE_ARGS[@]}"
        [ "${status}" -eq 0 ]
        issue_create_called_with "issue create --repo ${REPO} --title repo: A new issue --body-file BODY --label ${canonical}"
    done
}

@test "a priority given as --label is refused in any case, pointing at --priority, and nothing is created" {
    prepare_issue_create
    create_args Low
    local row given canonical
    for row in "Urgent|Urgent" "urgent|Urgent" "HIGH|High" "security|Security" "Medium|Medium" "low|Low"; do
        given="${row%|*}"
        canonical="${row#*|}"
        run "${SCRIPT}" "${CREATE_ARGS[@]}" --label "${given}"
        [ "${status}" -eq 2 ] || { echo "--label ${given} was accepted" >&2; return 1; }
        [[ "${output}" == *"'${given}' is a priority; use --priority ${canonical}, not --label"* ]]
    done
    [ ! -f "${GH_LOG}" ]
}

@test "a priority label is refused among other labels too, whatever its position" {
    prepare_issue_create
    create_args
    run "${SCRIPT}" "${CREATE_ARGS[@]}" --label Bug --label Urgent --label cfwf
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"'Urgent' is a priority; use --priority Urgent, not --label"* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "issue create rejects a label with a comma or a control character, and an empty title, without calling gh" {
    prepare_issue_create
    create_args
    run "${SCRIPT}" "${CREATE_ARGS[@]}" --label "a,b"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"invalid value for --label: it must not contain a comma or a control character"* && "${output}" != *"a,b"* ]]

    run "${SCRIPT}" "${CREATE_ARGS[@]}" --label $'a\nb'
    [ "${status}" -eq 2 ]

    run "${SCRIPT}" issue create --repo "${REPO}" --priority High --title "" --body-file "${TEST_TMP}/body.md"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"invalid value for --title"* ]]

    run "${SCRIPT}" issue create --repo "${REPO}" --priority High --title $'a\tb' --body-file "${TEST_TMP}/body.md"
    [ "${status}" -eq 2 ]
    [ ! -f "${GH_LOG}" ]
}

@test "a usage error names the option and the rule but never echoes the value, which could hold a token" {
    prepare_issue_create
    create_args
    local secret="LEAKMARKER0123456789" flag
    for flag in --title --label --body-file --repo; do
        # The bad value comes first, so it is parsed before the same option given by create_args.
        run --separate-stderr "${SCRIPT}" issue create "${flag}" "${secret}"$'\tx' "${CREATE_ARGS[@]:2}"
        [ "${status}" -eq 2 ] || { echo "${flag} was accepted" >&2; return 1; }
        [[ "${stderr}" == "cfwf: invalid value for ${flag}: it must "* ]]
        [[ "${stderr}" != *"${secret}"* ]]
    done

    run --separate-stderr "${SCRIPT}" issue create --repo "${REPO}" --priority "${secret}" --title "repo: T" --body-file "${TEST_TMP}/body.md"
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: unknown --priority "* && "${stderr}" != *"${secret}"* ]]

    for flag in --pr --status; do
        run --separate-stderr "${SCRIPT}" workflow-status --set --repo "${REPO}" --issue 1346 --status Approved "${flag}" "${secret}"$'\tx'
        [ "${status}" -eq 2 ]
        [[ "${stderr}" == "cfwf: invalid value for ${flag}: it must "* && "${stderr}" != *"${secret}"* ]]
    done
    [ ! -f "${GH_LOG}" ]

    run --separate-stderr "${SCRIPT}" workflow-status --set --repo "${REPO}" --issue 1346 --status "${secret}"
    [ "${status}" -eq 1 ]
    [[ "${stderr}" == "cfwf: unknown --status "* && "${stderr}" != *"${secret}"* ]]
}

@test "issue create rejects the options that belong to workflow-status, and unknown ones" {
    prepare_issue_create
    create_args
    local flag
    for flag in --status --pr --issue --set --check --bogus; do
        run "${SCRIPT}" "${CREATE_ARGS[@]}" "${flag}" 1
        [ "${status}" -eq 2 ] || { echo "${flag} was accepted" >&2; return 1; }
        [[ "${output}" == *"unknown option (argument 11; its value is not shown)"* ]]
    done
    [ ! -f "${GH_LOG}" ]
}

@test "issue create refuses one argument that holds two of its flags as an unknown option" {
    prepare_issue_create
    run --separate-stderr "${SCRIPT}" issue create "--title --body-file" x --repo "${REPO}" --priority High --title "repo: T" --body-file "${TEST_TMP}/body.md"
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == *"unknown option (argument 3; its value is not shown)"* && "${stderr}" != *"--title --body-file"* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "a token-shaped stray argument is named by its position, never echoed, as a command, a subcommand or an option" {
    prepare_issue_create
    local secret="ghp_${RANDOM}abcdefghijklmnopqrstuvwxyz0123456789"
    run --separate-stderr "${SCRIPT}" "${secret}"
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: unknown command (argument 1; its value is not shown)"* && "${stderr}" != *"${secret}"* ]]

    run --separate-stderr "${SCRIPT}" body "${secret}"
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: unknown body subcommand (argument 2; its value is not shown)"* && "${stderr}" != *"${secret}"* ]]

    # An unquoted title: --title takes the first word, and the token after it is a stray argument.
    run --separate-stderr "${SCRIPT}" issue create --repo "${REPO}" --priority High --title Rotate "${secret}" now --body-file "${TEST_TMP}/body.md"
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: unknown option (argument 9; its value is not shown)"* && "${stderr}" != *"${secret}"* ]]
    [ -z "${output}" ]
    [ ! -f "${GH_LOG}" ]
}

@test "an option that workflow-status does not have is not accepted there either" {
    local flag
    for flag in --priority --title --body-file --label; do
        run "${SCRIPT}" workflow-status --set --repo "${REPO}" --issue 1346 --status Approved "${flag}" value
        [ "${status}" -eq 2 ]
        [[ "${output}" == *"unknown option (argument 9; its value is not shown)"* ]]
    done
    [ ! -f "${GH_LOG}" ]
}

@test "issue create refuses a missing, unreadable, empty or blank body, without calling gh" {
    prepare_issue_create
    create_args
    run "${SCRIPT}" issue create --repo "${REPO}" --priority High --title "repo: T" --body-file "${TEST_TMP}/nope.md"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"cfwf: cannot read the --body-file"* && "${output}" != *"${TEST_TMP}"* ]]

    : > "${TEST_TMP}/empty.md"
    run "${SCRIPT}" issue create --repo "${REPO}" --priority High --title "repo: T" --body-file "${TEST_TMP}/empty.md"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"the body is empty"* ]]

    printf ' \n\t\n' > "${TEST_TMP}/blank.md"
    run "${SCRIPT}" issue create --repo "${REPO}" --priority High --title "repo: T" --body-file "${TEST_TMP}/blank.md"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"the body is empty"* ]]

    run "${SCRIPT}" issue create --repo "${REPO}" --priority High --title "repo: T" --body-file "${TEST_TMP}"
    [ "${status}" -eq 1 ]
    [ ! -f "${GH_LOG}" ]
}

@test "issue create refuses a body of only U+3000, U+00A0, U+200B or U+FEFF as empty, never echoing it, and takes one with a visible character" {
    prepare_issue_create
    write_invisible_bodies
    local name
    for name in "${INVISIBLE_BODIES[@]}"; do
        run --separate-stderr "${SCRIPT}" issue create --repo "${REPO}" --priority High --title "repo: T" --body-file "${TEST_TMP}/invisible-${name}.md"
        [ "${status}" -eq 1 ] || { echo "took ${name}" >&2; return 1; }
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: the body is empty" ] || { echo "wrong message for ${name}" >&2; return 1; }
    done
    [ ! -f "${GH_LOG}" ]

    run --separate-stderr "${SCRIPT}" issue create --repo "${REPO}" --priority High --title "repo: T" --body-file "${TEST_TMP}/visible-among-invisible.md"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${NEW_ISSUE_URL}" ]
    cmp "${TEST_TMP}/visible-among-invisible.md" "${GH_FIXTURES}/issue-body.txt"
}

@test "issue create reads the body from stdin for --body-file -, and an empty stdin is refused" {
    prepare_issue_create
    run "${SCRIPT}" issue create --repo "${REPO}" --priority High --title "repo: A new issue" --body-file - <<< "A body from stdin"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${NEW_ISSUE_URL}" ]
    [ "$(cat "${GH_FIXTURES}/issue-body.txt")" = "A body from stdin" ]

    : > "${GH_LOG}"
    run "${SCRIPT}" issue create --repo "${REPO}" --priority High --title "repo: A new issue" --body-file - < /dev/null
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"the body is empty"* ]]
    assert_nothing_created
}

@test "issue create hands gh the private copy it checked, so a body file rewritten after the check is never posted" {
    prepare_issue_create
    cp "${TEST_TMP}/body.md" "${TEST_TMP}/checked.md"
    printf '%s\n' "${TEST_TMP}/body.md" > "${GH_FIXTURES}/label-list.rewrite"
    create_args
    run "${SCRIPT}" "${CREATE_ARGS[@]}"
    [ "${status}" -eq 0 ]
    # The rewrite happened, between the check and the issue create, and gh still got the checked text.
    [[ "$(cat "${TEST_TMP}/body.md")" == rewritten* ]]
    cmp "${TEST_TMP}/checked.md" "${GH_FIXTURES}/issue-body.txt"
    [ "$(gh_call_count "--body-file ${TEST_TMP}/body.md")" -eq 0 ]
}

@test "issue create hands the body file to gh unchanged" {
    prepare_issue_create
    create_args
    run "${SCRIPT}" "${CREATE_ARGS[@]}"
    [ "${status}" -eq 0 ]
    cmp "${TEST_TMP}/body.md" "${GH_FIXTURES}/issue-body.txt"
}

@test "issue create fails, creating nothing, when no project titled Workflow is linked to the repo" {
    prepare_issue_create
    jq -n '{projectsV2: {Nodes: [{id: "PVT_other", title: "Roadmap", number: 9, resourcePath: "/users/credfeto/projects/9", closed: false}]}}' > "${GH_FIXTURES}/repo-view.json"
    create_args
    run "${SCRIPT}" "${CREATE_ARGS[@]}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"no project titled Workflow is linked to ${REPO}"* ]]
    assert_nothing_created
    [ "$(gh_call_count "label list")" -eq 0 ]
}

@test "issue create fails, creating nothing, when the board has no Not Started option" {
    prepare_issue_create
    jq -n '{fields: [{id: "PVTSSF_status", name: "Status", options: [{id: "st_2", name: "Planning"}], type: "ProjectV2SingleSelectField"}], totalCount: 1}' > "${GH_FIXTURES}/field-list.json"
    create_args
    run "${SCRIPT}" "${CREATE_ARGS[@]}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"has no 'Not Started' option"* ]]
    assert_nothing_created
}

@test "issue create makes the issue, puts it on the board as Not Started and prints only the URL" {
    prepare_issue_create
    create_args
    run --separate-stderr "${SCRIPT}" "${CREATE_ARGS[@]}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${NEW_ISSUE_URL}" ]
    [ -z "${stderr}" ]

    issue_create_called_with "issue create --repo ${REPO} --title repo: A new issue --body-file BODY --label High"
    grep -qxF "project item-add 74 --owner credfeto --url ${NEW_ISSUE_URL} --format json --jq .id" "${GH_LOG}"
    grep -qxF "project item-edit --project-id PVT_proj --id PVTI_target --field-id PVTSSF_status --single-select-option-id st_1" "${GH_LOG}"
    [ "$(gh_call_count "project item-edit")" -eq 1 ]
}

@test "issue create checks everything first: board, then labels, then the issue, then the board writes, and never reads back" {
    prepare_issue_create
    create_args
    run "${SCRIPT}" "${CREATE_ARGS[@]}"
    [ "${status}" -eq 0 ]
    local repo_view field_list label_list issue add edit
    repo_view=$(gh_line_of "repo view")
    field_list=$(gh_line_of "project field-list")
    label_list=$(gh_line_of "label list")
    issue=$(gh_line_of "issue create")
    add=$(gh_line_of "project item-add")
    edit=$(gh_line_of "--field-id PVTSSF_status ")
    [ "${repo_view}" -lt "${field_list}" ]
    [ "${field_list}" -lt "${label_list}" ]
    [ "${label_list}" -lt "${issue}" ]
    [ "${issue}" -lt "${add}" ]
    [ "${add}" -lt "${edit}" ]
    [ "${edit}" -eq "$(wc -l < "${GH_LOG}")" ]
    [ "$(gh_call_count "api graphql")" -eq 0 ]
    [ "$(gh_call_count "project item-list")" -eq 0 ]
}

@test "issue create reads the labels of the repo with a limit above gh's default of 30" {
    prepare_issue_create
    create_args
    run "${SCRIPT}" "${CREATE_ARGS[@]}"
    [ "${status}" -eq 0 ]
    grep -qF "label list --repo ${REPO} --limit 1000 --json name" "${GH_LOG}"
}

@test "issue create applies the priority and each given label, once each, and creates none that exist" {
    prepare_issue_create
    create_args
    run "${SCRIPT}" "${CREATE_ARGS[@]}" --label cfwf --label CFWF
    [ "${status}" -eq 0 ]
    issue_create_called_with "issue create --repo ${REPO} --title repo: A new issue --body-file BODY --label High --label cfwf"
    [ "$(gh_call_count "label create")" -eq 0 ]
}

@test "issue create creates a missing standard label with its standard colour and description" {
    prepare_issue_create
    create_args
    run "${SCRIPT}" "${CREATE_ARGS[@]}" --label AI-Work --label "on hold"
    [ "${status}" -eq 0 ]
    grep -qxF "label create --repo ${REPO} --color ffa500 --description Work for an AI Agent -- AI-Work" "${GH_LOG}"
    grep -qxF "label create --repo ${REPO} --color ff0000 --description Do not work on this -- On Hold" "${GH_LOG}"
    issue_create_called_with "issue create --repo ${REPO} --title repo: A new issue --body-file BODY --label High --label AI-Work --label On Hold"
}

@test "issue create creates any other missing label with the colour gh picks, passing no colour or description" {
    prepare_issue_create
    create_args
    run "${SCRIPT}" "${CREATE_ARGS[@]}" --label "brand new"
    [ "${status}" -eq 0 ]
    grep -qxF "label create --repo ${REPO} -- brand new" "${GH_LOG}"
    issue_create_called_with "issue create --repo ${REPO} --title repo: A new issue --body-file BODY --label High --label brand new"
}

@test "issue create creates a missing priority label with its standard colour and description" {
    prepare_issue_create
    create_args Medium
    run "${SCRIPT}" "${CREATE_ARGS[@]}"
    [ "${status}" -eq 0 ]
    grep -qxF "label create --repo ${REPO} --color ffff00 --description Medium Priority -- Medium" "${GH_LOG}"
}

@test "issue create does not create a label that exists in another case" {
    prepare_issue_create
    jq -n '[{name: "high"}, {name: "bug"}]' > "${GH_FIXTURES}/label-list.json"
    create_args
    run "${SCRIPT}" "${CREATE_ARGS[@]}" --label Bug
    [ "${status}" -eq 0 ]
    [ "$(gh_call_count "label create")" -eq 0 ]
}

@test "issue create treats an already-exists answer to a label create as done, and any other failure as fatal before the issue" {
    prepare_issue_create
    printf 'HTTP 422: Validation Failed (already_exists)\n' > "${GH_FIXTURES}/label-create.fail"
    create_args
    run "${SCRIPT}" "${CREATE_ARGS[@]}" --label "brand new"
    [ "${status}" -eq 0 ]

    : > "${GH_LOG}"
    printf 'HTTP 403: Resource not accessible\nsecond line\n' > "${GH_FIXTURES}/label-create.fail"
    run "${SCRIPT}" "${CREATE_ARGS[@]}" --label "brand new"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"could not create the label 'brand new' in ${REPO}: HTTP 403: Resource not accessible"* ]]
    [[ "${output}" != *"second line"* ]]
    [ "$(gh_call_count "issue create")" -eq 0 ]
    [ "$(gh_call_count "project item-add")" -eq 0 ]
}

@test "issue create fails, creating nothing, when the labels of the repo cannot be read" {
    prepare_issue_create
    touch "${GH_FIXTURES}/label-list.fail"
    create_args
    run "${SCRIPT}" "${CREATE_ARGS[@]}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"could not read the labels of ${REPO}"* ]]
    [[ "${output}" != *"already created"* ]]
    assert_nothing_created
}

@test "issue create exits 1 without touching the board when gh cannot create the issue" {
    prepare_issue_create
    touch "${GH_FIXTURES}/issue-create.fail"
    create_args
    run "${SCRIPT}" "${CREATE_ARGS[@]}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"could not create the issue in ${REPO}"* ]]
    [ "$(gh_call_count "project item-add")" -eq 0 ]
}

@test "issue create refuses a result that is not an issue URL" {
    prepare_issue_create
    create_args
    printf 'something odd\n' > "${GH_FIXTURES}/issue-create.out"
    run "${SCRIPT}" "${CREATE_ARGS[@]}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"unexpected result for the new issue, which may have been created: something odd"* ]]
    [[ "${output}" != *"the issue was already created"* ]]
    [ "$(gh_call_count "project item-add")" -eq 0 ]
}

@test "issue create puts a new issue on the board when gh answers with another host, such as a proxy" {
    prepare_issue_create
    printf 'https://github-proxy.example.com/credfeto/credfeto-orchestrator/issues/7\n' > "${GH_FIXTURES}/issue-create.out"
    create_args
    run "${SCRIPT}" "${CREATE_ARGS[@]}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "https://github-proxy.example.com/credfeto/credfeto-orchestrator/issues/7" ]
    grep -qF "project item-add 74 --owner credfeto --url https://github-proxy.example.com/credfeto/credfeto-orchestrator/issues/7 " "${GH_LOG}"
}

@test "issue create refuses an answer that is not an https issue URL, whatever the host" {
    prepare_issue_create
    create_args
    local answer
    for answer in "http://github.com/credfeto/credfeto-orchestrator/issues/7" "https://github.com/credfeto/credfeto-orchestrator/pull/7" "https://github.com/credfeto/issues/7" "https://ho st/credfeto/credfeto-orchestrator/issues/7"; do
        printf '%s\n' "${answer}" > "${GH_FIXTURES}/issue-create.out"
        run "${SCRIPT}" "${CREATE_ARGS[@]}"
        [ "${status}" -eq 1 ]
        [[ "${output}" == *"unexpected result for the new issue"* ]]
    done
    [ "$(gh_call_count "project item-add")" -eq 0 ]
}

@test "issue create puts a new issue on the board even when a renamed repository answers with its new name" {
    prepare_issue_create
    printf 'https://github.com/credfeto/renamed-repo/issues/5\n' > "${GH_FIXTURES}/issue-create.out"
    create_args
    run "${SCRIPT}" "${CREATE_ARGS[@]}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "https://github.com/credfeto/renamed-repo/issues/5" ]
    grep -qF "project item-add 74 --owner credfeto --url https://github.com/credfeto/renamed-repo/issues/5 " "${GH_LOG}"
}

@test "issue create accepts the repository in a different case in the returned URL, and uses the last line of gh's output" {
    prepare_issue_create
    printf 'Creating issue in repo\nhttps://github.com/CredFeto/Credfeto-Orchestrator/issues/1600\n' > "${GH_FIXTURES}/issue-create.out"
    create_args
    run "${SCRIPT}" "${CREATE_ARGS[@]}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "https://github.com/CredFeto/Credfeto-Orchestrator/issues/1600" ]
}

@test "issue create exits 1 and names the issue URL on stderr when the board write is rejected, printing nothing on stdout" {
    prepare_issue_create
    create_args
    touch "${GH_FIXTURES}/item-edit.fail"
    run --separate-stderr "${SCRIPT}" "${CREATE_ARGS[@]}"
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == *"could not set the Status of ${NEW_ISSUE_URL}"* ]]
    [[ "${stderr}" == *"the issue was already created: ${NEW_ISSUE_URL}"* ]]

    rm "${GH_FIXTURES}/item-edit.fail"
    touch "${GH_FIXTURES}/item-add.fail"
    run --separate-stderr "${SCRIPT}" "${CREATE_ARGS[@]}"
    [ "${status}" -eq 1 ]
    [[ "${stderr}" == *"the issue was already created: ${NEW_ISSUE_URL}"* ]]
}

@test "issue create sets Not Started on the Workflow Status field of a board not converted yet (#1519)" {
    prepare_issue_create
    write_legacy_field_list
    create_args
    run --separate-stderr "${SCRIPT}" "${CREATE_ARGS[@]}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${NEW_ISSUE_URL}" ]
    grep -qxF "project item-edit --project-id PVT_proj --id PVTI_target --field-id PVTSSF_wf --single-select-option-id wf_1" "${GH_LOG}"
    [ "$(gh_call_count "project item-edit")" -eq 1 ]
}

@test "issue create leaves no temporary file behind, for a stdin body, a failed run and a run that succeeds" {
    prepare_issue_create
    local scratch="${TEST_TMP}/tmp"
    mkdir -p "${scratch}"

    TMPDIR="${scratch}" run "${SCRIPT}" issue create --repo "${REPO}" --priority High --title "repo: T" --body-file - <<< "from stdin"
    [ "${status}" -eq 0 ]
    [ -z "$(ls -A "${scratch}")" ]

    TMPDIR="${scratch}" run "${SCRIPT}" issue create --repo "${REPO}" --priority High --title "repo: T" --body-file "${TEST_TMP}/body.md"
    [ "${status}" -eq 0 ]
    [ -z "$(ls -A "${scratch}")" ]

    touch "${GH_FIXTURES}/issue-create.fail"
    TMPDIR="${scratch}" run "${SCRIPT}" issue create --repo "${REPO}" --priority High --title "repo: T" --body-file - <<< "from stdin"
    [ "${status}" -eq 1 ]
    [ -z "$(ls -A "${scratch}")" ]

    TMPDIR="${scratch}" run "${SCRIPT}" issue create --repo "${REPO}" --priority High --title "repo: T" --body-file - < /dev/null
    [ "${status}" -eq 1 ]
    [ -z "$(ls -A "${scratch}")" ]
}

# --- body leak check -----------------------------------------------------------

run_issue_create_leak() {
    run --separate-stderr "${SCRIPT}" issue create --repo "${REPO}" --priority High --title "repo: T" --body-file "${TEST_TMP}/leak.md"
}

# Text that looks like one of the credential forms and is not: a key one character short, a key
# prefix inside a longer word, an Authorization header name with no value, or a URL with no
# password (a user name alone, an empty password or a port).
harmless_credential_shapes() {
    printf '%s\n' "np""m_$(run_of a 35) is one short" "npm_config_registry and npm_package_version" \
        "AI""za$(run_of b 34) is one short" "sk""-$(run_of c 47) is one short" "de""sk-$(run_of c 48)" \
        "ASI""A$(run_of Q 15) is one short" \
        "Authorization:" "Authorization: " "\"Authorization\":" "Proxy-Authorization:" "authorization =" \
        "The Authorization header carries the credential." "Set the Proxy-Authorization header with a Basic value." \
        "Authorization header: Bearer" "Basic authentication sends an Authorization header." "The basic steps are below." \
        "Digest and Negotiate are Authorization schemes too." \
        "The user name is x-access-token: the token follows it." "x-access-token:@example.com" \
        "$(url_with_password https x-access-token "\${{ secrets.GITHUB_TOKEN }}")" \
        "{\"url\":\"http://localhost:8080\",\"email\":\"someone@example.com\"}" \
        "\`http://localhost:8080\`,\`someone@example.com\`" "http://localhost:8080/path" \
        "https://example.com:8080/path?user=someone@example.com" "ssh://git@example.com:22/path" "http://[::1]:8080/path" \
        "https://example.com:8080?user=someone@example.com and https://example.com:8080#someone@example.com" \
        "https://example.com?at=12:30&to=someone@example.com" "https://example.com#line:5@someone" \
        "https://user@example.com?at=12:30&to=someone@example.com" \
        "Mail someone@example.com about https://example.com:8443 and ask @someone at 12:30." \
        "https:/""/user:@example.com/path" "https:/""/user:@example.com/path?to=someone@example.com" \
        "https:/""/user:@localhost, then mail someone@example.com" \
        "$(url_with_password smtp "someone@example.com" "")" "smtp://someone@example.com@smtp.example.com/path" \
        "ssh://git@example.com" "https://user@example.com" "ssh://git@example.com:22" "git@example.com:owner/repo.git" \
        "ssh://git@example.com:owner/repo.git" "docker://alpine@sha256:0123abcd" \
        "docker://library/alpine:3.20@sha256:0123abcd" "image: alpine:3.20@sha256:0123abcd" \
        "https://user@example.com:8080/path?to=someone@example.com" "ssh://git@localhost:22, then mail someone@example.com"
}

@test "issue create refuses a body with any token form with exit 8, naming the rule and line only, before calling gh" {
    prepare_issue_create
    local token
    while IFS= read -r token; do
        write_leak_body "the value is ${token} here"
        run_issue_create_leak
        assert_refused "${status}" "${output}" "${stderr}" token "${token}"
        [ ! -f "${GH_LOG}" ]
    done < <(leak_tokens)
}

@test "body check passes a key one character short, a key prefix inside a word, an Authorization header name with no value and a URL with no password" {
    local body
    while IFS= read -r body; do
        printf '%s\n' "${body}" > "${TEST_TMP}/leak.md"
        run_body_check
        [ "${status}" -eq 0 ] || { echo "refused: ${body}" >&2; return 1; }
        [ -z "${output}" ]
        [ -z "${stderr}" ]
        [ ! -f "${GH_LOG}" ]
    done < <(harmless_credential_shapes)
}

@test "body check refuses a token at the very start of the body, and one after punctuation" {
    local body
    for body in "gh""p_abc def" "url?t=gh""p_abc"; do
        printf '%s\n' "${body}" > "${TEST_TMP}/leak.md"
        run_body_check
        [ "${status}" -eq 8 ]
        [ "${stderr}" = "cfwf: body refused: token (line 1)" ]
    done
}

@test "issue create refuses a body naming a host path, from any of the starts of a path, before calling gh" {
    prepare_issue_create
    local path start
    for path in /home/someone/work /Users/someone/work /root/.ssh /run/user/1000/scratch /tmp/claude-out; do
        for start in "" " " '"' "'" '`' "(" "[" "=" "file://" ":" "," "*" "_" "<" "{" "|" "/"; do
            write_leak_body "${start:+see }${start}${path}/file"
            run_issue_create_leak
            assert_refused "${status}" "${output}" "${stderr}" "host path" "${path}"
            [ ! -f "${GH_LOG}" ]
        done
    done
}

@test "body check still refuses a host path after punctuation that does not follow a slash, at a line start, or after a run of slashes" {
    local body
    for body in "_/home/someone/x_" "__/tmp/claude-out__" "**/root/.ssh**" "see a,/run/user/1000/x" "see /_/home/someone/x" \
        "///home/someone/x" "x//tmp/claude-out" "https://example.com//home/someone"; do
        write_leak_body "${body}"
        run_body_check
        assert_refused "${status}" "${output}" "${stderr}" "host path" "someone"
    done
}

@test "body check refuses a home, a user runtime directory or tmp deeper inside an absolute path, and a Windows drive path under Users" {
    local path start
    for path in /mnt/c/Users/someone/work /var/home/someone/work /private/tmp/claude-out /var/tmp/x /var/run/user/1000/x /a.b/tmp/x \
        /var/root/.ssh /mnt/x/root/y; do
        for start in "" " " '"' "(" "=" ":" "," "*" "file://"; do
            write_leak_body "${start:+see }${start}${path}/file"
            run_body_check
            assert_refused "${status}" "${output}" "${stderr}" "host path" "${path}"
        done
    done
    for path in 'C:\Users\someone\x' 'c:/users/someone/x' 'D:\\USERS\\someone' '(C:\Users\someone)'; do
        write_leak_body "see ${path}"
        run_body_check
        assert_refused "${status}" "${output}" "${stderr}" "host path" "someone"
    done
}

@test "issue create refuses a body with a control character other than tab and newline, before calling gh" {
    prepare_issue_create
    local control
    for control in '\000' '\001' '\010' '\013' '\014' '\015' '\033' '\037' '\177' '\302\200' '\302\205' '\302\233' '\302\237'; do
        printf "A clean first line.\n\nsecret%bvalue\nA clean last line.\n" "${control}" > "${TEST_TMP}/leak.md"
        run_issue_create_leak
        assert_refused "${status}" "${output}" "${stderr}" "control character" "secret"
        [ ! -f "${GH_LOG}" ]
    done
}

@test "the first rule that matches wins, in the order token, host path, control character, invalid UTF-8, too long" {
    printf 'a /tmp/x path\n%s\n' "gh""p_abc" > "${TEST_TMP}/leak.md"
    run_body_check
    [ "${stderr}" = "cfwf: body refused: token (line 2)" ]

    printf 'a\033b\nsee /tmp/x\n' > "${TEST_TMP}/leak.md"
    run_body_check
    [ "${stderr}" = "cfwf: body refused: host path (line 2)" ]

    {
        printf 'a\033b\n'
        head -c 65537 /dev/zero | tr '\0' 'x'
    } > "${TEST_TMP}/leak.md"
    run_body_check
    [ "${stderr}" = "cfwf: body refused: control character (line 1)" ]

    printf 'a\205b\nc\033d\n' > "${TEST_TMP}/leak.md"
    run_body_check
    [ "${stderr}" = "cfwf: body refused: control character (line 2)" ]

    {
        printf 'a\205b\n'
        head -c 65537 /dev/zero | tr '\0' 'x'
    } > "${TEST_TMP}/leak.md"
    run_body_check
    [ "${stderr}" = "cfwf: body refused: invalid UTF-8 (line 1)" ]
}

@test "a body, a title or a label that is not valid UTF-8 is refused with exit 8, naming only the line, before calling gh" {
    prepare_issue_create
    local bytes
    # A Latin-1 or CP1252 C1 byte alone, any byte that never starts UTF-8, a lead byte with no
    # continuation, an overlong NUL, a UTF-16 surrogate, a code point above U+10FFFF, and a
    # continuation byte straight after a whole character.
    for bytes in '\205' '\237' '\377' '\300' '\342\202' '\300\200' '\355\240\200' '\364\220\200\200' '\303\251\251'; do
        printf "A clean first line.\n\nsecret%bvalue\nA clean last line.\n" "${bytes}" > "${TEST_TMP}/leak.md"
        run_issue_create_leak
        assert_refused "${status}" "${output}" "${stderr}" "invalid UTF-8" "secret"
        [ ! -f "${GH_LOG}" ]

        run --separate-stderr "${SCRIPT}" issue create --repo "${REPO}" --priority High --title "repo: $(printf "a%bb" "${bytes}")" --body-file "${TEST_TMP}/body.md"
        [ "${status}" -eq 8 ]
        [ "${stderr}" = "cfwf: title refused: invalid UTF-8" ]

        run --separate-stderr "${SCRIPT}" issue create --repo "${REPO}" --priority High --title "repo: T" --body-file "${TEST_TMP}/body.md" --label "$(printf "a%bb" "${bytes}")"
        [ "${status}" -eq 8 ]
        [ "${stderr}" = "cfwf: label refused: invalid UTF-8" ]
        [ ! -f "${GH_LOG}" ]
    done
}

@test "body check passes a body with no leaks, printing nothing and calling gh for nothing" {
    printf '%s\n' \
        "Tabs$(printf '\t')are fine, as are multi-byte characters: $(printf '\303\251 \303\274 \346\227\245 \302\240 \302\251 \342\200\256 \304\200')." \
        "Relative paths such as test/cfwf.bats, lib/state and containers/base/x are fine." \
        "So are /usr/local/bin/cfwf, ~/work, ~/tmp/x, ~/work/home/x, ./tmp/x, ./a/tmp/x, ../home/x, tmp/notes, src/tmp/x, a/b/home/x, a/b/root/x, /users/x and example.com/home/x." \
        "URL paths pass too: https://example.com/home/x, http://h/tmp/x, //cdn.example.com/tmp/x, https://example.com/var/home/x and https://example.com/var/root/x." \
        "So does a URL path segment of punctuation: https://example.com/_/home/x, https://example.com/a/*/tmp/x, http://h/,/Users/x and https://example.com/:/root/x." \
        "So do Windows paths not under Users, a drive letter inside a word, and a relative one: C:\\Program Files\\x, abc:\\Users\\x, docs\\Users\\x." \
        "Words such as keyboard, laughs_at, monkey and the word TOKEN alone are fine, as is KEY = value." \
        "A token prefix on its own, gh""p_, is fine." \
        "credfeto/other-repo with no link and no number is not looked up." > "${TEST_TMP}/leak.md"
    run_body_check
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    [ -z "${stderr}" ]
    [ ! -f "${GH_LOG}" ]
}

@test "body check passes a token prefix, Bearer with no token after it or a webhook placeholder with no secret after it" {
    local body
    while IFS= read -r body; do
        printf '%s\n' "${body}" > "${TEST_TMP}/leak.md"
        run_body_check
        [ "${status}" -eq 0 ] || { echo "refused: ${body}" >&2; return 1; }
        [ -z "${stderr}" ]
    done << 'BODIES'
An Anthropic key starts sk-ant- and a project key sk-proj- on their own.
desk-proj-x and task-ant-y are words.
A Slack prefix such as xoxz-abc is not one of the token forms.
A Bearer token is sent in the Authorization header.
Bearer <token>
Bearer authentication is used.
Bearer authentication-mechanism-description
The bearer token-based-authentication-scheme is used.
Bearer Authentication-Mechanism-Description.
Bearer abcdefghijklmnopqrstuvwxyz
Bearer abcdefghijklmnopqr9
https://discord.com/api/webhooks/<id>/<token>
discord.com/api/webhooks/123456/<token>
BODIES
}

@test "body check passes a NAME=value whose name only ends in the letters, or whose value is a reference" {
    local body
    while IFS= read -r body; do
        printf '%s\n' "${body}" > "${TEST_TMP}/leak.md"
        run_body_check
        [ "${status}" -eq 0 ] || { echo "refused: ${body}" >&2; return 1; }
        [ -z "${stderr}" ]
    done << 'BODIES'
MONKEY=banana
TURKEY=x
MYTOKEN=x
my_api_key=x
GITHUB_TOKEN=${{ secrets.GITHUB_TOKEN }}
GH_TOKEN=${GH_TOKEN}
API_KEY=$API_KEY
GH_TOKEN="${GH_TOKEN}"
GH_TOKEN='$GH_TOKEN'
GH_TOKEN=
GH_TOKEN= x
BODIES
}

@test "a public target refuses a link to, or a reference to, a private repository, without naming it" {
    write_visibility "${REPO}" PUBLIC
    write_visibility credfeto/hidden-thing PRIVATE
    local reference
    for reference in "https://github.com/credfeto/hidden-thing/issues/4" "github.com/credfeto/hidden-thing" \
        "credfeto/hidden-thing#12" "(credfeto/hidden-thing#12)" "https://www.github.com/credfeto/hidden-thing.git" \
        "https://GitHub.COM/credfeto/hidden-thing" "git@github.com:credfeto/hidden-thing.git" \
        "https://api.github.com/repos/credfeto/hidden-thing/issues/4" "https://raw.githubusercontent.com/credfeto/hidden-thing/main/README.md" \
        "RAW.GITHUBUSERCONTENT.COM/credfeto/hidden-thing" "the clone...github.com/credfeto/hidden-thing" "(.github.com/credfeto/hidden-thing)"; do
        write_leak_body "see ${reference} for details"
        rm -f "${GH_LOG}"
        run_body_check
        assert_refused "${status}" "${output}" "${stderr}" "private repository" "hidden-thing"
        [ "$(visibility_lookups credfeto/hidden-thing)" -eq 1 ]
    done
}

@test "a repository GitHub does not show the caller counts as private, and so does an internal one" {
    write_visibility "${REPO}" PUBLIC
    write_leak_body "see https://github.com/credfeto/not-visible/pull/2"
    run_body_check
    assert_refused "${status}" "${output}" "${stderr}" "private repository" "not-visible"

    write_visibility credfeto/inside INTERNAL
    write_leak_body "see credfeto/inside#2"
    run_body_check
    assert_refused "${status}" "${output}" "${stderr}" "private repository" "inside"
}

@test "a private target accepts the same reference to a private repository, and looks nothing else up" {
    write_visibility "${REPO}" PRIVATE
    write_visibility credfeto/hidden-thing PRIVATE
    write_leak_body "see https://github.com/credfeto/hidden-thing/issues/4 and credfeto/hidden-thing#5"
    run_body_check
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ "$(visibility_lookups "${REPO}")" -eq 1 ]
    [ "$(visibility_lookups credfeto/hidden-thing)" -eq 0 ]
}

@test "a reference to the target itself or to a GitHub page that is not a repository passes with no lookup" {
    write_leak_body "see https://github.com/Credfeto/Credfeto-Orchestrator/pull/1 and ${REPO}#2 and https://github.com/orgs/credfeto/projects/74 and https://github.com/advisories/GHSA-abcd-efgh-ijkl"
    run_body_check
    [ "${status}" -eq 0 ]
    [ ! -f "${GH_LOG}" ]
}

@test "links to GitHub's other pages, such as starred lists, Copilot and the team plan, pass with no lookup" {
    write_leak_body "see https://github.com/stars/someone/lists/tools, github.com/copilot/c/abc123, https://github.com/team/compare and https://github.com/dashboard/feed"
    run_body_check
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ ! -f "${GH_LOG}" ]
}

@test "a link to the target's own wiki passes with no lookup, and another repository's wiki is looked up as that repository" {
    write_leak_body "see https://github.com/${REPO}.wiki, git@github.com:${REPO}.wiki.git and https://github.com/${REPO}/wiki/Home"
    run_body_check
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ ! -f "${GH_LOG}" ]

    write_visibility "${REPO}" PUBLIC
    write_visibility credfeto/hidden-thing PRIVATE
    local reference
    for reference in "https://github.com/credfeto/hidden-thing.wiki" "github.com/credfeto/hidden-thing.WIKI.git"; do
        write_leak_body "see ${reference} here"
        rm -f "${GH_LOG}"
        run_body_check
        assert_refused "${status}" "${output}" "${stderr}" "private repository" "hidden-thing"
        [ "$(visibility_lookups credfeto/hidden-thing)" -eq 1 ]
    done
}

@test "a pasted image or file, or one on GitHub's image hosts, passes on a public target with no lookup" {
    write_visibility "${REPO}" PUBLIC
    write_leak_body "![img](https://github.com/user-attachments/assets/0f1e2d3c-4b5a-6978-8a9b-0c1d2e3f4a5b) and [log](https://github.com/user-attachments/files/123/build.log), https://user-images.githubusercontent.com/1/2.png, https://private-user-images.githubusercontent.com/1/3.png and https://github.com/${REPO}/assets/1/4"
    run_body_check
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ ! -f "${GH_LOG}" ]
}

@test "a gist, another GitHub host or a host that only ends in github.com is not a repository link, and passes with no lookup" {
    write_visibility "${REPO}" PUBLIC
    write_leak_body "see https://gist.github.com/credfeto/abc123, https://docs.github.com/en/actions, notgithub.com/credfeto/hidden-thing, my-github.com/credfeto/hidden-thing and https://api.github.com/users/credfeto"
    run_body_check
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ ! -f "${GH_LOG}" ]
}

@test "a link with an ellipsis or a bare .git for the repository names none, and passes with no lookup" {
    write_visibility "${REPO}" PUBLIC
    write_leak_body "the repositories under https://github.com/credfeto/... and github.com/credfeto/.git"
    run_body_check
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ ! -f "${GH_LOG}" ]
}

@test "a reference to a public repository passes, and each repository is looked up once per run" {
    write_visibility "${REPO}" PUBLIC
    write_visibility credfeto/open-thing PUBLIC
    printf '%s\n' "https://github.com/credfeto/open-thing/issues/1" "credfeto/open-thing#2" \
        "https://github.com/credfeto/open-thing.git" "git@github.com:credfeto/open-thing.git" "CREDFETO/OPEN-THING#3" "https://github.com/credfeto/open-thing." > "${TEST_TMP}/leak.md"
    run_body_check
    [ "${status}" -eq 0 ]
    [ "$(gh_call_count "--json visibility")" -eq 2 ]
    [ "$(visibility_lookups "${REPO}")" -eq 1 ]
    [ "$(visibility_lookups credfeto/open-thing)" -eq 1 ]
}

@test "the first private reference in the body is the one refused, after the public ones before it pass" {
    write_visibility "${REPO}" PUBLIC
    write_visibility credfeto/open-thing PUBLIC
    write_visibility credfeto/hidden-thing PRIVATE
    printf '%s\n' "credfeto/open-thing#1" "fine" "https://github.com/credfeto/hidden-thing" "credfeto/hidden-thing#9" > "${TEST_TMP}/leak.md"
    run_body_check
    assert_refused "${status}" "${output}" "${stderr}" "private repository" "hidden-thing"
}

@test "a visibility lookup that fails is a runtime failure (exit 1), never a pass or a refusal" {
    write_visibility "${REPO}" PUBLIC
    fail_visibility credfeto/flaky-thing
    write_leak_body "see credfeto/flaky-thing#3"
    run_body_check
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: could not read the visibility of the repository named on line 3 of the body" ]

    # Access denied (an organisation enforcing SSO, or a proxy) is not "not found": it fails closed
    # as a runtime failure rather than counting as private.
    rm -f "${GH_FIXTURES}"/visibility-credfeto_flaky-thing.*
    fail_visibility credfeto/flaky-thing $'HTTP 403: Resource protected by organization SAML enforcement\n'
    run_body_check
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: could not read the visibility of the repository named on line 3 of the body" ]

    rm -f "${GH_FIXTURES}"/visibility-*
    fail_visibility "${REPO}"
    run_body_check
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: could not read the visibility of ${REPO}" ]
}

@test "a target repository GitHub does not show the caller is a runtime failure (exit 1), never a pass" {
    write_visibility credfeto/hidden-thing PRIVATE
    local reference
    for reference in "credfeto/hidden-thing#3" "https://github.com/credfeto/hidden-thing" "secret-org/plans"; do
        write_leak_body "see ${reference}"
        CFWF_PRIVATE_OWNERS="secret-org" run --separate-stderr "${SCRIPT}" body check --repo credfeto/no-such-repo --body-file "${TEST_TMP}/leak.md"
        [ "${status}" -eq 1 ]
        [ "${stderr}" = "cfwf: the repository credfeto/no-such-repo was not found, or the caller cannot see it" ]
        [ -z "${output}" ]
    done

    prepare_issue_create
    rm -f "${GH_LOG}"
    run --separate-stderr "${SCRIPT}" issue create --repo credfeto/no-such-repo --priority High --title "repo: see credfeto/hidden-thing#3" --body-file "${TEST_TMP}/body.md"
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: the repository credfeto/no-such-repo was not found, or the caller cannot see it" ]
    assert_nothing_created
}

@test "a target repository GitHub does not show the caller is never looked up when the text names no other repository" {
    rm -f "${GH_LOG}"
    write_leak_body "see credfeto/no-such-repo#3, which is the target itself, and test/cfwf.bats"
    run --separate-stderr "${SCRIPT}" body check --repo credfeto/no-such-repo --body-file "${TEST_TMP}/leak.md"
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ ! -f "${GH_LOG}" ]
}

@test "a grep that fails while scanning the body is a runtime failure (exit 1), never a pass" {
    write_visibility "${REPO}" PUBLIC
    write_visibility credfeto/open-thing PUBLIC
    write_leak_body "see credfeto/open-thing#1 and https://github.com/credfeto/open-thing"
    local real_grep flags
    real_grep=$(command -v grep)
    # Each pass makes one of the scans fail: the rule scans (-naE), the UTF-8 scan alone (-xv), the
    # link scan (-inoaE) and the owner/repo scan (-noaE). Every other grep is the real one.
    for flags in -naE -xv -inoaE -noaE; do
        make_stub_multiline grep \
            "case \" \$* \" in *\" ${flags} \"*) echo 'grep: read error' >&2; exit 2 ;; esac" \
            "exec ${real_grep} \"\$@\""
        rm -f "${GH_LOG}"
        run_body_check
        [ "${status}" -eq 1 ]
        [ "${stderr##*$'\n'}" = "cfwf: could not scan the body" ]
        [ ! -f "${GH_LOG}" ]
    done
}

@test "an owner in CFWF_PRIVATE_OWNERS is refused with no lookup, even as a bare owner/repo" {
    write_visibility "${REPO}" PUBLIC
    local reference
    for reference in "secret-org/plans" "https://github.com/Secret-Org/plans/issues/1" "secret-org/plans#4" "\`other-hidden/plans\`" \
        "https://raw.githubusercontent.com/secret-org/plans/main/x" "https://api.github.com/repos/secret-org/plans" \
        "REPO=secret-org/plans" "repo:secret-org/plans" "?r=secret-org/plans#1" "x@secret-org/plans@abc1234"; do
        write_leak_body "see ${reference}"
        rm -f "${GH_LOG}"
        CFWF_PRIVATE_OWNERS="secret-org other-hidden" run_body_check
        assert_refused "${status}" "${output}" "${stderr}" "private repository" "plans"
        [ "$(gh_call_count "--json visibility")" -eq "$(visibility_lookups "${REPO}")" ]
    done
}

@test "a bare owner/repo inside a longer path is not read as a reference to a listed owner" {
    write_visibility "${REPO}" PUBLIC
    write_leak_body "see src/secret-org/plans and docs.secret-org/plans"
    CFWF_PRIVATE_OWNERS="secret-org" run_body_check
    [ "${status}" -eq 0 ]
    [ ! -f "${GH_LOG}" ]
}

@test "a reference in Markdown emphasis is still checked, and an underscore inside a word is not a boundary" {
    write_visibility "${REPO}" PUBLIC
    write_visibility credfeto/hidden-thing PRIVATE
    write_visibility credfeto/open-thing PUBLIC
    local body
    for body in "see _credfeto/hidden-thing#5_" "see __credfeto/hidden-thing#5__" "_credfeto/hidden-thing#5_ first" \
        "see *credfeto/hidden-thing#5*" "see **credfeto/hidden-thing@abc1234**" "(_credfeto/hidden-thing@abc1234_)"; do
        write_leak_body "${body}"
        run_body_check
        assert_refused "${status}" "${output}" "${stderr}" "private repository" "hidden-thing"
    done

    for body in "see _secret-org/plans_" "see __secret-org/plans__"; do
        write_leak_body "${body}"
        CFWF_PRIVATE_OWNERS="secret-org" run_body_check
        assert_refused "${status}" "${output}" "${stderr}" "private repository" "plans"
    done

    write_leak_body "see _credfeto/open-thing#5_ and *credfeto/open-thing#6*"
    rm -f "${GH_LOG}"
    run_body_check
    [ "${status}" -eq 0 ]
    [ "$(visibility_lookups credfeto/open-thing)" -eq 1 ]

    # An underscore inside a word, or a #n followed by more than closing underscores, is not a
    # reference, so nothing is looked up.
    for body in "see my_credfeto/hidden-thing#5" "see credfeto/hidden-thing#5_x" "see /_credfeto/hidden-thing#5_" "see =_credfeto/hidden-thing#5_"; do
        write_leak_body "${body}"
        rm -f "${GH_LOG}"
        run_body_check
        [ "${status}" -eq 0 ] || { echo "${body} was refused" >&2; return 1; }
        [ ! -f "${GH_LOG}" ]
    done
    write_leak_body "see my_secret-org/plans"
    CFWF_PRIVATE_OWNERS="secret-org" run_body_check
    [ "${status}" -eq 0 ]
}

@test "a #n inside a longer word, or an owner/repo#n inside a path or a URL, is not a cross-reference, and passes with no lookup" {
    write_visibility "${REPO}" PUBLIC
    write_visibility credfeto/hidden-thing PRIVATE
    local body
    for body in "docs/setup.md#1-prerequisites" "fix/foo#12abc" "src/app.ts#12_x" "fix/foo#12-bar" "credfeto/hidden-thing#1x" \
        "https://example.com/?p=credfeto/hidden-thing#1" "user@credfeto/hidden-thing#1" "~credfeto/hidden-thing#1" \
        "localhost:8080/hidden-thing#1" "https://example.com:8443/credfeto/hidden-thing#1" "a&b=credfeto/hidden-thing#1" "%2Fcredfeto/hidden-thing#1" "+credfeto/hidden-thing#1"; do
        write_leak_body "see ${body} here"
        rm -f "${GH_LOG}"
        run_body_check
        [ "${status}" -eq 0 ] || { echo "refused: ${body}" >&2; return 1; }
        [ -z "${stderr}" ]
        [ ! -f "${GH_LOG}" ]
    done
}

@test "standalone cross-references side by side are each checked, so a private one after a public one is refused" {
    write_visibility "${REPO}" PUBLIC
    write_visibility credfeto/open-thing PUBLIC
    write_visibility credfeto/hidden-thing PRIVATE
    local body
    for body in "credfeto/open-thing#1 credfeto/hidden-thing#2" "credfeto/open-thing#1,credfeto/hidden-thing#2." \
        "(credfeto/open-thing#1)(credfeto/hidden-thing#2)" "credfeto/hidden-thing#2" "Related:credfeto/hidden-thing#2" \
        "Fixes:credfeto/hidden-thing@abc1234" "x:credfeto/hidden-thing#2"; do
        write_leak_body "${body}"
        run_body_check
        assert_refused "${status}" "${output}" "${stderr}" "private repository" "hidden-thing"
    done
}

@test "a public target refuses a codeload link or an owner/repo@sha autolink to a private repository" {
    write_visibility "${REPO}" PUBLIC
    write_visibility credfeto/hidden-thing PRIVATE
    write_visibility credfeto/open-thing PUBLIC
    local sha40 reference
    sha40=$(printf 'a%.0s' {1..40})
    for reference in "https://codeload.github.com/credfeto/hidden-thing/zip/refs/heads/main" "codeload.github.com/credfeto/hidden-thing/tar.gz/v1" \
        "credfeto/hidden-thing@abc1234" "credfeto/hidden-thing@ABC1234." "(credfeto/hidden-thing@${sha40})" "credfeto/open-thing#1 credfeto/hidden-thing@abc1234"; do
        write_leak_body "see ${reference}"
        run_body_check
        assert_refused "${status}" "${output}" "${stderr}" "private repository" "hidden-thing"
    done
}

@test "an @ that is not followed by a commit SHA alone, or a host that only ends in codeload.github.com, passes with no lookup" {
    write_visibility "${REPO}" PUBLIC
    write_visibility credfeto/hidden-thing PRIVATE
    local body
    for body in "credfeto/hidden-thing@abc123" "credfeto/hidden-thing@$(printf 'a%.0s' {1..41})" "credfeto/hidden-thing@abc1234x" \
        "credfeto/hidden-thing@abc1234-x" "credfeto/hidden-thing@v1.2.3" "actions/checkout@v4" "notcodeload.github.com/credfeto/hidden-thing" \
        "x@credfeto/hidden-thing@abc1234"; do
        write_leak_body "see ${body} here"
        rm -f "${GH_LOG}"
        run_body_check
        [ "${status}" -eq 0 ] || { echo "refused: ${body}" >&2; return 1; }
        [ -z "${stderr}" ]
        [ ! -f "${GH_LOG}" ]
    done
}

@test "a value in CFWF_PRIVATE_OWNERS that is not an owner is a runtime failure" {
    write_visibility "${REPO}" PUBLIC
    write_leak_body "see credfeto/x#1"
    CFWF_PRIVATE_OWNERS="good bad/owner" run_body_check
    [ "${status}" -eq 1 ]
    [[ "${stderr}" == *"CFWF_PRIVATE_OWNERS holds a value that is not an owner"* ]]
}

@test "issue create refuses a body naming a private repository before any board read or write" {
    prepare_issue_create
    write_visibility "${REPO}" PUBLIC
    write_leak_body "see https://github.com/credfeto/hidden-thing/issues/4"
    run_issue_create_leak
    assert_refused "${status}" "${output}" "${stderr}" "private repository" "hidden-thing"
    assert_nothing_created
    [ "$(gh_call_count "label list")" -eq 0 ]
    [ "$(gh_call_count "project field-list")" -eq 0 ]
    [ "$(gh_call_count "--json projectsV2")" -eq 0 ]
}

@test "issue create refuses a title or a label with a token or a host path, naming only the rule, before calling gh" {
    prepare_issue_create
    local leak
    for leak in "fix gh""p_LEAKMARKER0123456789 now" "see /home/someone/work" "set MY_SEC""RET=LEAKMARKER" "clone $(url_with_password https user LEAKMARKER)"; do
        run --separate-stderr "${SCRIPT}" issue create --repo "${REPO}" --priority High --title "repo: ${leak}" --body-file "${TEST_TMP}/body.md"
        [ "${status}" -eq 8 ]
        [[ "${stderr}" == "cfwf: title refused: "@(token|host path) ]]
        [[ "${stderr}" != *LEAKMARKER* && "${stderr}" != *someone* ]]
        [ -z "${output}" ]

        run --separate-stderr "${SCRIPT}" issue create --repo "${REPO}" --priority High --title "repo: T" --body-file "${TEST_TMP}/body.md" --label ok --label "${leak}"
        [ "${status}" -eq 8 ]
        [[ "${stderr}" == "cfwf: label refused: "@(token|host path) ]]
        [[ "${stderr}" != *LEAKMARKER* && "${stderr}" != *someone* ]]
        [ -z "${output}" ]
    done
    [ ! -f "${GH_LOG}" ]

    run --separate-stderr "${SCRIPT}" issue create --repo "${REPO}" --priority High --title "repo: see /tmp/x" --body-file "${TEST_TMP}/body.md"
    [ "${stderr}" = "cfwf: title refused: host path" ]
    run --separate-stderr "${SCRIPT}" issue create --repo "${REPO}" --priority High --title "repo: T" --body-file "${TEST_TMP}/body.md" --label "see /tmp/x"
    [ "${stderr}" = "cfwf: label refused: host path" ]
}

@test "issue create refuses a title or a label naming a private repository on a public target, before any write" {
    prepare_issue_create
    write_visibility "${REPO}" PUBLIC
    write_visibility credfeto/hidden-thing PRIVATE
    run --separate-stderr "${SCRIPT}" issue create --repo "${REPO}" --priority High --title "repo: port credfeto/hidden-thing#3" --body-file "${TEST_TMP}/body.md"
    [ "${status}" -eq 8 ]
    [ "${stderr}" = "cfwf: title refused: private repository" ]
    assert_nothing_created
    [ "$(gh_call_count "label list")" -eq 0 ]

    run --separate-stderr "${SCRIPT}" issue create --repo "${REPO}" --priority High --title "repo: T" --body-file "${TEST_TMP}/body.md" --label "credfeto/hidden-thing#3"
    [ "${status}" -eq 8 ]
    [ "${stderr}" = "cfwf: label refused: private repository" ]
    assert_nothing_created

    fail_visibility credfeto/flaky-thing
    run --separate-stderr "${SCRIPT}" issue create --repo "${REPO}" --priority High --title "repo: see credfeto/flaky-thing#1" --body-file "${TEST_TMP}/body.md"
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: could not read the visibility of the repository named in the title" ]
    assert_nothing_created
}

@test "issue create checks the stdin copy it hands to gh, and refuses a leak there before any write" {
    prepare_issue_create
    run --separate-stderr "${SCRIPT}" issue create --repo "${REPO}" --priority High --title "repo: T" --body-file - <<< "a path /tmp/out"
    [ "${status}" -eq 8 ]
    [ "${stderr}" = "cfwf: body refused: host path (line 1)" ]
    [ ! -f "${GH_LOG}" ]
}

@test "body check reads the body from stdin, and leaves no temporary file behind" {
    local scratch="${TEST_TMP}/tmp"
    mkdir -p "${scratch}"
    write_visibility "${REPO}" PUBLIC
    write_visibility credfeto/open-thing PUBLIC
    TMPDIR="${scratch}" run --separate-stderr "${SCRIPT}" body check --repo "${REPO}" --body-file - <<< "see credfeto/open-thing#1"
    [ "${status}" -eq 0 ]
    [ "$(visibility_lookups credfeto/open-thing)" -eq 1 ]
    [ -z "$(ls -A "${scratch}")" ]

    TMPDIR="${scratch}" run --separate-stderr "${SCRIPT}" body check --repo "${REPO}" --body-file - <<< "see /home/x/y"
    [ "${status}" -eq 8 ]
    [ -z "$(ls -A "${scratch}")" ]
}

@test "body check help and usage errors, none of which call gh" {
    run "${SCRIPT}" body check --help
    [ "${status}" -eq 0 ]
    [[ "${output}" == "Usage: cfwf body check"* ]]

    run "${SCRIPT}" body -h
    [ "${status}" -eq 0 ]
    [[ "${output}" == "Usage: cfwf body check"* ]]

    run --separate-stderr "${SCRIPT}" body
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == *"body needs a subcommand (check)"* ]]

    run --separate-stderr "${SCRIPT}" body frobnicate
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == *"unknown body subcommand (argument 2; its value is not shown)"* && "${stderr}" != *frobnicate* ]]

    printf 'clean\n' > "${TEST_TMP}/leak.md"
    run --separate-stderr "${SCRIPT}" body check --body-file "${TEST_TMP}/leak.md"
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == *"missing required option --repo"* ]]
    [[ "${stderr}" == *"Usage: cfwf body check"* ]]

    run --separate-stderr "${SCRIPT}" body check --repo "${REPO}"
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == *"missing required option --body-file"* ]]

    run --separate-stderr "${SCRIPT}" body check --repo "${REPO}" --body-file "${TEST_TMP}/leak.md" --title T
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == *"unknown option (argument 7; its value is not shown)"* ]]

    run --separate-stderr "${SCRIPT}" body check --repo "${REPO}" --repo credfeto/other --body-file "${TEST_TMP}/leak.md"
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == *"--repo can only be given once"* ]]

    run --separate-stderr "${SCRIPT}" body check --repo "no-slash" --body-file "${TEST_TMP}/leak.md"
    [ "${status}" -eq 2 ]

    local flag
    for flag in --skip-leak-check --force "--repo --body-file"; do
        run --separate-stderr "${SCRIPT}" body check --repo "${REPO}" --body-file "${TEST_TMP}/leak.md" "${flag}"
        [ "${status}" -eq 2 ]
        [[ "${stderr}" == *"unknown option (argument 7; its value is not shown)"* && "${stderr}" != *"${flag}"* ]]
    done
    [ ! -f "${GH_LOG}" ]
}

@test "body check refuses a missing or blank body as a runtime failure, without calling gh" {
    run --separate-stderr "${SCRIPT}" body check --repo "${REPO}" --body-file "${TEST_TMP}/nope.md"
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: cannot read the --body-file" ]

    printf ' \n' > "${TEST_TMP}/blank.md"
    run --separate-stderr "${SCRIPT}" body check --repo "${REPO}" --body-file "${TEST_TMP}/blank.md"
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: the body is empty" ]
    [ ! -f "${GH_LOG}" ]
}
