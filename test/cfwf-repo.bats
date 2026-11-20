#!/usr/bin/env bats
# shellcheck disable=SC2154  # stderr is set by run --separate-stderr

bats_require_minimum_version 1.5.0

load test_helper
load cfwf_helper

# --- repo view, repo collaborators and auth status ------------------------------
# The fixture path (without .json, .fail or .out) the gh stub reads for the repo view read of REPO.
repository_fixture() {
    printf '%s/repository-%s' "${GH_FIXTURES}" "${REPO//\//_}"
}

# Writes REPO as gh repo view --json answers it: its default branch main, public, with a
# description, merge commits allowed and squash and rebase merges not, and two fields repo view
# does not ask for. An optional jq filter $1 changes it.
write_repository_metadata() {
    jq -n '{defaultBranchRef: {name: "main"}, description: "Runs the agents", visibility: "PUBLIC",
            mergeCommitAllowed: true, squashMergeAllowed: false, rebaseMergeAllowed: false,
            name: "decoy-name", url: "https://example.com/decoy"} | '"${1:-.}" > "$(repository_fixture).json"
}

# Makes the repo view read of REPO fail with the error text $1.
fail_repository() {
    printf '%s\n' "$1" > "$(repository_fixture).fail"
}

# The six lines repo view prints for the repository write_repository_metadata writes, with the description
# $1 in place of its own when one is given.
repo_view_lines() {
    printf 'default-branch\tmain\nvisibility\tPUBLIC\nallow-merge-commit\tyes\nallow-squash-merge\tno\nallow-rebase-merge\tno\ndescription\t%s' \
        "${1-Runs the agents}"
}

run_repo() {
    local subcommand="$1"
    shift
    run --separate-stderr "${SCRIPT}" repo "${subcommand}" --repo "${REPO}" "$@"
}

# Writes the rate limits as the REST API answers them, with fields auth status does not ask for. An
# optional jq filter $1 changes them; further arguments are options for jq.
write_rate_limit() {
    local filter="${1:-.}"
    shift || true
    jq -n --argjson core "${CORE_RESET}" --argjson graphql "${GRAPHQL_RESET}" "$@" \
        '{resources: {core: {limit: 5000, remaining: 4992, reset: $core, used: 8},
                      search: {limit: 30, remaining: 29, reset: 1, used: 1},
                      graphql: {limit: 6000, remaining: 5996, reset: $graphql, used: 4}},
          rate: {limit: 1, remaining: 1, reset: 1, used: 0}} | '"${filter}" | write_api rate_limit
}

# Writes the answers auth status reads: the first lines of gh --version, the authenticated user
# credfeto and the rate limits, each with fields auth status does not ask for.
prepare_auth_status() {
    printf '%s\n' "gh version 2.102.0 (2026-09-30)" "https://github.com/cli/cli/releases/tag/v2.102.0" > "${GH_FIXTURES}/gh-version.out"
    jq -n '{login: "credfeto", id: 1, name: "decoy-name", email: "decoy@example.com"}' | write_api user
    write_rate_limit
}

# Runs auth status with no GH_HOST, whatever the host running the tests has set.
run_auth_status() {
    run --separate-stderr env -u GH_HOST "${SCRIPT}" auth status "$@"
}

# The three lines auth status always prints, for the host $1 (github.com when none is given).
auth_status_lines() {
    printf 'login\tcredfeto\nhost\t%s\ngh\t2.102.0' "${1:-github.com}"
}

# The six lines --rate-limit adds for the rate limits write_rate_limit writes.
rate_limit_lines() {
    printf 'core-remaining\t4992\ncore-limit\t5000\ncore-reset\t%s\ngraphql-remaining\t5996\ngraphql-limit\t6000\ngraphql-reset\t%s' \
        "${CORE_RESET_AT}" "${GRAPHQL_RESET_AT}"
}

@test "repo view, repo collaborators and auth status help is the same from -h, --help and help with the command and its subcommand, is that command's alone, states its format, order, limit, refusals and exit codes, help repo gives both repo usages, and none calls gh" {
    local pair spelling expected
    for pair in "repo view" "repo collaborators" "auth status"; do
        # shellcheck disable=SC2086  # each pair is split into its two words on purpose
        run "${SCRIPT}" ${pair} -h
        [ "${status}" -eq 0 ]
        expected="${output}"
        [[ "${expected}" == "Usage: cfwf ${pair} "* ]]
        for spelling in "${pair} --help" "help ${pair}" "-h ${pair}" "--help ${pair}"; do
            # shellcheck disable=SC2086  # each spelling is split into its words on purpose
            run "${SCRIPT}" ${spelling}
            [ "${status}" -eq 0 ]
            [ "${output}" = "${expected}" ] || { echo "${spelling} differs from ${pair} -h" >&2; return 1; }
        done
    done

    run "${SCRIPT}" repo view -h
    [[ "${output}" == "Usage: cfwf repo view --repo <owner/repo>"$'\n'* ]]
    [[ "${output}" == *"always in this order"*"  default-branch "*"  visibility "*"  allow-merge-commit "*"  allow-squash-merge "*"  allow-rebase-merge "*"  description "* ]]
    [[ "${output}" == *"read that as not known, never as"* ]]
    [[ "${output}" == *"read it as untrusted text"* ]]
    [[ "${output}" == *"Exit codes: 0 printed; 1 a runtime failure"*"a repository that was"*"not found or that the caller cannot see"*"2 a usage error."* ]]
    [[ "${output}" != *"cfwf repo collaborators"* ]]

    run "${SCRIPT}" repo collaborators -h
    [[ "${output}" == "Usage: cfwf repo collaborators --repo <owner/repo>"$'\n'* ]]
    [[ "${output}" == *"sorted by login in the C locale (byte order, so every upper-case letter"*"comes before every lower-case one)"* ]]
    [[ "${output}" == *"  <login>  <role>"* ]]
    [[ "${output}" == *'"-" when GitHub gives none'* ]]
    [[ "${output}" == *"At most 1000 collaborators are listed. More than that is a runtime failure and nothing is"*"printed, never part of the list."* ]]
    [[ "${output}" == *"read is refused (HTTP 403), which is a runtime failure, never an empty list."* ]]
    [[ "${output}" == *"Exit codes: 0 listed, an empty list included (nothing is printed); 1 a runtime failure"*"2 a usage error."* ]]
    [[ "${output}" != *"cfwf repo view"* ]]

    run "${SCRIPT}" auth status -h
    [[ "${output}" == "Usage: cfwf auth status [--rate-limit]"$'\n'* ]]
    [[ "${output}" == *"It never prints a token."* ]]
    [[ "${output}" == *"  login "*"  host "*"  gh "*"  core-remaining "*"  core-limit "*"  core-reset "*"  graphql-remaining "*"  graphql-limit "*"  graphql-reset "* ]]
    [[ "${output}" == *"cfwf never runs gh auth status, gh auth token or gh config"* ]]
    [[ "${output}" == *"No environment variable"*"but GH_HOST is printed"* ]]
    [[ "${output}" == *'Exit codes: 0 printed; 1 a runtime failure, prefixed "cfwf:": "cfwf: not authenticated"'*"2 a usage error."* ]]

    run "${SCRIPT}" help repo
    [ "${status}" -eq 0 ]
    expected="${output}"
    [[ "${expected}" == "Usage: cfwf repo view --repo <owner/repo>"*$'\n\n'"Usage: cfwf repo collaborators --repo <owner/repo>"* ]]
    for spelling in "repo -h" "repo --help" "help repo frobnicate"; do
        # shellcheck disable=SC2086  # each spelling is split into its words on purpose
        run "${SCRIPT}" ${spelling}
        [ "${status}" -eq 0 ]
        [ "${output}" = "${expected}" ]
    done
    run "${SCRIPT}" auth status -h
    expected="${output}"
    for spelling in "help auth" "auth -h" "auth --help"; do
        # shellcheck disable=SC2086  # each spelling is split into its words on purpose
        run "${SCRIPT}" ${spelling}
        [ "${status}" -eq 0 ]
        [ "${output}" = "${expected}" ]
    done
    [ ! -f "${GH_LOG}" ]
}

@test "repo and auth with no subcommand name theirs, and a subcommand neither has is refused by its position and never echoed, each exit 2 with nothing on stdout and no gh call" {
    run --separate-stderr "${SCRIPT}" repo
    [ "${status}" -eq 2 ]
    [ -z "${output}" ]
    [[ "${stderr}" == "cfwf: repo needs a subcommand (view, collaborators, advisories, list, search, file)"$'\n'* ]]

    run --separate-stderr "${SCRIPT}" auth
    [ "${status}" -eq 2 ]
    [ -z "${output}" ]
    [[ "${stderr}" == "cfwf: auth needs a subcommand (status)"$'\n'* ]]

    run --separate-stderr "${SCRIPT}" repo frobnicate --repo "${REPO}"
    [ "${status}" -eq 2 ]
    [ -z "${output}" ]
    [[ "${stderr}" == "cfwf: unknown repo subcommand (argument 2; its value is not shown)"$'\n'* && "${stderr}" != *frobnicate* ]]

    # gh's own auth subcommands that print or change a credential are not cfwf's.
    local subcommand
    for subcommand in token login logout refresh setup-git switch; do
        run --separate-stderr "${SCRIPT}" auth "${subcommand}"
        [ "${status}" -eq 2 ] || { echo "accepted: auth ${subcommand}" >&2; return 1; }
        [ -z "${output}" ]
        [[ "${stderr}" == "cfwf: unknown auth subcommand (argument 2; its value is not shown)"$'\n'* ]]
    done
    [ ! -f "${GH_LOG}" ]
}

@test "repo view and repo collaborators usage errors exit 2 with their own usage and nothing on stdout, never echoing a value, before any gh call" {
    local token
    token="gh""p_$(run_of a 36)"
    local -a cases=(
        ""
        "--repo"
        "--repo ${REPO} --repo ${REPO}"
        "--repo not-a-repo"
        "--repo a/b/c"
        "--repo ./x"
        "--repo x/.."
        "--repo ../.."
        "--repo ${token}/${token}/x"
        "--repo ${REPO} --json name"
        "--repo ${REPO} --jq ."
        "--repo ${REPO} --template x"
        "--repo ${REPO} --hostname example.com"
        "--repo ${REPO} --affiliation direct"
        "--repo ${REPO} --permission admin"
        "--repo ${REPO} --paginate"
        "--repo ${REPO} --limit 5"
        "--repo ${REPO} --branch main"
        "--repo ${REPO} --web"
        "--repo ${REPO} --issue 7"
        "--repo ${REPO} --rate-limit"
        "--repo ${REPO} ${token}"
    )
    local subcommand other args
    for subcommand in view collaborators; do
        other=collaborators
        [ "${subcommand}" = view ] || other=view
        for args in "${cases[@]}"; do
            # shellcheck disable=SC2086  # each case is split into its words on purpose
            run --separate-stderr "${SCRIPT}" repo "${subcommand}" ${args}
            [ "${status}" -eq 2 ] || { echo "accepted: ${subcommand} ${args} (${status})" >&2; return 1; }
            [ -z "${output}" ]
            [[ "${stderr}" == *"Usage: cfwf repo ${subcommand} --repo <owner/repo>"* ]]
            [[ "${stderr}" != *"cfwf repo ${other}"* && "${stderr}" != *"${token}"* ]]
        done

        run --separate-stderr "${SCRIPT}" repo "${subcommand}"
        [[ "${stderr%%$'\n'*}" == "cfwf: missing required option --repo" ]]
        run_repo "${subcommand}" --repo "${REPO}"
        [[ "${stderr%%$'\n'*}" == "cfwf: --repo can only be given once" ]]
        run --separate-stderr "${SCRIPT}" repo "${subcommand}" --repo x/..
        [[ "${stderr%%$'\n'*}" == "cfwf: invalid value for --repo: neither the owner nor the repository can be . or .." ]]
        run_repo "${subcommand}" --json name
        [[ "${stderr%%$'\n'*}" == "cfwf: unknown option (argument 5; its value is not shown)" ]]
    done
    [ ! -f "${GH_LOG}" ]
}

