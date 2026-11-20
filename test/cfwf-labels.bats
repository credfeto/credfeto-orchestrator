#!/usr/bin/env bats
# shellcheck disable=SC2154  # stderr is set by run --separate-stderr

bats_require_minimum_version 1.5.0

load test_helper
load cfwf_helper

# Assigned in cfwf_helper.bash. Declared here, which keeps the value, because shellcheck does not
# follow bats `load` and would otherwise read REPO as a misspelling.
declare -g REPO

# --- issue label-history and pr ready-at ----------------------------------------

# Writes the timeline of the number $1 as several pages, which the gh stub hands to the jq program
# one at a time, as gh --paginate does: each further argument a page (timeline_page).
write_timeline_pages() {
    local number="$1"
    shift
    printf '%s\n' "$@" | jq -s '.' > "$(api_fixture "repos/${REPO}/issues/${number}/timeline").pages"
}

run_label_history() {
    run --separate-stderr "${SCRIPT}" issue label-history --repo "${REPO}" "$@"
}

run_ready_at() {
    run --separate-stderr "${SCRIPT}" pr ready-at --repo "${REPO}" "$@"
}

# Writes what gh prints for the API endpoint $1 as each further argument a line, its fields joined
# by | standing for ROW_SEPARATOR. The stub prints it without running the call's --jq program, so a
# row the program could never give, such as one with a field more or less, can be answered.
write_raw_rows() {
    local endpoint="$1" row
    shift
    for row in "$@"; do
        printf '%s\n' "${row//|/$'\x1f'}"
    done > "$(api_fixture "${endpoint}").out"
}

@test "issue label-history and pr ready-at help, from each -h and from help, gives the usage, the output and the exit codes, help issue and help pr include them, the general help lists both, and none calls gh" {
    local invocation
    for invocation in "issue label-history -h" "issue label-history --help" "help issue label-history" "issue label-history --repo ${REPO} --help --bogus"; do
        # shellcheck disable=SC2086  # each invocation is split into its words on purpose
        run "${SCRIPT}" ${invocation}
        [ "${status}" -eq 0 ]
        [[ "${output}" == "${LABEL_HISTORY_USAGE}"$'\n'* ]]
        [[ "${output}" == *"--json, --jq, --paginate and --limit are not options: every page of the timeline is read"* ]]
        [[ "${output}" == *"  <added|removed>  <time>  <actor>  <label>"* ]]
        [[ "${output}" == *"oldest first (changes made in the same second keep GitHub's order)"* ]]
        [[ "${output}" == *"exactly four tab-separated fields and none is empty"* ]]
        [[ "${output}" == *"ends in [bot], ghost is GitHub's placeholder for an account that was deleted (never a person to"$'\n'"trust), and \"-\" is printed when GitHub names no one"* ]]
        [[ "${output}" == *"label is the name GitHub records on the"$'\n'"change"* ]]
        [[ "${output}" == *"matched without regard to ASCII"$'\n'"         case"*"longer than 50 characters"* ]]
        [[ "${output}" == *"At most 1000 label changes are read, counted before --label is applied. More than that is a"$'\n'"runtime failure and nothing is printed, never part of the list."* ]]
        [[ "${output}" == *"Exit codes: 0 printed, nothing to print included; 9 the issue or pull request does not exist"*"1 a runtime failure"*"2 a usage error." ]]
        [[ "${output}" != *"Usage: cfwf issue view"* && "${output}" != *"Usage: cfwf issue create"* ]]
    done

    for invocation in "pr ready-at -h" "pr ready-at --help" "help pr ready-at"; do
        # shellcheck disable=SC2086  # each invocation is split into its words on purpose
        run "${SCRIPT}" ${invocation}
        [ "${status}" -eq 0 ]
        [[ "${output}" == "${READY_AT_USAGE}"$'\n'* ]]
        [[ "${output}" == *"  ready-at  the time, ISO 8601 in UTC"$'\n'"  source    ready-for-review when ready-at is the time of the last ready_for_review event"* ]]
        [[ "${output}" == *"created when it has none, and ready-at is when the"$'\n'"            pull request was created"* ]]
        [[ "${output}" == *"one opened as a draft and never marked ready: check whether it is a draft now with"$'\n'"'cfwf pr view --field draft'"* ]]
        [[ "${output}" == *"A conversion back to draft after the last ready event is not looked"$'\n'"at."* ]]
        [[ "${output}" == *"Exit codes: 0 printed; 9 the pull request does not exist (the number of an issue included); 1 a"*"2 a usage error." ]]
        [[ "${output}" != *"Usage: cfwf pr checks"* ]]
    done

    run "${SCRIPT}" help issue
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Usage: cfwf issue plan-status"*$'\n\n'"${ISSUE_LIST_USAGE}"$'\n'*$'\n\n'"${ISSUE_SEARCH_USAGE}"$'\n'*$'\n\n'"${LABEL_HISTORY_USAGE}"$'\n'* ]]

    run "${SCRIPT}" help pr
    [ "${status}" -eq 0 ]
    [[ "${output}" == *$'\n'"Run 'cfwf pr ready-at --help' for pr ready-at, which prints when a pull request was last marked"$'\n'"ready for review."$'\n'* ]]

    run "${SCRIPT}" help
    [ "${status}" -eq 0 ]
    [[ "${output}" == *$'\n'"  issue label-history      Print when each label was added to or removed from an issue or PR, and by whom (exit 9 when not found)"$'\n'* ]]
    [[ "${output}" == *$'\n'"  pr ready-at              Print when a PR was last marked ready for review, or when it was created (exit 9 when not found)"$'\n'* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "issue label-history prints each label change as added or removed with its time, actor and label, leaves out every other event, and reads the item and then every page of its timeline" {
    write_issue_kind 7 issue
    write_timeline 7 \
        "$(timeline_event labeled credfeto Medium 2026-10-01T10:00:00Z)" \
        "$(timeline_event commented credfeto "" 2026-10-01T10:01:00Z)" \
        "$(timeline_event unlabeled octocat Medium 2026-10-01T10:02:00Z)" \
        "$(timeline_event ready_for_review credfeto "" 2026-10-01T10:03:00Z)" \
        "$(timeline_event cross-referenced credfeto "" 2026-10-01T10:04:00Z)" \
        "$(timeline_event labeled credfeto Blocked 2026-10-01T10:05:00Z)"
    run_label_history --issue 007
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ "${output}" = "$(tab_row added 2026-10-01T10:00:00Z credfeto Medium)
$(tab_row removed 2026-10-01T10:02:00Z octocat Medium)
$(tab_row added 2026-10-01T10:05:00Z credfeto Blocked)" ]
    has_field_lines "${output}" 3 4

    [ "$(wc -l < "${GH_LOG}")" -eq 2 ]
    [[ "$(sed -n 1p "${GH_LOG}")" == "api repos/${REPO}/issues/7 --jq "* ]]
    [[ "$(sed -n 2p "${GH_LOG}")" == "api repos/${REPO}/issues/7/timeline?per_page=100 --paginate --jq "* ]]
}

@test "issue label-history keeps the timeline's order, changes made in the same second included, and reads a pull request's with --pr" {
    write_issue_kind 8 pull
    write_timeline 8 \
        "$(timeline_event labeled credfeto zeta 2026-10-01T10:00:00Z)" \
        "$(timeline_event labeled credfeto alpha 2026-10-01T10:00:00Z)" \
        "$(timeline_event unlabeled credfeto zeta 2026-10-01T09:59:59Z)"
    run_label_history --pr 8
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(tab_row added 2026-10-01T10:00:00Z credfeto zeta)
$(tab_row added 2026-10-01T10:00:00Z credfeto alpha)
$(tab_row removed 2026-10-01T09:59:59Z credfeto zeta)" ]
}

@test "issue label-history prints - for an actor GitHub gives as null, ghost and an app's login as GitHub gives them, and - for an event with no label" {
    write_issue_kind 7 issue
    write_timeline 7 \
        "$(timeline_event labeled none Medium 2026-10-01T10:00:00Z)" \
        "$(timeline_event labeled ghost Medium 2026-10-01T10:01:00Z)" \
        "$(timeline_event unlabeled 'github-actions[bot]' Medium 2026-10-01T10:02:00Z)" \
        "$(timeline_event labeled credfeto "" 2026-10-01T10:03:00Z)"
    run_label_history --issue 7
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(tab_row added 2026-10-01T10:00:00Z - Medium)
$(tab_row added 2026-10-01T10:01:00Z ghost Medium)
$(tab_row removed 2026-10-01T10:02:00Z 'github-actions[bot]' Medium)
$(tab_row added 2026-10-01T10:03:00Z credfeto -)" ]
    has_field_lines "${output}" 4 4
}

@test "issue label-history keeps a label holding a tab, a newline or a C1 control on one line of four fields" {
    write_issue_kind 7 issue
    write_timeline 7 "$(timeline_event labeled credfeto $'a\tb\nc\xc2\x9bd' 2026-10-01T10:00:00Z)"
    run_label_history --issue 7
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(tab_row added 2026-10-01T10:00:00Z credfeto 'a b c d')" ]
    has_field_lines "${output}" 1 4
}

@test "issue label-history prints nothing and exits 1 for an actor that is not a login or a time that is not GitHub's, even after rows that are" {
    local bad
    write_issue_kind 7 issue
    for bad in "$(timeline_event labeled 'cred feto' Medium 2026-10-01T10:01:00Z)" \
        "$(timeline_event labeled credfeto Medium '2026-10-01 10:01:00')" \
        "$(timeline_event labeled credfeto Medium 2026-10-01T10:01:00+01:00)"; do
        write_timeline 7 "$(timeline_event labeled credfeto Medium 2026-10-01T10:00:00Z)" "${bad}"
        run_label_history --issue 7
        [ "${status}" -eq 1 ]
        [ -z "${output}" ]
        [ "${stderr}" = "${TIMELINE_UNEXPECTED}7" ]
    done
}

@test "issue label-history prints nothing and exits 0 for a timeline with no label change" {
    write_issue_kind 7 issue
    write_timeline 7
    run_label_history --issue 7
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    [ -z "${stderr}" ]

    write_timeline 7 "$(timeline_event commented credfeto "" 2026-10-01T10:00:00Z)"
    run_label_history --issue 7
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ -z "${output}" ]
}

@test "issue label-history --label keeps only the changes of that label, matched without regard to case, and prints nothing for a label that never changed" {
    write_issue_kind 7 issue
    write_timeline 7 \
        "$(timeline_event labeled credfeto Blocked 2026-10-01T10:00:00Z)" \
        "$(timeline_event labeled credfeto Medium 2026-10-01T10:01:00Z)" \
        "$(timeline_event unlabeled octocat Blocked 2026-10-01T10:02:00Z)" \
        "$(timeline_event labeled credfeto 'a,b' 2026-10-01T10:03:00Z)"
    local expected
    expected="$(tab_row added 2026-10-01T10:00:00Z credfeto Blocked)
$(tab_row removed 2026-10-01T10:02:00Z octocat Blocked)"
    run_label_history --issue 7 --label Blocked
    [ "${status}" -eq 0 ]
    [ "${output}" = "${expected}" ]

    run_label_history --label bLOCKED --issue 7
    [ "${status}" -eq 0 ]
    [ "${output}" = "${expected}" ]

    run_label_history --issue 7 --label 'a,b'
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(tab_row added 2026-10-01T10:03:00Z credfeto 'a,b')" ]

    run_label_history --issue 7 --label Block
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "issue label-history prints exactly 1000 label changes, and with 1001 prints none and exits 1, whatever --label keeps" {
    write_issue_kind 7 issue
    jq -n '[range(1000) | {event: "labeled", created_at: "2026-10-01T10:00:00Z", actor: {login: "credfeto"}, label: {name: "label \(.)"}}]
        + [range(5) | {event: "commented", created_at: "2026-10-01T10:00:00Z", actor: {login: "credfeto"}}]' \
        | write_api "repos/${REPO}/issues/7/timeline"
    run_label_history --issue 7
    [ "${status}" -eq 0 ]
    has_field_lines "${output}" 1000 4
    [ "${output%%$'\n'*}" = "$(tab_row added 2026-10-01T10:00:00Z credfeto 'label 0')" ]
    [ "${output##*$'\n'}" = "$(tab_row added 2026-10-01T10:00:00Z credfeto 'label 999')" ]
    [ "${output}" = "$(jq -n -r 'range(1000) | "added\t2026-10-01T10:00:00Z\tcredfeto\tlabel \(.)"')" ]

    jq -n '[range(1001) | {event: "unlabeled", created_at: "2026-10-01T10:00:00Z", actor: {login: "credfeto"}, label: {name: "label \(.)"}}]' \
        | write_api "repos/${REPO}/issues/7/timeline"
    run_label_history --issue 7
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: ${REPO}#7 has more than 1000 label events, so none is printed" ]

    run_label_history --issue 7 --label none
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: ${REPO}#7 has more than 1000 label events, so none is printed" ]
}

@test "issue label-history prints the label changes of every page, in page order" {
    write_issue_kind 7 issue
    write_timeline_pages 7 \
        "$(timeline_page "$(timeline_event labeled credfeto Medium 2026-10-01T10:00:00Z)" "$(timeline_event commented credfeto "" 2026-10-01T10:01:00Z)")" \
        "$(timeline_page "$(timeline_event commented credfeto "" 2026-10-01T10:02:00Z)")" \
        "$(timeline_page "$(timeline_event unlabeled credfeto Medium 2026-10-01T10:03:00Z)" "$(timeline_event labeled octocat Blocked 2026-10-01T10:04:00Z)")"
    run_label_history --issue 7
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(tab_row added 2026-10-01T10:00:00Z credfeto Medium)
$(tab_row removed 2026-10-01T10:03:00Z credfeto Medium)
$(tab_row added 2026-10-01T10:04:00Z octocat Blocked)" ]
}

@test "pr ready-at prints the last ready_for_review event of every page, and ignores a conversion to draft after it" {
    write_issue_kind 8 pull
    write_timeline_pages 8 \
        "$(timeline_page "$(timeline_event ready_for_review credfeto "" 2026-10-02T10:00:00Z)" "$(timeline_event convert_to_draft credfeto "" 2026-10-02T11:00:00Z)")" \
        "$(timeline_page "$(timeline_event ready_for_review octocat "" 2026-10-03T10:00:00Z)" "$(timeline_event labeled credfeto Medium 2026-10-03T10:30:00Z)")" \
        "$(timeline_page "$(timeline_event convert_to_draft credfeto "" 2026-10-04T10:00:00Z)")"
    run_ready_at --pr 0008
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ "${output}" = $'ready-at\t2026-10-03T10:00:00Z\nsource\tready-for-review' ]
    [ "$(wc -l < "${GH_LOG}")" -eq 2 ]
    [[ "$(sed -n 1p "${GH_LOG}")" == "api repos/${REPO}/issues/8 --jq "* ]]
    [[ "$(sed -n 2p "${GH_LOG}")" == "api repos/${REPO}/issues/8/timeline?per_page=100 --paginate --jq "* ]]
}

@test "pr ready-at falls back to when the pull request was created when its timeline has no ready_for_review event" {
    write_issue_kind 8 pull 2026-09-30T08:07:06Z
    write_timeline 8 "$(timeline_event labeled credfeto Medium 2026-10-01T10:00:00Z)" "$(timeline_event convert_to_draft credfeto "" 2026-10-01T11:00:00Z)"
    run_ready_at --pr 8
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ "${output}" = $'ready-at\t2026-09-30T08:07:06Z\nsource\tcreated' ]
}

@test "issue label-history and pr ready-at print nothing and exit 1 for a time that is not GitHub's, on the item or on the last ready_for_review event" {
    write_issue_kind 8 pull 'yesterday'
    write_timeline 8
    run_ready_at --pr 8
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: gh returned an unexpected result for ${REPO}#8" ]
    run_label_history --pr 8
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: gh returned an unexpected result for ${REPO}#8" ]

    write_issue_kind 8 pull
    write_timeline 8 "$(timeline_event ready_for_review credfeto "" 2026-10-01T10:00:00Z)" "$(timeline_event ready_for_review credfeto "" 'soon')"
    run_ready_at --pr 8
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "${TIMELINE_UNEXPECTED}8" ]
}

