#!/usr/bin/env bats
# shellcheck disable=SC2154  # stderr is set by run --separate-stderr

bats_require_minimum_version 1.5.0

load test_helper
load cfwf_helper

# Assigned in cfwf_helper.bash. Declared here, which keeps the value, because shellcheck does not
# follow bats `load` and would otherwise read REPO as a misspelling.
declare -g REPO

# --- pr checks ------------------------------------------------------------------

@test "pr checks help, from help pr, pr -h and pr checks -h, describes every exit code and calls no gh" {
    local invocation
    for invocation in "help pr" "pr -h" "pr checks --help" "pr checks -h"; do
        # shellcheck disable=SC2086  # each invocation is split into its words on purpose
        run "${SCRIPT}" ${invocation}
        [ "${status}" -eq 0 ]
        [[ "${output}" == *"cfwf pr checks --repo <owner/repo> (--pr <n> | --sha <40-hex> | --branch <name>) [--all]"* ]]
        [[ "${output}" == *"Exit codes: 0 every judged check passed; 3 at least one failed; 4 none failed and at least one is"*"pending; 5 the head has no check runs or statuses at all"* ]]
        [[ "${output}" == *"1 a runtime failure"*"never reported as a failed check; 2 a usage error."* ]]
        [[ "${output}" == *"never waits or polls"* ]]
    done
    [ ! -f "${GH_LOG}" ]
}

@test "pr checks refuses an owner or repository of . or .., which would change the API path, before any gh call" {
    local bad
    for bad in "../.." "./x" "x/." "x/.." "../repo" "owner/.."; do
        run --separate-stderr "${SCRIPT}" pr checks --repo "${bad}" --pr 42
        [ "${status}" -eq 2 ] || { echo "--repo '${bad}' was accepted (${status})" >&2; return 1; }
        [ -z "${output}" ]
        [[ "${stderr}" == *"invalid value for --repo: neither the owner nor the repository can be . or .."* ]]
        [[ "${stderr}" != *"${bad}"* ]]
    done
    [ ! -f "${GH_LOG}" ]

    # A name that only starts with a dot, such as .github, is a real repository and is still taken.
    run --separate-stderr "${SCRIPT}" pr checks --repo owner/.github --pr 42
    [ "${status}" -eq 1 ]
    [ "$(gh_call_count "api repos/owner/.github/pulls/42 ")" -eq 1 ]
}

@test "pr checks usage errors exit 2 before any gh call" {
    local sha_upper="${HEAD_SHA^^}"
    local -a cases=(
        "--sha 111111111111111111111111111111111111111"
        "--sha 111111111111111111111111111111111111111g"
        "--sha 11111111111111111111111111111111111111111"
        "--pr 42 --sha ${HEAD_SHA}"
        "--pr 42 --branch main"
        "--sha ${HEAD_SHA} --branch main"
        ""
        "--pr 42 --pr 43"
        "--sha ${sha_upper} --sha ${HEAD_SHA}"
        "--branch main --branch dev"
        "--pr x42"
        "--pr 42 --json name"
        "--pr 42 --jq ."
        "--pr 42 --template x"
        "--pr 42 --watch"
        "--pr 42 --interval 10"
        "--pr 42 -i 10"
        "--pr 42 --required"
        "--pr 42 --all extra"
        "--branch -main"
        "--branch /main"
        "--branch a..b"
        "--branch a//b"
        "--branch a/"
        "--branch .hidden"
        "--branch main.lock"
        "--branch a.lock/b"
        "--branch a@{1}"
        "--branch HEAD"
        "--branch @{-1}"
        "--branch a."
        "--pr"
    )
    local args
    for args in "${cases[@]}"; do
        # shellcheck disable=SC2086  # each case is split into its words on purpose
        run_pr_checks ${args}
        [ "${status}" -eq 2 ] || { echo "accepted: ${args} (${status})" >&2; return 1; }
        [ -z "${output}" ]
        [[ "${stderr}" == *"Usage: cfwf pr checks"* ]]
    done

    run --separate-stderr "${SCRIPT}" pr checks --pr 42
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == *"missing required option --repo"* ]]

    local branch
    for branch in "bad name" "bad?x" "bad*" $'bad\tx' "bad~1" "bad:x" "bad^x" "bad@{x" "bad[x" 'bad\x' $'bad\x7fx'; do
        run_pr_checks --branch "${branch}"
        [ "${status}" -eq 2 ]
        [[ "${stderr%%$'\n'*}" == "cfwf: invalid value for --branch: "* && "${stderr%%$'\n'*}" != *"${branch}"* ]]
    done

    run_pr_checks --pr 42 --json name
    [[ "${stderr}" == *"unknown option (argument 7; its value is not shown)"* && "${stderr%%$'\n'*}" != *json* ]]

    run_pr_checks --pr 42 --branch main
    [[ "${stderr}" == *"give exactly one of --pr, --sha and --branch"* ]]

    run --separate-stderr "${SCRIPT}" pr frobnicate
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == *"unknown pr subcommand"* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "pr checks exits 0 when every required check passed, reading the PR head, its base's required checks and both result sources" {
    prepare_pr_checks
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    [ "${output}" = "build"$'\t'"pass"$'\t'"${COMPLETED_AT}"$'\t'"11"$'\n'"summary passed=1 failed=0 pending=0 head=${HEAD_SHA}" ]
    [ -z "${stderr}" ]
    [ "$(gh_call_count "api repos/${REPO}/pulls/42 ")" -eq 1 ]
    [ "$(gh_call_count "api repos/${REPO}/branches/main --jq ")" -eq 1 ]
    [ "$(gh_call_count "/protection")" -eq 0 ]
    [ "$(gh_call_count "api repos/${REPO}/rules/branches/main?per_page=100 --paginate ")" -eq 1 ]
    [ "$(gh_call_count "api repos/${REPO}/commits/${HEAD_SHA}/check-runs?per_page=100&filter=all --paginate ")" -eq 1 ]
    [ "$(gh_call_count "api repos/${REPO}/commits/${HEAD_SHA}/status?per_page=100 --paginate ")" -eq 1 ]
    [ "$(gh_call_count " api graphql")" -eq 0 ]
}

@test "pr checks reads a PR number given with leading zeros as that number, without them" {
    run_pr_checks --pr 042
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: ${REPO}#42 was not found" ]

    prepare_pr_checks
    : > "${GH_LOG}"
    run_pr_checks --pr 00042
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"summary passed=1 failed=0 pending=0 head=${HEAD_SHA}" ]]
    [ "$(gh_call_count "api repos/${REPO}/pulls/42 ")" -eq 1 ]
    [ "$(gh_call_count "pulls/0")" -eq 0 ]
}

@test "pr checks exits 3 for each failing conclusion, and for a conclusion it does not know" {
    prepare_pr_checks
    local conclusion
    for conclusion in failure cancelled timed_out action_required startup_failure stale something_new; do
        write_check_runs "${HEAD_SHA}" "$(check_run build "${conclusion}" 11)"
        run_pr_checks --pr 42
        [ "${status}" -eq 3 ] || { echo "${conclusion}: ${status}" >&2; return 1; }
        [ "${output}" = "build"$'\t'"fail"$'\t'"${COMPLETED_AT}"$'\t'"11"$'\n'"summary passed=0 failed=1 pending=0 head=${HEAD_SHA}" ]
    done
}

@test "pr checks counts skipped and neutral as passed" {
    prepare_pr_checks
    write_protection main build lint
    write_check_runs "${HEAD_SHA}" "$(check_run build skipped 11)" "$(check_run lint neutral 12)"
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"summary passed=2 failed=0 pending=0 head=${HEAD_SHA}" ]]
}

@test "pr checks exits 4 for a run in progress, and counts a run with a conclusion as finished whatever its status" {
    prepare_pr_checks
    write_check_runs "${HEAD_SHA}" "$(check_run build "" 11)"
    run_pr_checks --pr 42
    [ "${status}" -eq 4 ]
    [ "${output}" = "build"$'\t'"pending"$'\t'$'\t'"11"$'\n'"summary passed=0 failed=0 pending=1 head=${HEAD_SHA}" ]

    write_check_runs "${HEAD_SHA}" "$(check_run build "" 11 completed)"
    run_pr_checks --pr 42
    [ "${status}" -eq 4 ]

    write_check_runs "${HEAD_SHA}" "$(check_run build success 11 in_progress)"
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]

    write_check_runs "${HEAD_SHA}" "$(check_run build failure 11 queued)"
    run_pr_checks --pr 42
    [ "${status}" -eq 3 ]
}

@test "pr checks counts a required check with no run as pending, and a failure still wins over it" {
    prepare_pr_checks
    write_protection main build lint
    run_pr_checks --pr 42
    [ "${status}" -eq 4 ]
    [ "${output}" = "build"$'\t'"pass"$'\t'"${COMPLETED_AT}"$'\t'"11"$'\n'"lint"$'\t'"pending"$'\t'$'\t'$'\n'"summary passed=1 failed=0 pending=1 head=${HEAD_SHA}" ]

    run_pr_checks --pr 42 --all
    [ "${status}" -eq 4 ]
    [[ "${output}" == *"lint"$'\t'"pending"$'\t'$'\t'* ]]

    write_check_runs "${HEAD_SHA}" "$(check_run build failure 11)"
    run_pr_checks --pr 42
    [ "${status}" -eq 3 ]
}

@test "pr checks exits 5 when the head has no check runs or statuses at all" {
    prepare_pr_checks
    write_check_runs "${HEAD_SHA}"
    write_protection main
    run_pr_checks --pr 42
    [ "${status}" -eq 5 ]
    [ "${output}" = "summary passed=0 failed=0 pending=0 head=${HEAD_SHA}" ]

    # A draft-gated PR has none until it is marked ready, even where checks are required.
    write_protection main build
    run_pr_checks --pr 42
    [ "${status}" -eq 5 ]
    [ "${output}" = "build"$'\t'"pending"$'\t'$'\t'$'\n'"summary passed=0 failed=0 pending=1 head=${HEAD_SHA}" ]
}

@test "pr checks judges only the required checks, unless --all is given" {
    prepare_pr_checks
    write_check_runs "${HEAD_SHA}" "$(check_run build success 11)" "$(check_run optional failure 12)"
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    [ "$(grep -c optional <<< "${output}")" -eq 0 ]

    run_pr_checks --pr 42 --all
    [ "${status}" -eq 3 ]
    [[ "${output}" == *"optional"$'\t'"fail"$'\t'"${COMPLETED_AT}"$'\t'"12"* ]]
    [[ "${output}" == *"summary passed=1 failed=1 pending=0"* ]]
}