@test "auth status usage errors, --repo and every way of naming a host or asking for a token among them, exit 2 with its usage and nothing on stdout, never echoing a value, before any gh call" {
    local token args
    token="gh""p_$(run_of a 36)"
    local -a cases=(
        "--repo ${REPO}"
        "--hostname example.com"
        "--show-token"
        "--active"
        "--json hosts"
        "--jq ."
        "--template x"
        "--rate-limit=yes"
        "--rate-limit ${token}"
        "${token}"
    )
    for args in "${cases[@]}"; do
        # shellcheck disable=SC2086  # each case is split into its words on purpose
        run_auth_status ${args}
        [ "${status}" -eq 2 ] || { echo "accepted: ${args} (${status})" >&2; return 1; }
        [ -z "${output}" ]
        [[ "${stderr}" == *"Usage: cfwf auth status [--rate-limit]"* && "${stderr}" != *"${token}"* ]]
    done
    run_auth_status --repo "${REPO}"
    [[ "${stderr%%$'\n'*}" == "cfwf: unknown option (argument 3; its value is not shown)" ]]
    run_auth_status --rate-limit --hostname example.com
    [[ "${stderr%%$'\n'*}" == "cfwf: unknown option (argument 4; its value is not shown)" ]]
    [ ! -f "${GH_LOG}" ]
}

@test "repo view prints the six fields in their fixed order, GitHub's own visibility and yes or no for each merge method, and nothing gh was not asked for, from one gh repo view call for exactly its six fields" {
    write_repository_metadata
    run_repo view
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(repo_view_lines)" ]
    [ -z "${stderr}" ]
    [[ "${output}" != *decoy* ]]
    [ "$(wc -l < "${GH_LOG}")" -eq 1 ]
    [ "$(gh_call_count "repo view ${REPO} --json ${REPO_VIEW_JSON_FIELDS} --jq ")" -eq 1 ]

    # Each merge method is its own answer, and GitHub's visibility is printed as it is.
    write_repository_metadata '.mergeCommitAllowed = false | .squashMergeAllowed = true | .visibility = "INTERNAL" | .defaultBranchRef.name = "release/1.x"'
    run_repo view
    [ "${status}" -eq 0 ]
    [ "${output}" = $'default-branch\trelease/1.x\nvisibility\tINTERNAL\nallow-merge-commit\tno\nallow-squash-merge\tyes\nallow-rebase-merge\tno\ndescription\tRuns the agents' ]

    write_repository_metadata '.mergeCommitAllowed = false | .rebaseMergeAllowed = true | .visibility = "PRIVATE"'
    run_repo view
    [ "${status}" -eq 0 ]
    [ "${output}" = $'default-branch\tmain\nvisibility\tPRIVATE\nallow-merge-commit\tno\nallow-squash-merge\tno\nallow-rebase-merge\tyes\ndescription\tRuns the agents' ]
}

@test "repo view prints an empty value, keeping the tab, for the default branch of an empty repository, a description that is null and a merge method GitHub did not give" {
    local branch
    # Two paths through the program: no default branch at all, which is a null the program turns into
    # an empty value, and a default branch whose name is already the empty string.
    for branch in 'null' '{name: ""}'; do
        write_repository_metadata ".defaultBranchRef = ${branch} | .description = null | .mergeCommitAllowed = null | del(.squashMergeAllowed) | .rebaseMergeAllowed = null"
        "${SCRIPT}" repo view --repo "${REPO}" > "${TEST_TMP}/out" 2> "${TEST_TMP}/err" < /dev/null
        printf 'default-branch\t\nvisibility\tPUBLIC\nallow-merge-commit\t\nallow-squash-merge\t\nallow-rebase-merge\t\ndescription\t\n' > "${TEST_TMP}/expected"
        cmp "${TEST_TMP}/expected" "${TEST_TMP}/out" || { echo "default branch ${branch}" >&2; return 1; }
        [ ! -s "${TEST_TMP}/err" ]
    done
}

@test "repo view keeps a description or a default branch holding a tab, a newline, a carriage return, a C1 control or a whole forged line on one line of two fields" {
    local forged=$'tidy\nallow-squash-merge\tyes\r\nvisibility\tPRIVATE\x1b[2J\xc2\x9b0m end'
    jq -n --arg forged "${forged}" '{defaultBranchRef: {name: "ma\tin\nx"}, description: $forged, visibility: "PUBLIC",
        mergeCommitAllowed: true, squashMergeAllowed: false, rebaseMergeAllowed: false}' > "$(repository_fixture).json"
    run_repo view
    [ "${status}" -eq 0 ]
    [ "${output}" = $'default-branch\tma in x\nvisibility\tPUBLIC\nallow-merge-commit\tyes\nallow-squash-merge\tno\nallow-rebase-merge\tno\ndescription\ttidy allow-squash-merge yes  visibility PRIVATE [2J 0m end' ]
    [ "$(awk -F '\t' 'NF != 2' <<< "${output}" | wc -l)" -eq 0 ]
    [ "$(wc -l <<< "${output}")" -eq 6 ]
}

@test "repo view prints a description and a default branch holding an accented letter and an emoji unchanged, byte for byte, run in the C locale or a UTF-8 one" {
    local locale
    write_repository_metadata '.description = "café 🚀 ok" | .defaultBranchRef.name = "release/café"'
    for locale in C C.UTF-8; do
        LC_ALL="${locale}" run_repo view
        [ "${status}" -eq 0 ] || { echo "refused in ${locale}: ${stderr}" >&2; return 1; }
        [ "${output}" = $'default-branch\trelease/caf\xc3\xa9\nvisibility\tPUBLIC\nallow-merge-commit\tyes\nallow-squash-merge\tno\nallow-rebase-merge\tno\ndescription\tcaf\xc3\xa9 \xf0\x9f\x9a\x80 ok' ]
        [ -z "${stderr}" ]
    done
}

@test "repo view exits 1 with the repository message and nothing on stdout for a repository GitHub does not show the caller, whichever of its two answers gh gives" {
    run_repo view
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "${REPO_MISSING}" ]

    fail_repository "gh: Not Found (HTTP 404)"
    run_repo view
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "${REPO_MISSING}" ]
}

@test "repo view exits 1 quoting only the first line of gh's error, and prints nothing, for any other failed read" {
    write_repository_metadata
    fail_repository $'gh: Bad Gateway (HTTP 502)\nsecond-line-marker'
    run_repo view
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not read ${REPO}: gh: Bad Gateway (HTTP 502)" ]

    fail_repository "gh: Resource protected by organization SAML enforcement (HTTP 403)"
    run_repo view
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not read ${REPO}: gh: Resource protected by organization SAML enforcement (HTTP 403)" ]
}

@test "repo view prints nothing and exits 1 when gh's answer is not its six lines in order, each one field, with a visibility and yes, no or nothing for each merge method, and prints an answer that is" {
    local answer good
    good="$(repo_view_lines)"
    local -a answers=(
        ""
        "${good%$'\n'*}"
        "${good}"$'\n'"description"$'\t'"again"
        "${good/visibility/visible}"
        "${good/PUBLIC/}"
        "${good/PUBLIC/public}"
        "${good/yes/maybe}"
        "${good/$'squash-merge\tno'/$'squash-merge\tnever'}"
        "${good/$'rebase-merge\tno'/$'rebase-merge\ttrue'}"
        "${good/$'\tmain'/$'\tma\tin'}"
        "${good}"$'\t'"extra"
        "$(printf '%s\n' "${good}" | tac)"
    )
    for answer in "${answers[@]}"; do
        printf '%s\n' "${answer}" > "$(repository_fixture).out"
        run_repo view
        [ "${status}" -eq 1 ] || { echo "printed: ${answer}" >&2; return 1; }
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: gh returned an unexpected result for ${REPO}" ]
    done

    printf '%s\n' "${good}" > "$(repository_fixture).out"
    run_repo view
    [ "${status}" -eq 0 ]
    [ "${output}" = "${good}" ]
}

@test "a visibility lookup gh answers with HTTP 404 is the one gh repo view of the visibility alone, and counts as a repository the caller cannot see: refused when the text names it, exit 1 when it is the target" {
    write_visibility "${REPO}" PUBLIC
    fail_visibility credfeto/gone-thing "gh: Not Found (HTTP 404)"
    write_leak_body "see credfeto/gone-thing#3"
    run_body_check
    assert_refused "${status}" "${output}" "${stderr}" "private repository" "gone-thing"
    [ "$(wc -l < "${GH_LOG}")" -eq 2 ]
    grep -qxF "repo view ${REPO} --json visibility --jq .visibility" "${GH_LOG}"
    grep -qxF "repo view credfeto/gone-thing --json visibility --jq .visibility" "${GH_LOG}"

    rm -f "${GH_FIXTURES}"/visibility-*
    fail_visibility "${REPO}" "gh: Not Found (HTTP 404)"
    run_body_check
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "${REPO_MISSING}" ]
}

@test "a visibility lookup whose answer is not a visibility is a runtime failure (exit 1), never a pass or a refusal, for a repository the text names and for the target" {
    write_visibility "${REPO}" PUBLIC
    write_visibility credfeto/odd-thing SECRET
    write_leak_body "see credfeto/odd-thing#3"
    run_body_check
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not read the visibility of the repository named on line 3 of the body: gh gave an unexpected answer" ]

    write_visibility "${REPO}" ""
    run_body_check
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not read the visibility of ${REPO}: gh gave an unexpected answer" ]
}

@test "repo collaborators prints each login and role sorted by login in the C locale, - for a role GitHub left out or left empty, from one paged read of 100 a page" {
    write_collaborators "$(collaborator zed admin)" "$(collaborator alice write)" "$(collaborator Bob maintain)" \
        "$(collaborator 'dependabot[bot]' read)" "$(collaborator a-b triage)" "$(collaborator a_b "Release Manager")" \
        "$(collaborator a)" "$(collaborator 9lives read | jq '.role_name = ""')" "$(collaborator Zed read | jq '.role_name = null')"
    run_repo collaborators
    [ "${status}" -eq 0 ]
    [ "${output}" = $'9lives\t-\nBob\tmaintain\nZed\t-\na\t-\na-b\ttriage\na_b\tRelease Manager\nalice\twrite\ndependabot[bot]\tread\nzed\tadmin' ]
    [ -z "${stderr}" ]
    [ "$(wc -l < "${GH_LOG}")" -eq 1 ]
    [ "$(gh_call_count "api ${COLLABORATORS_ENDPOINT}?per_page=100 --paginate --jq ")" -eq 1 ]
}

@test "repo collaborators prints nothing and exits 0 for a repository with no collaborators" {
    write_collaborators
    run_repo collaborators
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    [ -z "${stderr}" ]
}

@test "repo collaborators prints exactly 1000 collaborators, and with 1001 prints none and exits 1" {
    jq -n '[range(1000) | {login: "user-\(.)", role_name: "read"}]' | write_api "${COLLABORATORS_ENDPOINT}"
    run_repo collaborators
    [ "${status}" -eq 0 ]
    [ "$(wc -l <<< "${output}")" -eq 1000 ]
    [ "$(awk -F '\t' 'NF != 2 || $2 != "read"' <<< "${output}" | wc -l)" -eq 0 ]

    jq -n '[range(1001) | {login: "user-\(.)", role_name: "read"}]' | write_api "${COLLABORATORS_ENDPOINT}"
    run_repo collaborators
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: ${REPO} has more than 1000 collaborators, so none is printed" ]
}