@test "issue label-history and pr ready-at exit 9 for a number that is not there or is of the other kind, and 1 when the repository is not there" {
    write_this_repository
    run_label_history --issue 7
    [ "${status}" -eq 9 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: ${REPO}#7 was not found" ]
    run_ready_at --pr 7
    [ "${status}" -eq 9 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: ${REPO}#7 was not found" ]

    write_issue_kind 8 pull
    write_timeline 8
    run_label_history --issue 8
    [ "${status}" -eq 9 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: ${REPO}#8 is a pull request, not an issue" ]

    write_issue_kind 7 issue
    write_timeline 7
    run_label_history --pr 7
    [ "${status}" -eq 9 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: the pull request ${REPO}#7 was not found" ]
    run_ready_at --pr 7
    [ "${status}" -eq 9 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: the pull request ${REPO}#7 was not found" ]
    [ "$(gh_call_count "/timeline")" -eq 0 ]

    rm "$(api_fixture "repos/${REPO}").json"
    run_label_history --issue 9
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: the repository ${REPO} was not found, or the caller cannot see it" ]
    run_ready_at --pr 9
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: the repository ${REPO} was not found, or the caller cannot see it" ]
}

@test "issue label-history and pr ready-at exit 1 quoting gh's error for a failed read of the item or the timeline, and for a timeline that is not there after the item was" {
    fail_api "repos/${REPO}/issues/7"
    run_label_history --issue 7
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not read ${REPO}#7: gh: Bad Gateway (HTTP 502)" ]
    run_ready_at --pr 7
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not read ${REPO}#7: gh: Bad Gateway (HTTP 502)" ]
    [ "$(gh_call_count "/timeline")" -eq 0 ]

    write_issue_kind 8 pull
    fail_api "repos/${REPO}/issues/8/timeline"
    run_ready_at --pr 8
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not read the timeline of ${REPO}#8: gh: Bad Gateway (HTTP 502)" ]
    run_label_history --pr 8
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not read the timeline of ${REPO}#8: gh: Bad Gateway (HTTP 502)" ]

    rm "$(api_fixture "repos/${REPO}/issues/8/timeline").fail"
    run_ready_at --pr 8
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "${TIMELINE_UNEXPECTED}8" ]
    run_label_history --pr 8
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "${TIMELINE_UNEXPECTED}8" ]
}

@test "issue label-history and pr ready-at usage errors exit 2 with their own usage before any gh call, never echoing a value" {
    local secret="never-echoed-value"
    local long
    long=$(printf 'x%.0s' {1..51})
    local -a label_cases=(
        "--issue 7"
        "--repo ${REPO}"
        "--repo ${REPO} --issue 7 --pr 8"
        "--repo ${REPO} --pr 8 --pr 9"
        "--repo ${REPO} --issue 7 --issue 7"
        "--repo ${REPO} --repo ${REPO} --issue 7"
        "--repo ${REPO} --issue 0"
        "--repo ${REPO} --issue 000"
        "--repo ${REPO} --pr 0"
        "--repo ${REPO} --issue 7x"
        "--repo ${REPO} --issue"
        "--repo ${REPO} --issue 7 --label a --label b"
        "--repo ${REPO} --issue 7 --label ${long}"
        "--repo ${REPO} --issue 7 --json labels"
        "--repo ${REPO} --issue 7 --jq ."
        "--repo ${REPO} --issue 7 --paginate"
        "--repo ${REPO} --issue 7 --limit 5"
        "--repo x/.. --issue 7"
        "--repo ${REPO} 7"
    )
    local args
    for args in "${label_cases[@]}"; do
        # shellcheck disable=SC2086  # each case is split into its words on purpose
        run --separate-stderr "${SCRIPT}" issue label-history ${args}
        [ "${status}" -eq 2 ] || { echo "accepted: ${args} (${status})" >&2; return 1; }
        [ -z "${output}" ]
        [[ "${stderr}" == "cfwf: "*$'\n\n'"${LABEL_HISTORY_USAGE}"$'\n'* ]]
    done

    run_label_history
    [[ "${stderr}" == "cfwf: missing required option --pr or --issue"$'\n'* ]]
    run_label_history --issue 7 --pr 8
    [[ "${stderr}" == "cfwf: --pr or --issue can only be given once, and not both"$'\n'* ]]
    run_label_history --issue 000
    [[ "${stderr}" == "cfwf: invalid value for --issue: it must be a number above 0"$'\n'* ]]
    run_label_history --pr 0
    [[ "${stderr}" == "cfwf: invalid value for --pr: it must be a number above 0"$'\n'* ]]
    run_label_history --issue 7 --label Blocked --label Medium
    [[ "${stderr}" == "cfwf: --label can only be given once"$'\n'* ]]

    local bad
    for bad in $'a\t'"${secret}" $'a\n'"${secret}" $'a\xc2\x9b'"${secret}" $'a\x7f'"${secret}" "   " "${secret}${long}"; do
        run_label_history --issue 7 --label "${bad}"
        [ "${status}" -eq 2 ]
        [ -z "${output}" ]
        [[ "${stderr}" == "cfwf: invalid value for --label: it must "* && "${stderr}" != *"${secret}"* ]]
    done
    run_label_history --issue 7 --label "   "
    [[ "${stderr}" == "cfwf: invalid value for --label: it must not be blank or longer than 50 characters"$'\n'* ]]
    run_label_history --issue 7 --label $'a\tb'
    [[ "${stderr}" == "cfwf: invalid value for --label: it must not contain a control character"$'\n'* ]]
    run_label_history --issue 7 --label $'a\xc2\x9bb'
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: invalid value for --label: it must not contain a control character"$'\n'* ]]

    local -a ready_cases=(
        "--pr 8"
        "--repo ${REPO}"
        "--repo ${REPO} --pr 0"
        "--repo ${REPO} --pr 8 --pr 9"
        "--repo ${REPO} --issue 8"
        "--repo ${REPO} --pr 8 --label Blocked"
        "--repo ${REPO} --pr 8 --field draft"
        "--repo ${REPO} --pr 8 --json createdAt"
        "--repo ${REPO} --pr 8 --jq ."
        "--repo ${REPO} --pr 8 --paginate"
        "--repo ${REPO} 8"
    )
    for args in "${ready_cases[@]}"; do
        # shellcheck disable=SC2086  # each case is split into its words on purpose
        run --separate-stderr "${SCRIPT}" pr ready-at ${args}
        [ "${status}" -eq 2 ] || { echo "accepted: ${args} (${status})" >&2; return 1; }
        [ -z "${output}" ]
        [[ "${stderr}" == "cfwf: "*$'\n\n'"${READY_AT_USAGE}"$'\n'* ]]
    done
    run_ready_at
    [[ "${stderr}" == "cfwf: missing required option --pr"$'\n'* ]]
    run_ready_at --pr 000
    [[ "${stderr}" == "cfwf: invalid value for --pr: it must be a number above 0"$'\n'* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "issue label-history and pr ready-at print nothing and exit 1 for a row gh prints that is not of the kind, change or field count the program gives" {
    local row
    for row in "thing|${CREATED_AT}|end" "issue|${CREATED_AT}" "issue|${CREATED_AT}|x|end" "pull|${CREATED_AT}|end|x"; do
        write_raw_rows "repos/${REPO}/issues/7" "${row}"
        run_label_history --issue 7
        [ "${status}" -eq 1 ] || { echo "accepted: ${row} (${status})" >&2; return 1; }
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: gh returned an unexpected result for ${REPO}#7" ]
        run_ready_at --pr 7
        [ "${status}" -eq 1 ]
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: gh returned an unexpected result for ${REPO}#7" ]
    done

    rm "$(api_fixture "repos/${REPO}/issues/7").out"
    write_issue_kind 7 issue
    for row in "labeled|2026-10-01T10:00:00Z|credfeto|Medium|end" "added|2026-10-01T10:00:00Z|credfeto|Medium" \
        "removed|2026-10-01T10:00:00Z|credfeto|Medium|x|end"; do
        write_raw_rows "repos/${REPO}/issues/7/timeline" "added|2026-10-01T09:00:00Z|credfeto|Medium|end" "${row}"
        run_label_history --issue 7
        [ "${status}" -eq 1 ] || { echo "accepted: ${row} (${status})" >&2; return 1; }
        [ -z "${output}" ]
        [ "${stderr}" = "${TIMELINE_UNEXPECTED}7" ]
    done

    write_issue_kind 8 pull
    for row in "2026-10-01T10:00:00Z" "2026-10-01T10:00:00Z|x|end"; do
        write_raw_rows "repos/${REPO}/issues/8/timeline" "2026-10-01T09:00:00Z|end" "${row}"
        run_ready_at --pr 8
        [ "${status}" -eq 1 ] || { echo "accepted: ${row} (${status})" >&2; return 1; }
        [ -z "${output}" ]
        [ "${stderr}" = "${TIMELINE_UNEXPECTED}8" ]
    done
}

# --- issue add-sub-issue, label create and pr auto-merge-at --------------------------

SUB_ISSUE_USAGE="Usage: cfwf issue add-sub-issue --repo <owner/repo> --issue <parent> --sub-issue <child>"
LABEL_CREATE_USAGE="Usage: cfwf label create --repo <owner/repo> --name <name> [--color <hex>] [--description <text>]"
AUTO_MERGE_AT_USAGE="Usage: cfwf pr auto-merge-at --repo <owner/repo> --pr <n>"

# The fixture path (without .json or .fail) the gh stub reads for a write with the method $1 to the
# API endpoint $2.
api_write_fixture() {
    local endpoint="${2%%\?*}"
    printf '%s/api-%s-%s' "${GH_FIXTURES}" "$1" "${endpoint//\//_}"
}

# Writes the number $1 as the issues endpoint gives it, with its id ($1 + 5000) and its URL: an
# issue, or a pull request when $2 is pull.
write_issue_with_id() {
    jq -n --argjson n "$1" --arg kind "${2:-issue}" --arg repo "${REPO}" \
        '{number: $n, id: ($n + 5000), title: "a title", state: "open", created_at: "2026-10-01T09:00:00Z",
          html_url: "https://github.com/\($repo)/\(if $kind == "pull" then "pull" else "issues" end)/\($n)"}
         + (if $kind == "pull" then {pull_request: {url: "https://api.github.com/repos/x/y/pulls/\($n)"}} else {} end)' \
        | write_api "repos/${REPO}/issues/$1"
}

# Writes the sub-issues of the parent $1: each further argument a child's number.
write_sub_issues() {
    local parent="$1"
    shift
    printf '%s\n' "$@" | jq -R -s '[split("\n")[:-1][] | select(. != "") | {number: tonumber, id: (tonumber + 5000)}]' \
        | write_api "repos/${REPO}/issues/${parent}/sub_issues"
}

run_sub_issue() {
    run --separate-stderr "${SCRIPT}" issue add-sub-issue --repo "${REPO}" "$@"
}

run_label_create() {
    run --separate-stderr "${SCRIPT}" label create --repo "${REPO}" "$@"
}

run_auto_merge_at() {
    run --separate-stderr "${SCRIPT}" pr auto-merge-at --repo "${REPO}" "$@"
}

# Writes the label $1 with the colour $2 and the description $3 as the repository has it.
write_label() {
    jq -n --arg name "$1" --arg color "$2" --arg description "$3" '{id: 1, name: $name, color: $color, description: $description, default: false}' \
        | write_api "repos/${REPO}/labels/${4:-$1}"
}

@test "issue add-sub-issue, label create and pr auto-merge-at help, from each -h and from help, gives the usage, the output and the exit codes, the group helps include them, the general help lists them, and none calls gh" {
    local invocation
    for invocation in "issue add-sub-issue -h" "issue add-sub-issue --help" "help issue add-sub-issue"; do
        # shellcheck disable=SC2086  # each invocation is split into its words on purpose
        run "${SCRIPT}" ${invocation}
        [ "${status}" -eq 0 ]
        [[ "${output}" == "${SUB_ISSUE_USAGE}"$'\n'* ]]
        [[ "${output}" == *"  result     linked, or already-linked when the child was a sub-issue of the parent already"* ]]
        [[ "${output}" == *"--replace-parent, --json and --jq are not options"* ]]
        [[ "${output}" == *"Exit codes: 0 linked, or already linked; 8 GitHub refused the link"*"9 an issue does not exist, or a number is a pull request's"* ]]
    done
    for invocation in "label create -h" "label create --help" "help label create" "help label" "label -h"; do
        # shellcheck disable=SC2086  # each invocation is split into its words on purpose
        run "${SCRIPT}" ${invocation}
        [ "${status}" -eq 0 ]
        [[ "${output}" == "${LABEL_CREATE_USAGE}"$'\n'* ]]
        [[ "${output}" == *"exists-different when it had it with another colour or description, which is left"* ]]
        [[ "${output}" == *"Exit codes: 0 created or there already; 8 the name is not a standard label"* ]]
    done
    for invocation in "pr auto-merge-at -h" "pr auto-merge-at --help" "help pr auto-merge-at"; do
        # shellcheck disable=SC2086  # each invocation is split into its words on purpose
        run "${SCRIPT}" ${invocation}
        [ "${status}" -eq 0 ]
        [[ "${output}" == "${AUTO_MERGE_AT_USAGE}"$'\n'* ]]
        [[ "${output}" == *"  enabled-at      the time of the last auto_merge_enabled, auto_squash_enabled or"* ]]
        [[ "${output}" == *"A pull request that never had auto-merge prints \"-\" on every line."* ]]
        [[ "${output}" == *"Exit codes: 0 printed; 9 the pull request does not exist"* ]]
    done

    run "${SCRIPT}" help issue
    [[ "${output}" == *"${LABEL_HISTORY_USAGE}"$'\n'*$'\n\n'"${SUB_ISSUE_USAGE}"$'\n'* ]]
    run "${SCRIPT}" help pr
    [[ "${output}" == *$'\n'"Run 'cfwf pr auto-merge-at --help' for pr auto-merge-at, which prints when auto-merge was last"$'\n'"enabled on a pull request."$'\n'* ]]
    run "${SCRIPT}" help
    [[ "${output}" == *$'\n'"  issue add-sub-issue      Link an issue to a parent issue as its sub-issue (exit 8 when refused, 9 when not found)"$'\n'* ]]
    [[ "${output}" == *$'\n'"  pr auto-merge-at         Print when auto-merge was last enabled on a PR and its last change (exit 9 when not found)"$'\n'* ]]
    [[ "${output}" == *$'\n'"  label create             Create one of the standard labels in a repository (exit 8 for any other name)"$'\n'* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "label without a subcommand names its subcommand" {
    run --separate-stderr "${SCRIPT}" label
    [ "${status}" -eq 2 ]
    [ -z "${output}" ]
    [[ "${stderr}" == "cfwf: label needs a subcommand (create, add, remove, list)"$'\n\n'"${LABEL_CREATE_USAGE}"$'\n'* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "issue add-sub-issue usage errors exit 2 with its own usage and nothing on stdout, before any gh call" {
    local args
    for args in "--issue 5" "--sub-issue 6" "--issue 5 --sub-issue 5" "--issue 05 --sub-issue 5" "--issue 0 --sub-issue 6" \
        "--issue 5 --sub-issue 0" "--issue 5 --sub-issue x" "--issue 5 --sub-issue 6 --sub-issue 7" \
        "--issue 5 --issue 6 --sub-issue 7" "--issue 5 --sub-issue 6 --replace-parent" "--issue 5 --sub-issue 6 --json number"; do
        # shellcheck disable=SC2086  # each case is split into its words on purpose
        run_sub_issue ${args}
        [ "${status}" -eq 2 ] || { echo "not a usage error: ${args}" >&2; return 1; }
        [ -z "${output}" ]
        [[ "${stderr}" == *"${SUB_ISSUE_USAGE}"* ]]
    done
    run --separate-stderr "${SCRIPT}" issue add-sub-issue --issue 5 --sub-issue 6
    [ "${status}" -eq 2 ]
    [ ! -f "${GH_LOG}" ]
}

@test "issue add-sub-issue links the child with one POST of its id after reading both issues and every page of the parent's sub-issues, and prints both URLs" {
    write_issue_with_id 5
    write_issue_with_id 7
    printf '%s\n' "$(timeline_page '{"number": 3}' '{"number": 4}')" "$(timeline_page '{"number": 6}')" | jq -s '.' \
        > "$(api_fixture "repos/${REPO}/issues/5/sub_issues").pages"
    jq -n '{number: 5, id: 5005}' > "$(api_write_fixture POST "repos/${REPO}/issues/5/sub_issues").json"
    run_sub_issue --issue 5 --sub-issue 007
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ "${output}" = "$(tab_row parent "https://github.com/${REPO}/issues/5")
$(tab_row sub-issue "https://github.com/${REPO}/issues/7")
$(tab_row result linked)" ]
    [ "$(wc -l < "${GH_LOG}")" -eq 4 ]
    [[ "$(sed -n 3p "${GH_LOG}")" == "api repos/${REPO}/issues/5/sub_issues?per_page=100 --paginate --jq "* ]]
    [[ "$(sed -n 4p "${GH_LOG}")" == "api --method POST repos/${REPO}/issues/5/sub_issues -F sub_issue_id=5007 --jq "* ]]
}

@test "issue add-sub-issue writes nothing and exits 0 when the child is already a sub-issue of the parent" {
    write_issue_with_id 5
    write_issue_with_id 7
    write_sub_issues 5 3 7
    run_sub_issue --issue 5 --sub-issue 7
    [ "${status}" -eq 0 ]
    [ "${output##*$'\n'}" = "$(tab_row result already-linked)" ]
    [ "$(grep -c -- '--method' "${GH_LOG}")" -eq 0 ]
}

@test "issue add-sub-issue exits 8 when GitHub refuses the link with 422, and 1 saying it may be linked for any other failed write" {
    write_issue_with_id 5
    write_issue_with_id 7
    write_sub_issues 5
    printf '%s\n' "gh: Validation Failed (HTTP 422)" > "$(api_write_fixture POST "repos/${REPO}/issues/5/sub_issues").fail"
    run_sub_issue --issue 5 --sub-issue 7
    [ "${status}" -eq 8 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: sub-issue refused: GitHub refused the link (the child may already have another parent)" ]

    printf '%s\n' "gh: Bad Gateway (HTTP 502)" > "$(api_write_fixture POST "repos/${REPO}/issues/5/sub_issues").fail"
    run_sub_issue --issue 5 --sub-issue 7
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == "cfwf: could not link ${REPO}#7 to ${REPO}#5, and it may have been linked: gh: Bad Gateway (HTTP 502)" ]]
}

@test "issue add-sub-issue exits 9 for a number that is not there or is a pull request's, and 1 when the repository is not there, writing nothing" {
    write_this_repository
    write_issue_with_id 5
    run_sub_issue --issue 5 --sub-issue 7
    [ "${status}" -eq 9 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: ${REPO}#7 was not found" ]

    write_issue_with_id 7 pull
    run_sub_issue --issue 5 --sub-issue 7
    [ "${status}" -eq 9 ]
    [ "${stderr}" = "cfwf: ${REPO}#7 is a pull request, not an issue" ]

    run_sub_issue --issue 7 --sub-issue 5
    [ "${status}" -eq 9 ]
    [ "${stderr}" = "cfwf: ${REPO}#7 is a pull request, not an issue" ]

    rm "$(api_fixture "repos/${REPO}").json"
    run_sub_issue --issue 9 --sub-issue 5
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: the repository ${REPO} was not found, or the caller cannot see it" ]
    [ "$(grep -c -- '--method' "${GH_LOG}")" -eq 0 ]
}

@test "issue add-sub-issue exits 1 for an answer that is not the issue, its sub-issues or the parent it linked" {
    jq -n '{number: 5, id: "x", html_url: "https://github.com/credfeto/credfeto-orchestrator/issues/5"}' | write_api "repos/${REPO}/issues/5"
    write_issue_with_id 7
    run_sub_issue --issue 5 --sub-issue 7
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: gh returned an unexpected result for ${REPO}#5" ]

    jq -n '{number: 5, id: 5005, html_url: "https://github.com/credfeto/credfeto-orchestrator/issues/6"}' | write_api "repos/${REPO}/issues/5"
    run_sub_issue --issue 5 --sub-issue 7
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: gh returned an unexpected result for ${REPO}#5" ]

    write_issue_with_id 5
    jq -n '[{number: "x"}]' | write_api "repos/${REPO}/issues/5/sub_issues"
    run_sub_issue --issue 5 --sub-issue 7
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: gh returned an unexpected result for the sub-issues of ${REPO}#5" ]

    write_sub_issues 5
    jq -n '{number: 6}' > "$(api_write_fixture POST "repos/${REPO}/issues/5/sub_issues").json"
    run_sub_issue --issue 5 --sub-issue 7
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: ${REPO}#7 may have been linked to ${REPO}#5 (gh returned an unexpected answer); run this again to check" ]
}

@test "issue add-sub-issue reads at most 1000 sub-issues, and with 1001 links nothing and exits 1" {
    write_issue_with_id 5
    write_issue_with_id 2000
    jq -n '[range(1; 1001) | {number: .}]' | write_api "repos/${REPO}/issues/5/sub_issues"
    jq -n '{number: 5}' > "$(api_write_fixture POST "repos/${REPO}/issues/5/sub_issues").json"
    run_sub_issue --issue 5 --sub-issue 2000
    [ "${status}" -eq 0 ]
    [ "${output##*$'\n'}" = "$(tab_row result linked)" ]

    jq -n '[range(1; 1002) | {number: .}]' | write_api "repos/${REPO}/issues/5/sub_issues"
    : > "${GH_LOG}"
    run_sub_issue --issue 5 --sub-issue 2000
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: ${REPO}#5 has more than 1000 sub-issues, so nothing is linked" ]
    [ "$(grep -c -- '--method' "${GH_LOG}")" -eq 0 ]
}

@test "label create refuses a name that is not a standard label with exit 8, and a bad colour or description with exit 2, before any gh call" {
    local args
    run_label_create --name "Not A Label"
    [ "${status}" -eq 8 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: label refused: not a standard label: only the labels the repositories share can be created" ]
    for args in "--name Blocked --color ff00" "--name Blocked --color #ff0000" "--name Blocked --color gggggg" "--name Blocked --color ff00001" \
        "--color ff0000" "--name Blocked --name High" "--name Blocked --force"; do
        # shellcheck disable=SC2086  # each case is split into its words on purpose
        run_label_create ${args}
        [ "${status}" -eq 2 ] || { echo "not a usage error: ${args}" >&2; return 1; }
        [[ "${stderr}" == *"${LABEL_CREATE_USAGE}"* ]]
    done
    run_label_create --name Blocked --description "$(printf 'a\tb')"
    [ "${status}" -eq 2 ]
    run_label_create --name Blocked --description "$(printf 'x%.0s' {1..101})"
    [ "${status}" -eq 2 ]
    run --separate-stderr "${SCRIPT}" label create --name Blocked
    [ "${status}" -eq 2 ]
    [ ! -f "${GH_LOG}" ]
}

@test "label create creates a standard label in its standard spelling, colour and description with one POST after reading the label and the repository" {
    write_this_repository
    jq -n '{id: 9, name: "On Hold", color: "ff0000", description: "Do not work on this"}' > "$(api_write_fixture POST "repos/${REPO}/labels").json"
    run_label_create --name "on hold"
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ "${output}" = "$(tab_row label "On Hold")
$(tab_row color ff0000)
$(tab_row description "Do not work on this")
$(tab_row result created)" ]
    [[ "$(sed -n 1p "${GH_LOG}")" == "api repos/${REPO}/labels/On%20Hold --jq "* ]]
    [[ "$(sed -n 2p "${GH_LOG}")" == "api repos/${REPO} --jq "* ]]
    [[ "$(sed -n 3p "${GH_LOG}")" == "api --method POST repos/${REPO}/labels -f name=On Hold -f color=ff0000 -f description=Do not work on this --jq "* ]]
}

@test "label create uses the colour and description given, the colour in lower case" {
    write_this_repository
    jq -n '{id: 9, name: "High", color: "abcdef", description: "Most important"}' > "$(api_write_fixture POST "repos/${REPO}/labels").json"
    run_label_create --name High --color ABCDEF --description "Most important"
    [ "${status}" -eq 0 ]
    [ "${output##*$'\n'}" = "$(tab_row result created)" ]
    grep -q -- "-f color=abcdef -f description=Most important" "${GH_LOG}"
}

@test "label create reports exists or exists-different for a label the repository has, never changing it" {
    write_label Blocked FF0000 "Blocked by a dependency or external factor"
    run_label_create --name blocked
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(tab_row label Blocked)
$(tab_row color ff0000)
$(tab_row description "Blocked by a dependency or external factor")
$(tab_row result exists)" ]

    write_label Blocked 00ff00 "Something else"
    run_label_create --name Blocked
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(tab_row label Blocked)
$(tab_row color 00ff00)
$(tab_row description "Something else")
$(tab_row result exists-different)" ]
    [ "$(grep -c -- '--method' "${GH_LOG}")" -eq 0 ]
}

@test "label create reports a label that turned up between the read and the create as there, and exits 1 for any other failed create or a missing repository" {
    write_this_repository
    local post
    post="$(api_write_fixture POST "repos/${REPO}/labels")"
    printf '%s\n' "gh: Validation Failed (HTTP 422) already_exists" > "${post}.fail"
    mkdir -p "${post}.then"
    jq -n '{name: "Urgent", color: "ff0000", description: "Urgent Priority"}' > "${post}.then/$(basename "$(api_fixture "repos/${REPO}/labels/Urgent")").json"
    run_label_create --name Urgent
    [ "${status}" -eq 0 ]
    [ "${output##*$'\n'}" = "$(tab_row result exists)" ]

    rm -rf "${post}.then" "$(api_fixture "repos/${REPO}/labels/Urgent").json"
    printf '%s\n' "gh: Bad Gateway (HTTP 502)" > "${post}.fail"
    run_label_create --name Urgent
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not create the label Urgent in ${REPO}: gh: Bad Gateway (HTTP 502)" ]

    rm "$(api_fixture "repos/${REPO}").json"
    run_label_create --name Urgent
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: the repository ${REPO} was not found, or the caller cannot see it" ]
}

@test "label create refuses a description that leaks with exit 8, before any write" {
    write_this_repository
    run_label_create --name Blocked --description "see /home/someone/notes"
    [ "${status}" -eq 8 ]
    [ -z "${output}" ]
    [[ "${stderr}" == "cfwf: description refused: "* ]]
    [ ! -f "${GH_LOG}" ] || [ "$(grep -c -- '--method' "${GH_LOG}")" -eq 0 ]
}

@test "label create percent-encodes a name for the label path, and exits 1 for an answer that is not the label" {
    write_label "C#" db6baa "C# Source Files" "C%23"
    run_label_create --name "c#"
    [ "${status}" -eq 0 ]
    [ "${output##*$'\n'}" = "$(tab_row result exists)" ]
    [[ "$(sed -n 1p "${GH_LOG}")" == "api repos/${REPO}/labels/C%23 --jq "* ]]

    write_label "Other" db6baa "C# Source Files" "C%23"
    run_label_create --name "C#"
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: gh returned an unexpected result for the label C# of ${REPO}" ]
}

@test "pr auto-merge-at prints the last enable of any merge method and the last change, from every page of the timeline" {
    write_issue_kind 8 pull
    write_timeline_pages 8 \
        "$(timeline_page "$(timeline_event auto_merge_enabled credfeto "" 2026-10-02T10:00:00Z)" "$(timeline_event labeled credfeto Medium 2026-10-02T10:30:00Z)")" \
        "$(timeline_page "$(timeline_event auto_merge_disabled octocat "" 2026-10-03T10:00:00Z)" "$(timeline_event auto_squash_enabled dnyw4l3n13 "" 2026-10-04T10:00:00Z)")" \
        "$(timeline_page "$(timeline_event auto_merge_disabled none "" 2026-10-05T10:00:00Z)")"
    run_auto_merge_at --pr 0008
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ "${output}" = $'enabled-at\t2026-10-04T10:00:00Z\nenabled-by\tdnyw4l3n13\nlast-change\tdisabled\nlast-change-at\t2026-10-05T10:00:00Z\nlast-change-by\t-' ]
    [ "$(wc -l < "${GH_LOG}")" -eq 2 ]
    [[ "$(sed -n 2p "${GH_LOG}")" == "api repos/${REPO}/issues/8/timeline?per_page=100 --paginate --jq "* ]]
}

@test "pr auto-merge-at prints - on every line for a pull request that never had auto-merge, and an enable as the last change" {
    write_issue_kind 8 pull
    write_timeline 8 "$(timeline_event labeled credfeto Medium 2026-10-01T10:00:00Z)"
    run_auto_merge_at --pr 8
    [ "${status}" -eq 0 ]
    [ "${output}" = $'enabled-at\t-\nenabled-by\t-\nlast-change\t-\nlast-change-at\t-\nlast-change-by\t-' ]

    write_timeline 8 "$(timeline_event auto_rebase_enabled credfeto "" 2026-10-01T10:00:00Z)"
    run_auto_merge_at --pr 8
    [ "${status}" -eq 0 ]
    [ "${output}" = $'enabled-at\t2026-10-01T10:00:00Z\nenabled-by\tcredfeto\nlast-change\tenabled\nlast-change-at\t2026-10-01T10:00:00Z\nlast-change-by\tcredfeto' ]
}

@test "pr auto-merge-at exits 9 for an issue's number or one that is not there, 2 for a usage error before any gh call, and 1 for an unexpected event row or too many events" {
    local args
    for args in "" "--pr 0" "--pr x" "--pr 8 --pr 9" "--pr 8 --field auto-merge" "--issue 8"; do
        # shellcheck disable=SC2086  # each case is split into its words on purpose
        run_auto_merge_at ${args}
        [ "${status}" -eq 2 ] || { echo "not a usage error: ${args}" >&2; return 1; }
        [[ "${stderr}" == *"${AUTO_MERGE_AT_USAGE}"* ]]
    done
    [ ! -f "${GH_LOG}" ]

    write_this_repository
    run_auto_merge_at --pr 7
    [ "${status}" -eq 9 ]
    [ "${stderr}" = "cfwf: ${REPO}#7 was not found" ]
    write_issue_kind 7 issue
    run_auto_merge_at --pr 7
    [ "${status}" -eq 9 ]
    [ -z "${output}" ]

    write_issue_kind 8 pull
    write_timeline 8 "$(timeline_event auto_merge_enabled credfeto "" soon)"
    run_auto_merge_at --pr 8
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "${TIMELINE_UNEXPECTED}8" ]

    write_timeline 8 "$(timeline_event auto_merge_enabled 'bad login' "" 2026-10-01T10:00:00Z)"
    run_auto_merge_at --pr 8
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "${TIMELINE_UNEXPECTED}8" ]

    jq -n '[range(1001) | {event: "auto_merge_enabled", created_at: "2026-10-01T10:00:00Z", actor: {login: "credfeto"}}]' \
        | write_api "repos/${REPO}/issues/8/timeline"
    run_auto_merge_at --pr 8
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: ${REPO}#8 has more than 1000 auto-merge events, so none is printed" ]
}

# --- label add, label remove and label list (#1593, #1595) ----------------------

LABEL_ISSUE=1346
LABEL_ISSUE_URL="https://github.com/${REPO}/issues/${LABEL_ISSUE}"
LABEL_PR=1701
LABEL_PR_URL="https://github.com/${REPO}/pull/${LABEL_PR}"
LABEL_HUMAN=credfeto

# Writes the number $1 as the issues endpoint gives it, an issue or a pull request ($2, issue or
# pull), carrying the labels given as the further arguments.
write_label_target() {
    local number="$1" kind="$2" url
    shift 2
    url="https://github.com/${REPO}/issues/${number}"
    [ "${kind}" = issue ] || url="https://github.com/${REPO}/pull/${number}"
    jq -n --argjson n "${number}" --arg kind "${kind}" --arg url "${url}" --args \
        '{number: $n, html_url: $url, state: "open", created_at: "2026-10-01T09:00:00Z",
          labels: ($ARGS.positional | map({id: 1, name: ., color: "ffffff"}))}
         + (if $kind == "pull" then {pull_request: {url: "https://api.github.com/repos/x/y/pulls/\($n)", merged_at: null}} else {} end)' \
        "$@" | write_api "repos/${REPO}/issues/${number}"
}

# The repository has every label these tests use.
prepare_labels() {
    write_repository_labels AI-Work Blocked Bug "On Hold" High Enhancement "Tech Debt"
    write_agent_login
}

run_label() {
    run --separate-stderr "${SCRIPT}" label "$@"
}

@test "label add, label remove and label list help, from -h, --help and help, describe the rules and none calls gh; the general help lists all three" {
    local invocation
    for invocation in "label add -h" "label add --help" "help label add"; do
        # shellcheck disable=SC2086  # each invocation is several words on purpose
        run "${SCRIPT}" ${invocation}
        [ "${status}" -eq 0 ]
        [[ "${output}" == "Usage: cfwf label add --repo <owner/repo> (--issue <n> | --pr <n>) --label <name> [--label <name> ...]"* ]]
        [[ "${output}" == *"label add creates none"* ]]
    done
    run "${SCRIPT}" help label remove
    [ "${status}" -eq 0 ]
    [[ "${output}" == "Usage: cfwf label remove --repo <owner/repo> (--issue <n> | --pr <n>) --label <name> [--label <name> ...]"* ]]
    [[ "${output}" == *"On Hold  is never removed"* ]]
    [[ "${output}" == *"added by the agent's own login"* ]]
    run "${SCRIPT}" label list --help
    [ "${status}" -eq 0 ]
    [[ "${output}" == "Usage: cfwf label list --repo <owner/repo>"* ]]
    run "${SCRIPT}" help label
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"cfwf label add"*"cfwf label remove"*"cfwf label list"* ]]
    run "${SCRIPT}" help
    [[ "${output}" == *$'\n'"  label add                Add standard labels to an issue or PR, one gh call a label (exit 8 when refused, 9 when not found)"$'\n'* ]]
    [[ "${output}" == *$'\n'"  label remove             Remove labels from an issue or PR: never On Hold, Blocked only when the agent added it (exit 8 refused, 9 not found)"$'\n'* ]]
    [[ "${output}" == *$'\n'"  label list               List a repository's label names, one a line"$'\n'* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "label needs a subcommand, and an unknown one is refused" {
    run --separate-stderr "${SCRIPT}" label
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: label needs a subcommand (create, add, remove, list)"* ]]
    run --separate-stderr "${SCRIPT}" label frobnicate
    [ "${status}" -eq 2 ]
    [[ "${stderr}" != *frobnicate* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "label add adds each label to an issue with one gh issue edit --add-label a label, in its standard spelling and once, then prints the URL, the changes and the labels" {
    prepare_labels
    write_label_target "${LABEL_ISSUE}" issue AI-Work
    run_label add --repo "${REPO}" --issue "${LABEL_ISSUE}" --label blocked --label "tech debt" --label BLOCKED
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ "${output}" = "url"$'\t'"${LABEL_ISSUE_URL}"$'\n'"add"$'\t'"Blocked"$'\t'"added"$'\n'"add"$'\t'"Tech Debt"$'\t'"added"$'\n'"label"$'\t'"AI-Work"$'\n'"label"$'\t'"Blocked"$'\n'"label"$'\t'"Tech Debt" ]
    [ "$(gh_call_count "issue edit ${LABEL_ISSUE} --repo ${REPO} --add-label Blocked")" -eq 1 ]
    [ "$(gh_call_count "issue edit ${LABEL_ISSUE} --repo ${REPO} --add-label Tech Debt")" -eq 1 ]
    [ "$(gh_call_count "--add-label")" -eq 2 ]
    [ "$(gh_call_count "--label")" -eq 0 ]
}

@test "label add on a pull request uses gh pr edit" {
    prepare_labels
    write_label_target "${LABEL_PR}" pull
    run_label add --repo "${REPO}" --pr "${LABEL_PR}" --label Blocked
    [ "${status}" -eq 0 ]
    [[ "${output}" == "url"$'\t'"${LABEL_PR_URL}"$'\n'"add"$'\t'"Blocked"$'\t'"added"$'\n'* ]]
    [ "$(gh_call_count "pr edit ${LABEL_PR} --repo ${REPO} --add-label Blocked")" -eq 1 ]
    [ "$(gh_call_count "issue edit")" -eq 0 ]
}

@test "label add is idempotent: a label the item was read to carry prints present and is still added, because a read can lag behind a write" {
    prepare_labels
    write_label_target "${LABEL_ISSUE}" issue Blocked
    run_label add --repo "${REPO}" --issue "${LABEL_ISSUE}" --label Blocked
    [ "${status}" -eq 0 ]
    [ "${output}" = "url"$'\t'"${LABEL_ISSUE_URL}"$'\n'"add"$'\t'"Blocked"$'\t'"present"$'\n'"label"$'\t'"Blocked" ]
    [ "$(gh_call_count "--add-label Blocked")" -eq 1 ]
}

@test "label add and label remove refuse (exit 8) a priority label and one that is not standard, before any gh call, never echoing the non-standard name" {
    local change
    for change in add remove; do
        run_label "${change}" --repo "${REPO}" --issue "${LABEL_ISSUE}" --label Blocked --label high
        [ "${status}" -eq 8 ]
        [ "${stderr}" = "cfwf: label refused: High is a priority label; label add and label remove never change a priority" ]
        run_label "${change}" --repo "${REPO}" --issue "${LABEL_ISSUE}" --label urgent
        [ "${status}" -eq 8 ]
        run_label "${change}" --repo "${REPO}" --issue "${LABEL_ISSUE}" --label ghp_notalabel
        [ "${status}" -eq 8 ]
        [ "${stderr}" = "cfwf: label refused: a --label is not one of the standard labels" ]
    done
    [ ! -f "${GH_LOG}" ]
}

@test "label add and label remove refuse (exit 2) a comma-joined, blank or control-character --label, before any gh call" {
    local bad
    for bad in "AI-Work,Medium" "" "   " $'Blo\x01cked'; do
        run_label add --repo "${REPO}" --issue "${LABEL_ISSUE}" --label "${bad}"
        [ "${status}" -eq 2 ]
    done
    run_label remove --repo "${REPO}" --issue "${LABEL_ISSUE}" --label "Blocked,On Hold"
    [ "${status}" -eq 2 ]
    [ ! -f "${GH_LOG}" ]
}

@test "label add refuses (exit 8) a label the repository does not have, creating none and writing nothing" {
    write_repository_labels AI-Work
    write_label_target "${LABEL_ISSUE}" issue
    run_label add --repo "${REPO}" --issue "${LABEL_ISSUE}" --label AI-Work --label Blocked
    [ "${status}" -eq 8 ]
    [ "${stderr}" = "cfwf: label refused: ${REPO} has no label Blocked; it must be created first" ]
    [ "$(gh_call_count "edit")" -eq 0 ]
    [ "$(gh_call_count "label create")" -eq 0 ]
}

@test "label remove refuses (exit 8) On Hold, in any case, before any gh call" {
    run_label remove --repo "${REPO}" --issue "${LABEL_ISSUE}" --label Bug --label "on hold"
    [ "${status}" -eq 8 ]
    [ "${stderr}" = "cfwf: label refused: On Hold is set and lifted by a human, never removed with cfwf" ]
    [ ! -f "${GH_LOG}" ]
}

@test "label add may add On Hold and Blocked: only their removal is a human's" {
    prepare_labels
    write_label_target "${LABEL_ISSUE}" issue
    run_label add --repo "${REPO}" --issue "${LABEL_ISSUE}" --label "On Hold" --label Blocked
    [ "${status}" -eq 0 ]
    [ "$(gh_call_count "--add-label On Hold")" -eq 1 ]
    [ "$(gh_call_count "--add-label Blocked")" -eq 1 ]
}

@test "label remove removes Blocked when the agent added it last, reading the agent's login and the item's timeline first" {
    prepare_labels
    write_label_target "${LABEL_ISSUE}" issue AI-Work Blocked
    write_timeline "${LABEL_ISSUE}" \
        "$(timeline_event labeled "${LABEL_HUMAN}" Blocked 2026-10-02T09:00:00Z)" \
        "$(timeline_event unlabeled "${LABEL_HUMAN}" Blocked 2026-10-03T09:00:00Z)" \
        "$(timeline_event labeled "${AGENT}" Blocked 2026-10-04T09:00:00Z)"
    run_label remove --repo "${REPO}" --issue "${LABEL_ISSUE}" --label Blocked
    [ "${status}" -eq 0 ]
    [ "${output}" = "url"$'\t'"${LABEL_ISSUE_URL}"$'\n'"remove"$'\t'"Blocked"$'\t'"removed"$'\n'"label"$'\t'"AI-Work" ]
    [ "$(gh_call_count "issue edit ${LABEL_ISSUE} --repo ${REPO} --remove-label Blocked")" -eq 1 ]
    [ "$(gh_line_of "api user")" -lt "$(gh_line_of "--remove-label")" ]
    [ "$(gh_line_of "timeline")" -lt "$(gh_line_of "--remove-label")" ]
}

@test "label remove refuses (exit 8) Blocked a human added last, even when the agent added it before, and even when the item is read not to carry it" {
    local carried
    prepare_labels
    write_timeline "${LABEL_ISSUE}" \
        "$(timeline_event labeled "${AGENT}" Blocked 2026-10-02T09:00:00Z)" \
        "$(timeline_event unlabeled "${AGENT}" Blocked 2026-10-03T09:00:00Z)" \
        "$(timeline_event labeled "${LABEL_HUMAN}" blocked 2026-10-04T09:00:00Z)"
    for carried in Blocked ""; do
        # shellcheck disable=SC2086  # an empty label list on purpose
        write_label_target "${LABEL_ISSUE}" issue AI-Work ${carried}
        run_label remove --repo "${REPO}" --issue "${LABEL_ISSUE}" --label AI-Work --label Blocked
        [ "${status}" -eq 8 ]
        [ "${stderr}" = "cfwf: label refused: Blocked was last added by someone other than the agent, so only a human can remove it" ]
        [ -z "${output}" ]
    done
    [ "$(gh_call_count "edit")" -eq 0 ]
}

@test "label remove refuses (exit 8) Blocked added last by a ghost, an actor GitHub gives as null" {
    prepare_labels
    write_label_target "${LABEL_ISSUE}" issue Blocked
    write_timeline "${LABEL_ISSUE}" "$(timeline_event labeled none Blocked 2026-10-04T09:00:00Z)"
    run_label remove --repo "${REPO}" --issue "${LABEL_ISSUE}" --label Blocked
    [ "${status}" -eq 8 ]
    [ "$(gh_call_count "edit")" -eq 0 ]
}

@test "label remove prints absent and writes nothing for Blocked the timeline shows was never added" {
    prepare_labels
    write_label_target "${LABEL_ISSUE}" issue AI-Work
    write_timeline "${LABEL_ISSUE}" "$(timeline_event labeled "${LABEL_HUMAN}" AI-Work 2026-10-04T09:00:00Z)"
    run_label remove --repo "${REPO}" --issue "${LABEL_ISSUE}" --label Blocked
    [ "${status}" -eq 0 ]
    [ "${output}" = "url"$'\t'"${LABEL_ISSUE_URL}"$'\n'"remove"$'\t'"Blocked"$'\t'"absent"$'\n'"label"$'\t'"AI-Work" ]
    [ "$(gh_call_count "edit")" -eq 0 ]
}

@test "label remove of another label needs no timeline read, prints absent for one the item was read not to carry and still removes it, and skips one the repository does not have" {
    write_repository_labels AI-Work Bug
    write_label_target "${LABEL_PR}" pull AI-Work
    run_label remove --repo "${REPO}" --pr "${LABEL_PR}" --label Bug --label AI-Work --label Enhancement
    [ "${status}" -eq 0 ]
    [ "${output}" = "url"$'\t'"${LABEL_PR_URL}"$'\n'"remove"$'\t'"Bug"$'\t'"absent"$'\n'"remove"$'\t'"AI-Work"$'\t'"removed"$'\n'"remove"$'\t'"Enhancement"$'\t'"absent" ]
    [ "$(gh_call_count "pr edit ${LABEL_PR} --repo ${REPO} --remove-label Bug")" -eq 1 ]
    [ "$(gh_call_count "pr edit ${LABEL_PR} --repo ${REPO} --remove-label AI-Work")" -eq 1 ]
    [ "$(gh_call_count "--remove-label Enhancement")" -eq 0 ]
    [ "$(gh_call_count "timeline")" -eq 0 ]
    [ "$(gh_call_count "api user")" -eq 0 ]
}

@test "label add and label remove exit 9 for a number that is not there or is of the other kind, writing nothing" {
    prepare_labels
    write_this_repository
    run_label add --repo "${REPO}" --issue "${LABEL_ISSUE}" --label Blocked
    [ "${status}" -eq 9 ]
    [ "${stderr}" = "cfwf: ${REPO}#${LABEL_ISSUE} was not found" ]
    write_label_target "${LABEL_ISSUE}" pull
    run_label add --repo "${REPO}" --issue "${LABEL_ISSUE}" --label Blocked
    [ "${status}" -eq 9 ]
    [ "${stderr}" = "cfwf: ${REPO}#${LABEL_ISSUE} is a pull request, not an issue" ]
    write_label_target "${LABEL_PR}" issue
    run_label remove --repo "${REPO}" --pr "${LABEL_PR}" --label Bug
    [ "${status}" -eq 9 ]
    [ "${stderr}" = "cfwf: the pull request ${REPO}#${LABEL_PR} was not found" ]
    [ "$(gh_call_count "edit")" -eq 0 ]
}

@test "label add fails (exit 1) naming the labels already changed when a write fails part way" {
    prepare_labels
    write_label_target "${LABEL_ISSUE}" issue
    echo "HTTP 502: Bad Gateway" > "${GH_FIXTURES}/issue-edit.fail"
    run_label add --repo "${REPO}" --issue "${LABEL_ISSUE}" --label Bug
    [ "${status}" -eq 1 ]
    [[ "${stderr}" == "cfwf: could not add the label Bug to ${REPO}#${LABEL_ISSUE}: "* ]]
    [ -z "${output}" ]
}

@test "label add and label remove fail (exit 1) for an item answer that is not of the shape asked for, writing nothing" {
    prepare_labels
    jq -n --arg url "https://github.com/${REPO}/issues/9999" '{number: 1346, html_url: $url, labels: []}' | write_api "repos/${REPO}/issues/${LABEL_ISSUE}"
    run_label add --repo "${REPO}" --issue "${LABEL_ISSUE}" --label Bug
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: gh returned an unexpected result for ${REPO}#${LABEL_ISSUE}" ]
    [ "$(gh_call_count "edit")" -eq 0 ]
}

@test "label add and label remove usage errors exit 2 before any gh call" {
    run_label add --repo "${REPO}" --issue "${LABEL_ISSUE}"
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == *"missing required option --label"* ]]
    run_label add --repo "${REPO}" --label Bug
    [ "${status}" -eq 2 ]
    run_label add --repo "${REPO}" --issue 1 --pr 2 --label Bug
    [ "${status}" -eq 2 ]
    run_label remove --repo "${REPO}" --pr 0 --label Bug
    [ "${status}" -eq 2 ]
    run_label remove --issue 1 --label Bug
    [ "${status}" -eq 2 ]
    run_label add --repo "${REPO}" --issue 1 --label Bug --add-label Bug
    [ "${status}" -eq 2 ]
    [ ! -f "${GH_LOG}" ]
}

@test "label list prints each label name on its own line, asking gh for at most 1000 names" {
    write_repository_labels AI-Work Blocked "On Hold"
    run_label list --repo "${REPO}"
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ "${output}" = "AI-Work"$'\n'"Blocked"$'\n'"On Hold" ]
    grep -qF "label list --repo ${REPO} --limit 1000 --json name" "${GH_LOG}"
}

@test "label list prints nothing for a repository with no label, warns at 1000 labels, and fails (exit 1) on a failed read" {
    write_repository_labels
    run_label list --repo "${REPO}"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    jq -n '[range(1000) | {name: "label-\(.)"}]' > "${GH_FIXTURES}/label-list.json"
    run_label list --repo "${REPO}"
    [ "${status}" -eq 0 ]
    [ "$(printf '%s\n' "${output}" | wc -l)" -eq 1000 ]
    [ "${stderr}" = "cfwf: warning: ${REPO} has at least 1000 labels; only the first 1000 are listed" ]
    touch "${GH_FIXTURES}/label-list.fail"
    run_label list --repo "${REPO}"
    [ "${status}" -eq 1 ]
    [[ "${stderr}" == *"cfwf: could not read the labels of ${REPO}" ]]
    [ -z "${output}" ]
}

@test "label list usage errors exit 2 before any gh call" {
    run_label list
    [ "${status}" -eq 2 ]
    run_label list --repo "${REPO}" --limit 5
    [ "${status}" -eq 2 ]
    [ ! -f "${GH_LOG}" ]
}

# --- pr sync-labels (#1603) --------------------------------------------------------

# Succeeds when no gh call removed a label or wrote anything but a pr edit of SYNC_PR.
no_label_removed() {
    [ "$(gh_call_count "remove")" -eq 0 ]
    [ "$(gh_call_count "issue edit")" -eq 0 ]
    [ "$(grep -c ' edit ' "${GH_LOG}" || true)" -eq "$(gh_call_count "pr edit ${SYNC_PR} --repo ${REPO} --add-")" ]
}

@test "pr sync-labels adds each label of the closing issues, one from an issue in another repository included, in the repository's spelling, one gh call a label" {
    write_sync_pr "${REPO} 10" "other-org/other-repo 11"
    write_sync_issue_labels 10 Medium AI-Work
    write_sync_issue_labels 11 security AI-Work
    write_repository_labels AI-Work Bug Medium Security
    run_sync_labels
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ "${output}" = "$(printf 'AI-Work\nMedium\nSecurity\n%s synced' "${SYNC_PR_URL}")" ]
    grep -qxF "pr view ${SYNC_PR} --repo ${REPO} --json url,closingIssuesReferences --jq .url, (.closingIssuesReferences[] | [(.repository.owner.login + \"/\" + .repository.name), (.number | tostring)] | @tsv)" "${GH_LOG}"
    grep -qF "issue view 10 --repo ${REPO} " "${GH_LOG}"
    grep -qF "issue view 11 --repo other-org/other-repo " "${GH_LOG}"
    [ "$(gh_call_count "label list --repo ${REPO} ")" -eq 1 ]
    [ "$(gh_call_count "pr edit ${SYNC_PR} --repo ${REPO} --add-label AI-Work")" -eq 1 ]
    [ "$(gh_call_count "pr edit ${SYNC_PR} --repo ${REPO} --add-label Medium")" -eq 1 ]
    [ "$(gh_call_count "pr edit ${SYNC_PR} --repo ${REPO} --add-label Security")" -eq 1 ]
    [ "$(gh_call_count "--add-label")" -eq 3 ]
    [ "$(gh_call_count "api user")" -eq 0 ]
    [ "$(gh_call_count "--add-assignee")" -eq 0 ]
    no_label_removed
}

@test "pr sync-labels never adds Blocked or On Hold, in either spelling and any case" {
    write_sync_pr "${REPO} 10" "other-org/other-repo 11"
    write_sync_issue_labels 10 Blocked "on hold" Bug Blocked-by-upstream
    write_sync_issue_labels 11 BLOCKED On-Hold "On Hold"
    write_repository_labels Blocked "On Hold" On-Hold Bug Blocked-by-upstream
    run_sync_labels
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ "${output}" = "$(printf 'Blocked-by-upstream\nBug\n%s synced' "${SYNC_PR_URL}")" ]
    [ "$(gh_call_count "--add-label")" -eq 2 ]
    [ "$(gh_call_count "--add-label Blocked-by-upstream")" -eq 1 ]
    [ "$(grep -ciE -- '--add-label (blocked|on.hold)$' "${GH_LOG}" || true)" -eq 0 ]
    no_label_removed
}

@test "pr sync-labels skips a label the pull request's repository does not have, with a warning naming it and the repository, and adds the rest" {
    write_sync_pr "other-org/other-repo 11"
    write_sync_issue_labels 11 Bug Foreign
    write_repository_labels Bug
    run_sync_labels
    [ "${status}" -eq 0 ]
    [ "${stderr}" = "cfwf: warning: ${REPO} has no label Foreign; it was not added" ]
    [ "${output}" = "$(printf 'Bug\n%s synced' "${SYNC_PR_URL}")" ]
    [ "$(gh_call_count "--add-label")" -eq 1 ]
    [ "$(gh_call_count "Foreign")" -eq 0 ]
    no_label_removed
}

@test "pr sync-labels adds what it could read and exits 1 without synced when a closing issue cannot be read" {
    write_sync_pr "${REPO} 10" "${REPO} 11"
    write_sync_issue_labels 11 Bug
    write_repository_labels Bug
    write_agent_login
    run_sync_labels --assign-self
    [ "${status}" -eq 1 ]
    [ "${output}" = "Bug" ]
    [[ "${stderr}" == *"cfwf: warning: could not fetch the labels of ${REPO}#10"* ]]
    [[ "${stderr}" == *"cfwf: the labels of a closing issue of ${REPO}#${SYNC_PR} could not be read, so only those read were added" ]]
    [ "$(gh_call_count "pr edit ${SYNC_PR} --repo ${REPO} --add-label Bug")" -eq 1 ]
    [ "$(gh_call_count "pr edit ${SYNC_PR} --repo ${REPO} --add-assignee ${AGENT}")" -eq 1 ]
    no_label_removed
}

@test "pr sync-labels --assign-self adds the agent's login as an assignee after the labels, as pr edit does" {
    write_sync_pr "${REPO} 10"
    write_sync_issue_labels 10 Bug
    write_repository_labels Bug
    write_agent_login
    run --separate-stderr "${SCRIPT}" pr sync-labels --assign-self --pr "0${SYNC_PR}" --repo "${REPO}"
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ "${output}" = "$(printf 'Bug\n%s synced' "${SYNC_PR_URL}")" ]
    [ "$(gh_call_count "api user")" -eq 1 ]
    [ "$(gh_call_count "pr edit ${SYNC_PR} --repo ${REPO} --add-assignee ${AGENT}")" -eq 1 ]
    [ "$(sed -n '$p' "${GH_LOG}")" = "pr edit ${SYNC_PR} --repo ${REPO} --add-assignee ${AGENT}" ]
    no_label_removed

    # With nothing to add, the agent is still assigned, and the repository's labels are not read.
    rm -f "${GH_LOG}"
    write_sync_pr
    run_sync_labels --assign-self
    [ "${status}" -eq 0 ]
    [ "${output}" = "${SYNC_PR_URL} synced" ]
    [ "$(gh_call_count "label list")" -eq 0 ]
    [ "$(gh_call_count "--add-label")" -eq 0 ]
    [ "$(gh_call_count "--add-assignee ${AGENT}")" -eq 1 ]

    # A failed read of the login writes nothing.
    rm -f "${GH_LOG}"
    write_sync_pr "${REPO} 10"
    fail_api user
    run_sync_labels --assign-self
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "$(gh_call_count " edit ")" -eq 0 ]
}

@test "pr sync-labels exits 0 with only the synced line, writing nothing, when there is nothing to add" {
    write_sync_pr
    run_sync_labels
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ "${output}" = "${SYNC_PR_URL} synced" ]
    [ "$(gh_call_count "label list")" -eq 0 ]
    [ "$(gh_call_count " edit ")" -eq 0 ]

    # A closing issue with only Blocked and On Hold has nothing to add either.
    rm -f "${GH_LOG}"
    write_sync_pr "${REPO} 10"
    write_sync_issue_labels 10 Blocked "On Hold"
    run_sync_labels
    [ "${status}" -eq 0 ]
    [ "${output}" = "${SYNC_PR_URL} synced" ]
    [ "$(gh_call_count " edit ")" -eq 0 ]
}

@test "pr sync-labels exits 1 for a failed read or write, never reporting synced" {
    write_sync_issue_labels 10 AI-Work Bug
    write_repository_labels AI-Work Bug

    # The pull request cannot be read.
    run_sync_labels
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == *"cfwf: could not read the closing issues of ${REPO}#${SYNC_PR}"* ]]

    # It answers with the URL of another pull request.
    SYNC_URL="https://github.com/${REPO}/pull/9" write_sync_pr "${REPO} 10"
    run_sync_labels
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == *"cfwf: gh returned an unexpected result for ${REPO}#${SYNC_PR}"* ]]

    # The repository's labels cannot be read.
    write_sync_pr "${REPO} 10"
    touch "${GH_FIXTURES}/label-list.fail"
    run_sync_labels
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == *"cfwf: could not read the labels of ${REPO}"* ]]
    rm -f "${GH_FIXTURES}/label-list.fail"

    # The write fails.
    rm -f "${GH_LOG}"
    echo "HTTP 502: Bad Gateway" > "${GH_FIXTURES}/pr-edit.fail"
    run_sync_labels
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == "cfwf: could not add the label AI-Work to ${REPO}#${SYNC_PR}: HTTP 502: Bad Gateway" ]]
    [ "$(gh_call_count "--add-label")" -eq 1 ]
    no_label_removed
}