@test "pr checks matches a required check pinned to an app only with a run from that app, and any other by name alone" {
    prepare_pr_checks
    # build must come from GitHub Actions (15368); another app's build does not satisfy it.
    write_protection main first build#15368
    write_check_runs "${HEAD_SHA}" "$(check_run first success 10 "" "" 57789 3)" "$(check_run build success 11 "" "" 57789 4)"
    run_pr_checks --pr 42
    [ "${status}" -eq 4 ]
    [ "${output}" = "build"$'\t'"pending"$'\t'$'\t'$'\n'"first"$'\t'"pass"$'\t'"${COMPLETED_AT}"$'\t'"10"$'\n'"summary passed=1 failed=0 pending=1 head=${HEAD_SHA}" ]

    # Nor does a commit status, which carries no app.
    write_statuses "${HEAD_SHA}" "$(commit_status build success 31)"
    run_pr_checks --pr 42
    [ "${status}" -eq 4 ]
    [[ "${output}" == "build"$'\t'"pending"$'\t'$'\t'$'\n'* ]]

    # But a failed commit status of its name fails it, on its own or beside a pass from that app.
    write_statuses "${HEAD_SHA}" "$(commit_status build failure 31)"
    run_pr_checks --pr 42
    [ "${status}" -eq 3 ]
    [[ "${output}" == "build"$'\t'"fail"$'\t'"${COMPLETED_AT}"$'\t'"31"$'\n'* ]]
    write_check_runs "${HEAD_SHA}" "$(check_run first success 10 "" "" 57789 3)" "$(check_run build success 12 "" "" 15368 5)"
    run_pr_checks --pr 42
    [ "${status}" -eq 3 ]
    [[ "${output}" == "build"$'\t'"fail"$'\t'"${COMPLETED_AT}"$'\t'"31"$'\n'* ]]
    write_statuses "${HEAD_SHA}" "$(commit_status build pending 31)"
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    write_statuses "${HEAD_SHA}" "$(commit_status build success 31)"

    write_check_runs "${HEAD_SHA}" "$(check_run first success 10 "" "" 57789 3)" "$(check_run build success 11 "" "" 57789 4)" \
        "$(check_run build success 12 "" "" 15368 5)"
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"build"$'\t'"pass"$'\t'"${COMPLETED_AT}"$'\t'"12"$'\n'* ]]

    # The pinned app's own failure fails it, whatever another app says; a failure from another
    # app does not.
    write_statuses "${HEAD_SHA}"
    write_check_runs "${HEAD_SHA}" "$(check_run first success 10)" "$(check_run build failure 13 "" "" 57789 4)" \
        "$(check_run build success 12 "" "" 15368 5)"
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]

    # A name required for any source (app_id null) takes every result of that name.
    write_protection main first build
    run_pr_checks --pr 42
    [ "${status}" -eq 3 ]

    # A ruleset pins an app through integration_id.
    write_branch main
    write_rulesets main lint#15368
    write_check_runs "${HEAD_SHA}" "$(check_run lint success 14 "" "" 57789 6)"
    run_pr_checks --pr 42
    [ "${status}" -eq 4 ]
    [[ "${output}" == "lint"$'\t'"pending"$'\t'$'\t'$'\n'* ]]
}

@test "pr checks shows the app of each line of a name required more than once, keeping four columns" {
    prepare_pr_checks
    write_protection main first build#15368 build#57789
    write_check_runs "${HEAD_SHA}" "$(check_run first success 10)" "$(check_run build success 11 "" "" 15368 5)" \
        "$(check_run build failure 12 "" "" 57789 6)"
    run_pr_checks --pr 42
    [ "${status}" -eq 3 ]
    [ "${output}" = "build (app 15368)"$'\t'"pass"$'\t'"${COMPLETED_AT}"$'\t'"11"$'\n'"build (app 57789)"$'\t'"fail"$'\t'"${COMPLETED_AT}"$'\t'"12"$'\n'"first"$'\t'"pass"$'\t'"${COMPLETED_AT}"$'\t'"10"$'\n'"summary passed=2 failed=1 pending=0 head=${HEAD_SHA}" ]

    # Required from an app and from any source: only the pinned line names its app.
    write_branch main
    write_rulesets main build build#15368
    write_check_runs "${HEAD_SHA}" "$(check_run build success 11 "" "" 15368 5)"
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    [ "${output}" = "build"$'\t'"pass"$'\t'"${COMPLETED_AT}"$'\t'"11"$'\n'"build (app 15368)"$'\t'"pass"$'\t'"${COMPLETED_AT}"$'\t'"11"$'\n'"summary passed=2 failed=0 pending=0 head=${HEAD_SHA}" ]
    [ "$(awk -F '\t' 'NF != 4' <<< "${output}")" = "summary passed=2 failed=0 pending=0 head=${HEAD_SHA}" ]
}

@test "pr checks judges every check when the branch requires none" {
    prepare_pr_checks
    jq -n --arg sha "${HEAD_SHA}" '{name: "main", commit: {sha: $sha}}' | write_api "repos/${REPO}/branches/main"
    write_rulesets main
    write_check_runs "${HEAD_SHA}" "$(check_run build success 11)" "$(check_run optional failure 12)"
    run_pr_checks --pr 42
    [ "${status}" -eq 3 ]
    [[ "${output}" == *"summary passed=1 failed=1 pending=0"* ]]
}

@test "pr checks reads required checks from branch protection, from rulesets, from both without duplicates, and from neither" {
    prepare_pr_checks
    write_check_runs "${HEAD_SHA}" "$(check_run a success 1)" "$(check_run b success 2)" "$(check_run c success 3)" "$(check_run d failure 4)"

    write_protection main a b
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    [ "$(cut -sf1 <<< "${output}" | paste -sd ' ')" = "a b" ]

    write_branch main
    write_rulesets main b c
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    [ "$(cut -sf1 <<< "${output}" | paste -sd ' ')" = "b c" ]

    write_protection main a b
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    [ "$(cut -sf1 <<< "${output}" | paste -sd ' ')" = "a b c" ]
    [[ "${output}" == *"passed=3 failed=0 pending=0"* ]]

    write_branch main
    write_no_rulesets main
    run_pr_checks --pr 42
    [ "${status}" -eq 3 ]
    [ "$(cut -sf1 <<< "${output}" | paste -sd ' ')" = "a b c d" ]

    # Required checks switched off on a protected branch can still be listed; they require nothing.
    jq -n --arg sha "${HEAD_SHA}" '{name: "main", commit: {sha: $sha}, protected: true,
        protection: {enabled: true, required_status_checks: {enforcement_level: "off", contexts: ["a"], checks: [{context: "b"}]}}}' \
        | write_api "repos/${REPO}/branches/main"
    run_pr_checks --pr 42
    [ "${status}" -eq 3 ]
    [ "$(cut -sf1 <<< "${output}" | paste -sd ' ')" = "a b c d" ]
}

@test "pr checks treats a 404 from the rulesets as a failed read (exit 1), never as no rulesets" {
    # GitHub answers a branch no ruleset applies to with an empty list, so a 404 means the rules
    # could not be read; taking it as none would judge only the checks that happen to be present.
    prepare_pr_checks
    write_branch main
    rm "$(api_fixture "repos/${REPO}/rules/branches/main").json"
    run_pr_checks --pr 42
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not read the rulesets of ${REPO}: gh: Not Found (HTTP 404)" ]

    fail_api "repos/${REPO}/rules/branches/main" "gh: Resource not accessible by integration (HTTP 403)"
    run_pr_checks --pr 42
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not read the rulesets of ${REPO}: gh: Resource not accessible by integration (HTTP 403)" ]
}

@test "pr checks reads the 403 for a plan with no rulesets as no rulesets, and still judges the branch protection" {
    # A private repository on GitHub Free cannot have rulesets, and GitHub refuses the read.
    prepare_pr_checks
    fail_api "repos/${REPO}/rules/branches/main" \
        "gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)"
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    [ "${output}" = "build"$'\t'"pass"$'\t'"${COMPLETED_AT}"$'\t'"11"$'\n'"summary passed=1 failed=0 pending=0 head=${HEAD_SHA}" ]
    [ -z "${stderr}" ]

    write_check_runs "${HEAD_SHA}" "$(check_run build failure 11)"
    run_pr_checks --pr 42
    [ "${status}" -eq 3 ]

    # The same text with any other status is still a failed read.
    fail_api "repos/${REPO}/rules/branches/main" \
        "gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 404)"
    run_pr_checks --pr 42
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
}

@test "pr checks --branch judges the branch tip against that branch's required checks" {
    write_protection release/v2 build
    write_no_rulesets release/v2
    write_check_runs "${HEAD_SHA}" "$(check_run build success 11)"
    write_statuses "${HEAD_SHA}"
    run_pr_checks --branch release/v2
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"head=${HEAD_SHA}" ]]
    [ "$(gh_call_count "api repos/${REPO}/branches/release/v2 --jq")" -eq 1 ]
    [ "$(gh_call_count "/protection")" -eq 0 ]
    [ "$(gh_call_count "api repos/${REPO}/rules/branches/release/v2?per_page=100 ")" -eq 1 ]

    run_pr_checks --branch gone
    [ "${status}" -eq 1 ]
    [[ "${stderr}" == "cfwf: the --branch was not found in ${REPO}" ]]

    # The one read of the branch gives both its tip and its protection, so a failure of it names
    # the --branch.
    : > "${GH_LOG}"
    fail_api "repos/${REPO}/branches/release/v2"
    run_pr_checks --branch release/v2
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not read the --branch of ${REPO}: gh: Bad Gateway (HTTP 502)" ]
    [ "$(gh_call_count "branches/release/v2")" -eq 1 ]
}

# Makes a git checkout on the branch feature, switched to from main so that @{-1} names main, and
# runs the rest of the test from inside it.
enter_checkout_with_previous_branch() {
    local repo="${TEST_TMP}/checkout"
    git init -q -b main "${repo}"
    git -C "${repo}" -c user.name=test -c user.email=test@example.com -c commit.gpgsign=false \
        commit -q --allow-empty -m first
    git -C "${repo}" switch -q -c feature
    cd "${repo}" || return 1
    [ "$(git -C "${repo}" rev-parse --abbrev-ref '@{-1}')" = main ]
}

@test "pr checks --branch judges a name as git does, even run from a repository where @{-1} names a branch" {
    enter_checkout_with_previous_branch
    local branch
    for branch in '@{-1}' HEAD -main main.lock a..b; do
        run_pr_checks --branch "${branch}"
        [ "${status}" -eq 2 ] || { echo "accepted: ${branch} (${status})" >&2; return 1; }
        [[ "${stderr%%$'\n'*}" == "cfwf: invalid value for --branch: "* ]]
        [ ! -s "${GH_LOG}" ]
    done
}