@test "repo collaborators keeps a role holding a tab, a newline or a whole forged row on one line of two fields" {
    write_collaborators "$(collaborator alice $'write\nmallory\tadmin\r\x1fend')" "$(collaborator bob $'a\tb')"
    run_repo collaborators
    [ "${status}" -eq 0 ]
    [ "${output}" = $'alice\twrite mallory admin  end\nbob\ta b' ]
}

@test "repo collaborators prints nothing and exits 1 for a login that is not a login or is missing, or a row that does not have exactly its fields, and prints a row that has them" {
    local login
    for login in "" "two words" $'tab\tbed' $'line\nfeed' "slash/login" "dot.ted" "bot[bot]x" "[bot]" $'unit\x1fend'; do
        write_collaborators "$(collaborator alice write)" "$(collaborator "${login}" admin)"
        run_repo collaborators
        [ "${status}" -eq 1 ] || { echo "printed: ${login}" >&2; return 1; }
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: gh returned an unexpected result for the collaborators of ${REPO}" ]
    done

    write_collaborators "$(collaborator alice write)" "$(collaborator bob admin | jq 'del(.login)')"
    run_repo collaborators
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: gh returned an unexpected result for the collaborators of ${REPO}" ]

    # A row with no closing field, with a field too many, or an empty line among the rows.
    local row
    for row in $'bob\x1fadmin' $'bob\x1fadmin\x1f' $'bob\x1fadmin\x1fextra\x1fend' $'bob\x1fadmin\x1fend\x1fend' $'\nbob\x1fadmin\x1fend'; do
        printf 'alice\x1fwrite\x1fend\n%s\n' "${row}" > "$(api_fixture "${COLLABORATORS_ENDPOINT}").out"
        run_repo collaborators
        [ "${status}" -eq 1 ] || { echo "printed: ${row}" >&2; return 1; }
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: gh returned an unexpected result for the collaborators of ${REPO}" ]
    done

    printf 'alice\x1fwrite\x1fend\nbob\x1f\x1fend\n' > "$(api_fixture "${COLLABORATORS_ENDPOINT}").out"
    run_repo collaborators
    [ "${status}" -eq 0 ]
    [ "${output}" = $'alice\twrite\nbob\t-' ]
}

@test "repo collaborators exits 1 quoting GitHub's HTTP 403 for a caller without push access, never printing an empty list" {
    fail_api "${COLLABORATORS_ENDPOINT}" "${PUSH_ACCESS_ERROR}"
    run_repo collaborators
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not list the collaborators of ${REPO}: ${PUSH_ACCESS_ERROR}" ]
}

@test "repo collaborators exits 1 with the repository message for a 404, and quoting only the first line of gh's error for any other failed read, printing nothing" {
    run_repo collaborators
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "${REPO_MISSING}" ]

    fail_api "${COLLABORATORS_ENDPOINT}" $'gh: Bad Gateway (HTTP 502)\nsecond-line-marker'
    run_repo collaborators
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not list the collaborators of ${REPO}: gh: Bad Gateway (HTTP 502)" ]
}

@test "auth status prints the login, github.com for a GH_HOST that is unset or empty, and the gh version, and nothing else of gh's answers, calling only gh --version and gh api user" {
    prepare_auth_status
    run_auth_status
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(auth_status_lines)" ]
    [ -z "${stderr}" ]
    [[ "${output}" != *decoy* ]]
    [ "$(wc -l < "${GH_LOG}")" -eq 2 ]
    [ "$(sed -n 1p "${GH_LOG}")" = "--version" ]
    [ "$(sed -n 2p "${GH_LOG}")" = 'api user --jq .login // ""' ]

    run --separate-stderr env GH_HOST="" "${SCRIPT}" auth status
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(auth_status_lines)" ]
}

@test "auth status prints a GH_HOST that is a host name, with or without a port, and exits 1 without echoing one that is not, before any gh call" {
    local host
    prepare_auth_status
    for host in github-api.example.com localhost:8080 GHE.Example.com 10.0.0.1; do
        run --separate-stderr env GH_HOST="${host}" "${SCRIPT}" auth status
        [ "${status}" -eq 0 ]
        [ "${output}" = "$(auth_status_lines "${host}")" ]
    done

    rm -f "${GH_LOG}"
    for host in "https://example.com" "example.com/path" "user@example.com" "example.com:port" "example.com:80:80" "two words" \
        $'example.com\nlogin\tmallory' $'tab\tbed' "exa_mple.com" ":8080" "example.com:"; do
        run --separate-stderr env GH_HOST="${host}" "${SCRIPT}" auth status
        [ "${status}" -eq 1 ] || { echo "printed: ${host}" >&2; return 1; }
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: GH_HOST is not a host name, with or without a port" ]
    done
    [ ! -f "${GH_LOG}" ]
}

@test "auth status --rate-limit adds the remaining, limit and reset of the core and graphql limits, each reset as ISO 8601 in UTC, from one more call, gh api rate_limit" {
    prepare_auth_status
    run_auth_status --rate-limit
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(auth_status_lines)"$'\n'"$(rate_limit_lines)" ]
    [ -z "${stderr}" ]
    [ "$(wc -l < "${GH_LOG}")" -eq 3 ]
    [ "$(sed -n 1p "${GH_LOG}")" = "--version" ]
    [ "$(sed -n 2p "${GH_LOG}")" = 'api user --jq .login // ""' ]
    [[ "$(sed -n 3p "${GH_LOG}")" == "api rate_limit --jq "* ]]
}

@test "auth status takes --rate-limit given twice as given once, as pr checks takes --all: the same nine lines from the same three gh calls" {
    prepare_auth_status
    run_auth_status --rate-limit --rate-limit
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(auth_status_lines)"$'\n'"$(rate_limit_lines)" ]
    [ -z "${stderr}" ]
    [ "$(wc -l < "${GH_LOG}")" -eq 3 ]
    [ "$(gh_call_count "api rate_limit")" -eq 1 ]
}

@test "auth status exits 1 with not authenticated, and prints nothing, for an HTTP 401 or gh's own prompt to log in, from the user read or the rate limit read, and never for the same words on the stdout of a read that failed otherwise" {
    local error endpoint
    prepare_auth_status
    for error in "gh: Bad credentials (HTTP 401)" "gh: Requires authentication (HTTP 401)" \
        $'To get started with GitHub CLI, please run:  gh auth login\nAlternatively, populate the GH_TOKEN environment variable with a GitHub API authentication token.'; do
        for endpoint in user rate_limit; do
            fail_api "${endpoint}" "${error}"
            run_auth_status --rate-limit
            [ "${status}" -eq 1 ] || { echo "${endpoint}: ${error}" >&2; return 1; }
            [ -z "${output}" ]
            [ "${stderr}" = "cfwf: not authenticated" ]
            rm -f "$(api_fixture "${endpoint}").fail"
        done
    done

    # Only what gh wrote to stderr is read for it. gh can put an answer's body on stdout when a call
    # fails, and the same words there are not it, whether stderr names another error or is empty.
    local body='{"message":"HTTP 401: run gh auth login","status":"502"}' message
    for endpoint in user rate_limit; do
        message="could not read the authenticated user"
        [ "${endpoint}" = user ] || message="could not read the rate limit"
        printf '%s\n' "${body}" > "$(api_fixture "${endpoint}").failout"
        fail_api "${endpoint}"
        run_auth_status --rate-limit
        [ "${status}" -eq 1 ]
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: ${message}: gh: Bad Gateway (HTTP 502)" ]

        : > "$(api_fixture "${endpoint}").fail"
        run_auth_status --rate-limit
        [ "${status}" -eq 1 ]
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: ${message}: ${body}" ]
        rm -f "$(api_fixture "${endpoint}").fail" "$(api_fixture "${endpoint}").failout"
    done
}

@test "auth status exits 1 with the failed read's own message, quoting only the first line of gh's error, and prints nothing, when gh --version, the user read or the rate limit read fails otherwise" {
    prepare_auth_status
    fail_api user $'gh: Bad Gateway (HTTP 502)\nsecond-line-marker'
    run_auth_status
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not read the authenticated user: gh: Bad Gateway (HTTP 502)" ]

    rm -f "$(api_fixture user).fail"
    fail_api rate_limit $'gh: Not Found (HTTP 404)\nsecond-line-marker'
    run_auth_status --rate-limit
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not read the rate limit: gh: Not Found (HTTP 404)" ]

    printf '%s\n' "gh: cannot run" "second-line-marker" > "${GH_FIXTURES}/gh-version.fail"
    run_auth_status
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not read the version of gh: gh: cannot run" ]
}

@test "auth status prints nothing and exits 1 for a gh version, a login or a rate limit that is not what it expects, and takes a version of two or more parts, with a suffix or with nothing after it" {
    local version login filter
    prepare_auth_status
    for version in "" "gh version" "gh version DEV" "GitHub CLI 2.102.0" "gh version v2.102.0" "version 2.102.0" "gh version 2" $'\ngh version 2.102.0'; do
        printf '%s\n' "${version}" > "${GH_FIXTURES}/gh-version.out"
        run_auth_status
        [ "${status}" -eq 1 ] || { echo "printed: ${version}" >&2; return 1; }
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: gh returned an unexpected version" ]
    done
    for version in "2.102.0" "2.40" "2.103.0-pre.1" "2.102.0+build.5"; do
        printf '%s\n' "gh version ${version} (2026-09-30)" > "${GH_FIXTURES}/gh-version.out"
        run_auth_status
        [ "${status}" -eq 0 ]
        [ "${output}" = $'login\tcredfeto\nhost\tgithub.com\ngh\t'"${version}" ]
    done
    printf '%s\n' "gh version 2.102.0" > "${GH_FIXTURES}/gh-version.out"
    run_auth_status
    [ "${output}" = "$(auth_status_lines)" ]

    # An empty login and a null one are two paths: the null is what the program's own alternative
    # turns into an empty value, and without it would print as the word null, which is a login's shape.
    for login in '""' 'null' '"two words"' '"line\nlogin\tmallory"' '"a/b"' '"tab\tbed"'; do
        jq -n "{login: ${login}}" | write_api user
        run_auth_status
        [ "${status}" -eq 1 ] || { echo "printed: ${login}" >&2; return 1; }
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: gh returned an unexpected result for the authenticated user" ]
    done

    prepare_auth_status
    for filter in '.resources.core.remaining = "many"' '.resources.core.limit = null' '.resources.core.reset = "soon"' \
        '.resources.graphql.remaining = -1' '.resources.graphql.limit = 1.5' 'del(.resources.graphql.reset)' \
        'del(.resources.graphql)' 'del(.resources)' '.resources.core.remaining = "1\u001f2"'; do
        write_rate_limit "${filter}"
        run_auth_status --rate-limit
        [ "${status}" -eq 1 ] || { echo "printed: ${filter}" >&2; return 1; }
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: gh returned an unexpected result for the rate limit" ]
    done
}