@test "pr sync-labels usage errors exit 2 with its usage on stderr and nothing on stdout, never echoing a value, before any gh call" {
    local repo="--repo ${REPO}" args
    local -a cases=(
        "" "${repo}" "--pr 7" "${repo} --pr x" "${repo} --pr 0" "${repo} --pr -1" "${repo} --pr 7 --pr 7"
        "--repo x --pr 7" "${repo} ${repo} --pr 7" "${repo} --pr 7 --assign-self --assign-self"
        "${repo} --pr 7 --assign-self yes" "${repo} --pr 7 --label Bug" "${repo} --pr 7 --remove-label Bug"
        "${repo} --pr 7 --issue 3" "${repo} --pr 7 --json url" "${repo} --pr 7 --jq ." "${repo} --pr 7 extra" "${repo} --pr"
    )
    for args in "${cases[@]}"; do
        # shellcheck disable=SC2086  # each case is split into its words on purpose
        run --separate-stderr "${SCRIPT}" pr sync-labels ${args}
        if [ "${status}" -ne 2 ]; then
            echo "accepted: ${args} (${status})" >&2
            return 1
        fi
        [ -z "${output}" ]
        if [[ "${stderr}" != "cfwf: "*$'\n\n'"${SYNC_USAGE}"$'\n'* ]]; then
            echo "usage: ${args}" >&2
            return 1
        fi
    done
    local secret="ghp_${RANDOM}abcdefghijklmnopqrstuvwxyz0123456789"
    run_sync_labels "${secret}"
    [ "${status}" -eq 2 ]
    [[ "${stderr}" != *"${secret}"* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "pr sync-labels help, from -h, --help and help, gives the usage, the rules, the output and every exit code; help pr and the general help point to it; none calls gh" {
    local invocation
    for invocation in "pr sync-labels -h" "pr sync-labels --help" "help pr sync-labels"; do
        # shellcheck disable=SC2086  # each invocation is split into its words on purpose
        run --separate-stderr "${SCRIPT}" ${invocation}
        [ "${status}" -eq 0 ]
        [ -z "${stderr}" ]
        [[ "${output}" == "${SYNC_USAGE}"$'\n'* ]]
        [[ "${output}" == *"There is no --label: the labels come only from the closing issues."* ]]
        [[ "${output}" == *"Blocked and On Hold (spelt On Hold or On-Hold, in any case) are"$'\n'"never added."* ]]
        [[ "${output}" == *$'\n'"  cfwf: warning: <owner/repo> has no label <name>; it was not added"$'\n'* ]]
        [[ "${output}" == *"Output: each label added, one a line, then \"<url> synced\""* ]]
        [[ "${output}" == *"Exit codes: 0 synced (nothing to add included); 1 a runtime failure"* ]]
        [[ "${output}" == *"so a partial sync is never reported as complete; 2 a usage error; 8"*"--assign-self on a pull request assigned to another user"* ]]
        [[ "${output}" != *"usage_"* ]]
    done
    run "${SCRIPT}" help pr
    [ "${status}" -eq 0 ]
    [[ "${output}" == *$'\n'"merged pull request's merge commit, on its base branch."$'\n'"Run 'cfwf pr sync-labels --help' for pr sync-labels, which adds the labels of the issues a pull"$'\n'"request closes to it."$'\n'* ]]
    run "${SCRIPT}" help
    [ "${status}" -eq 0 ]
    [[ "${output}" == *$'\n'"  pr sync-labels           Add the labels of the issues a PR closes to it, never removing one, and optionally assign the agent"$'\n'* ]]
    [ ! -f "${GH_LOG}" ]
}