@test "pr checks percent-encodes a branch name git allows but an API path cannot hold as it is, rather than refusing it" {
    jq -n --arg sha "${HEAD_SHA}" '{number: 42, head: {sha: $sha}, base: {ref: "release/v2+lts"}}' | write_api "repos/${REPO}/pulls/42"
    write_protection "release/v2%2Blts" build
    write_rulesets "release/v2%2Blts" lint
    write_check_runs "${HEAD_SHA}" "$(check_run build success 11)" "$(check_run lint success 12)"
    write_statuses "${HEAD_SHA}"
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"passed=2 failed=0 pending=0"* ]]
    [ "$(gh_call_count "api repos/${REPO}/branches/release/v2%2Blts --jq ")" -eq 1 ]
    [ "$(gh_call_count "api repos/${REPO}/rules/branches/release/v2%2Blts?per_page=100 ")" -eq 1 ]

    # A non-ASCII letter is encoded byte by byte, and % itself is encoded, so it can never be read
    # as an escape.
    write_protection "feat/caf%C3%A9%40x%25y" build
    write_no_rulesets "feat/caf%C3%A9%40x%25y"
    run_pr_checks --branch "$(printf 'feat/caf\xc3\xa9@x%%y')"
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ "$(gh_call_count "api repos/${REPO}/branches/feat/caf%C3%A9%40x%25y --jq ")" -eq 1 ]

    # git allows @ alone as a branch name (only the whole ref @ is refused), so cfwf does too.
    write_protection "%40" build
    write_no_rulesets "%40"
    run_pr_checks --branch @
    [ "${status}" -eq 0 ]
    [ "$(gh_call_count "api repos/${REPO}/branches/%40 --jq ")" -eq 1 ]

    # A base branch GitHub returns that git itself would never allow is an unexpected answer.
    jq -n --arg sha "${HEAD_SHA}" '{number: 42, head: {sha: $sha}, base: {ref: "a..b"}}' | write_api "repos/${REPO}/pulls/42"
    run_pr_checks --pr 42
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: gh returned an unexpected branch whose required checks apply for ${REPO}" ]
}

@test "pr checks --pr reads the branch and the rulesets of a base branch with a slash at the same path, the slash kept as it is" {
    jq -n --arg sha "${HEAD_SHA}" '{number: 42, head: {sha: $sha}, base: {ref: "release/1.0"}}' | write_api "repos/${REPO}/pulls/42"
    write_protection release/1.0 build
    write_rulesets release/1.0 lint
    write_check_runs "${HEAD_SHA}" "$(check_run build success 11)" "$(check_run lint failure 12)"
    write_statuses "${HEAD_SHA}"
    run_pr_checks --pr 42
    [ "${status}" -eq 3 ]
    [[ "${output}" == *"lint"$'\t'"fail"$'\t'"${COMPLETED_AT}"$'\t'"12"* ]]
    [[ "${output}" == *"summary passed=1 failed=1 pending=0 head=${HEAD_SHA}" ]]
    [ "$(gh_call_count "api repos/${REPO}/branches/release/1.0 --jq ")" -eq 1 ]
    [ "$(gh_call_count "api repos/${REPO}/rules/branches/release/1.0?per_page=100 --paginate ")" -eq 1 ]
    [ "$(gh_call_count "%2F")" -eq 0 ]
}

@test "pr checks --sha judges that commit, given in any case, against the default branch's required checks" {
    jq -n '{default_branch: "trunk"}' | write_api "repos/${REPO}"
    write_protection trunk build
    write_no_rulesets trunk
    write_check_runs "${HEAD_SHA}" "$(check_run build success 11)"
    write_statuses "${HEAD_SHA}"
    run_pr_checks --sha "${HEAD_SHA^^}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"head=${HEAD_SHA}" ]]
    [ "$(gh_call_count "api repos/${REPO}/branches/trunk --jq ")" -eq 1 ]
    [ "$(gh_call_count "branches/main")" -eq 0 ]
    [ "$(gh_call_count "pulls/")" -eq 0 ]
}

@test "pr checks never counts a run on an older head" {
    prepare_pr_checks
    write_check_runs "${OLD_SHA}" "$(check_run build failure 9 completed "${OLD_SHA}")"
    write_check_runs "${HEAD_SHA}" "$(check_run build success 11)"
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    [[ "${output}" == "build"$'\t'"pass"$'\t'"${COMPLETED_AT}"$'\t'"11"$'\n'* ]]
    [ "$(gh_call_count "${OLD_SHA}")" -eq 0 ]
}

@test "pr checks keeps the newest run of each name, whatever the order GitHub lists them in" {
    prepare_pr_checks
    write_check_runs "${HEAD_SHA}" "$(check_run build success 21)" "$(check_run build failure 20)"
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    [[ "${output}" == *$'\t'"21"$'\n'* ]]

    write_check_runs "${HEAD_SHA}" "$(check_run build success 20)" "$(check_run build "" 21)"
    run_pr_checks --pr 42
    [ "${status}" -eq 4 ]
}

@test "pr checks judges the newest run of a name from each app across check suites, and fails a name when that of any app failed" {
    prepare_pr_checks
    # The PR was marked ready, which started a new check suite and, with cancel-in-progress, left the
    # draft's run cancelled in the old one: the newer success in the later suite clears it.
    write_check_runs "${HEAD_SHA}" "$(check_run build cancelled 100 "" "" 15368 7)" "$(check_run build success 101 "" "" 15368 8)"
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    [ "${output}" = "build"$'\t'"pass"$'\t'"${COMPLETED_AT}"$'\t'"101"$'\n'"summary passed=1 failed=0 pending=0 head=${HEAD_SHA}" ]

    # A newer success clears an older failure the same way, whatever order GitHub lists them in.
    write_check_runs "${HEAD_SHA}" "$(check_run build success 101 "" "" 15368 8)" "$(check_run build failure 100 "" "" 15368 7)"
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    [[ "${output}" == "build"$'\t'"pass"$'\t'"${COMPLETED_AT}"$'\t'"101"$'\n'* ]]

    # A newer failure in a later suite fails the name after an older success.
    write_check_runs "${HEAD_SHA}" "$(check_run build success 100 "" "" 15368 7)" "$(check_run build failure 101 "" "" 15368 8)"
    run_pr_checks --pr 42
    [ "${status}" -eq 3 ]
    [ "${output}" = "build"$'\t'"fail"$'\t'"${COMPLETED_AT}"$'\t'"101"$'\n'"summary passed=0 failed=1 pending=0 head=${HEAD_SHA}" ]

    # A newer run still going in a later suite keeps the name pending.
    write_check_runs "${HEAD_SHA}" "$(check_run build success 101 "" "" 15368 8)" "$(check_run build "" 102 "" "" 15368 9)"
    run_pr_checks --pr 42
    [ "${status}" -eq 4 ]
    [[ "${output}" == "build"$'\t'"pending"$'\t'$'\t'"102"$'\n'* ]]

    # A re-run adds its runs to the same suite, and the newest replaces the failure there too.
    write_check_runs "${HEAD_SHA}" "$(check_run build failure 100 "" "" 15368 7)" "$(check_run build success 103 "" "" 15368 7)"
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    [[ "${output}" == "build"$'\t'"pass"$'\t'"${COMPLETED_AT}"$'\t'"103"$'\n'* ]]

    # Two apps reporting build are each judged on their own newest run, so a failure from one still
    # fails the name after the other, newer, succeeds.
    write_check_runs "${HEAD_SHA}" "$(check_run build failure 100 "" "" 57789 9)" "$(check_run build success 101 "" "" 15368 8)"
    run_pr_checks --pr 42
    [ "${status}" -eq 3 ]
    [[ "${output}" == "build"$'\t'"fail"$'\t'"${COMPLETED_AT}"$'\t'"100"$'\n'* ]]
}

@test "pr checks never lets a skipped run replace a run of its name that ran, whatever their order" {
    prepare_pr_checks
    # A relabelled PR starts a new suite whose job skips itself: the older failure still fails it.
    write_check_runs "${HEAD_SHA}" "$(check_run build failure 100 "" "" 15368 7)" "$(check_run build skipped 101 "" "" 15368 8)"
    run_pr_checks --pr 42
    [ "${status}" -eq 3 ]
    [ "${output}" = "build"$'\t'"fail"$'\t'"${COMPLETED_AT}"$'\t'"100"$'\n'"summary passed=0 failed=1 pending=0 head=${HEAD_SHA}" ]

    # The same whatever order GitHub lists them in.
    write_check_runs "${HEAD_SHA}" "$(check_run build skipped 101 "" "" 15368 8)" "$(check_run build failure 100 "" "" 15368 7)"
    run_pr_checks --pr 42
    [ "${status}" -eq 3 ]
    [[ "${output}" == "build"$'\t'"fail"$'\t'"${COMPLETED_AT}"$'\t'"100"$'\n'* ]]

    # An older success with a newer skipped run passes on the success.
    write_check_runs "${HEAD_SHA}" "$(check_run build success 100 "" "" 15368 7)" "$(check_run build skipped 101 "" "" 15368 8)"
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    [ "${output}" = "build"$'\t'"pass"$'\t'"${COMPLETED_AT}"$'\t'"100"$'\n'"summary passed=1 failed=0 pending=0 head=${HEAD_SHA}" ]

    # Only skipped runs (a check skipped while the PR was a draft, with nothing newer) pass, on the newest.
    write_check_runs "${HEAD_SHA}" "$(check_run build skipped 100 "" "" 15368 7)" "$(check_run build skipped 101 "" "" 15368 8)"
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    [ "${output}" = "build"$'\t'"pass"$'\t'"${COMPLETED_AT}"$'\t'"101"$'\n'"summary passed=1 failed=0 pending=0 head=${HEAD_SHA}" ]

    # An older skipped run with a newer failure fails.
    write_check_runs "${HEAD_SHA}" "$(check_run build skipped 100 "" "" 15368 7)" "$(check_run build failure 101 "" "" 15368 8)"
    run_pr_checks --pr 42
    [ "${status}" -eq 3 ]
    [ "${output}" = "build"$'\t'"fail"$'\t'"${COMPLETED_AT}"$'\t'"101"$'\n'"summary passed=0 failed=1 pending=0 head=${HEAD_SHA}" ]

    # A run that has not finished replaces a skipped one, and still replaces an older failure.
    write_check_runs "${HEAD_SHA}" "$(check_run build skipped 100 "" "" 15368 7)" "$(check_run build "" 101 "" "" 15368 8)"
    run_pr_checks --pr 42
    [ "${status}" -eq 4 ]
    [[ "${output}" == "build"$'\t'"pending"$'\t'$'\t'"101"$'\n'* ]]

    write_check_runs "${HEAD_SHA}" "$(check_run build failure 100 "" "" 15368 7)" "$(check_run build "" 101 "" "" 15368 8)"
    run_pr_checks --pr 42
    [ "${status}" -eq 4 ]
    [[ "${output}" == "build"$'\t'"pending"$'\t'$'\t'"101"$'\n'* ]]

    # A run that decided is never replaced by a newer skipped run, whatever its conclusion.
    local conclusion
    for conclusion in timed_out action_required; do
        write_check_runs "${HEAD_SHA}" "$(check_run build skipped 101 "" "" 15368 8)" "$(check_run build "${conclusion}" 100 "" "" 15368 7)"
        run_pr_checks --pr 42
        [ "${status}" -eq 3 ] || { echo "${conclusion}: ${status}" >&2; return 1; }
        [[ "${output}" == "build"$'\t'"fail"$'\t'"${COMPLETED_AT}"$'\t'"100"$'\n'* ]]
    done
}