@test "auth status never prints a token from its environment or from GitHub's answer, on stdout or stderr, whether it works or fails, and never runs gh auth, gh config or gh with an option that shows headers or names a host" {
    local token
    token="gh""p_$(run_of Z 36)"
    prepare_auth_status
    jq -n --arg token "${token}" '{login: "credfeto", token: $token, authorization: ("Bearer " + $token)}' | write_api user
    write_rate_limit ".token = \$token | .resources.core.token = \$token" --arg token "${token}"

    run --separate-stderr env GH_TOKEN="${token}" GITHUB_TOKEN="${token}" GH_ENTERPRISE_TOKEN="${token}" GH_HOST=github-api.example.com \
        "${SCRIPT}" auth status --rate-limit
    [ "${status}" -eq 0 ]
    [[ "${output}" == "$(auth_status_lines github-api.example.com)"$'\n'* ]]
    [[ "${output}" != *"${token}"* && "${output}" != *Bearer* ]]
    [ -z "${stderr}" ]
    [ "$(wc -l <<< "${output}")" -eq 9 ]

    # A GH_HOST whose only defect is the underscore a GitHub token holds is refused, never printed.
    local calls
    calls="$(wc -l < "${GH_LOG}")"
    run --separate-stderr env GH_TOKEN="${token}" GITHUB_TOKEN="${token}" GH_HOST="${token}" "${SCRIPT}" auth status
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: GH_HOST is not a host name, with or without a port" ]
    [ "$(wc -l < "${GH_LOG}")" -eq "${calls}" ]

    fail_api user "gh: Bad credentials (HTTP 401)"
    run --separate-stderr env GH_TOKEN="${token}" GITHUB_TOKEN="${token}" GH_HOST=github-api.example.com "${SCRIPT}" auth status --rate-limit
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: not authenticated" ]

    [ "$(grep -cE '^(--version|api user --jq |api rate_limit --jq )' "${GH_LOG}")" -eq "$(wc -l < "${GH_LOG}")" ]
    [ "$(grep -cE '(^| )(auth|config|token|-i|--include|--verbose|--hostname)( |$)' "${GH_LOG}")" -eq 0 ]
    [ "$(gh_call_count "${token}")" -eq 0 ]
}

# One repository security advisory as the REST API lists it: GHSA id $1, severity $2, state $3 and
# summary $4, with fields repo advisories does not ask for. An empty severity is left as null.
advisory() {
    jq -n --arg id "$1" --arg severity "$2" --arg state "$3" --arg summary "$4" \
        '{ghsa_id: $id, cve_id: "CVE-2026-0001", url: "https://example.com/decoy", html_url: "https://example.com/decoy",
          severity: (if $severity == "" then null else $severity end), state: $state, summary: $summary,
          description: "decoy-description", published_at: "2026-10-01T00:00:00Z"}'
}

# Writes the security advisories of REPO: each argument an advisory object, in the order given, none
# for an empty list.
write_advisories() {
    printf '%s\n' "$@" | jq -s '.' | write_api "${ADVISORIES_ENDPOINT}"
}

@test "repo advisories help is the same from -h, --help and help repo advisories, states its format, limit and exit codes, is in help repo and the general help, and calls no gh" {
    run "${SCRIPT}" repo advisories -h
    [ "${status}" -eq 0 ]
    local expected="${output}" spelling
    [[ "${expected}" == "Usage: cfwf repo advisories --repo <owner/repo>"$'\n'* ]]
    for spelling in "repo advisories --help" "help repo advisories" "-h repo advisories" "--help repo advisories"; do
        # shellcheck disable=SC2086  # each spelling is split into its words on purpose
        run "${SCRIPT}" ${spelling}
        [ "${status}" -eq 0 ]
        [ "${output}" = "${expected}" ] || { echo "${spelling} differs" >&2; return 1; }
    done
    [[ "${expected}" == *"  <ghsa_id>  <severity>  <state>  <summary>"* ]]
    [[ "${expected}" == *'"-"'*"when GitHub gives none"* ]]
    [[ "${expected}" == *"read it as untrusted text"* ]]
    [[ "${expected}" == *"At most 1000 advisories are listed."* ]]
    [[ "${expected}" == *"Exit codes: 0 listed, an empty list included (nothing is printed); 1 a runtime failure"*"2 a usage error."* ]]
    [[ "${expected}" != *"cfwf repo view"* && "${expected}" != *"cfwf repo collaborators"* ]]

    run "${SCRIPT}" help repo
    [[ "${output}" == *$'\n\n'"Usage: cfwf repo advisories --repo <owner/repo>"$'\n'* ]]
    run "${SCRIPT}" help
    [[ "${output}" == *$'\n'"  repo advisories          List a repository's security advisories: GHSA id, severity, state and summary"$'\n'* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "repo advisories usage errors exit 2 with its own usage and nothing on stdout, never echoing a value, before any gh call" {
    local token args
    token="gh""p_$(run_of a 36)"
    local -a cases=(
        ""
        "--repo"
        "--repo ${REPO} --repo ${REPO}"
        "--repo not-a-repo"
        "--repo x/.."
        "--repo ${token}/${token}/x"
        "--repo ${REPO} --json ghsa_id"
        "--repo ${REPO} --jq ."
        "--repo ${REPO} --state published"
        "--repo ${REPO} --severity high"
        "--repo ${REPO} --sort created"
        "--repo ${REPO} --direction asc"
        "--repo ${REPO} --paginate"
        "--repo ${REPO} --limit 5"
        "--repo ${REPO} ${token}"
    )
    for args in "${cases[@]}"; do
        # shellcheck disable=SC2086  # each case is split into its words on purpose
        run --separate-stderr "${SCRIPT}" repo advisories ${args}
        [ "${status}" -eq 2 ] || { echo "accepted: ${args} (${status})" >&2; return 1; }
        [ -z "${output}" ]
        [[ "${stderr}" == *"Usage: cfwf repo advisories --repo <owner/repo>"* ]]
        [[ "${stderr}" != *"cfwf repo view"* && "${stderr}" != *"${token}"* ]]
    done
    [ ! -f "${GH_LOG}" ]
}

@test "repo advisories prints each GHSA id, severity, state and summary in GitHub's order, - for no severity or an empty summary, from one paged read of 100 a page" {
    write_advisories "$(advisory GHSA-cfgh-jmpq-rvwx critical published 'Remote code execution in parser')" \
        "$(advisory GHSA-2345-6789-cfgh '' draft 'Unrated draft')" \
        "$(advisory GHSA-jmpq-rvwx-2345 low withdrawn '')" \
        "$(advisory GHSA-cccc-ffff-gggg medium closed 'Closed one')" \
        "$(advisory GHSA-hhhh-jjjj-mmmm high triage 'In triage')"
    run_repo advisories
    [ "${status}" -eq 0 ]
    [ "${output}" = $'GHSA-cfgh-jmpq-rvwx\tcritical\tpublished\tRemote code execution in parser\nGHSA-2345-6789-cfgh\t-\tdraft\tUnrated draft\nGHSA-jmpq-rvwx-2345\tlow\twithdrawn\t-\nGHSA-cccc-ffff-gggg\tmedium\tclosed\tClosed one\nGHSA-hhhh-jjjj-mmmm\thigh\ttriage\tIn triage' ]
    [ -z "${stderr}" ]
    [ "$(wc -l < "${GH_LOG}")" -eq 1 ]
    [ "$(gh_call_count "api ${ADVISORIES_ENDPOINT}?per_page=100 --paginate --jq ")" -eq 1 ]
}

@test "repo advisories prints nothing and exits 0 for a repository with no advisories" {
    write_advisories
    run_repo advisories
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    [ -z "${stderr}" ]
}

@test "repo advisories keeps a summary holding a tab, a newline, a control character or a whole forged row on one line of four fields" {
    write_advisories "$(advisory GHSA-cfgh-jmpq-rvwx high published $'one\ttwo\nGHSA-2345-6789-cfgh\tcritical\tpublished\tforged\r\x1fend\x07')"
    run_repo advisories
    [ "${status}" -eq 0 ]
    [ "$(wc -l <<< "${output}")" -eq 1 ]
    [ "$(awk -F '\t' '{print NF}' <<< "${output}")" -eq 4 ]
    [ "${output}" = $'GHSA-cfgh-jmpq-rvwx\thigh\tpublished\tone two GHSA-2345-6789-cfgh critical published forged  end ' ]
}

@test "repo advisories prints nothing and exits 1 for a GHSA id, severity or state that is not GitHub's, or a row that does not have exactly its fields" {
    local bad
    for bad in "id:" "id:GHSA-cfgh-jmpq" "id:GHSA-cfgh-jmpq-rvwx-2345" "id:GHSA-CFGH-JMPQ-RVWX" "id:GHSA-cfgh-jmpq-rvwa" "id:GHSA-cfgh-jmpq-rvw1" $'id:GHSA-cfgh-jmpq-rvwx\tx' "id:CVE-2026-0001" \
        "severity:severe" "severity:High" $'severity:high\tx' "state:open" "state:" "state:Published"; do
        local id=GHSA-cfgh-jmpq-rvwx severity=high state=published
        case "${bad}" in
            id:*) id="${bad#id:}" ;;
            severity:*) severity="${bad#severity:}" ;;
            state:*) state="${bad#state:}" ;;
        esac
        write_advisories "$(advisory GHSA-2345-6789-cfgh low published ok)" "$(advisory "${id}" "${severity}" "${state}" summary)"
        run_repo advisories
        [ "${status}" -eq 1 ] || { echo "printed: ${bad}" >&2; return 1; }
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: gh returned an unexpected result for the security advisories of ${REPO}" ]
    done

    local row
    for row in $'GHSA-2345-6789-cfgh\x1flow\x1fpublished\x1fok' $'GHSA-2345-6789-cfgh\x1flow\x1fpublished\x1fok\x1fextra\x1fend' $'\nGHSA-2345-6789-cfgh\x1flow\x1fpublished\x1fok\x1fend'; do
        printf '%s\n' "${row}" > "$(api_fixture "${ADVISORIES_ENDPOINT}").out"
        run_repo advisories
        [ "${status}" -eq 1 ] || { echo "printed: ${row}" >&2; return 1; }
        [ -z "${output}" ]
    done
}

@test "repo advisories prints exactly 1000 advisories, and with 1001 prints none and exits 1" {
    jq -n '[range(1000) | {ghsa_id: "GHSA-2345-6789-cfgh", severity: "low", state: "published", summary: "s\(.)"}]' | write_api "${ADVISORIES_ENDPOINT}"
    run_repo advisories
    [ "${status}" -eq 0 ]
    [ "$(wc -l <<< "${output}")" -eq 1000 ]

    jq -n '[range(1001) | {ghsa_id: "GHSA-2345-6789-cfgh", severity: "low", state: "published", summary: "s\(.)"}]' | write_api "${ADVISORIES_ENDPOINT}"
    run_repo advisories
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: ${REPO} has more than 1000 security advisories, so none is printed" ]
}

@test "repo advisories exits 1 with the repository message for a 404, and quoting only the first line of gh's error for any other failed read, printing nothing" {
    run_repo advisories
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "${REPO_MISSING}" ]

    fail_api "${ADVISORIES_ENDPOINT}" $'gh: Bad Gateway (HTTP 502)\nsecond-line-marker'
    run_repo advisories
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not list the security advisories of ${REPO}: gh: Bad Gateway (HTTP 502)" ]
}

# The advisory database endpoint advisory view reads for the GHSA id $1 (GHSA_ID by default).
GHSA_ID="GHSA-cfgh-jmpq-rvwx"
global_advisory_endpoint() {
    printf 'advisories/%s' "${1:-${GHSA_ID}}"
}

# One global advisory as the REST API gives it: GHSA id $1, severity $2 ("" for null), summary $3,
# published $4, withdrawn $5 ("" for null), then the affected packages as a JSON array $6, with
# fields advisory view does not ask for.
global_advisory() {
    jq -n --arg id "$1" --arg severity "$2" --arg summary "$3" --arg published "$4" --arg withdrawn "$5" --argjson vulns "${6:-[]}" \
        '{ghsa_id: $id, cve_id: "CVE-2026-0001", url: "https://example.com/decoy", html_url: "https://example.com/decoy",
          type: "reviewed", description: "decoy-description", references: ["https://example.com/decoy-ref"],
          severity: (if $severity == "" then null else $severity end), summary: $summary,
          published_at: $published, withdrawn_at: (if $withdrawn == "" then null else $withdrawn end),
          vulnerabilities: $vulns}'
}

# One affected package: ecosystem $1, name $2, vulnerable range $3 ("" for null) and first patched
# version $4 ("" for null), as the global database writes them.
affected_package() {
    jq -n --arg eco "$1" --arg name "$2" --arg range "$3" --arg patched "$4" \
        '{package: {ecosystem: $eco, name: $name}, vulnerable_version_range: (if $range == "" then null else $range end),
          first_patched_version: (if $patched == "" then null else $patched end), vulnerable_functions: []}'
}

run_advisory_view() {
    run --separate-stderr "${SCRIPT}" advisory view --ghsa "${1:-${GHSA_ID}}"
}

@test "advisory view help is the same from -h, --help, help advisory and help advisory view, states its format and exit codes, is in the general help, and calls no gh" {
    run "${SCRIPT}" advisory view -h
    [ "${status}" -eq 0 ]
    local expected="${output}" spelling
    [[ "${expected}" == "Usage: cfwf advisory view --ghsa <GHSA-xxxx-xxxx-xxxx>"$'\n'* ]]
    for spelling in "advisory view --help" "help advisory view" "help advisory" "advisory -h" "-h advisory view"; do
        # shellcheck disable=SC2086  # each spelling is split into its words on purpose
        run "${SCRIPT}" ${spelling}
        [ "${status}" -eq 0 ]
        [ "${output}" = "${expected}" ] || { echo "${spelling} differs" >&2; return 1; }
    done
    [[ "${expected}" == *"  <ecosystem>  <package>  <vulnerable_range>  <first_patched>"* ]]
    [[ "${expected}" == *"withdrawn  when it was withdrawn"*"empty when it has not been"* ]]
    [[ "${expected}" == *"read them as"*"untrusted text"* ]]
    [[ "${expected}" == *"At most 1000 affected packages are printed"* ]]
    [[ "${expected}" == *"Exit codes: 0 printed; 9 the advisory was not found; 1 a runtime failure"*"2 a usage error."* ]]

    run "${SCRIPT}" help
    [[ "${output}" == *$'\n'"  advisory view            Print a global security advisory and its affected packages by GHSA id (exit 9 when not found)"$'\n'* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "advisory view usage errors, a malformed GHSA id included, exit 2 with its own usage and nothing on stdout, never echoing a value, before any gh call" {
    local token args
    token="gh""p_$(run_of a 36)"
    local -a cases=(
        ""
        "--ghsa"
        "--ghsa ${GHSA_ID} --ghsa ${GHSA_ID}"
        "--ghsa GHSA-CFGH-JMPQ-RVWX"
        "--ghsa GHSA-cfgh-jmpq"
        "--ghsa GHSA-cfgh-jmpq-rvwx-2345"
        "--ghsa GHSA-cfgh-jmpq-rvwa"
        "--ghsa GHSA-cfgh-jmpq-rvw1"
        "--ghsa CVE-2021-44228"
        "--ghsa ../../repos/x/y"
        "--ghsa ${token}"
        "--ghsa ${GHSA_ID} --repo ${REPO}"
        "--ghsa ${GHSA_ID} --json ghsa_id"
        "--ghsa ${GHSA_ID} --jq ."
        "--ghsa ${GHSA_ID} --ecosystem npm"
        "--ghsa ${GHSA_ID} ${token}"
    )
    for args in "${cases[@]}"; do
        # shellcheck disable=SC2086  # each case is split into its words on purpose
        run --separate-stderr "${SCRIPT}" advisory view ${args}
        [ "${status}" -eq 2 ] || { echo "accepted: ${args} (${status})" >&2; return 1; }
        [ -z "${output}" ]
        [[ "${stderr}" == *"Usage: cfwf advisory view --ghsa <GHSA-xxxx-xxxx-xxxx>"* ]]
        [[ "${stderr}" != *"${token}"* ]]
    done
    run --separate-stderr "${SCRIPT}" advisory list
    [ "${status}" -eq 2 ]
    [ ! -f "${GH_LOG}" ]
}

@test "advisory view prints the advisory's five fields then each affected package in GitHub's order, - for an empty range or no patched version, from one read" {
    local vulns
    vulns="$(printf '%s\n' "$(affected_package nuget Example.Package '>= 1.0.0, < 1.2.3' 1.2.3)" \
        "$(affected_package npm example-js '< 4.0.0' '')" \
        "$(affected_package pip example-py '' '')" | jq -s '.')"
    global_advisory "${GHSA_ID}" high 'Remote code execution in parser' 2026-10-01T12:34:56Z '' "${vulns}" | write_api "$(global_advisory_endpoint)"
    run_advisory_view
    [ "${status}" -eq 0 ]
    [ "${output}" = $'ghsa_id\tGHSA-cfgh-jmpq-rvwx\nseverity\thigh\nsummary\tRemote code execution in parser\npublished\t2026-10-01T12:34:56Z\nwithdrawn\t\nnuget\tExample.Package\t>= 1.0.0, < 1.2.3\t1.2.3\nnpm\texample-js\t< 4.0.0\t-\npip\texample-py\t-\t-' ]
    [ -z "${stderr}" ]
    [ "$(wc -l < "${GH_LOG}")" -eq 1 ]
    [ "$(gh_call_count "api advisories/${GHSA_ID} --jq ")" -eq 1 ]
    [[ "${output}" != *decoy* ]]
}

@test "advisory view prints a withdrawn advisory, no severity, no affected packages and a first patched version given as an object" {
    jq -n '{ghsa_id: "GHSA-cfgh-jmpq-rvwx", severity: null, summary: "Withdrawn one", published_at: "2026-01-02T03:04:05Z",
            withdrawn_at: "2026-02-03T04:05:06Z", vulnerabilities: []}' | write_api "$(global_advisory_endpoint)"
    run_advisory_view
    [ "${status}" -eq 0 ]
    [ "${output}" = $'ghsa_id\tGHSA-cfgh-jmpq-rvwx\nseverity\t\nsummary\tWithdrawn one\npublished\t2026-01-02T03:04:05Z\nwithdrawn\t2026-02-03T04:05:06Z' ]

    jq -n '{ghsa_id: "GHSA-cfgh-jmpq-rvwx", severity: "unknown", summary: "s", published_at: "2026-01-02T03:04:05Z",
            vulnerabilities: [{package: {ecosystem: "nuget", name: "P"}, vulnerable_version_range: "< 2", first_patched_version: {identifier: "2.0.0"}}]}' \
        | write_api "$(global_advisory_endpoint)"
    run_advisory_view
    [ "${status}" -eq 0 ]
    [ "${output##*$'\n'}" = $'nuget\tP\t< 2\t2.0.0' ]
    [[ "${output}" == *$'\nseverity\tunknown\n'* ]]
}

@test "advisory view exits 9 for an advisory that is not there, and 1 quoting only the first line of gh's error for any other failed read, printing nothing" {
    run_advisory_view
    [ "${status}" -eq 9 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: the advisory ${GHSA_ID} was not found" ]

    fail_api "$(global_advisory_endpoint)" $'gh: Bad Gateway (HTTP 502)\nsecond-line-marker'
    run_advisory_view
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: could not read the advisory ${GHSA_ID}: gh: Bad Gateway (HTTP 502)" ]
}

@test "advisory view keeps a summary, a package name or a range holding a tab, a newline or a forged line on its own line with its own fields" {
    local vulns
    vulns="$(affected_package nuget $'Evil\tPkg\nnpm' $'< 1\x1fend\nx' $'2.0\r' | jq -s '.')"
    global_advisory "${GHSA_ID}" low $'one\ttwo\nwithdrawn\t2026-01-01T00:00:00Z\x07' 2026-10-01T12:34:56Z '' "${vulns}" | write_api "$(global_advisory_endpoint)"
    run_advisory_view
    [ "${status}" -eq 0 ]
    [ "$(wc -l <<< "${output}")" -eq 6 ]
    [ "$(sed -n 3p <<< "${output}")" = $'summary\tone two withdrawn 2026-01-01T00:00:00Z ' ]
    [ "$(sed -n 6p <<< "${output}")" = $'nuget\tEvil Pkg npm\t< 1 end x\t2.0 ' ]
    [ "$(sed -n 6p <<< "${output}" | awk -F '\t' '{print NF}')" -eq 4 ]
}

@test "advisory view prints nothing and exits 1 for an answer that is not the advisory asked for, or does not have exactly its fields and rows" {
    local bad vulns
    vulns="$(affected_package nuget P '< 1' 1.0 | jq -s '.')"
    for bad in "id:GHSA-2345-6789-cfgh" "id:" "severity:severe" "severity:High" "published:" "published:2026-10-01" "published:yesterday" "withdrawn:soon" \
        "eco:" "name:"; do
        local id="${GHSA_ID}" severity=high published=2026-10-01T12:34:56Z withdrawn="" eco=nuget name=P
        case "${bad}" in
            id:*) id="${bad#id:}" ;;
            severity:*) severity="${bad#severity:}" ;;
            published:*) published="${bad#published:}" ;;
            withdrawn:*) withdrawn="${bad#withdrawn:}" ;;
            eco:*) eco="${bad#eco:}" ;;
            name:*) name="${bad#name:}" ;;
        esac
        vulns="$(affected_package "${eco}" "${name}" '< 1' 1.0 | jq -s '.')"
        global_advisory "${id}" "${severity}" summary "${published}" "${withdrawn}" "${vulns}" | write_api "$(global_advisory_endpoint)"
        run_advisory_view
        [ "${status}" -eq 1 ] || { echo "printed: ${bad}" >&2; return 1; }
        [ -z "${output}" ]
        [ "${stderr}" = "cfwf: gh returned an unexpected result for the advisory ${GHSA_ID}" ]
    done

    local out
    for out in "" \
        $'GHSA-cfgh-jmpq-rvwx\x1fhigh\x1fs\x1f2026-10-01T12:34:56Z\x1f\x1f2\x1fend\nnuget\x1fP\x1f<1\x1f1\x1fend' \
        $'GHSA-cfgh-jmpq-rvwx\x1fhigh\x1fs\x1f2026-10-01T12:34:56Z\x1f\x1f0\x1fend\nnuget\x1fP\x1f<1\x1f1\x1fend' \
        $'GHSA-cfgh-jmpq-rvwx\x1fhigh\x1fs\x1f2026-10-01T12:34:56Z\x1f\x1f1\x1fend\nnuget\x1fP\x1f<1\x1f1\x1fend\x1fextra' \
        $'GHSA-cfgh-jmpq-rvwx\x1fhigh\x1fs\x1f2026-10-01T12:34:56Z\x1f\x1fone\x1fend' \
        $'GHSA-cfgh-jmpq-rvwx\x1fhigh\x1fs\x1f2026-10-01T12:34:56Z\x1f\x1f0'; do
        printf '%s\n' "${out}" > "$(api_fixture "$(global_advisory_endpoint)").out"
        run_advisory_view
        [ "${status}" -eq 1 ] || { echo "printed: ${out}" >&2; return 1; }
        [ -z "${output}" ]
    done
}

@test "advisory view prints exactly 1000 affected packages, and with 1001 prints none and exits 1" {
    local n
    for n in 1000 1001; do
        jq -n --argjson n "${n}" '{ghsa_id: "GHSA-cfgh-jmpq-rvwx", severity: "low", summary: "s", published_at: "2026-10-01T12:34:56Z",
            vulnerabilities: [range($n) | {package: {ecosystem: "npm", name: "p\(.)"}, vulnerable_version_range: "< 1", first_patched_version: "1.0.0"}]}' \
            | write_api "$(global_advisory_endpoint)"
        run_advisory_view
        if [ "${n}" -eq 1000 ]; then
            [ "${status}" -eq 0 ]
            [ "$(wc -l <<< "${output}")" -eq 1005 ]
        else
            [ "${status}" -eq 1 ]
            [ -z "${output}" ]
            [ "${stderr}" = "cfwf: the advisory ${GHSA_ID} has more than 1000 affected packages, so none is printed" ]
        fi
    done
}