@test "pr checks lets a newer skipped run replace an older cancelled one, which was superseded, not decided, whatever their order" {
    prepare_pr_checks
    # cancel-in-progress cancels the older run when a relabelled PR starts a suite whose job skips
    # itself: GitHub passes the check on the skipped run, and so does pr checks.
    local expected="build"$'\t'"pass"$'\t'"${COMPLETED_AT}"$'\t'"101"$'\n'"summary passed=1 failed=0 pending=0 head=${HEAD_SHA}"
    write_check_runs "${HEAD_SHA}" "$(check_run build cancelled 100 "" "" 15368 7)" "$(check_run build skipped 101 "" "" 15368 8)"
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    [ "${output}" = "${expected}" ]

    write_check_runs "${HEAD_SHA}" "$(check_run build skipped 101 "" "" 15368 8)" "$(check_run build cancelled 100 "" "" 15368 7)"
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    [ "${output}" = "${expected}" ]

    # A failure that a newer run superseded stays superseded when that run was cancelled in turn,
    # in any listing order.
    write_check_runs "${HEAD_SHA}" "$(check_run build failure 99 "" "" 15368 6)" "$(check_run build skipped 101 "" "" 15368 8)" \
        "$(check_run build cancelled 100 "" "" 15368 7)"
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    [ "${output}" = "${expected}" ]

    write_check_runs "${HEAD_SHA}" "$(check_run build skipped 101 "" "" 15368 8)" "$(check_run build cancelled 100 "" "" 15368 7)" \
        "$(check_run build failure 99 "" "" 15368 6)"
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    [ "${output}" = "${expected}" ]

    # A cancelled run alone, or one newer than the skipped run, still fails.
    write_check_runs "${HEAD_SHA}" "$(check_run build cancelled 100 "" "" 15368 7)"
    run_pr_checks --pr 42
    [ "${status}" -eq 3 ]
    [ "${output}" = "build"$'\t'"fail"$'\t'"${COMPLETED_AT}"$'\t'"100"$'\n'"summary passed=0 failed=1 pending=0 head=${HEAD_SHA}" ]

    write_check_runs "${HEAD_SHA}" "$(check_run build cancelled 101 "" "" 15368 8)" "$(check_run build skipped 100 "" "" 15368 7)"
    run_pr_checks --pr 42
    [ "${status}" -eq 3 ]
    [[ "${output}" == "build"$'\t'"fail"$'\t'"${COMPLETED_AT}"$'\t'"101"$'\n'* ]]

    # A newer run that ran replaces a cancelled one, as any newer run does.
    write_check_runs "${HEAD_SHA}" "$(check_run build success 101 "" "" 15368 8)" "$(check_run build cancelled 100 "" "" 15368 7)"
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    [ "${output}" = "build"$'\t'"pass"$'\t'"${COMPLETED_AT}"$'\t'"101"$'\n'"summary passed=1 failed=0 pending=0 head=${HEAD_SHA}" ]
}

@test "pr checks judges commit statuses, and a check run and a status of the same name must both pass" {
    prepare_pr_checks
    write_protection main build ci/legacy ci/error ci/waiting
    write_statuses "${HEAD_SHA}" "$(commit_status build success 31)" "$(commit_status ci/legacy success 32)"
    run_pr_checks --pr 42
    [[ "${output}" == *"build"$'\t'"pass"$'\t'"${COMPLETED_AT}"$'\t'"31"* ]]
    [[ "${output}" == *"ci/legacy"$'\t'"pass"$'\t'"${COMPLETED_AT}"$'\t'"32"* ]]

    write_statuses "${HEAD_SHA}" "$(commit_status build failure 31)"
    run_pr_checks --pr 42
    [ "${status}" -eq 3 ]
    [[ "${output}" == *"build"$'\t'"fail"$'\t'"${COMPLETED_AT}"$'\t'"31"* ]]

    write_statuses "${HEAD_SHA}" "$(commit_status ci/legacy failure 32)" "$(commit_status ci/error error 33)" "$(commit_status ci/waiting pending 34)"
    run_pr_checks --pr 42
    [ "${status}" -eq 3 ]
    [[ "${output}" == *"ci/error"$'\t'"fail"$'\t'"${COMPLETED_AT}"$'\t'"33"* ]]
    [[ "${output}" == *"ci/legacy"$'\t'"fail"* ]]
    [[ "${output}" == *"ci/waiting"$'\t'"pending"$'\t'$'\t'"34"* ]]
    [[ "${output}" == *"summary passed=1 failed=2 pending=1"* ]]
}

@test "pr checks puts a check name with a tab or a newline on one line of the output" {
    prepare_pr_checks
    write_protection main
    write_check_runs "${HEAD_SHA}" "$(check_run $'odd\tname\nhere' success 11)"
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    [ "${output}" = "odd name here"$'\t'"pass"$'\t'"${COMPLETED_AT}"$'\t'"11"$'\n'"summary passed=1 failed=0 pending=0 head=${HEAD_SHA}" ]
}

@test "pr checks prints every C0, DEL and C1 control in a check name as a space, and keeps U+00A0, just past C1" {
    prepare_pr_checks
    write_protection main
    # ESC, U+009B (CSI, a one-character escape in C1), U+0085 (NEL) and DEL are controls; U+00A0,
    # just past C1, is not. gh's --jq (gojq) reads [[:cntrl:]] as ASCII only, so the range is
    # written out; this stub runs jq, so the test pins the range, not the engine.
    write_check_runs "${HEAD_SHA}" "$(check_run $'a\x1b[1mb\xc2\x9b31mc\xc2\x85d\x7fe\xc2\xa0f' success 11)"
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    [ "${output}" = "a [1mb 31mc d e"$'\xc2\xa0'"f"$'\t'"pass"$'\t'"${COMPLETED_AT}"$'\t'"11"$'\n'"summary passed=1 failed=0 pending=0 head=${HEAD_SHA}" ]
}

@test "pr checks keeps apart two names that differ only in a control character, though both print alike" {
    prepare_pr_checks
    write_protection main
    write_check_runs "${HEAD_SHA}" "$(check_run $'a\tb' failure 11)" "$(check_run "a b" success 12)"
    run_pr_checks --pr 42
    [ "${status}" -eq 3 ]
    [ "${output}" = "a b"$'\t'"fail"$'\t'"${COMPLETED_AT}"$'\t'"11"$'\n'"a b"$'\t'"pass"$'\t'"${COMPLETED_AT}"$'\t'"12"$'\n'"summary passed=1 failed=1 pending=0 head=${HEAD_SHA}" ]

    # A required name matches only the name it is, byte for byte.
    write_protection main "a b"
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    [ "${output}" = "a b"$'\t'"pass"$'\t'"${COMPLETED_AT}"$'\t'"12"$'\n'"summary passed=1 failed=0 pending=0 head=${HEAD_SHA}" ]
}

@test "pr checks judges a check really named like the app label of a name required twice apart from that name" {
    prepare_pr_checks
    write_branch main
    write_rulesets main foo#15368 foo#57789 "foo (app 15368)"
    write_check_runs "${HEAD_SHA}" "$(check_run foo success 11 "" "" 15368 5)" "$(check_run foo success 12 "" "" 57789 6)" \
        "$(check_run "foo (app 15368)" failure 13 "" "" 15368 5)"
    run_pr_checks --pr 42
    [ "${status}" -eq 3 ]
    [ "${output}" = "foo (app 15368)"$'\t'"fail"$'\t'"${COMPLETED_AT}"$'\t'"13"$'\n'"foo (app 15368)"$'\t'"pass"$'\t'"${COMPLETED_AT}"$'\t'"11"$'\n'"foo (app 57789)"$'\t'"pass"$'\t'"${COMPLETED_AT}"$'\t'"12"$'\n'"summary passed=2 failed=1 pending=0 head=${HEAD_SHA}" ]
}

@test "pr checks keeps a check named summary apart from the summary line, the only line with no tab" {
    prepare_pr_checks
    write_protection main summary
    write_check_runs "${HEAD_SHA}" "$(check_run summary success 11)"
    run_pr_checks --pr 42
    [ "${status}" -eq 0 ]
    [ "${output}" = "summary"$'\t'"pass"$'\t'"${COMPLETED_AT}"$'\t'"11"$'\n'"summary passed=1 failed=0 pending=0 head=${HEAD_SHA}" ]
    [ "$(grep -v $'\t' <<< "${output}")" = "summary passed=1 failed=0 pending=0 head=${HEAD_SHA}" ]
    [ "$(grep -c $'\t' <<< "${output}")" -eq 1 ]
}

@test "pr checks reports a transport failure as a runtime failure (exit 1), never as a failed check" {
    local endpoint
    for endpoint in "repos/${REPO}/pulls/42" \
        "repos/${REPO}/branches/main" \
        "repos/${REPO}/rules/branches/main" \
        "repos/${REPO}/commits/${HEAD_SHA}/check-runs" \
        "repos/${REPO}/commits/${HEAD_SHA}/status"; do
        rm -f "${GH_FIXTURES}"/api-*
        prepare_pr_checks
        write_check_runs "${HEAD_SHA}" "$(check_run build failure 11)"
        fail_api "${endpoint}"
        run_pr_checks --pr 42
        [ "${status}" -eq 1 ] || { echo "${endpoint}: ${status}" >&2; return 1; }
        [ -z "${output}" ]
        [[ "${stderr}" == "cfwf: could not read "*": gh: Bad Gateway (HTTP 502)" ]]
        [ "$(grep -c fail <<< "${stderr}")" -eq 0 ]
    done

    rm -f "${GH_FIXTURES}"/api-*
    prepare_pr_checks
    fail_api "repos/${REPO}/branches/main" "gh: Resource not accessible by integration (HTTP 403)"
    run_pr_checks --pr 42
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: could not read the branch protection of ${REPO}: gh: Resource not accessible by integration (HTTP 403)" ]
}

@test "pr checks needs no admin rights: the protection endpoint, which answers 403 without them, is never read" {
    prepare_pr_checks
    write_protection main build lint
    fail_api "repos/${REPO}/branches/main/protection/required_status_checks" "gh: Resource not accessible by integration (HTTP 403)"
    fail_api "repos/${REPO}/branches/main/protection" "gh: Resource not accessible by integration (HTTP 403)"
    run_pr_checks --pr 42
    [ "${status}" -eq 4 ]
    [[ "${output}" == *"lint"$'\t'"pending"$'\t'* ]]
    [ -z "${stderr}" ]
    [ "$(gh_call_count "/protection")" -eq 0 ]
}