@test "advisory view fails (exit 1) when gh is not installed, after its options are checked" {
    mkdir -p "${TEST_TMP}/empty-path"
    run --separate-stderr env PATH="${TEST_TMP}/empty-path" "$(command -v bash)" "${SCRIPT}" advisory view --ghsa "${GHSA_ID}"
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == "cfwf: gh is not installed"* ]]
    run --separate-stderr env PATH="${TEST_TMP}/empty-path" "$(command -v bash)" "${SCRIPT}" advisory view --ghsa bad
    [ "${status}" -eq 2 ]
}

@test "repo view, repo collaborators and auth status fail (exit 1) when gh is not installed, after their options are checked" {
    local args
    mkdir -p "${TEST_TMP}/empty-path"
    for args in "repo view --repo ${REPO}" "repo collaborators --repo ${REPO}" "repo advisories --repo ${REPO}" "auth status" "auth status --rate-limit"; do
        # shellcheck disable=SC2086  # each command is split into its words on purpose
        run --separate-stderr env PATH="${TEST_TMP}/empty-path" "$(command -v bash)" "${SCRIPT}" ${args}
        [ "${status}" -eq 1 ] || { echo "${args}: ${status}" >&2; return 1; }
        [ -z "${output}" ]
        [[ "${stderr}" == "cfwf: gh is not installed"* ]]

        # shellcheck disable=SC2086  # each command is split into its words on purpose
        run --separate-stderr env PATH="${TEST_TMP}/empty-path" "$(command -v bash)" "${SCRIPT}" ${args} --json x
        [ "${status}" -eq 2 ]
    done
}

@test "repo view, repo collaborators and auth status leave no temporary file behind, whether the read works or fails" {
    local scratch="${TEST_TMP}/scratch"
    mkdir -p "${scratch}"
    write_repository_metadata
    write_collaborators "$(collaborator alice write)"
    prepare_auth_status
    TMPDIR="${scratch}" run_repo view
    [ "${status}" -eq 0 ]
    [ -z "$(ls -A "${scratch}")" ]
    TMPDIR="${scratch}" run_repo collaborators
    [ "${status}" -eq 0 ]
    [ -z "$(ls -A "${scratch}")" ]
    TMPDIR="${scratch}" run_auth_status --rate-limit
    [ "${status}" -eq 0 ]
    [ -z "$(ls -A "${scratch}")" ]

    fail_repository "gh: Bad Gateway (HTTP 502)"
    fail_api "${COLLABORATORS_ENDPOINT}"
    fail_api user
    TMPDIR="${scratch}" run_repo view
    [ "${status}" -eq 1 ]
    [ -z "$(ls -A "${scratch}")" ]
    TMPDIR="${scratch}" run_repo collaborators
    [ "${status}" -eq 1 ]
    [ -z "$(ls -A "${scratch}")" ]
    TMPDIR="${scratch}" run_auth_status
    [ "${status}" -eq 1 ]
    [ -z "$(ls -A "${scratch}")" ]
}

# --- repo list, repo search, pr search, code search and workflow list -------------------------------
# One repository as gh repo list gives it: name $1, visibility $2, archived $3 (true or false) and
# default branch $4 (empty for none), with a field repo list does not print.
listed_repository() {
    jq -n --arg name "$1" --arg visibility "$2" --argjson archived "$3" --arg branch "$4" \
        '{name: $name, visibility: $visibility, isArchived: $archived, description: "decoy-description",
          defaultBranchRef: (if $branch == "" then null else {name: $branch} end)}'
}

# Writes the repositories gh repo list answers with: each argument a repository object.
write_repo_list() {
    printf '%s\n' "$@" | jq -s '.' > "${GH_FIXTURES}/repo-list.json"
}

write_owner() {
    jq -n --arg login "${OWNER}" '{login: $login}' | write_api "users/${OWNER}"
}

@test "repo list prints each repository's name, visibility, active or archived and default branch, sorted by name, archived ones left out unless asked for, after reading the owner" {
    write_owner
    write_repo_list "$(listed_repository zeta PUBLIC false main)" "$(listed_repository Alpha PRIVATE false trunk)" \
        "$(listed_repository old-one PUBLIC true master)" "$(listed_repository empty-repo PUBLIC false '')"
    run --separate-stderr "${SCRIPT}" repo list --owner "${OWNER}"
    [ "${status}" -eq 0 ]
    [ "${output}" = $'Alpha\tPRIVATE\tactive\ttrunk\nempty-repo\tPUBLIC\tactive\t-\nzeta\tPUBLIC\tactive\tmain' ]
    [ "$(gh_call_count "api users/${OWNER} --jq .login")" -eq 1 ]
    [ "$(gh_call_count "repo list ${OWNER} --limit 1001 --json name,visibility,isArchived,defaultBranchRef --jq ")" -eq 1 ]
    [ "$(gh_call_count "--no-archived")" -eq 1 ]

    run --separate-stderr "${SCRIPT}" repo list --owner "${OWNER}" --include-archived
    [ "${status}" -eq 0 ]
    [ "${output}" = $'Alpha\tPRIVATE\tactive\ttrunk\nempty-repo\tPUBLIC\tactive\t-\nold-one\tPUBLIC\tarchived\tmaster\nzeta\tPUBLIC\tactive\tmain' ]
}

@test "repo list exits 9 for an owner that is not there, and 1 for any other failed read, printing nothing" {
    run --separate-stderr "${SCRIPT}" repo list --owner "${OWNER}"
    [ "${status}" -eq 9 ]
    [ -z "${output}" ]
    [ "${stderr}" = "cfwf: the owner ${OWNER} was not found" ]
    [ "$(gh_call_count "repo list")" -eq 0 ]

    write_owner
    echo "HTTP 502: Bad Gateway" > "${GH_FIXTURES}/repo-list.fail"
    run --separate-stderr "${SCRIPT}" repo list --owner "${OWNER}"
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == "cfwf: could not list the repositories of ${OWNER}: HTTP 502: Bad Gateway" ]]
}

@test "repo list prints nothing and exits 1 for a row that is not a repository, or more than 1000 repositories, and keeps a forged branch name on one line" {
    write_owner
    write_repo_list "$(listed_repository 'bad name' PUBLIC false main)"
    run --separate-stderr "${SCRIPT}" repo list --owner "${OWNER}"
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    write_repo_list "$(listed_repository good SECRET false main)"
    run --separate-stderr "${SCRIPT}" repo list --owner "${OWNER}"
    [ "${status}" -eq 1 ]
    write_repo_list "$(listed_repository good PUBLIC false $'main\nforged\tPUBLIC\tactive\tx')"
    run --separate-stderr "${SCRIPT}" repo list --owner "${OWNER}"
    [ "${status}" -eq 0 ]
    [ "${output}" = $'good\tPUBLIC\tactive\tmain forged PUBLIC active x' ]
    jq -n '[range(1001) | {name: ("r" + tostring), visibility: "PUBLIC", isArchived: false, defaultBranchRef: {name: "main"}}]' > "${GH_FIXTURES}/repo-list.json"
    run --separate-stderr "${SCRIPT}" repo list --owner "${OWNER}"
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    [[ "${stderr}" == "cfwf: ${OWNER} has more than 1000 repositories, so none is printed" ]]
}

@test "repo list and repo search usage errors exit 2 before any gh call, never echoing a value" {
    local token args
    token="gh""p_$(run_of a 36)"
    local -a cases=(
        "repo list"
        "repo list --owner"
        "repo list --owner -bad"
        "repo list --owner a/b"
        "repo list --owner ${OWNER} --owner ${OWNER}"
        "repo list --owner ${OWNER} --limit 5"
        "repo list --owner ${OWNER} --json name"
        "repo list --repo ${REPO}"
        "repo search --owner ${OWNER}"
        "repo search --text words"
        "repo search --owner ${OWNER} --text"
        "repo search --owner ${OWNER} --text ..."
        "repo search --owner ${OWNER} --text a OR b"
        "repo search --owner ${OWNER} --text words --limit 0"
        "repo search --owner ${OWNER} --text words --limit 101"
        "repo search --owner ${OWNER} --text words --state open"
        "repo list --owner ${OWNER} ${token}"
    )
    for args in "${cases[@]}"; do
        # shellcheck disable=SC2086  # each case is split into its words on purpose
        run --separate-stderr "${SCRIPT}" ${args}
        [ "${status}" -eq 2 ] || {
            echo "accepted: ${args} (${status})" >&2
            return 1
        }
        [ -z "${output}" ]
        [[ "${stderr}" == *"Usage: cfwf repo "* ]]
        [[ "${stderr}" != *"${token}"* ]]
    done
    [ ! -f "${GH_LOG}" ]
}

# One repository as gh search repos gives it: owner/name $1, visibility $2 (gh gives lower case),
# archived $3 and default branch $4.
found_repository() {
    jq -n --arg name "$1" --arg visibility "$2" --argjson archived "$3" --arg branch "$4" \
        '{fullName: $name, visibility: $visibility, isArchived: $archived, defaultBranch: $branch, description: "decoy-description"}'
}

@test "repo search searches names and descriptions of one owner after --, archived ones left out unless asked for, sorted, and cut with a warning at --limit" {
    printf '%s\n' "$(found_repository credfeto/zz public false main)" "$(found_repository credfeto/aa private false trunk)" \
        "$(found_repository credfeto/mm public false main)" | jq -s '.' > "${GH_FIXTURES}/search-repos.json"
    run --separate-stderr "${SCRIPT}" repo search --owner "${OWNER}" --text "cfwf: tools"
    [ "${status}" -eq 0 ]
    [ "${output}" = $'credfeto/aa\tPRIVATE\tactive\ttrunk\ncredfeto/mm\tPUBLIC\tactive\tmain\ncredfeto/zz\tPUBLIC\tactive\tmain' ]
    [ -z "${stderr}" ]
    [ "$(gh_call_count "search repos --owner ${OWNER} --limit 31 --json fullName,visibility,isArchived,defaultBranch --jq ")" -eq 1 ]
    grep -qF -- "--archived=false -- in:name,description cfwf tools" "${GH_LOG}"

    run --separate-stderr "${SCRIPT}" repo search --owner "${OWNER}" --text tools --limit 2 --include-archived
    [ "${status}" -eq 0 ]
    [ "${output}" = $'credfeto/aa\tPRIVATE\tactive\ttrunk\ncredfeto/zz\tPUBLIC\tactive\tmain' ]
    [ "${stderr}" = "cfwf: warning: more than 2 repositories match; only the first 2 are printed" ]
    [ "$(grep -cF -- "--archived=false" "${GH_LOG}")" -eq 1 ]
}

@test "repo search exits 9 when GitHub cannot search the owner, and 8 for a token in --text before any gh call" {
    echo "The listed users and repositories cannot be searched either because the resources do not exist or you do not have permission to view them." > "${GH_FIXTURES}/search-repos.fail"
    run --separate-stderr "${SCRIPT}" repo search --owner "${OWNER}" --text tools
    [ "${status}" -eq 9 ]
    [ "${stderr}" = "cfwf: the owner ${OWNER} was not found" ]
    rm -f "${GH_LOG}"
    run --separate-stderr "${SCRIPT}" repo search --owner "${OWNER}" --text "gh""p_$(run_of a 36)"
    [ "${status}" -eq 8 ]
    [ "${stderr}" = "cfwf: text refused: token" ]
    [ ! -f "${GH_LOG}" ]
}

# One pull request as gh pr list gives it for pr search: number $1, state $2, head $3 and title $4.
searched_pull_request() {
    jq -n --argjson number "$1" --arg state "$2" --arg head "$3" --arg title "$4" \
        '{number: $number, state: $state, headRefName: $head, title: $title, author: {login: "decoy"}}'
}

@test "pr search searches titles and bodies of one repository's pull requests in the search's order, with --state, and cuts with a warning at --limit" {
    printf '%s\n' "$(searched_pull_request 9 MERGED feat/9-x 'feat: x')" "$(searched_pull_request 3 OPEN fix/3-y 'fix: y')" \
        "$(searched_pull_request 5 CLOSED feat/5-z $'tab\there')" | jq -s '.' > "${GH_FIXTURES}/pr-list.json"
    run --separate-stderr "${SCRIPT}" pr search --repo "${REPO}" --text "repo advisories" --state merged
    [ "${status}" -eq 0 ]
    [ "${output}" = $'9\tMERGED\tfeat/9-x\tfeat: x\n3\tOPEN\tfix/3-y\tfix: y\n5\tCLOSED\tfeat/5-z\ttab here' ]
    [ "$(gh_call_count "pr list --repo ${REPO} --state merged --search in:title,body repo advisories --limit 31 --json number,state,headRefName,title --jq ")" -eq 1 ]

    run --separate-stderr "${SCRIPT}" pr search --repo "${REPO}" --text words --limit 2
    [ "${status}" -eq 0 ]
    [ "${output}" = $'9\tMERGED\tfeat/9-x\tfeat: x\n3\tOPEN\tfix/3-y\tfix: y' ]
    [ "${stderr}" = "cfwf: warning: more than 2 pull requests match; only the first 2 are printed" ]
    grep -qF -- "--state open --search" "${GH_LOG}"
}

@test "pr search usage errors exit 2 before any gh call, and a row that is not a pull request prints nothing and exits 1" {
    local args
    for args in "--text x" "--repo ${REPO}" "--repo ${REPO} --text x --state draft" "--repo ${REPO} --text a NOT b" "--repo ${REPO} --text x --label y"; do
        # shellcheck disable=SC2086  # each case is split into its words on purpose
        run --separate-stderr "${SCRIPT}" pr search ${args}
        [ "${status}" -eq 2 ] || {
            echo "accepted: ${args}" >&2
            return 1
        }
        [[ "${stderr}" == *"Usage: cfwf pr search "* ]]
    done
    [ ! -f "${GH_LOG}" ]
    searched_pull_request 9 DRAFT feat/9-x x | jq -s '.' > "${GH_FIXTURES}/pr-list.json"
    run --separate-stderr "${SCRIPT}" pr search --repo "${REPO}" --text words
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
}

# One file as gh search code gives it: path $1 and the number $2 of text matches, each holding file
# content that must never be printed.
found_code() {
    jq -n --arg path "$1" --argjson n "$2" \
        '{path: $path, sha: "decoy", url: "https://example.com/decoy", textMatches: [range($n) | {fragment: "SECRET-CONTENT", matches: []}]}'
}

@test "code search reads the repository first, then prints each matching file's path and match count sorted by path, and never any file content" {
    jq -n '{id: 1}' | write_api "repos/${REPO}"
    printf '%s\n' "$(found_code src/z.sh 2)" "$(found_code README.md 1)" "$(found_code lib/a 0)" | jq -s '.' > "${GH_FIXTURES}/search-code.json"
    run --separate-stderr "${SCRIPT}" code search --repo "${REPO}" --text usage_repo_advisories
    [ "${status}" -eq 0 ]
    [ "${output}" = $'README.md\t1\nlib/a\t0\nsrc/z.sh\t2' ]
    [[ "${output}" != *"SECRET-CONTENT"* ]]
    [ "$(gh_line_of "api repos/${REPO} --jq .id")" -lt "$(gh_line_of "search code")" ]
    [ "$(gh_call_count "search code --repo ${REPO} --limit 31 --json path,textMatches --jq ")" -eq 1 ]
    grep -qF -- " -- usage_repo_advisories" "${GH_LOG}"

    run --separate-stderr "${SCRIPT}" code search --repo "${REPO}" --text x --limit 1
    [ "${status}" -eq 0 ]
    [ "${output}" = $'src/z.sh\t2' ]
    [ "${stderr}" = "cfwf: warning: more than 1 files match; only the first 1 are printed" ]
}

@test "code search exits 1 with the repository message for a repository that is not there, and 2 for usage errors, before searching" {
    run --separate-stderr "${SCRIPT}" code search --repo "${REPO}" --text words
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: the repository ${REPO} was not found, or the caller cannot see it" ]
    [ "$(gh_call_count "search code")" -eq 0 ]
    rm -f "${GH_LOG}"
    local args
    for args in "" "--repo ${REPO}" "--text x" "--repo ${REPO} --text x --owner y" "--repo ${REPO} --text x --limit 200"; do
        # shellcheck disable=SC2086  # each case is split into its words on purpose
        run --separate-stderr "${SCRIPT}" code search ${args}
        [ "${status}" -eq 2 ] || {
            echo "accepted: ${args}" >&2
            return 1
        }
    done
    run --separate-stderr "${SCRIPT}" code
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: code needs a subcommand (search)"$'\n'* ]]
    [ ! -f "${GH_LOG}" ]
}

write_workflows() {
    printf '%s\n' "$@" | jq -s '{total_count: length, workflows: .}' | write_api "${WORKFLOWS_ENDPOINT}"
}

@test "workflow list prints each workflow's path, state and name sorted by path, disabled ones included, from one paged read" {
    write_workflows "$(workflow 'Build' .github/workflows/build.yml active)" \
        "$(workflow 'Old' .github/workflows/old.yml disabled_manually)" "$(workflow $'Lint\tx' .github/workflows/a-lint.yml active)"
    run --separate-stderr "${SCRIPT}" workflow list --repo "${REPO}"
    [ "${status}" -eq 0 ]
    [ "${output}" = $'.github/workflows/a-lint.yml\tactive\tLint x\n.github/workflows/build.yml\tactive\tBuild\n.github/workflows/old.yml\tdisabled_manually\tOld' ]
    [ "$(gh_call_count "api ${WORKFLOWS_ENDPOINT}?per_page=100 --paginate --jq ")" -eq 1 ]
}