@test "pr checks --sha treats a repository that is not there, whose default branch cannot be read, as a runtime failure (exit 1) naming it" {
    write_check_runs "${HEAD_SHA}" "$(check_run build success 11)"
    write_statuses "${HEAD_SHA}"
    run_pr_checks --sha "${HEAD_SHA}"
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: the repository ${REPO} was not found, or the caller cannot see it" ]
    [ "$(wc -l < "${GH_LOG}")" -eq 1 ]
    [ "$(gh_call_count "api repos/${REPO} --jq ")" -eq 1 ]
}

@test "pr checks treats a missing PR, base branch or commit as a runtime failure (exit 1)" {
    run_pr_checks --pr 42
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: ${REPO}#42 was not found" ]

    prepare_pr_checks
    rm "$(api_fixture "repos/${REPO}/branches/main").json"
    write_rulesets main build
    run_pr_checks --pr 42
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: the branch whose required checks apply was not found in ${REPO}" ]
    [ "$(gh_call_count "rules/branches")" -eq 0 ]

    # GitHub answers a --sha that is not in the repository with 422, not 404.
    rm -f "${GH_FIXTURES}"/api-*
    jq -n '{default_branch: "main"}' | write_api "repos/${REPO}"
    write_protection main build
    write_no_rulesets main
    fail_api "repos/${REPO}/commits/${HEAD_SHA}/check-runs" "gh: No commit found for SHA: ${HEAD_SHA} (HTTP 422)"
    run_pr_checks --sha "${HEAD_SHA}"
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: the commit ${HEAD_SHA} was not found in ${REPO}" ]

    # Any other 422 is a failed read, not a missing commit.
    fail_api "repos/${REPO}/commits/${HEAD_SHA}/check-runs" "gh: Validation Failed (HTTP 422)"
    run_pr_checks --sha "${HEAD_SHA}"
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not read the check runs of ${HEAD_SHA}: gh: Validation Failed (HTTP 422)" ]
}

# --- branch required-checks -------------------------------------------------------

run_branch_required_checks() {
    run --separate-stderr "${SCRIPT}" branch required-checks --repo "${REPO}" "$@"
}

# The branch required-checks usage, which every usage error of the command prints after its message.
branch_required_checks_help() {
    "${SCRIPT}" branch required-checks --help
}

@test "branch required-checks help, from help branch, branch -h and branch required-checks -h, is one text that describes every exit code and calls no gh" {
    local invocation help_text=""
    for invocation in "help branch" "help branch required-checks" "branch -h" "branch --help" \
        "branch required-checks -h" "branch required-checks --help"; do
        # shellcheck disable=SC2086  # each invocation is split into its words on purpose
        run "${SCRIPT}" ${invocation}
        [ "${status}" -eq 0 ] || { echo "${invocation}: ${status}" >&2; return 1; }
        [ -n "${help_text}" ] || help_text="${output}"
        [ "${output}" = "${help_text}" ]
        [[ "${output}" == "Usage: cfwf branch required-checks --repo <owner/repo> --branch <name>"$'\n'* ]]
        [[ "${output}" == *$'\n'"--pr, --sha, --all, --json, --jq and --template are not options: the output has one fixed format."$'\n'* ]]
        [[ "${output}" == *"Check names are chosen by whoever configures the repository, so"$'\n'"read them as untrusted text."* ]]
        [[ "${output}" == *"run 'cfwf pr checks --pr <n>'; its third column is each check's completion time on the"$'\n'"current head."* ]]
        [[ "${output}" == *"Exit codes: 0 printed, an empty list included (nothing is printed); 9 the repository has no"$'\n'"branch of that name; 1 a runtime failure"*"2 a usage error." ]]
    done
    [ ! -s "${GH_LOG}" ]
}

@test "branch without a subcommand names the one it has, and one it does not have is named by its position (exit 2)" {
    run --separate-stderr "${SCRIPT}" branch
    [ "${status}" -eq 2 ]
    [ -z "${output}" ]
    [[ "${stderr}" == "cfwf: branch needs a subcommand (required-checks)"$'\n\n'"Usage: cfwf branch required-checks "* ]]

    local help_text
    help_text="$(branch_required_checks_help)"
    run --separate-stderr "${SCRIPT}" branch protection --repo "${REPO}"
    [ "${status}" -eq 2 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: unknown branch subcommand (argument 2; its value is not shown)"$'\n\n'"${help_text}" ]
    [ ! -s "${GH_LOG}" ]
}

@test "branch required-checks refuses a missing, repeated or unknown option (exit 2) before any gh call, never echoing a value" {
    local help_text
    help_text="$(branch_required_checks_help)"

    # Each case is its expected first stderr line, a tab, then the arguments; the distinctive values
    # (zz-*, 4242) are what an echo would show, and the whole of stderr is compared, so none can.
    local -a cases=(
        $'cfwf: missing required option --repo\t--branch zz-branch'
        $'cfwf: missing required option --branch\t--repo zz-owner/zz-repo'
        $'cfwf: --branch needs a value\t--repo zz-owner/zz-repo --branch'
        $'cfwf: --repo needs a value\t--branch zz-branch --repo'
        $'cfwf: --branch can only be given once\t--repo zz-owner/zz-repo --branch main --branch zz-branch'
        $'cfwf: --repo can only be given once\t--repo zz-owner/zz-repo --repo zz-other/zz-repo --branch main'
        $'cfwf: invalid value for --repo: neither the owner nor the repository can be . or ..\t--repo zz-owner/.. --branch main'
        $'cfwf: unknown option (argument 7; its value is not shown)\t--repo zz-owner/zz-repo --branch main --pr 4242'
        $'cfwf: unknown option (argument 7; its value is not shown)\t--repo zz-owner/zz-repo --branch main --sha '"${OLD_SHA}"
        $'cfwf: unknown option (argument 7; its value is not shown)\t--repo zz-owner/zz-repo --branch main --all'
        $'cfwf: unknown option (argument 7; its value is not shown)\t--repo zz-owner/zz-repo --branch main --json zz-field'
        $'cfwf: unknown option (argument 7; its value is not shown)\t--repo zz-owner/zz-repo --branch main --jq .zz'
        $'cfwf: unknown option (argument 7; its value is not shown)\t--repo zz-owner/zz-repo --branch main --template zz-tpl'
        $'cfwf: unknown option (argument 7; its value is not shown)\t--repo zz-owner/zz-repo --branch main zz-stray'
    )
    local entry expected args
    for entry in "${cases[@]}"; do
        expected="${entry%%$'\t'*}"
        args="${entry#*$'\t'}"
        # shellcheck disable=SC2086  # each case is split into its words on purpose
        run --separate-stderr "${SCRIPT}" branch required-checks ${args}
        [ "${status}" -eq 2 ] || { echo "${args}: ${status}" >&2; return 1; }
        [ -z "${output}" ]
        [ "${stderr}" = "${expected}"$'\n\n'"${help_text}" ] || { echo "${args}: ${stderr%%$'\n'*}" >&2; return 1; }
    done
    [ ! -s "${GH_LOG}" ]
}

@test "branch required-checks judges a --branch as git does, even run from a repository where @{-1} names a branch" {
    enter_checkout_with_previous_branch
    local help_text branch
    help_text="$(branch_required_checks_help)"
    for branch in '@{-1}' HEAD -main main.lock a..b; do
        run_branch_required_checks --branch "${branch}"
        [ "${status}" -eq 2 ] || { echo "accepted: ${branch} (${status})" >&2; return 1; }
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: invalid value for --branch: it must be a branch name git allows"$'\n\n'"${help_text}" ]
        [ ! -s "${GH_LOG}" ]
    done
}

@test "branch required-checks merges the branch protection and the rulesets, one name a line, sorted in the C locale" {
    write_protection main a b
    write_no_rulesets main
    run_branch_required_checks --branch main
    [ "${status}" -eq 0 ]
    [ "${output}" = $'a\nb' ]
    [ -z "${stderr}" ]

    write_branch main
    write_rulesets main b c
    run_branch_required_checks --branch main
    [ "${status}" -eq 0 ]
    [ "${output}" = $'b\nc' ]

    : > "${GH_LOG}"
    write_protection main a b
    run_branch_required_checks --branch main
    [ "${status}" -eq 0 ]
    [ "${output}" = $'a\nb\nc' ]
    [ -z "${stderr}" ]
    [ "$(gh_call_count "api repos/${REPO}/branches/main --jq ")" -eq 1 ]
    [ "$(gh_call_count "api repos/${REPO}/rules/branches/main?per_page=100 --paginate ")" -eq 1 ]
    [ "$(gh_call_count "/protection")" -eq 0 ]
    [ "$(gh_call_count "api repos/")" -eq 2 ]

    write_protection main a B
    write_rulesets main _
    run_branch_required_checks --branch main
    [ "${status}" -eq 0 ]
    [ "${output}" = $'B\n_\na' ]
}

@test "branch required-checks prints nothing (exit 0) when the branch requires no check, or its required checks are switched off" {
    write_branch main
    write_no_rulesets main
    run_branch_required_checks --branch main
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    [ -z "${stderr}" ]

    jq -n --arg sha "${HEAD_SHA}" '{name: "main", commit: {sha: $sha}, protected: true,
        protection: {enabled: true, required_status_checks: {enforcement_level: "off", contexts: ["a"], checks: [{context: "b", app_id: 1}]}}}' \
        | write_api "repos/${REPO}/branches/main"
    run_branch_required_checks --branch main
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    [ -z "${stderr}" ]
}

@test "branch required-checks prints a name required from two apps, or from both sources, once, without its app" {
    # lint is in contexts only (any app); build is pinned to app 1 in the protection and app 2 in a ruleset.
    write_protection main lint build#1
    write_rulesets main build#2 lint
    run_branch_required_checks --branch main
    [ "${status}" -eq 0 ]
    [ "${output}" = $'build\nlint' ]
    [ -z "${stderr}" ]
}

@test "branch required-checks reads the 403 for a plan with no rulesets as none, and any other failed rulesets read as a runtime failure" {
    write_protection main a b
    fail_api "repos/${REPO}/rules/branches/main" \
        "gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)"
    run_branch_required_checks --branch main
    [ "${status}" -eq 0 ]
    [ "${output}" = $'a\nb' ]
    [ -z "${stderr}" ]

    fail_api "repos/${REPO}/rules/branches/main" \
        "gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 404)"
    run_branch_required_checks --branch main
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not read the rulesets of ${REPO}: gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 404)" ]

    rm "$(api_fixture "repos/${REPO}/rules/branches/main").fail"
    run_branch_required_checks --branch main
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not read the rulesets of ${REPO}: gh: Not Found (HTTP 404)" ]

    fail_api "repos/${REPO}/rules/branches/main" "gh: Resource not accessible by integration (HTTP 403)"
    run_branch_required_checks --branch main
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not read the rulesets of ${REPO}: gh: Resource not accessible by integration (HTTP 403)" ]
}

@test "branch required-checks exits 9 for a branch that is not there, 1 for a repository that is not, and 1 for any other failed branch read, without reading the rulesets" {
    write_rulesets main build
    jq -n '{id: 1}' | write_api "repos/${REPO}"
    run_branch_required_checks --branch main
    [ "${status}" -eq 9 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: the --branch was not found in ${REPO}" ]
    [ "$(gh_call_count "rules/branches")" -eq 0 ]

    rm "$(api_fixture "repos/${REPO}").json"
    run_branch_required_checks --branch main
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: the repository ${REPO} was not found, or the caller cannot see it" ]

    : > "${GH_LOG}"
    fail_api "repos/${REPO}/branches/main"
    run_branch_required_checks --branch main
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not read the --branch of ${REPO}: gh: Bad Gateway (HTTP 502)" ]
    [ "$(gh_call_count "rules/branches")" -eq 0 ]
    [ "$(gh_call_count "api repos/")" -eq 1 ]
}

@test "branch required-checks prints each control character in a name as a space, so a name never adds a line, and names that then print alike once" {
    write_branch main
    write_rulesets main $'x\ty\nz\x1bw\x7fv\xc2\x9bu\x1ft\xc2\xa0s'
    run_branch_required_checks --branch main
    [ "${status}" -eq 0 ]
    [ "${output}" = $'x y z w v u t\xc2\xa0s' ]
    [[ "${output}" != *$'\xc2\x9b'* ]]
    [ -z "${stderr}" ]

    write_rulesets main $'a\tb' $'a\nb' 'a b'
    run_branch_required_checks --branch main
    [ "${status}" -eq 0 ]
    [ "${output}" = "a b" ]
}

@test "branch required-checks refuses an empty check name as an unexpected answer (exit 1), printing nothing" {
    jq -n --arg sha "${HEAD_SHA}" '{name: "main", commit: {sha: $sha}, protected: true,
        protection: {enabled: true, required_status_checks: {enforcement_level: "non_admins", contexts: ["build", ""], checks: [{context: "build", app_id: 1}]}}}' \
        | write_api "repos/${REPO}/branches/main"
    write_rulesets main lint
    run_branch_required_checks --branch main
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: gh returned an unexpected result for the required checks of ${REPO}" ]
}

@test "branch required-checks percent-encodes a --branch for both reads, keeping a slash as it is" {
    write_protection release/1.0 build
    write_rulesets release/1.0 lint
    run_branch_required_checks --branch release/1.0
    [ "${status}" -eq 0 ]
    [ "${output}" = $'build\nlint' ]
    [ "$(gh_call_count "api repos/${REPO}/branches/release/1.0 --jq ")" -eq 1 ]
    [ "$(gh_call_count "api repos/${REPO}/rules/branches/release/1.0?per_page=100 --paginate ")" -eq 1 ]
    [ "$(gh_call_count "%2F")" -eq 0 ]

    write_protection "release/v2%2Blts" build
    write_no_rulesets "release/v2%2Blts"
    run_branch_required_checks --branch release/v2+lts
    [ "${status}" -eq 0 ]
    [ "${output}" = build ]
    [ "$(gh_call_count "api repos/${REPO}/branches/release/v2%2Blts --jq ")" -eq 1 ]
    [ "$(gh_call_count "api repos/${REPO}/rules/branches/release/v2%2Blts?per_page=100 --paginate ")" -eq 1 ]

    write_protection "feat/caf%C3%A9%40x%25y" build
    write_rulesets "feat/caf%C3%A9%40x%25y" lint
    run_branch_required_checks --branch "$(printf 'feat/caf\xc3\xa9@x%%y')"
    [ "${status}" -eq 0 ]
    [ "${output}" = $'build\nlint' ]
    [ -z "${stderr}" ]
    [ "$(gh_call_count "api repos/${REPO}/branches/feat/caf%C3%A9%40x%25y --jq ")" -eq 1 ]
    [ "$(gh_call_count "api repos/${REPO}/rules/branches/feat/caf%C3%A9%40x%25y?per_page=100 --paginate ")" -eq 1 ]
}

@test "branch required-checks fails (exit 1) when gh is not installed, after the options are checked, and when git is not" {
    mkdir -p "${TEST_TMP}/empty-path" "${TEST_TMP}/git-only"
    ln -s "$(command -v git)" "${TEST_TMP}/git-only/git"
    local bash_path
    bash_path="$(command -v bash)"
    run --separate-stderr env PATH="${TEST_TMP}/git-only" "${bash_path}" "${SCRIPT}" branch required-checks --repo "${REPO}" --branch main
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == "cfwf: gh is not installed"* ]]

    # Only the first line is compared: without cat on the PATH the usage after it cannot be printed.
    run --separate-stderr env PATH="${TEST_TMP}/git-only" "${bash_path}" "${SCRIPT}" branch required-checks --repo "${REPO}" --branch main --json zz-field
    [ "${status}" -eq 2 ]
    [ -z "${output}" ]
    [ "${stderr%%$'\n'*}" = "cfwf: unknown option (argument 7; its value is not shown)" ]
    [[ "${stderr}" != *"zz-field"* ]]

    # --branch is judged by git, so a host without it is a runtime failure, not a usage error.
    run --separate-stderr env PATH="${TEST_TMP}/empty-path" "${bash_path}" "${SCRIPT}" branch required-checks --repo "${REPO}" --branch main
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == "cfwf: git is not installed"* ]]
}

@test "branch required-checks leaves no temporary file behind, whether the read works or fails" {
    local scratch="${TEST_TMP}/scratch"
    mkdir -p "${scratch}"
    write_protection main build
    write_no_rulesets main
    TMPDIR="${scratch}" run_branch_required_checks --branch main
    [ "${status}" -eq 0 ]
    [ -z "$(ls -A "${scratch}")" ]

    fail_api "repos/${REPO}/rules/branches/main"
    TMPDIR="${scratch}" run_branch_required_checks --branch main
    [ "${status}" -eq 1 ]
    [ -z "$(ls -A "${scratch}")" ]

    # The checks above would pass if no temporary file were ever made: one that cannot be made
    # under TMPDIR stops the read, which shows the file is made there and so was removed.
    : > "${GH_LOG}"
    TMPDIR="${TEST_TMP}/no-such-dir" run_branch_required_checks --branch main
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == *"cfwf: could not create a temporary file" ]]
    [ ! -s "${GH_LOG}" ]
}

# --- pr checks-wait ------------------------------------------------------------

# Stand-ins for the clock and for sleep, on top of prepare_pr_checks: date +%s prints the seconds in
# CLOCK_FILE (any other date call runs the real one), and each sleep logs its argument to SLEEP_LOG,
# adds it to the clock and, on its n-th call, copies the fixtures saved as stage n+1 (save_stage)
# over GH_FIXTURES, so the next read sees the next state.
prepare_checks_wait() {
    prepare_pr_checks
    export CLOCK_FILE="${TEST_TMP}/clock" SLEEP_LOG="${TEST_TMP}/sleep.log" STAGES="${TEST_TMP}/stages"
    printf '0\n' > "${CLOCK_FILE}"
    : > "${SLEEP_LOG}"
    mkdir -p "${STAGES}"
    local real_date
    real_date="$(command -v date)"
    # The stub bodies are deliberately single-quoted: they must expand when the stub runs, not here.
    # shellcheck disable=SC2016
    make_stub_multiline date \
        'if [ "$*" = "+%s" ]; then cat "${CLOCK_FILE}"; exit 0; fi' \
        "exec ${real_date} \"\$@\""
    # shellcheck disable=SC2016
    make_stub_multiline sleep \
        'printf "%s\n" "$1" >> "${SLEEP_LOG}"' \
        'printf "%s\n" "$(($(cat "${CLOCK_FILE}") + $1))" > "${CLOCK_FILE}"' \
        'next="${STAGES}/$(($(wc -l < "${SLEEP_LOG}") + 1))"' \
        '[ ! -d "${next}" ] || cp -f "${next}"/* "${GH_FIXTURES}/"'
}

# Saves the API fixtures as they are now as the stage $1, which the sleep stand-in copies back over
# GH_FIXTURES after its ($1 - 1)-th call.
save_stage() {
    mkdir -p "${STAGES}/$1"
    cp -f "${GH_FIXTURES}"/api-*.json "${STAGES}/$1/"
}

sleep_count() {
    wc -l < "${SLEEP_LOG}"
}

run_checks_wait() {
    run --separate-stderr "${SCRIPT}" pr checks-wait --repo "${REPO}" "$@"
}