@test "workflow list prints nothing and exits 1 for a state that is not GitHub's or a 404, and 2 for usage errors" {
    write_workflows "$(workflow Build .github/workflows/build.yml paused)"
    run --separate-stderr "${SCRIPT}" workflow list --repo "${REPO}"
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
    rm -f "$(api_fixture "${WORKFLOWS_ENDPOINT}").json"
    run --separate-stderr "${SCRIPT}" workflow list --repo "${REPO}"
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: the repository ${REPO} was not found, or the caller cannot see it" ]
    write_workflows
    run --separate-stderr "${SCRIPT}" workflow list --repo "${REPO}"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    rm -f "${GH_LOG}"
    run --separate-stderr "${SCRIPT}" workflow list
    [ "${status}" -eq 2 ]
    run --separate-stderr "${SCRIPT}" workflow list --repo "${REPO}" --all
    [ "${status}" -eq 2 ]
    run --separate-stderr "${SCRIPT}" workflow
    [[ "${stderr}" == "cfwf: workflow needs a subcommand (list)"$'\n'* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "the new commands are in the general help and their own help, and help calls no gh" {
    run "${SCRIPT}" help
    [[ "${output}" == *$'\n'"  repo list                List an owner's repositories, sorted by name, archived ones left out unless asked for"$'\n'* ]]
    [[ "${output}" == *$'\n'"  repo search              Search an owner's repositories by words in their name or description, one line each"$'\n'* ]]
    [[ "${output}" == *$'\n'"  pr search                Search one repository's pull requests by words in their title or body, one line each"$'\n'* ]]
    [[ "${output}" == *$'\n'"  code search              Search one repository's code by words, printing each matching file's path"$'\n'* ]]
    [[ "${output}" == *$'\n'"  workflow list            List a repository's Actions workflows: path, state and name, sorted by path"$'\n'* ]]
    local spelling
    for spelling in "repo list" "repo search" "pr search" "code search" "workflow list"; do
        # shellcheck disable=SC2086  # each spelling is split into its words on purpose
        run "${SCRIPT}" ${spelling} --help
        [ "${status}" -eq 0 ]
        [[ "${output}" == "Usage: cfwf ${spelling} "* ]] || {
            echo "${spelling}" >&2
            return 1
        }
        # shellcheck disable=SC2086
        run "${SCRIPT}" help ${spelling}
        [[ "${output}" == "Usage: cfwf ${spelling} "* ]]
    done
    run "${SCRIPT}" help repo
    [[ "${output}" == *"Usage: cfwf repo list --owner <owner> [--include-archived]"* ]]
    [[ "${output}" == *"Usage: cfwf repo search --owner <owner> --text <words>"* ]]
    run "${SCRIPT}" help pr
    [[ "${output}" == *"Run 'cfwf pr search --help' for pr search"* ]]
    [ ! -f "${GH_LOG}" ]
}

# --- repo file (#1721) -----------------------------------------------------------

REPO_FILE_USAGE="Usage: cfwf repo file --repo <owner/repo> --path <path> [--ref <branch|tag|sha>]"

# Writes the answer to the contents read of the path $1 (as it goes in the API path): a file of type
# $3 (file by default) whose bytes are the file $2, base64 encoded and broken into lines as GitHub
# breaks them. An optional jq filter $4 changes it.
write_repo_file() {
    jq -n --arg content "$(base64 -w 60 < "$2")" --argjson size "$(wc -c < "$2")" --arg kind "${3:-file}" \
        '{type: $kind, encoding: "base64", size: $size, name: "decoy-name", path: "decoy/path", sha: "0123", content: ($content + "\n")}' \
        | jq "${4:-.}" | write_api "repos/${REPO}/contents/$1"
}

# Writes a directory listing for the path $1: each further argument is one entry, "<type> <name>".
write_repo_directory() {
    local path="$1" entry
    shift
    for entry in "$@"; do
        jq -n --arg kind "${entry%% *}" --arg name "${entry#* }" '{type: $kind, name: $name, path: ("decoy/" + $name), size: 1}'
    done | jq -s '.' | write_api "repos/${REPO}/contents/${path}"
}

# Runs repo file on REPO with the given options, its stdout kept byte for byte in TEST_TMP/out.
run_repo_file() {
    # The inner script is single-quoted on purpose: the bash it runs expands it.
    # shellcheck disable=SC2016
    run --separate-stderr bash -c '"$0" repo file --repo "$1" "${@:3}" > "$2"' "${SCRIPT}" "${REPO}" "${TEST_TMP}/out" "$@"
}

@test "repo file help is the same from -h, --help and help repo file, states the output, the refusals and the exit codes, is in help repo and the general help, and calls no gh" {
    local spelling expected
    run "${SCRIPT}" repo file -h
    [ "${status}" -eq 0 ]
    expected="${output}"
    [[ "${expected}" == "${REPO_FILE_USAGE}"$'\n'* ]]
    [[ "${expected}" == *"byte for byte"* ]]
    [[ "${expected}" == *"<type>  <name>"* ]]
    [[ "${expected}" == *"a file over"*"1048576 bytes (1 MiB)"* ]]
    [[ "${expected}" == *"a directory of 1000 entries or more"* ]]
    [[ "${expected}" == *"--json, --jq, --raw and --web are not options"* ]]
    [[ "${expected}" == *"Exit codes: 0 printed; 8 refused; 9 the repository, the --path or the --ref was not found"* ]]
    for spelling in "repo file --help" "help repo file" "-h repo file" "--help repo file"; do
        # shellcheck disable=SC2086  # each spelling is split into its words on purpose
        run "${SCRIPT}" ${spelling}
        [ "${status}" -eq 0 ]
        [ "${output}" = "${expected}" ] || { echo "${spelling} differs" >&2; return 1; }
    done
    run "${SCRIPT}" help repo
    [[ "${output}" == *"Usage: cfwf repo search "*$'\n\n'"${REPO_FILE_USAGE}"$'\n'* ]]
    run "${SCRIPT}" help
    [[ "${output}" == *$'\n'"  repo search              Search an owner's repositories by words in their name or description, one line each"$'\n'"  repo file                Print a file's contents, or list a directory, at a branch, tag or commit (exit 8 refused, 9 not found)"$'\n'* ]]
    [ ! -f "${GH_LOG}" ]
}

@test "repo file prints a text file on the default branch byte for byte, trailing newlines, a carriage return and UTF-8 kept, from one read of its percent-encoded path with no ref" {
    printf 'first line\r\n\tsecond, caf\xc3\xa9 & 100%%\n\n\n' > "${TEST_TMP}/expected"
    write_repo_file "docs/read%20me%26notes.md" "${TEST_TMP}/expected"
    run_repo_file --path "docs/read me&notes.md"
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    cmp "${TEST_TMP}/out" "${TEST_TMP}/expected"
    [ "$(wc -l < "${GH_LOG}")" -eq 1 ]
    [ "$(gh_call_count "api repos/${REPO}/contents/docs/read%20me%26notes.md --jq ")" -eq 1 ]
    [ "$(gh_call_count "?ref=")" -eq 0 ]

    # A file with no newline at its end gets none, and an empty file prints nothing.
    printf 'no newline' > "${TEST_TMP}/expected"
    write_repo_file "LICENSE" "${TEST_TMP}/expected"
    run_repo_file --path LICENSE
    [ "${status}" -eq 0 ]
    cmp "${TEST_TMP}/out" "${TEST_TMP}/expected"
    : > "${TEST_TMP}/expected"
    write_repo_file "empty" "${TEST_TMP}/expected"
    run_repo_file --path empty
    [ "${status}" -eq 0 ]
    [ ! -s "${TEST_TMP}/out" ]
}

@test "repo file reads a file at a branch, a tag or a commit, the ref percent-encoded in the query with each slash kept" {
    local ref
    printf 'at a ref\n' > "${TEST_TMP}/expected"
    write_repo_file "src/main.c" "${TEST_TMP}/expected"
    run_repo_file --path src/main.c --ref "feature/a+b"
    [ "${status}" -eq 0 ]
    cmp "${TEST_TMP}/out" "${TEST_TMP}/expected"
    [ "$(gh_call_count "api repos/${REPO}/contents/src/main.c?ref=feature/a%2Bb --jq ")" -eq 1 ]
    for ref in v4.2.2 0123456789abcdef0123456789abcdef01234567 HEAD; do
        run_repo_file --path src/main.c --ref "${ref}"
        [ "${status}" -eq 0 ] || { echo "${ref}: ${status}" >&2; return 1; }
        cmp "${TEST_TMP}/out" "${TEST_TMP}/expected"
        [ "$(gh_call_count "api repos/${REPO}/contents/src/main.c?ref=${ref} --jq ")" -eq 1 ]
    done
}

@test "repo file lists a directory, one <type><TAB><name> line an entry sorted by name in the C locale, a forged name kept on one line" {
    write_repo_directory "src" "file zeta.c" "dir Alpha" "symlink link" "submodule vendor" $'file bad\nforged\tfile'
    run_repo_file --path src
    [ "${status}" -eq 0 ]
    [ -z "${stderr}" ]
    [ "$(cat "${TEST_TMP}/out")" = $'dir\tAlpha\nfile\tbad forged file\nsymlink\tlink\nsubmodule\tvendor\nfile\tzeta.c' ]
    [ "$(wc -l < "${TEST_TMP}/out")" -eq 5 ]
}

@test "repo file refuses (exit 8, nothing printed) a binary file, an oversized one, one GitHub sends no content for, a long directory, a submodule and a symlink" {
    printf 'PNG\000\001\002' > "${TEST_TMP}/binary"
    write_repo_file "logo.png" "${TEST_TMP}/binary"
    run_repo_file --path logo.png
    [ "${status}" -eq 8 ]
    [ ! -s "${TEST_TMP}/out" ]
    [ "${stderr}" = "cfwf: the --path of ${REPO} holds a NUL byte (binary), so nothing is printed" ]

    printf 'small\n' > "${TEST_TMP}/small"
    write_repo_file "big.log" "${TEST_TMP}/small" file '.size = 1048577'
    run_repo_file --path big.log
    [ "${status}" -eq 8 ]
    [ ! -s "${TEST_TMP}/out" ]
    [ "${stderr}" = "cfwf: the --path of ${REPO} is 1048577 bytes, over the limit of 1048576, so nothing is printed" ]

    write_repo_file "big.log" "${TEST_TMP}/small" file '.encoding = "none" | .content = "" | .size = 1000001'
    run_repo_file --path big.log
    [ "${status}" -eq 8 ]
    [ "${stderr}" = "cfwf: the --path of ${REPO} is too large for GitHub to send its content, so nothing is printed" ]

    jq -n '[range(1000) | {type: "file", name: ("f" + tostring)}]' | write_api "repos/${REPO}/contents/many"
    run_repo_file --path many
    [ "${status}" -eq 8 ]
    [ ! -s "${TEST_TMP}/out" ]
    [ "${stderr}" = "cfwf: the --path of ${REPO} is a directory of 1000 entries or more, which GitHub may have cut, so nothing is printed" ]

    local kind
    for kind in submodule symlink; do
        write_repo_file "vendor" "${TEST_TMP}/small" "${kind}"
        run_repo_file --path vendor
        [ "${status}" -eq 8 ] || { echo "${kind}: ${status}" >&2; return 1; }
        [ ! -s "${TEST_TMP}/out" ]
        [ "${stderr}" = "cfwf: the --path of ${REPO} is a ${kind}, not a file or a directory, so nothing is printed" ]
    done
}

@test "repo file exits 9 for a path or a ref that is not there, and for a repository that is not there, never naming the path or the ref" {
    write_this_repository
    run_repo_file --path no/such-file.md
    [ "${status}" -eq 9 ]
    [ ! -s "${TEST_TMP}/out" ]
    [ "${stderr}" = "cfwf: the --path was not found in ${REPO} on its default branch" ]
    [ "$(gh_line_of "api repos/${REPO} --jq .id")" -eq 2 ]

    run_repo_file --path no/such-file.md --ref main
    [ "${status}" -eq 9 ]
    [ "${stderr}" = "cfwf: the --path was not found in ${REPO} at the --ref" ]

    printf 'kept\n' > "${TEST_TMP}/small"
    write_repo_file "README.md" "${TEST_TMP}/small"
    fail_api "repos/${REPO}/contents/README.md" "gh: No commit found for the ref no-such-branch (HTTP 404)"
    run_repo_file --path README.md --ref no-such-branch
    [ "${status}" -eq 9 ]
    [ ! -s "${TEST_TMP}/out" ]
    [ "${stderr}" = "cfwf: the --ref was not found in ${REPO}" ]
    [[ "${stderr}" != *no-such-branch* ]]

    rm "$(api_fixture "repos/${REPO}").json"
    run_repo_file --path README.md --ref no-such-branch
    [ "${status}" -eq 9 ]
    [ "${stderr}" = "cfwf: the repository ${REPO} was not found, or the caller cannot see it" ]
}

@test "repo file reports a failed read, or an answer that is not a file or a directory, as a runtime failure (exit 1), printing nothing" {
    printf 'content\n' > "${TEST_TMP}/small"
    fail_api "repos/${REPO}/contents/README.md" "gh: Bad Gateway (HTTP 502)"$'\n'"a second line"
    run_repo_file --path README.md
    [ "${status}" -eq 1 ]
    [ ! -s "${TEST_TMP}/out" ]
    [ "${stderr}" = "cfwf: could not read the --path of ${REPO}: gh: Bad Gateway (HTTP 502)" ]
    rm "$(api_fixture "repos/${REPO}/contents/README.md").fail"

    local filter
    for filter in '.size = 99' '.content = "!!!not base64!!!"' '.encoding = "utf-8"' '.type = "dir"' 'del(.type)' '.size = "12"'; do
        write_repo_file "README.md" "${TEST_TMP}/small" file "${filter}"
        run_repo_file --path README.md
        [ "${status}" -eq 1 ] || { echo "${filter}: ${status}" >&2; return 1; }
        [ ! -s "${TEST_TMP}/out" ]
        [ "${stderr}" = "cfwf: gh returned an unexpected result for the --path of ${REPO}" ]
    done
    jq -n '[{type: "blob", name: "x"}]' | write_api "repos/${REPO}/contents/src"
    run_repo_file --path src
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "cfwf: gh returned an unexpected result for the --path of ${REPO}" ]
}

@test "repo file usage errors exit 2 before any gh call, each with its own usage, never echoing a value" {
    local long args
    long=$(run_of a 4097)
    local -a cases=(
        "repo file"
        "repo file --path README.md"
        "repo file --repo ${REPO}"
        "repo file --repo ${REPO} --path"
        "repo file --repo ${REPO} --path README.md --ref"
        "repo file --repo ${REPO} --path /etc/passwd"
        "repo file --repo ${REPO} --path docs/"
        "repo file --repo ${REPO} --path docs//x"
        "repo file --repo ${REPO} --path ./x"
        "repo file --repo ${REPO} --path docs/../../x"
        "repo file --repo ${REPO} --path .."
        "repo file --repo ${REPO} --path ${long}"
        "repo file --repo ${REPO} --path a --path b"
        "repo file --repo ${REPO} --path a --ref main --ref dev"
        "repo file --repo ${REPO} --path a --ref a..b"
        "repo file --repo ${REPO} --path a --ref refs/heads/x.lock"
        "repo file --repo ${REPO} --path a --ref x?y"
        "repo file --repo ${REPO} --path a --json content"
        "repo file --repo ${REPO} --path a --jq .content"
        "repo file --repo ${REPO} --path a --raw"
        "repo file --repo ../x --path a"
        "repo file --repo ${REPO} --path a stray"
    )
    for args in "${cases[@]}"; do
        # shellcheck disable=SC2086  # each case is split into its words on purpose
        run --separate-stderr "${SCRIPT}" ${args}
        [ "${status}" -eq 2 ] || { echo "accepted: ${args} (${status})" >&2; return 1; }
        [ -z "${output}" ]
        [[ "${stderr}" == "cfwf: "*$'\n\n'"${REPO_FILE_USAGE}"$'\n'* ]] || { echo "usage: ${args}" >&2; return 1; }
    done
    run --separate-stderr "${SCRIPT}" repo file --repo "${REPO}" --path ""
    [ "${status}" -eq 2 ]
    run --separate-stderr "${SCRIPT}" repo file --repo "${REPO}" --path $'a\nb'
    [ "${status}" -eq 2 ]
    [[ "${stderr}" == "cfwf: invalid value for --path: it must not contain a control character"$'\n'* ]]
    run --separate-stderr "${SCRIPT}" repo file --repo "${REPO}" --path a --ref $'main\xc2\x85'
    [ "${status}" -eq 2 ]
    run --separate-stderr "${SCRIPT}" repo file --repo "${REPO}" --path "secret-token-path" --ref "bad ref"
    [ "${status}" -eq 2 ]
    [[ "${stderr}" != *"bad ref"* && "${stderr}" != *secret-token-path* ]]
    [ ! -f "${GH_LOG}" ]
}

# Raw gh is denied to the agent's Bash tool (#1805), but cfwf runs gh as its own subprocess: the
# permission rules and PreToolUse hooks only ever see the command the agent typed (cfwf ...), so
# nothing in the agent's permission layer reaches the gh calls cfwf makes. This pins that cfwf
# still finds and runs gh from PATH, as it does in the container.
@test "cfwf runs gh itself as a subprocess, which the agent's raw-gh deny does not reach (#1805)" {
    prepare_auth_status
    run_auth_status
    [ "${status}" -eq 0 ]
    grep -qxF -- '--version' "${GH_LOG}"
    grep -q '^api user' "${GH_LOG}"
}