@test "pr checks-wait help, from help, -h and --help, gives the usage and every exit code, and calls no gh (#1626)" {
    local invocation
    for invocation in "help pr checks-wait" "pr checks-wait -h" "pr checks-wait --help"; do
        # shellcheck disable=SC2086  # each invocation is split into its words on purpose
        run "${SCRIPT}" ${invocation}
        [ "${status}" -eq 0 ] || { echo "${invocation}: ${status}" >&2; return 1; }
        [[ "${output}" == "Usage: cfwf pr checks-wait --repo <owner/repo> --pr <n> [--timeout-minutes <m>]"* ]]
        [[ "${output}" == *"from 1 to 120 minutes (default 30)"* ]]
        [[ "${output}" == *"  3  at least one check failed"*"  4  the time limit passed with checks still pending"* ]]
        [[ "${output}" == *"  5  the time limit passed and the head still has no check runs"*"  6  a gh, API or network failure"* ]]
    done
    run "${SCRIPT}" help
    [[ "${output}" == *"pr checks-wait           Wait for a PR's required checks to finish"* ]]
    run "${SCRIPT}" pr checks --help
    [[ "${output}" == *"Run 'cfwf pr checks-wait --help' for pr checks-wait"* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "pr checks-wait usage errors exit 2 before any gh call (#1626)" {
    local -a cases=(
        ""
        "--pr 42 --pr 43"
        "--pr x42"
        "--pr 0"
        "--pr 42 --sha ${HEAD_SHA}"
        "--pr 42 --branch main"
        "--pr 42 --all"
        "--pr 42 --json name"
        "--pr 42 --jq ."
        "--pr 42 --template x"
        "--pr 42 --watch"
        "--pr 42 --interval 10"
        "--pr 42 --timeout-minutes 0"
        "--pr 42 --timeout-minutes 121"
        "--pr 42 --timeout-minutes abc"
        "--pr 42 --timeout-minutes -1"
        "--pr 42 --timeout-minutes 1.5"
        "--pr 42 --timeout-minutes 5 --timeout-minutes 6"
        "--pr 42 --timeout-minutes"
    )
    local args
    for args in "${cases[@]}"; do
        # shellcheck disable=SC2086  # each case is split into its words on purpose
        run_checks_wait ${args}
        [ "${status}" -eq 2 ] || { echo "accepted: ${args} (${status})" >&2; return 1; }
        [ -z "${output}" ]
        [[ "${stderr}" == *"Usage: cfwf pr checks-wait"* ]]
    done

    run --separate-stderr "${SCRIPT}" pr checks-wait --pr 42
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == *"missing required option --repo"* ]]

    run_checks_wait --pr 42 --timeout-minutes 121
    [[ "${stderr}" == *"invalid value for --timeout-minutes: it must be at most 120 minutes"* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "pr checks-wait reports an all-pass only after a second read of the same head still passes (#1626)" {
    prepare_checks_wait
    run_checks_wait --pr 42
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ "${output}" = "build"$'\t'"pass"$'\t'"${COMPLETED_AT}"$'\t'"11"$'\n'"summary passed=1 failed=0 pending=0 head=${HEAD_SHA}" ]
    [ "$(sleep_count)" -eq 1 ]
    [ "$(cat "${SLEEP_LOG}")" = "30" ]
    [ "$(gh_call_count "api repos/${REPO}/pulls/42 ")" -eq 2 ]
    [ "$(gh_call_count "api repos/${REPO}/commits/${HEAD_SHA}/check-runs?per_page=100&filter=all --paginate ")" -eq 2 ]
}

@test "pr checks-wait keeps waiting while checks are pending, then reports the confirmed pass (#1626)" {
    prepare_checks_wait
    write_check_runs "${HEAD_SHA}" "$(check_run build "" 11)"
    save_stage 1
    write_check_runs "${HEAD_SHA}" "$(check_run build success 11)"
    save_stage 2
    cp -f "${STAGES}/1"/* "${GH_FIXTURES}/"
    run_checks_wait --pr 42
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"summary passed=1 failed=0 pending=0 head=${HEAD_SHA}" ]]
    [ "$(sleep_count)" -eq 2 ]
}

@test "pr checks-wait keeps waiting while the head has no checks at all yet (#1626)" {
    prepare_checks_wait
    write_check_runs "${HEAD_SHA}"
    save_stage 1
    write_check_runs "${HEAD_SHA}" "$(check_run build success 11)"
    save_stage 2
    cp -f "${STAGES}/1"/* "${GH_FIXTURES}/"
    run_checks_wait --pr 42
    [ "${status}" -eq 0 ]
    [ "$(sleep_count)" -eq 2 ]
}

@test "pr checks-wait exits 3 at once for a failed check, without waiting (#1626)" {
    prepare_checks_wait
    write_check_runs "${HEAD_SHA}" "$(check_run build failure 11)"
    run_checks_wait --pr 42
    [ "${status}" -eq 3 ]
    [ "${output}" = "build"$'\t'"fail"$'\t'"${COMPLETED_AT}"$'\t'"11"$'\n'"summary passed=0 failed=1 pending=0 head=${HEAD_SHA}" ]
    [ "$(sleep_count)" -eq 0 ]
}

@test "pr checks-wait exits 3 when a pass is followed by a failure on the confirming read (#1626)" {
    prepare_checks_wait
    save_stage 1
    write_check_runs "${HEAD_SHA}" "$(check_run build success 11)" "$(check_run build cancelled 12)"
    save_stage 2
    cp -f "${STAGES}/1"/* "${GH_FIXTURES}/"
    run_checks_wait --pr 42
    [ "${status}" -eq 3 ]
    [[ "${output}" == *"summary passed=0 failed=1 pending=0 head=${HEAD_SHA}" ]]
    [ "$(sleep_count)" -eq 1 ]
}

@test "pr checks-wait exits 4 at the time limit with checks still pending, printing the last read (#1626)" {
    prepare_checks_wait
    write_check_runs "${HEAD_SHA}" "$(check_run build "" 11)"
    run_checks_wait --pr 42 --timeout-minutes 1
    [ "${status}" -eq 4 ]
    [ "${output}" = "build"$'\t'"pending"$'\t'$'\t'"11"$'\n'"summary passed=0 failed=0 pending=1 head=${HEAD_SHA}" ]
    [ "${stderr}" = "cfwf: the checks have not finished after 1 minutes" ]
    # Reads at 0, 30 and 60 seconds: the third is at the limit.
    [ "$(sleep_count)" -eq 2 ]
    [ "$(gh_call_count "api repos/${REPO}/pulls/42 ")" -eq 3 ]
}

@test "pr checks-wait waits 30 minutes by default (#1626)" {
    prepare_checks_wait
    write_check_runs "${HEAD_SHA}" "$(check_run build "" 11)"
    run_checks_wait --pr 0042
    [ "${status}" -eq 4 ]
    [ "$(sleep_count)" -eq 60 ]
    [ "$(cat "${CLOCK_FILE}")" -eq 1800 ]
    [ "$(gh_call_count "pulls/0")" -eq 0 ]
}

@test "pr checks-wait exits 5 at the time limit when the head still has no checks at all (#1626)" {
    prepare_checks_wait
    write_check_runs "${HEAD_SHA}"
    write_protection main
    run_checks_wait --pr 42 --timeout-minutes 1
    [ "${status}" -eq 5 ]
    [ "${output}" = "summary passed=0 failed=0 pending=0 head=${HEAD_SHA}" ]
}

@test "pr checks-wait gives a confirming read even at the time limit (#1626)" {
    prepare_checks_wait
    write_check_runs "${HEAD_SHA}" "$(check_run build "" 11)"
    save_stage 1
    save_stage 2
    write_check_runs "${HEAD_SHA}" "$(check_run build success 11)"
    save_stage 3
    cp -f "${STAGES}/1"/* "${GH_FIXTURES}/"
    # Pending at 0 and 30 seconds, a first pass at 60 (the limit), confirmed at 90.
    run_checks_wait --pr 42 --timeout-minutes 1
    [ "${status}" -eq 0 ]
    [ "$(sleep_count)" -eq 3 ]
}

@test "pr checks-wait exits 6 for a failed read, never 3, and prints no verdict (#1626)" {
    prepare_checks_wait
    fail_api "repos/${REPO}/commits/${HEAD_SHA}/check-runs"
    run_checks_wait --pr 42
    [ "${status}" -eq 6 ]
    [ -z "${output}" ]
    [[ "${stderr}" == "cfwf: could not read the check runs of ${HEAD_SHA}: gh: Bad Gateway (HTTP 502)"* ]]
    [ "$(sleep_count)" -eq 0 ]

    rm -f "$(api_fixture "repos/${REPO}/commits/${HEAD_SHA}/check-runs").fail"
    rm -f "$(api_fixture "repos/${REPO}/pulls/42").json"
    run_checks_wait --pr 42
    [ "${status}" -eq 6 ]
    [ "${stderr}" = "cfwf: ${REPO}#42 was not found" ]
}

@test "pr checks-wait exits 6 when a later read fails after a pending one (#1626)" {
    prepare_checks_wait
    write_check_runs "${HEAD_SHA}" "$(check_run build "" 11)"
    mkdir -p "${STAGES}/2"
    printf '%s\n' "gh: Bad Gateway (HTTP 502)" \
        > "${STAGES}/2/$(basename "$(api_fixture "repos/${REPO}/commits/${HEAD_SHA}/status")").fail"
    run_checks_wait --pr 42
    [ "${status}" -eq 6 ]
    [ -z "${output}" ]
    [[ "${stderr}" == "cfwf: could not read the commit statuses of ${HEAD_SHA}: gh: Bad Gateway (HTTP 502)"* ]]
    [ "$(sleep_count)" -eq 1 ]
}

@test "pr checks-wait starts the confirmation again when the head changes while it waits (#1626)" {
    prepare_checks_wait
    save_stage 1
    jq -n --arg sha "${OLD_SHA}" '{number: 42, head: {sha: $sha}, base: {ref: "main"}}' | write_api "repos/${REPO}/pulls/42"
    write_check_runs "${OLD_SHA}" "$(check_run build success 21 "" "${OLD_SHA}")"
    write_statuses "${OLD_SHA}"
    save_stage 2
    cp -f "${STAGES}/1"/* "${GH_FIXTURES}/"
    run_checks_wait --pr 42
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"summary passed=1 failed=0 pending=0 head=${OLD_SHA}" ]]
    # Pass on the first head, pass on the new head (not a confirmation), then the confirming read.
    [ "$(sleep_count)" -eq 2 ]
}

# --- pr post-merge-runs (#1605) ---------------------------------------------------

POST_MERGE_USAGE="Usage: cfwf pr post-merge-runs --repo <owner/repo> --pr <n>"
POST_MERGE_PR=7
POST_MERGE_SHA="${RUN_SHA}"

# Writes the pull request POST_MERGE_PR as gh pr view answers it: the state $1 (MERGED), the merge
# commit $2 (POST_MERGE_SHA, "" for none) and the base branch main, beside fields not asked for.
write_post_merge_pr() {
    jq -n --arg state "${1:-MERGED}" --arg sha "${2-${POST_MERGE_SHA}}" \
        '{state: $state, mergeCommit: (if $sha == "" then null else {oid: $sha} end), baseRefName: "main",
          headRefOid: "0000000000000000000000000000000000000000", title: "feat: a change"}' > "${GH_FIXTURES}/pr-view.json"
}

# Writes the run list answer for the merge commit on main: each argument is "id|workflow|status|conclusion|event",
# created one minute apart in the order given, so the last is the newest.
write_post_merge_runs() {
    local row id workflow status conclusion event minute=0
    local -a rows=()
    for row in "$@"; do
        IFS='|' read -r id workflow status conclusion event <<< "${row}"
        rows+=("${id}|${workflow}|${status}|${conclusion}|${POST_MERGE_SHA}|main|${event}|2026-11-02T10:$(printf '%02d' "${minute}"):00Z")
        minute=$((minute + 1))
    done
    write_run_list "${rows[@]}"
}

run_post_merge_runs() {
    run --separate-stderr "${SCRIPT}" pr post-merge-runs --repo "${REPO}" --pr "${POST_MERGE_PR}" "$@"
}

# One expected run line: the fields given, joined with tabs.
post_merge_line() {
    local IFS=$'\t'
    printf '%s' "$*"
}

post_merge_summary() {
    printf 'summary\tpassed=%s failed=%s pending=%s merge=%s' "$1" "$2" "$3" "${POST_MERGE_SHA}"
}

@test "pr post-merge-runs passes (exit 0) when each workflow's run on the merge commit passed, a workflow_dispatch run included, in two reads with no event filter" {
    write_post_merge_pr
    write_post_merge_runs "21|build|completed|success|push" "22|lint|completed|skipped|push" \
        "23|deploy|completed|success|workflow_dispatch" "24|docs|completed|neutral|push"
    run_post_merge_runs
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    local expected
    expected="$(post_merge_line 24 docs completed neutral push)"$'\n'
    expected+="$(post_merge_line 23 deploy completed success workflow_dispatch)"$'\n'
    expected+="$(post_merge_line 22 lint completed skipped push)"$'\n'
    expected+="$(post_merge_line 21 build completed success push)"$'\n'
    expected+="$(post_merge_summary 4 0 0)"
    [ "${output}" = "${expected}" ]
    [ "$(wc -l < "${GH_LOG}")" -eq 2 ]
    [ "$(gh_line_of "pr view ${POST_MERGE_PR} --repo ${REPO} --json state,mergeCommit,baseRefName --jq ")" -eq 1 ]
    [ "$(gh_line_of "run list --repo ${REPO} --branch=main --commit=${POST_MERGE_SHA} --all --limit 201 --json databaseId,workflowName,status,conclusion,headSha,headBranch,event,createdAt --jq ")" -eq 2 ]
    [ "$(sed 's/--json [^ ]*//' "${GH_LOG}" | grep -cE -- "--event|event=")" -eq 0 ]
}

@test "pr post-merge-runs fails (exit 3) for a failure, and for a cancelled, timed out, action-required, stale or startup-failure run, as pr checks does" {
    local conclusion
    write_post_merge_pr
    for conclusion in failure cancelled timed_out action_required stale startup_failure; do
        write_post_merge_runs "21|build|completed|success|push" "22|test|completed|${conclusion}|workflow_dispatch" "23|lint|in_progress||push"
        run_post_merge_runs
        if [ "${status}" -ne 3 ]; then
            echo "${conclusion}: ${status}" >&2
            return 1
        fi
        [[ "${output}" == *$'\n'"$(post_merge_line 22 test completed "${conclusion}" workflow_dispatch)"$'\n'* ]]
        [[ "${output}" == *$'\n'"$(post_merge_summary 1 1 1)" ]]
    done
}

@test "pr post-merge-runs is pending (exit 4) when none failed and a run has no conclusion yet, printing - for it" {
    write_post_merge_pr
    write_post_merge_runs "21|build|completed|success|push" "22|deploy|queued||workflow_dispatch"
    run_post_merge_runs
    [ "${status}" -eq 4 ]
    [ "${output}" = "$(post_merge_line 22 deploy queued - workflow_dispatch)"$'\n'"$(post_merge_line 21 build completed success push)"$'\n'"$(post_merge_summary 1 0 1)" ]
}

@test "pr post-merge-runs exits 5 with only the summary when the merge commit has no runs yet" {
    write_post_merge_pr
    write_post_merge_runs
    run_post_merge_runs
    [ "${status}" -eq 5 ]
    [ -z "${stderr}" ]
    [ "${output}" = "$(post_merge_summary 0 0 0)" ]
}

@test "pr post-merge-runs marks an older run cancelled by a newer run of its workflow superseded and does not count it" {
    write_post_merge_pr
    write_post_merge_runs "21|build|completed|cancelled|push" "22|lint|completed|success|push" "23|build|completed|success|workflow_dispatch"
    run_post_merge_runs
    [ "${status}" -eq 0 ]
    local expected
    expected="$(post_merge_line 23 build completed success workflow_dispatch)"$'\n'
    expected+="$(post_merge_line 22 lint completed success push)"$'\n'
    expected+="$(post_merge_line 21 build superseded cancelled push)"$'\n'
    expected+="$(post_merge_summary 2 0 0)"
    [ "${output}" = "${expected}" ]

    # A newer run still running keeps the workflow pending, never failed by the run it replaced.
    write_post_merge_runs "21|build|completed|cancelled|push" "23|build|in_progress||push"
    run_post_merge_runs
    [ "${status}" -eq 4 ]
    [ "${output}" = "$(post_merge_line 23 build in_progress - push)"$'\n'"$(post_merge_line 21 build superseded cancelled push)"$'\n'"$(post_merge_summary 0 0 1)" ]

    # A newer skipped run does not hide an older failure: the failure is judged, the skipped run is not counted.
    write_post_merge_runs "21|build|completed|failure|push" "23|build|completed|skipped|push"
    run_post_merge_runs
    [ "${status}" -eq 3 ]
    [ "${output}" = "$(post_merge_line 23 build superseded skipped push)"$'\n'"$(post_merge_line 21 build completed failure push)"$'\n'"$(post_merge_summary 0 1 0)" ]
}

@test "pr post-merge-runs refuses (exit 6) a pull request that is not merged, without listing runs, and exits 9 for a number that is no pull request" {
    local state
    for state in OPEN CLOSED; do
        rm -f "${GH_LOG}"
        write_post_merge_pr "${state}" ""
        run_post_merge_runs
        if [ "${status}" -ne 6 ]; then
            echo "${state}: ${status}" >&2
            return 1
        fi
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: ${REPO}#${POST_MERGE_PR} is not merged" ]
        [ "$(wc -l < "${GH_LOG}")" -eq 1 ]
    done

    rm -f "${GH_LOG}"
    printf 'GraphQL: Could not resolve to a PullRequest with the number of %s. (repository.pullRequest)\n' "${POST_MERGE_PR}" > "${GH_FIXTURES}/pr-view.fail"
    run_post_merge_runs
    [ "${status}" -eq 9 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: the pull request ${REPO}#${POST_MERGE_PR} was not found" ]
    [ "$(wc -l < "${GH_LOG}")" -eq 1 ]
}

@test "pr post-merge-runs exits 1 with nothing printed, never a verdict, when a read fails or answers what it does not expect" {
    printf 'HTTP 502: Bad Gateway\n' > "${GH_FIXTURES}/pr-view.fail"
    run_post_merge_runs
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not read ${REPO}#${POST_MERGE_PR}: HTTP 502: Bad Gateway" ]
    rm -f "${GH_FIXTURES}/pr-view.fail"

    write_post_merge_pr MERGED ""
    run_post_merge_runs
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: gh returned an unexpected result for ${REPO}#${POST_MERGE_PR}" ]

    write_post_merge_pr
    printf 'HTTP 502: Bad Gateway\n' > "${GH_FIXTURES}/run-list.fail"
    run_post_merge_runs
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not list the runs of ${REPO}: HTTP 502: Bad Gateway" ]
    rm -f "${GH_FIXTURES}/run-list.fail"

    write_run_list "21|build|completed|failure|${MOVED_SHA}|main|push|2026-11-02T10:00:00Z"
    run_post_merge_runs
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: gh returned an unexpected result for the runs of ${REPO}" ]

    write_run_list "21|build|completed|failure|${POST_MERGE_SHA}|feat/x|push|2026-11-02T10:00:00Z"
    run_post_merge_runs
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]

    printf '201\n' > "${GH_FIXTURES}/run-list.out"
    run_post_merge_runs
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: the merge commit ${POST_MERGE_SHA} of ${REPO}#${POST_MERGE_PR} has more than 200 runs, so none is judged" ]
}

@test "pr post-merge-runs usage errors exit 2 with its usage on stderr and nothing on stdout, never echoing a value, before any gh call" {
    local repo="--repo ${REPO}" args
    local -a cases=(
        "" "${repo}" "--pr 7" "${repo} --pr x" "${repo} --pr 0" "${repo} --pr -1" "${repo} --pr 7 --pr 7"
        "--repo x --pr 7" "${repo} ${repo} --pr 7" "${repo} --pr 7 --sha ${RUN_SHA}" "${repo} --pr 7 --branch main"
        "${repo} --pr 7 --event push" "${repo} --pr 7 --json state" "${repo} --pr 7 --jq ." "${repo} --pr 7 --field state"
        "${repo} --pr 7 --limit 5" "${repo} --pr 7 extra" "${repo} --pr"
    )
    for args in "${cases[@]}"; do
        # shellcheck disable=SC2086  # each case is split into its words on purpose
        run --separate-stderr "${SCRIPT}" pr post-merge-runs ${args}
        if [ "${status}" -ne 2 ]; then
            echo "accepted: ${args} (${status})" >&2
            return 1
        fi
        [ -z "${output}" ]
        if [[ "${stderr}" != "cfwf: "*$'\n\n'"${POST_MERGE_USAGE}"$'\n'* ]]; then
            echo "usage: ${args}" >&2
            return 1
        fi
    done
    local secret="ghp_${RANDOM}abcdefghijklmnopqrstuvwxyz0123456789"
    run_post_merge_runs "${secret}"
    [ "${status}" -eq 2 ]
    [[ "${stderr}" != *"${secret}"* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "pr post-merge-runs help, from -h, --help and help, gives the usage, the rules, the output and every exit code; help pr and the general help point to it; none calls gh" {
    local invocation
    for invocation in "pr post-merge-runs -h" "pr post-merge-runs --help" "help pr post-merge-runs"; do
        # shellcheck disable=SC2086  # each invocation is split into its words on purpose
        run --separate-stderr "${SCRIPT}" ${invocation}
        [ "${status}" -eq 0 ]
        [ -z "${stderr}" ]
        [[ "${output}" == "${POST_MERGE_USAGE}"$'\n'* ]]
        [[ "${output}" == *"with no event filter, so a run started by a workflow_dispatch after"* ]]
        [[ "${output}" == *"At most 200 runs are judged"* ]]
        [[ "${output}" == *"  fail     failure, cancelled, timed_out, action_required, startup_failure, stale or any other"* ]]
        [[ "${output}" == *"printed with the status superseded and its"$'\n'"own conclusion, and is not counted."* ]]
        [[ "${output}" == *"  <run_id>  <workflow>  <status>  <conclusion>  <event>"$'\n'"  summary  passed=<a> failed=<b> pending=<c> merge=<sha>"* ]]
        [[ "${output}" == *"Exit codes: 0 every workflow's run passed; 3 at least one failed; 4 none failed and at least one is"$'\n'"pending; 5 the merge commit has no runs yet"* ]]
        [[ "${output}" == *$'\n'"6 the pull request is not merged, with \"cfwf: <owner/repo>#<n> is not merged\"; 9 the pull"$'\n'* ]]
        [[ "${output}" != *"usage_"* ]]
    done
    run "${SCRIPT}" help pr
    [ "${status}" -eq 0 ]
    [[ "${output}" == *$'\n'"Run 'cfwf pr post-merge-runs --help' for pr post-merge-runs, which judges the Actions runs on a"$'\n'"merged pull request's merge commit, on its base branch."$'\n'* ]]
    run "${SCRIPT}" help
    [ "${status}" -eq 0 ]
    [[ "${output}" == *$'\n'"  pr checks-wait           Wait for a PR's required checks to finish, up to a time limit (exit 0, 3, 4, 5 or 6)"$'\n'"  pr post-merge-runs       Judge the Actions runs on a merged PR's merge commit, on its base branch (exit 0, 3, 4, 5 or 6)"$'\n'* ]]
    [ ! -f "${GH_LOG}" ]
}
