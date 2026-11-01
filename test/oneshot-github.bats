#!/usr/bin/env bats
# shellcheck disable=SC2329  # functions in @test bodies are invoked indirectly via 'run'
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are used inside run() subshells where shellcheck cannot trace them

bats_require_minimum_version 1.5.0

load test_helper
load oneshot_helper

# lib/github-status sets pr_has_unaddressed_comment for its caller. It is declared here, with no
# value so it stays unset, because shellcheck does not follow bats `load` into lib/.
declare -g pr_has_unaddressed_comment

# --- fetch_pr_review_comments (#1127) -------------------------------------------

@test "fetch_pr_review_comments requests the pulls/<n>/comments REST endpoint with pagination and slurp (#1127)" {
    make_stub gh 'printf "%s" "$*" > "'"${TEST_TMP}"'/gh_args"; printf "[]"'
    fetch_pr_review_comments 42 > /dev/null
    run cat "${TEST_TMP}/gh_args"
    [[ "${output}" == *"repos/credfeto/credfeto-orchestrator/pulls/42/comments"* ]]
    [[ "${output}" == *"--paginate"* ]]
    [[ "${output}" == *"--slurp"* ]]
}

@test "fetch_pr_review_comments flattens multiple pages into a single flat array of comments (#1127)" {
    # --slurp wraps multi-page gh api --paginate output into one array of page-arrays
    # ([[...page1...],[...page2...]]); without flattening, a PR with enough inline comments
    # to span two pages would produce a nested structure that miscounts/breaks downstream jq.
    make_stub gh 'printf "[[{\"id\":1},{\"id\":2}],[{\"id\":3}]]"'
    run fetch_pr_review_comments 42
    [ "${status}" -eq 0 ]
    [ "${output}" = '[{"id":1},{"id":2},{"id":3}]' ]
}

@test "fetch_pr_review_comments retries and succeeds after a transient gh failure (#1127)" {
    GH_ITEM_FETCH_RETRY_ATTEMPTS=3
    GH_ITEM_FETCH_RETRY_DELAY_SECS=0
    # shellcheck disable=SC2016  # $n/$(...) are intentionally literal — evaluated inside the stub at run time
    make_stub gh 'n=$(cat "'"${TEST_TMP}"'/ghcount" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "'"${TEST_TMP}"'/ghcount"; [ "$n" -lt 2 ] && exit 1; printf "[]\n"'
    run fetch_pr_review_comments 5
    [ "${status}" -eq 0 ]
    [ "${output}" = "[]" ]
}

@test "fetch_pr_review_comments returns 1 without dying after exhausting retries (#1127)" {
    GH_ITEM_FETCH_RETRY_ATTEMPTS=2
    GH_ITEM_FETCH_RETRY_DELAY_SECS=0
    make_stub gh 'exit 1'
    run fetch_pr_review_comments 5
    [ "${status}" -ne 0 ]
}

# --- fetch_pr_issue_comments (#1309) --------------------------------------------

@test "fetch_pr_issue_comments requests the issues/<n>/comments REST endpoint with pagination and slurp (#1309)" {
    make_stub gh 'printf "%s" "$*" > "'"${TEST_TMP}"'/gh_args"; printf "[]"'
    fetch_pr_issue_comments 42 > /dev/null
    run cat "${TEST_TMP}/gh_args"
    [[ "${output}" == *"repos/credfeto/credfeto-orchestrator/issues/42/comments"* ]]
    [[ "${output}" == *"--paginate"* ]]
    [[ "${output}" == *"--slurp"* ]]
}

@test "fetch_pr_issue_comments flattens multiple pages into a single flat array of comments (#1309)" {
    make_stub gh 'printf "[[{\"id\":1},{\"id\":2}],[{\"id\":3}]]"'
    run fetch_pr_issue_comments 42
    [ "${status}" -eq 0 ]
    [ "${output}" = '[{"id":1},{"id":2},{"id":3}]' ]
}

@test "fetch_pr_issue_comments retries and succeeds after a transient gh failure (#1309)" {
    GH_ITEM_FETCH_RETRY_ATTEMPTS=3
    GH_ITEM_FETCH_RETRY_DELAY_SECS=0
    # shellcheck disable=SC2016  # $n/$(...) are intentionally literal — evaluated inside the stub at run time
    make_stub gh 'n=$(cat "'"${TEST_TMP}"'/ghcount" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "'"${TEST_TMP}"'/ghcount"; [ "$n" -lt 2 ] && exit 1; printf "[]\n"'
    run fetch_pr_issue_comments 5
    [ "${status}" -eq 0 ]
    [ "${output}" = "[]" ]
}

@test "fetch_pr_issue_comments returns 1 without dying after exhausting retries (#1309)" {
    GH_ITEM_FETCH_RETRY_ATTEMPTS=2
    GH_ITEM_FETCH_RETRY_DELAY_SECS=0
    make_stub gh 'exit 1'
    run fetch_pr_issue_comments 5
    [ "${status}" -ne 0 ]
}

# --- get_trusted_logins --------------------------------------------------------

@test "get_trusted_logins includes OWNER" {
    set_repo_context "myorg/myrepo"
    WHITELISTED_USERS=""
    make_stub gh 'printf ""'
    local result
    result=$(get_trusted_logins)
    printf '%s' "${result}" | jq -e 'index("myorg") != null' > /dev/null
}

@test "get_trusted_logins includes repo collaborators from GitHub API" {
    set_repo_context "myorg/myrepo"
    WHITELISTED_USERS=""
    make_stub gh 'printf "collab1\ncollab2\n"'
    local result
    result=$(get_trusted_logins)
    printf '%s' "${result}" | jq -e 'index("collab1") != null' > /dev/null
    printf '%s' "${result}" | jq -e 'index("collab2") != null' > /dev/null
}

@test "get_trusted_logins never includes the PR create bot, even as a collaborator or a whitelisted user (#1517)" {
    set_repo_context "myorg/myrepo"
    WHITELISTED_USERS="prpixie,friend"
    make_stub gh 'printf "collab1\nprpixie\n"'
    local result
    result=$(get_trusted_logins)
    printf '%s' "${result}" | jq -e 'index("prpixie") == null' > /dev/null
    printf '%s' "${result}" | jq -e 'index("collab1") != null and index("friend") != null' > /dev/null
}

@test "get_trusted_logins includes copilot-pull-request-reviewer" {
    set_repo_context "myorg/myrepo"
    WHITELISTED_USERS=""
    make_stub gh 'printf ""'
    local result
    result=$(get_trusted_logins)
    printf '%s' "${result}" | jq -e 'index("copilot-pull-request-reviewer") != null' > /dev/null
}

@test "get_trusted_logins includes github-advanced-security[bot]" {
    set_repo_context "myorg/myrepo"
    WHITELISTED_USERS=""
    make_stub gh 'printf ""'
    local result
    result=$(get_trusted_logins)
    printf '%s' "${result}" | jq -e 'index("github-advanced-security[bot]") != null' > /dev/null
}

@test "get_trusted_logins includes whitelisted users from WHITELISTED_USERS" {
    set_repo_context "myorg/myrepo"
    WHITELISTED_USERS="trusted1,trusted2"
    make_stub gh 'printf ""'
    local result
    result=$(get_trusted_logins)
    printf '%s' "${result}" | jq -e 'index("trusted1") != null' > /dev/null
    printf '%s' "${result}" | jq -e 'index("trusted2") != null' > /dev/null
}

@test "get_trusted_logins trims spaces from WHITELISTED_USERS entries" {
    set_repo_context "myorg/myrepo"
    WHITELISTED_USERS=" spaced1 , spaced2 "
    make_stub gh 'printf ""'
    local result
    result=$(get_trusted_logins)
    printf '%s' "${result}" | jq -e 'index("spaced1") != null' > /dev/null
    printf '%s' "${result}" | jq -e 'index("spaced2") != null' > /dev/null
}

@test "get_trusted_logins fails closed (does not fall back to a shrunken list) when GitHub API always fails (#1094)" {
    set_repo_context "myorg/myrepo"
    WHITELISTED_USERS=""
    GH_COLLABORATORS_RETRY_DELAY_SECS=0
    make_stub gh 'exit 1'
    run get_trusted_logins
    [ "${status}" -ne 0 ]
    [ -z "${_TRUSTED_LOGINS_JSON}" ]
}

@test "get_trusted_logins retries GH_COLLABORATORS_RETRY_ATTEMPTS times before giving up (#1094)" {
    set_repo_context "myorg/myrepo"
    WHITELISTED_USERS=""
    GH_COLLABORATORS_RETRY_ATTEMPTS=3
    GH_COLLABORATORS_RETRY_DELAY_SECS=0
    local call_log="${TEST_TMP}/gh_calls"
    make_stub gh "printf 'called\n' >> '${call_log}'; exit 1"
    run get_trusted_logins
    [ "${status}" -ne 0 ]
    [ "$(wc -l < "${call_log}")" -eq 3 ]
}

@test "get_trusted_logins succeeds after a transient failure on an earlier attempt (#1094)" {
    set_repo_context "myorg/myrepo"
    WHITELISTED_USERS=""
    GH_COLLABORATORS_RETRY_DELAY_SECS=0
    local call_log="${TEST_TMP}/gh_calls"
    make_stub gh "printf 'called\n' >> '${call_log}'; if [ \$(wc -l < '${call_log}') -lt 2 ]; then exit 1; fi; printf 'collab1\n'"
    local result
    result=$(get_trusted_logins)
    printf '%s' "${result}" | jq -e 'index("collab1") != null' > /dev/null
}

@test "get_trusted_logins passes --paginate to the collaborators API call (#1094)" {
    set_repo_context "myorg/myrepo"
    WHITELISTED_USERS=""
    export ARGS_LOG="${TEST_TMP}/gh_args"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "${ARGS_LOG}"; exit 0'
    get_trusted_logins > /dev/null
    grep -q -- '--paginate' "${ARGS_LOG}"
}

@test "get_trusted_logins does not cache a failed fetch, so the next call retries (#1094)" {
    set_repo_context "myorg/myrepo"
    WHITELISTED_USERS=""
    GH_COLLABORATORS_RETRY_DELAY_SECS=0
    local call_log="${TEST_TMP}/gh_calls"
    make_stub gh "printf 'called\n' >> '${call_log}'; exit 1"
    run get_trusted_logins
    [ "${status}" -ne 0 ]
    local first_calls
    first_calls=$(wc -l < "${call_log}")
    run get_trusted_logins
    [ "${status}" -ne 0 ]
    [ "$(wc -l < "${call_log}")" -gt "${first_calls}" ]
}

@test "get_trusted_logins deduplicates logins when OWNER appears as a collaborator" {
    set_repo_context "myorg/myrepo"
    WHITELISTED_USERS=""
    make_stub gh 'printf "myorg\ncollab1\n"'
    local result
    result=$(get_trusted_logins)
    local count
    count=$(printf '%s' "${result}" | jq '[.[] | select(. == "myorg")] | length')
    [ "${count}" = "1" ]
}

@test "get_trusted_logins caches result so GitHub API is called only once per repo context" {
    set_repo_context "myorg/myrepo"
    WHITELISTED_USERS=""
    local call_log="${TEST_TMP}/gh_calls"
    make_stub gh "printf 'called\n' >> '${call_log}'; printf 'collab1\n'"

    _TRUSTED_LOGINS_JSON=""
    get_trusted_logins > /dev/null
    local first_calls
    first_calls=$(wc -l < "${call_log}" 2>/dev/null || printf '0')

    get_trusted_logins > /dev/null
    local second_calls
    second_calls=$(wc -l < "${call_log}" 2>/dev/null || printf '0')

    [ "${first_calls}" = "${second_calls}" ]
}

@test "compute_issue_fingerprint passes trusted logins from get_trusted_logins to fingerprint_issue_json" {
    local captured_trusted="none"
    fetch_issue_json() { printf '{"title":"T","body":"B","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    get_trusted_logins() { printf '["testowner"]\n'; }
    fingerprint_issue_json() { captured_trusted="${2:-missing}"; printf 'test-fp\n'; }
    compute_issue_fingerprint 42
    [ "${captured_trusted}" = '["testowner"]' ]
}

@test "compute_pr_fingerprint passes trusted logins from get_trusted_logins to fingerprint_pr_json" {
    local captured_trusted="none"
    fetch_pr_json() { printf '{"title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}\n'; }
    get_trusted_logins() { printf '["testowner"]\n'; }
    fetch_pr_review_comments() { printf '[]\n'; }
    fingerprint_pr_json() { captured_trusted="${2:-missing}"; printf 'test-fp\n'; }
    compute_pr_fingerprint 5
    [ "${captured_trusted}" = '["testowner"]' ]
}

@test "compute_pr_fingerprint passes inline review comments from fetch_pr_review_comments to fingerprint_pr_json (#1127)" {
    local captured_review_comments="none"
    fetch_pr_json() { printf '{"title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}\n'; }
    get_trusted_logins() { printf '["testowner"]\n'; }
    fetch_pr_review_comments() { printf '[{"user":{"login":"testowner"},"body":"Why this change?","updated_at":"2024-01-01T00:00:00Z"}]\n'; }
    fingerprint_pr_json() { captured_review_comments="${3:-missing}"; printf 'test-fp\n'; }
    compute_pr_fingerprint 5
    printf '%s' "${captured_review_comments}" | jq -e '.[0].body == "Why this change?"' > /dev/null
}

@test "compute_pr_fingerprint returns non-zero without calling fingerprint_pr_json when fetch_pr_review_comments fails (#1127)" {
    fetch_pr_json() { printf '{"title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}\n'; }
    get_trusted_logins() { printf '["testowner"]\n'; }
    fetch_pr_review_comments() { return 1; }
    fingerprint_pr_json() { printf 'called\n' >> "${TEST_TMP}/fp_called"; printf 'test-fp\n'; }
    run compute_pr_fingerprint 5
    [ "${status}" -ne 0 ]
    [ ! -f "${TEST_TMP}/fp_called" ]
}

@test "compute_issue_fingerprint passes the item's board plan-approval status to fingerprint_issue_json (#1204)" {
    local captured_plan_approved="none"
    _WF_PROJECT_ID="PVT_test"
    REPO_FULL="owner/repo"
    fetch_issue_json() { printf '{"title":"T","body":"B","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    get_trusted_logins() { printf '["testowner"]\n'; }
    fetch_board_approved_items() { _WF_APPROVED_ITEMS["owner/repo/42"]=1; }
    fingerprint_issue_json() { captured_plan_approved="${3:-missing}"; printf 'test-fp\n'; }
    compute_issue_fingerprint 42
    [ "${captured_plan_approved}" = "true" ]
}

@test "compute_issue_fingerprint passes plan_approved=false when the item is not in _WF_APPROVED_ITEMS (#1204)" {
    local captured_plan_approved="none"
    _WF_PROJECT_ID="PVT_test"
    REPO_FULL="owner/repo"
    fetch_issue_json() { printf '{"title":"T","body":"B","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    get_trusted_logins() { printf '["testowner"]\n'; }
    fetch_board_approved_items() { return 0; }
    fingerprint_issue_json() { captured_plan_approved="${3:-missing}"; printf 'test-fp\n'; }
    compute_issue_fingerprint 42
    [ "${captured_plan_approved}" = "false" ]
}

@test "compute_issue_fingerprint returns non-zero without calling fingerprint_issue_json when get_trusted_logins fails (#1094)" {
    fetch_issue_json() { printf '{"title":"T","body":"B","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    get_trusted_logins() { return 1; }
    fingerprint_issue_json() { printf 'called\n' >> "${TEST_TMP}/fp_called"; printf 'test-fp\n'; }
    run compute_issue_fingerprint 42
    [ "${status}" -ne 0 ]
    [ ! -f "${TEST_TMP}/fp_called" ]
}

@test "compute_pr_fingerprint returns non-zero without calling fingerprint_pr_json when get_trusted_logins fails (#1094)" {
    fetch_pr_json() { printf '{"title":"T","body":"","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}\n'; }
    get_trusted_logins() { return 1; }
    fingerprint_pr_json() { printf 'called\n' >> "${TEST_TMP}/fp_called"; printf 'test-fp\n'; }
    run compute_pr_fingerprint 5
    [ "${status}" -ne 0 ]
    [ ! -f "${TEST_TMP}/fp_called" ]
}

# --- fetch_all_priorities -----------------------------------------------------

@test "fetch_all_priorities returns all open and draft non-on-hold items in API order" {
    _GH_ME="testuser"
    make_stub curl 'printf '"'"'{"priorities":[
        {"id":3,"itemType":"Issue","repository":"org/repo","status":"Open","isOnHold":false,"priority":3},
        {"id":1,"itemType":"Issue","repository":"org/repo","status":"Open","isOnHold":false,"priority":1},
        {"id":2,"itemType":"PullRequest","repository":"org/repo","status":"Draft","isOnHold":false,"priority":2},
        {"id":4,"itemType":"Issue","repository":"org/repo","status":"Closed","isOnHold":false,"priority":4},
        {"id":5,"itemType":"Issue","repository":"org/repo","status":"Open","isOnHold":true,"priority":0}
    ]}\n'"'"

    run fetch_all_priorities
    [ "${status}" -eq 0 ]
    # The 3 open/draft non-on-hold items appear in API order; Closed and on-hold are excluded
    local ids
    ids=$(printf '%s' "${output}" | jq -r '.[].id')
    [ "${ids}" = "$(printf '3\n1\n2')" ]
}

@test "fetch_all_priorities includes Draft items" {
    _GH_ME="testuser"
    make_stub curl 'printf '"'"'{"priorities":[
        {"id":1,"itemType":"PullRequest","repository":"org/repo","status":"Draft","isOnHold":false,"priority":1},
        {"id":2,"itemType":"PullRequest","repository":"org/repo","status":"Open","isOnHold":false,"priority":2}
    ]}\n'"'"

    run fetch_all_priorities
    [ "${status}" -eq 0 ]
    local ids
    ids=$(printf '%s' "${output}" | jq -r '.[].id')
    [ "${ids}" = "$(printf '1\n2')" ]
}

@test "fetch_all_priorities returns empty array when no open items exist" {
    _GH_ME="testuser"
    make_stub curl 'printf '"'"'{"priorities":[]}\n'"'"
    run fetch_all_priorities
    [ "${status}" -eq 0 ]
    [ "${output}" = "[]" ]
}

@test "fetch_all_priorities includes items from multiple repositories" {
    _GH_ME="testuser"
    make_stub curl 'printf '"'"'{"priorities":[
        {"id":10,"itemType":"Issue","repository":"org/repoA","status":"Open","isOnHold":false,"priority":1},
        {"id":20,"itemType":"Issue","repository":"org/repoB","status":"Open","isOnHold":false,"priority":2}
    ]}\n'"'"

    run fetch_all_priorities
    [ "${status}" -eq 0 ]
    local repos
    repos=$(printf '%s' "${output}" | jq -r '.[].repository')
    [[ "${repos}" == *"org/repoA"* ]]
    [[ "${repos}" == *"org/repoB"* ]]
}

@test "fetch_all_priorities retries and succeeds after a transient curl failure (#1089)" {
    _GH_ME="testuser"
    PRIORITIES_FETCH_RETRY_ATTEMPTS=3
    PRIORITIES_FETCH_RETRY_DELAY_SECS=0
    # shellcheck disable=SC2016  # $n/$(...) are intentionally literal — evaluated inside the stub at run time
    make_stub curl 'n=$(cat "'"${TEST_TMP}"'/curlcount" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "'"${TEST_TMP}"'/curlcount"; [ "$n" -lt 2 ] && exit 1; printf "{\"priorities\":[]}\n"'

    run fetch_all_priorities
    [ "${status}" -eq 0 ]
    [ "${output}" = "[]" ]
}

@test "fetch_all_priorities returns 1 without dying after exhausting retries on a persistent curl failure (#1089)" {
    _GH_ME="testuser"
    PRIORITIES_FETCH_RETRY_ATTEMPTS=2
    PRIORITIES_FETCH_RETRY_DELAY_SECS=0
    make_stub curl 'exit 1'

    run fetch_all_priorities
    [ "${status}" -eq 1 ]
}

@test "fetch_all_priorities returns 2 (not 1) without dying when the response is not valid JSON (#1089, #1171)" {
    _GH_ME="testuser"
    PRIORITIES_FETCH_RETRY_ATTEMPTS=1
    PRIORITIES_FETCH_RETRY_DELAY_SECS=0
    make_stub curl 'printf "not json"'

    run fetch_all_priorities
    [ "${status}" -eq 2 ]
}

@test "fetch_all_priorities sends the resolved GitHub login as the user query parameter (#1570)" {
    unset _GH_ME
    make_stub gh 'printf "octocat\n"'
    make_stub curl 'printf "%s\n" "$*" >> "'"${TEST_TMP}"'/curl_args"; printf "{\"priorities\":[]}\n"'

    run fetch_all_priorities
    [ "${status}" -eq 0 ]
    [ "${output}" = "[]" ]
    grep -qF -- "${PRIORITIES_URL}?user=octocat" "${TEST_TMP}/curl_args"
}

@test "fetch_all_priorities URL-encodes special characters in the user query parameter (#1570)" {
    _GH_ME='a b&c/d+e?f'
    make_stub curl 'printf "%s\n" "$*" >> "'"${TEST_TMP}"'/curl_args"; printf "{\"priorities\":[]}\n"'

    run fetch_all_priorities
    [ "${status}" -eq 0 ]
    grep -qF -- "${PRIORITIES_URL}?user=a%20b%26c%2Fd%2Be%3Ff" "${TEST_TMP}/curl_args"
}

@test "fetch_all_priorities fetches without the user query parameter when the login cannot be resolved (#1570)" {
    unset _GH_ME
    GH_USER_RETRY_ATTEMPTS=1
    GH_USER_RETRY_DELAY_SECS=0
    make_stub gh 'exit 1'
    make_stub curl 'printf "%s\n" "$*" >> "'"${TEST_TMP}"'/curl_args"; printf "{\"priorities\":[]}\n"'

    run fetch_all_priorities
    [ "${status}" -eq 0 ]
    [ "${output##*$'\n'}" = "[]" ]
    [[ "$(cat "${TEST_TMP}/curl_args")" == *" ${PRIORITIES_URL}" ]]
    [[ "$(cat "${TEST_TMP}/curl_args")" != *"user="* ]]
}

@test "fetch_all_priorities still returns 1 with the user query parameter set on a persistent curl failure (#1570)" {
    _GH_ME="testuser"
    PRIORITIES_FETCH_RETRY_ATTEMPTS=2
    PRIORITIES_FETCH_RETRY_DELAY_SECS=0
    make_stub curl 'exit 1'

    run fetch_all_priorities
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Failed to fetch priorities from ${PRIORITIES_URL}?user=testuser after 2 attempt(s)"* ]]
}

@test "fetch_all_priorities still returns 2 with the user query parameter set when the response is not valid JSON (#1570)" {
    _GH_ME="testuser"
    PRIORITIES_FETCH_RETRY_ATTEMPTS=1
    PRIORITIES_FETCH_RETRY_DELAY_SECS=0
    make_stub curl 'printf "not json"'

    run fetch_all_priorities
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"Failed to parse priorities JSON from ${PRIORITIES_URL}?user=testuser"* ]]
}

@test "fetch_all_priorities still returns 1 without the user query parameter when the login cannot be resolved (#1570)" {
    unset _GH_ME
    GH_USER_RETRY_ATTEMPTS=1
    GH_USER_RETRY_DELAY_SECS=0
    PRIORITIES_FETCH_RETRY_ATTEMPTS=1
    PRIORITIES_FETCH_RETRY_DELAY_SECS=0
    make_stub gh 'exit 1'
    make_stub curl 'exit 1'

    run fetch_all_priorities
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Failed to fetch priorities from ${PRIORITIES_URL} after 1 attempt(s)"* ]]
}

# --- find_open_nonblocked_pr_for_repo -----------------------------------------

@test "find_open_nonblocked_pr_for_repo returns first non-blocked PR with a bot-authored commit (#1131)" {
    _GH_ME="testuser"
    printf '%s' '[{"number":42,"labels":[],"author":{"login":"testuser"}},{"number":99,"labels":[{"name":"enhancement"}],"author":{"login":"testuser"}}]' > "${TEST_TMP}/prlist.json"
    printf '%s' '{"commits":[{"authors":[{"login":"testuser"}]}]}' > "${TEST_TMP}/pr42.json"
    make_stub gh 'case "$*" in *"pr list"*) cat "'"${TEST_TMP}"'/prlist.json" ;; *"pr view 42"*"--json commits"*) cat "'"${TEST_TMP}"'/pr42.json" ;; *) exit 1 ;; esac'
    run find_open_nonblocked_pr_for_repo "org/repo"
    [ "${status}" -eq 0 ]
    [ "${output}" = "42" ]
}

@test "find_open_nonblocked_pr_for_repo skips PRs with the Blocked label" {
    _GH_ME="testuser"
    printf '%s' '[{"number":7,"labels":[{"name":"Blocked"}],"author":{"login":"testuser"}},{"number":8,"labels":[],"author":{"login":"testuser"}}]' > "${TEST_TMP}/prlist.json"
    printf '%s' '{"commits":[{"authors":[{"login":"testuser"}]}]}' > "${TEST_TMP}/pr8.json"
    make_stub gh 'case "$*" in *"pr list"*) cat "'"${TEST_TMP}"'/prlist.json" ;; *"pr view 8"*"--json commits"*) cat "'"${TEST_TMP}"'/pr8.json" ;; *) exit 1 ;; esac'
    run find_open_nonblocked_pr_for_repo "org/repo"
    [ "${status}" -eq 0 ]
    [ "${output}" = "8" ]
}

@test "find_open_nonblocked_pr_for_repo returns a Blocked PR when include_blocked is true (#1463)" {
    _GH_ME="testuser"
    printf '%s' '[{"number":7,"labels":[{"name":"Blocked"}],"author":{"login":"testuser"}},{"number":8,"labels":[],"author":{"login":"testuser"}}]' > "${TEST_TMP}/prlist.json"
    printf '%s' '{"commits":[{"authors":[{"login":"testuser"}]}]}' > "${TEST_TMP}/pr7.json"
    make_stub gh 'case "$*" in *"pr list"*) cat "'"${TEST_TMP}"'/prlist.json" ;; *"pr view 7"*"--json commits"*) cat "'"${TEST_TMP}"'/pr7.json" ;; *) exit 1 ;; esac'
    run find_open_nonblocked_pr_for_repo "org/repo" true
    [ "${status}" -eq 0 ]
    [ "${output}" = "7" ]
}

@test "find_open_nonblocked_pr_for_repo skips a candidate with no bot-authored commits and returns the next (#1131)" {
    _GH_ME="testuser"
    printf '%s' '[{"number":42,"labels":[],"author":{"login":"testuser"}},{"number":50,"labels":[],"author":{"login":"testuser"}}]' > "${TEST_TMP}/prlist.json"
    printf '%s' '{"commits":[{"authors":[{"login":"humanuser"}]}]}' > "${TEST_TMP}/pr42.json"
    printf '%s' '{"commits":[{"authors":[{"login":"testuser"}]}]}' > "${TEST_TMP}/pr50.json"
    make_stub gh 'case "$*" in *"pr list"*) cat "'"${TEST_TMP}"'/prlist.json" ;; *"pr view 42"*"--json commits"*) cat "'"${TEST_TMP}"'/pr42.json" ;; *"pr view 50"*"--json commits"*) cat "'"${TEST_TMP}"'/pr50.json" ;; *) exit 1 ;; esac'
    run --separate-stderr find_open_nonblocked_pr_for_repo "org/repo"
    [ "${status}" -eq 0 ]
    [ "${output}" = "50" ]
    # shellcheck disable=SC2154  # stderr is set by run --separate-stderr
    [[ "${stderr}" == *"treating as human-driven"* ]]
}

@test "find_open_nonblocked_pr_for_repo returns empty when the only candidate has no bot-authored commits (#1131)" {
    _GH_ME="testuser"
    printf '%s' '[{"number":42,"labels":[],"author":{"login":"testuser"}}]' > "${TEST_TMP}/prlist.json"
    printf '%s' '{"commits":[{"authors":[{"login":"humanuser"}]}]}' > "${TEST_TMP}/pr42.json"
    make_stub gh 'case "$*" in *"pr list"*) cat "'"${TEST_TMP}"'/prlist.json" ;; *"pr view 42"*"--json commits"*) cat "'"${TEST_TMP}"'/pr42.json" ;; *) exit 1 ;; esac'
    run --separate-stderr find_open_nonblocked_pr_for_repo "org/repo"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    # shellcheck disable=SC2154  # stderr is set by run --separate-stderr
    [[ "${stderr}" == *"treating as human-driven"* ]]
}

@test "find_open_nonblocked_pr_for_repo returns 1 when the commits fetch fails (#1131)" {
    _GH_ME="testuser"
    GH_ITEM_FETCH_RETRY_ATTEMPTS=1
    GH_ITEM_FETCH_RETRY_DELAY_SECS=0
    printf '%s' '[{"number":42,"labels":[],"author":{"login":"testuser"}}]' > "${TEST_TMP}/prlist.json"
    make_stub gh 'case "$*" in *"pr list"*) cat "'"${TEST_TMP}"'/prlist.json" ;; *) exit 1 ;; esac'
    run find_open_nonblocked_pr_for_repo "org/repo"
    [ "${status}" -ne 0 ]
}

@test "find_open_nonblocked_pr_for_repo scans past a broken candidate to a healthy bot PR (#1134)" {
    _GH_ME="testuser"
    GH_ITEM_FETCH_RETRY_ATTEMPTS=1
    GH_ITEM_FETCH_RETRY_DELAY_SECS=0
    printf '%s' '[{"number":7,"labels":[],"author":{"login":"testuser"}},{"number":9,"labels":[],"author":{"login":"testuser"}}]' > "${TEST_TMP}/prlist.json"
    printf '%s' '{"commits":[{"authors":[{"login":"testuser"}]}]}' > "${TEST_TMP}/pr9.json"
    # PR 7's commits fetch always fails; PR 9 is healthy and bot-driven.
    make_stub gh 'case "$*" in *"pr list"*) cat "'"${TEST_TMP}"'/prlist.json" ;; *"pr view 9"*"--json commits"*) cat "'"${TEST_TMP}"'/pr9.json" ;; *) exit 1 ;; esac'
    run find_open_nonblocked_pr_for_repo "org/repo"
    [ "${status}" -eq 0 ]
    # stderr carries the "continuing scan" warning for PR 7; the selected PR is the last line.
    [[ "${output}" == *"continuing scan"* ]]
    [ "${lines[-1]}" = "9" ]
}

@test "find_open_nonblocked_pr_for_repo returns empty when all PRs are blocked" {
    _GH_ME="testuser"
    make_stub gh 'printf '"'"'[{"number":7,"labels":[{"name":"blocked"}],"author":{"login":"testuser"}}]\n'"'"
    run find_open_nonblocked_pr_for_repo "org/repo"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "find_open_nonblocked_pr_for_repo returns empty when no PRs exist" {
    _GH_ME="testuser"
    make_stub gh 'printf '"'"'[]\n'"'"
    run find_open_nonblocked_pr_for_repo "org/repo"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "find_open_nonblocked_pr_for_repo returns empty when all open PRs are by other authors" {
    _GH_ME="testuser"
    make_stub gh 'printf '"'"'[{"number":7,"labels":[],"author":{"login":"dependabot"}},{"number":8,"labels":[],"author":{"login":"github-actions"}}]\n'"'"
    run find_open_nonblocked_pr_for_repo "org/repo"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "find_open_nonblocked_pr_for_repo returns 1 when gh fails" {
    _GH_ME="testuser"
    make_stub gh 'exit 1'
    run find_open_nonblocked_pr_for_repo "org/repo"
    [ "${status}" -ne 0 ]
}

# --- json_has_commit_author_identity (#1294) --------------------------------------

@test "json_has_commit_author_identity matches on resolved login" {
    run json_has_commit_author_identity "testuser" <<< '{"commits":[{"authors":[{"login":"testuser"}]}]}'
    [ "${status}" -eq 0 ]
}

@test "json_has_commit_author_identity fails when neither login nor email is given/matches" {
    run json_has_commit_author_identity "testuser" <<< '{"commits":[{"authors":[{"login":"humanuser"}]}]}'
    [ "${status}" -ne 0 ]
}

@test "json_has_commit_author_identity matches on email when login is null (#1294)" {
    run json_has_commit_author_identity "testuser" "bot@example.com" \
        <<< '{"commits":[{"authors":[{"login":null,"email":"bot@example.com"}]}]}'
    [ "${status}" -eq 0 ]
}

@test "json_has_commit_author_identity ignores email match when the email argument is empty (#1294)" {
    run json_has_commit_author_identity "testuser" "" \
        <<< '{"commits":[{"authors":[{"login":null,"email":"bot@example.com"}]}]}'
    [ "${status}" -ne 0 ]
}

@test "json_has_commit_author_identity ignores email match when the email argument is omitted (#1294)" {
    run json_has_commit_author_identity "testuser" <<< '{"commits":[{"authors":[{"login":null,"email":"bot@example.com"}]}]}'
    [ "${status}" -ne 0 ]
}

@test "json_has_commit_author_identity ignores an email match when login is resolved to someone else (spoofing guard, #1294 review)" {
    # Security regression guard: a resolved (verified) login that is NOT the bot must win over a
    # spoofable raw email that happens to equal GIT_USER_EMAIL — otherwise anyone with push access
    # could claim bot authorship just by setting their commit-author email to a value copied from
    # the bot's own commit history, defeating the human-takeover check (#1131/#1134).
    run json_has_commit_author_identity "testuser" "bot@example.com" \
        <<< '{"commits":[{"authors":[{"login":"humanuser","email":"bot@example.com"}]}]}'
    [ "${status}" -ne 0 ]
}

@test "json_has_commit_author_identity email match is case-insensitive (#1294 review)" {
    run json_has_commit_author_identity "testuser" "Bot@Example.com" \
        <<< '{"commits":[{"authors":[{"login":null,"email":"bot@example.com"}]}]}'
    [ "${status}" -eq 0 ]
}

@test "json_has_commit_author_identity ignores a co-author email spoof when the same commit's primary author already resolved to a human (spoofing guard round 2, #1294 review)" {
    # A resolved GitHub identity anywhere on a commit (author or co-author) must gate the email
    # fallback for that WHOLE commit, not just the individual author entry it appears on —
    # otherwise a human could take over with their own resolved commit and add a free-text
    # "Co-authored-by: <name> <bot's email>" trailer to flip the commit back to "bot-authored"
    # even though GitHub has already unambiguously attributed the commit to them.
    run json_has_commit_author_identity "testuser" "bot@example.com" \
        <<< '{"commits":[{"authors":[{"login":"humanuser","email":"human@example.com"},{"login":null,"email":"bot@example.com"}]}]}'
    [ "${status}" -ne 0 ]
}

@test "json_has_commit_author_identity still matches email when every author entry on the commit is unresolved (#1294 review)" {
    # Companion to the above: a commit where NEITHER author nor co-author has a resolved login
    # yet must still get the lag-fix benefit of the doubt via email — the per-commit gate must
    # not become so strict it stops matching the original #1294 scenario.
    run json_has_commit_author_identity "testuser" "bot@example.com" \
        <<< '{"commits":[{"authors":[{"login":null,"email":"someone-else@example.com"},{"login":null,"email":"bot@example.com"}]}]}'
    [ "${status}" -eq 0 ]
}

@test "json_has_commit_author_identity does not match a different email (#1294)" {
    run json_has_commit_author_identity "testuser" "bot@example.com" \
        <<< '{"commits":[{"authors":[{"login":null,"email":"someone-else@example.com"}]}]}'
    [ "${status}" -ne 0 ]
}

# --- pr_has_bot_authored_commit (#1131) ----------------------------------------

@test "pr_has_bot_authored_commit returns 0 when the bot authored a commit" {
    _GH_ME="testuser"
    make_stub gh 'printf '"'"'{"commits":[{"authors":[{"login":"humanuser"}]},{"authors":[{"login":"testuser"}]}]}\n'"'"
    run pr_has_bot_authored_commit "org/repo" 5
    [ "${status}" -eq 0 ]
}

@test "pr_has_bot_authored_commit returns 0 when the bot co-authored a commit" {
    _GH_ME="testuser"
    make_stub gh 'printf '"'"'{"commits":[{"authors":[{"login":"humanuser"},{"login":"testuser"}]}]}\n'"'"
    run pr_has_bot_authored_commit "org/repo" 5
    [ "${status}" -eq 0 ]
}

@test "pr_has_bot_authored_commit returns 1 when only humans authored commits" {
    _GH_ME="testuser"
    make_stub gh 'printf '"'"'{"commits":[{"authors":[{"login":"humanuser"}]}]}\n'"'"
    run pr_has_bot_authored_commit "org/repo" 5
    [ "${status}" -eq 1 ]
}

@test "pr_has_bot_authored_commit ignores commits whose author has no mapped login" {
    _GH_ME="testuser"
    make_stub gh 'printf '"'"'{"commits":[{"authors":[{"login":null}]},{"authors":[]}]}\n'"'"
    run pr_has_bot_authored_commit "org/repo" 5
    [ "${status}" -eq 1 ]
}

@test "pr_has_bot_authored_commit falls back to matching GIT_USER_EMAIL when login is unresolved (#1294)" {
    # Simulates GitHub's commit-author login resolution lagging right after a push: the login is
    # still null, but the raw commit-author email (present immediately, not GitHub-derived) is
    # the bot's own — this must still classify as bot-authored.
    _GH_ME="testuser"
    GIT_USER_EMAIL="bot@example.com"
    make_stub gh 'printf '"'"'{"commits":[{"authors":[{"login":null,"email":"bot@example.com"}]}]}\n'"'"
    run pr_has_bot_authored_commit "org/repo" 5
    [ "${status}" -eq 0 ]
}

@test "pr_has_bot_authored_commit does not match on email when GIT_USER_EMAIL is unset" {
    # Regression guard for the pre-#1294 behaviour: no email means no email-based match, so this
    # falls back to login-only, matching every other pr_has_bot_authored_commit test in this file.
    _GH_ME="testuser"
    GIT_USER_EMAIL=""
    make_stub gh 'printf '"'"'{"commits":[{"authors":[{"login":null,"email":"bot@example.com"}]}]}\n'"'"
    run pr_has_bot_authored_commit "org/repo" 5
    [ "${status}" -eq 1 ]
}

@test "pr_has_bot_authored_commit still returns 1 when neither login nor GIT_USER_EMAIL match (#1294)" {
    _GH_ME="testuser"
    GIT_USER_EMAIL="bot@example.com"
    make_stub gh 'printf '"'"'{"commits":[{"authors":[{"login":"humanuser","email":"human@example.com"}]}]}\n'"'"
    run pr_has_bot_authored_commit "org/repo" 5
    [ "${status}" -eq 1 ]
}

@test "pr_has_bot_authored_commit returns 1 for a resolved human commit even with a spoofed matching email (#1294 review)" {
    # Security regression guard: find_human_taken_over_pr_for_issue relies on this returning 1
    # (not bot-authored) to detect a genuine takeover. A resolved, non-bot login must win over an
    # unauthenticated commit-author email that happens to equal GIT_USER_EMAIL - otherwise a
    # takeover is invisible to the stand-off logic and oneshot opens a duplicate branch/PR
    # alongside the human's already-in-progress work.
    _GH_ME="testuser"
    GIT_USER_EMAIL="bot@example.com"
    make_stub gh 'printf '"'"'{"commits":[{"authors":[{"login":"humanuser","email":"bot@example.com"}]}]}\n'"'"
    run pr_has_bot_authored_commit "org/repo" 5
    [ "${status}" -eq 1 ]
}

@test "pr_has_bot_authored_commit returns 2 when gh fails after retries" {
    _GH_ME="testuser"
    GH_ITEM_FETCH_RETRY_ATTEMPTS=2
    GH_ITEM_FETCH_RETRY_DELAY_SECS=0
    make_stub gh 'exit 1'
    run pr_has_bot_authored_commit "org/repo" 5
    [ "${status}" -eq 2 ]
}

@test "pr_has_bot_authored_commit returns 2, without reading the commits, when the identity cannot be resolved (#1517)" {
    # With no identity every commit would look human-authored, so this is a failure to classify.
    _GH_ME=""
    GH_USER_RETRY_ATTEMPTS=1
    GH_USER_RETRY_DELAY_SECS=0
    # shellcheck disable=SC2016  # $* expands inside the stub at run time
    make_stub gh 'printf "%s\n" "$*" >> "'"${TEST_TMP}"'/gh_args"; exit 1'
    run pr_has_bot_authored_commit "org/repo" 5
    [ "${status}" -eq 2 ]
    [ "$(grep -c -- "pr view" "${TEST_TMP}/gh_args")" -eq 0 ]
}

# --- find_human_taken_over_pr_for_issue (#1131) --------------------------------

# Stubs gh for the takeover lookup: `gh pr list` answers $1 (every open PR with its author, closing
# references and branch name, in one call) and `gh pr view 42 --json commits` answers $2. The
# repo's trusted logins are cached as the owner and one collaborator.
stub_open_prs_and_commits() {
    _GH_ME="testuser"
    _TRUSTED_LOGINS_JSON='["credfeto","humanuser"]'
    printf '%s' "$1" > "${TEST_TMP}/prlist.json"
    printf '%s' "$2" > "${TEST_TMP}/pr42commits.json"
    make_stub gh 'case "$*" in *"pr list"*) cat "'"${TEST_TMP}"'/prlist.json" ;; *"pr view 42"*"--json commits"*) cat "'"${TEST_TMP}"'/pr42commits.json" ;; *) exit 1 ;; esac'
}

@test "find_human_taken_over_pr_for_issue returns the bot's PR that closes the issue when a human took it over" {
    stub_open_prs_and_commits '[{"number":42,"author":{"login":"testuser"},"closingIssuesReferences":[{"number":164}],"headRefName":"feature/164-x"}]' '{"commits":[{"authors":[{"login":"humanuser"}]}]}'
    run find_human_taken_over_pr_for_issue 164
    [ "${status}" -eq 0 ]
    [ "${output}" = "42" ]
}

@test "find_human_taken_over_pr_for_issue returns a PR opened by the PR create bot that a human took over (#1517)" {
    stub_open_prs_and_commits '[{"number":42,"author":{"login":"prpixie"},"closingIssuesReferences":[{"number":164}],"headRefName":"feature/164-x"}]' '{"commits":[{"authors":[{"login":"credfeto"}]}]}'
    run find_human_taken_over_pr_for_issue 164
    [ "${status}" -eq 0 ]
    [ "${output}" = "42" ]
}

@test "find_human_taken_over_pr_for_issue returns a PR that a trusted person opened for the issue (#1517)" {
    stub_open_prs_and_commits '[{"number":42,"author":{"login":"credfeto"},"closingIssuesReferences":[{"number":164}],"headRefName":"feature/164-x"}]' '{"commits":[{"authors":[{"login":"credfeto"}]}]}'
    run find_human_taken_over_pr_for_issue 164
    [ "${status}" -eq 0 ]
    [ "${output}" = "42" ]
}

@test "find_human_taken_over_pr_for_issue ignores a stranger's PR that says it closes the issue (#1517)" {
    # Anyone who can open a PR could otherwise park the issue for good by writing "Closes #164".
    stub_open_prs_and_commits '[{"number":42,"author":{"login":"stranger"},"closingIssuesReferences":[{"number":164}],"headRefName":"feature/164-x"}]' '{"commits":[{"authors":[{"login":"stranger"}]}]}'
    run find_human_taken_over_pr_for_issue 164
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
}

@test "find_human_taken_over_pr_for_issue ignores a stranger's PR whose branch name carries the issue number (#1517)" {
    # The branch name of a fork PR is the forker's choice, so it must not park an issue either.
    stub_open_prs_and_commits '[{"number":42,"author":{"login":"stranger"},"closingIssuesReferences":[],"headRefName":"x/164-foo"}]' '{"commits":[{"authors":[{"login":"stranger"}]}]}'
    run find_human_taken_over_pr_for_issue 164
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
}

@test "find_human_taken_over_pr_for_issue asks for every open PR in one call (#1517)" {
    _GH_ME="testuser"
    _TRUSTED_LOGINS_JSON='["credfeto"]'
    # shellcheck disable=SC2016  # $* expands inside the stub at run time
    make_stub gh 'printf "%s\n" "$*" > "'"${TEST_TMP}"'/gh_args"; printf "[]"'
    run find_human_taken_over_pr_for_issue 164
    [ "${status}" -eq 1 ]
    grep -q -- "--state open" "${TEST_TMP}/gh_args"
    grep -q -- "--limit 200" "${TEST_TMP}/gh_args"
    grep -q -- "--json number,author,closingIssuesReferences,headRefName" "${TEST_TMP}/gh_args"
    [ "$(grep -c -- "--author" "${TEST_TMP}/gh_args")" -eq 0 ]
}

@test "find_human_taken_over_pr_for_issue scans past PRs for other issues to the one that owns this issue (#1517)" {
    stub_open_prs_and_commits '[{"number":7,"author":{"login":"credfeto"},"closingIssuesReferences":[{"number":5}],"headRefName":"feature/5-y"},{"number":42,"author":{"login":"credfeto"},"closingIssuesReferences":[{"number":164}],"headRefName":"feature/164-x"}]' '{"commits":[{"authors":[{"login":"humanuser"}]}]}'
    run find_human_taken_over_pr_for_issue 164
    [ "${status}" -eq 0 ]
    [ "${output}" = "42" ]
}

@test "find_human_taken_over_pr_for_issue returns 1 for a PR unrelated to the issue (#1517)" {
    stub_open_prs_and_commits '[{"number":42,"author":{"login":"credfeto"},"closingIssuesReferences":[],"headRefName":"fix/other-thing"}]' '{"commits":[{"authors":[{"login":"humanuser"}]}]}'
    run find_human_taken_over_pr_for_issue 164
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
}

@test "find_human_taken_over_pr_for_issue returns 1 for a PR that has the AI agent's commits" {
    stub_open_prs_and_commits '[{"number":42,"author":{"login":"prpixie"},"closingIssuesReferences":[{"number":164}],"headRefName":"feature/164-x"}]' '{"commits":[{"authors":[{"login":"testuser"}]}]}'
    run find_human_taken_over_pr_for_issue 164
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
}

@test "find_human_taken_over_pr_for_issue returns 1 when the PR closes a different issue" {
    stub_open_prs_and_commits '[{"number":42,"author":{"login":"credfeto"},"closingIssuesReferences":[{"number":164}],"headRefName":"feature/164-x"}]' '{"commits":[{"authors":[{"login":"humanuser"}]}]}'
    run find_human_taken_over_pr_for_issue 99
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
}

@test "find_human_taken_over_pr_for_issue still sees a Blocked taken-over PR (#1134)" {
    # Tagging a taken-over PR adds Blocked; the stand-off must not go blind because of it,
    # or a reopened issue would get duplicate work.
    stub_open_prs_and_commits '[{"number":42,"author":{"login":"testuser"},"labels":[{"name":"Blocked"}],"closingIssuesReferences":[{"number":164}],"headRefName":"feature/164-x"}]' '{"commits":[{"authors":[{"login":"humanuser"}]}]}'
    run find_human_taken_over_pr_for_issue 164
    [ "${status}" -eq 0 ]
    [ "${output}" = "42" ]
}

@test "find_human_taken_over_pr_for_issue returns 2 when the PR list fetch fails" {
    _GH_ME="testuser"
    _TRUSTED_LOGINS_JSON='["credfeto"]'
    make_stub gh 'exit 1'
    run find_human_taken_over_pr_for_issue 164
    [ "${status}" -eq 2 ]
}

@test "find_human_taken_over_pr_for_issue returns 2 when the identity cannot be resolved (#1517)" {
    _GH_ME=""
    GH_USER_RETRY_ATTEMPTS=1
    GH_USER_RETRY_DELAY_SECS=0
    _TRUSTED_LOGINS_JSON='["credfeto"]'
    make_stub gh 'exit 1'
    run find_human_taken_over_pr_for_issue 164
    [ "${status}" -eq 2 ]
}

@test "find_human_taken_over_pr_for_issue returns 2 when the trusted logins cannot be fetched (#1517)" {
    _GH_ME="testuser"
    _TRUSTED_LOGINS_JSON=""
    GH_COLLABORATORS_RETRY_ATTEMPTS=1
    GH_COLLABORATORS_RETRY_DELAY_SECS=0
    set_repo_context "org/repo"
    make_stub gh 'exit 1'
    run find_human_taken_over_pr_for_issue 164
    [ "${status}" -eq 2 ]
}

@test "find_human_taken_over_pr_for_issue returns 2 when the commits of the PR that owns the issue cannot be read (#1134)" {
    _GH_ME="testuser"
    _TRUSTED_LOGINS_JSON='["credfeto"]'
    GH_ITEM_FETCH_RETRY_ATTEMPTS=1
    GH_ITEM_FETCH_RETRY_DELAY_SECS=0
    printf '%s' '[{"number":42,"author":{"login":"credfeto"},"closingIssuesReferences":[{"number":164}],"headRefName":"feature/164-x"}]' > "${TEST_TMP}/prlist.json"
    make_stub gh 'case "$*" in *"pr list"*) cat "'"${TEST_TMP}"'/prlist.json" ;; *) exit 1 ;; esac'
    run find_human_taken_over_pr_for_issue 164
    [ "${status}" -eq 2 ]
}

@test "find_human_taken_over_pr_for_issue falls back to the branch-name convention when the closing reference is gone (#1134)" {
    stub_open_prs_and_commits '[{"number":42,"author":{"login":"testuser"},"closingIssuesReferences":[],"headRefName":"feature/164-buildtest-skip-benchmarks"}]' '{"commits":[{"authors":[{"login":"humanuser"}]}]}'
    run find_human_taken_over_pr_for_issue 164
    [ "${status}" -eq 0 ]
    [ "${output}" = "42" ]
}

@test "find_human_taken_over_pr_for_issue does not match a branch whose issue number merely starts with the target (#1134)" {
    stub_open_prs_and_commits '[{"number":42,"author":{"login":"testuser"},"closingIssuesReferences":[],"headRefName":"feature/1640-other-work"}]' '{"commits":[{"authors":[{"login":"humanuser"}]}]}'
    run find_human_taken_over_pr_for_issue 164
    [ "${status}" -eq 1 ]
}

@test "find_human_taken_over_pr_for_issue lets explicit closing references beat a stale branch name (#1134)" {
    # PR was retargeted to issue 264 (body edited) but still lives on branch fix/164-foo:
    # querying 164 must NOT match - the explicit reference wins over the branch convention.
    stub_open_prs_and_commits '[{"number":42,"author":{"login":"testuser"},"closingIssuesReferences":[{"number":264}],"headRefName":"fix/164-foo"}]' '{"commits":[{"authors":[{"login":"humanuser"}]}]}'
    run find_human_taken_over_pr_for_issue 164
    [ "${status}" -eq 1 ]
}

@test "list_bot_created_open_prs raises the gh pr list page size above the default 30 (#1134)" {
    _GH_ME="testuser"
    # shellcheck disable=SC2016  # $* expands inside the stub at run time
    make_stub gh 'printf "%s\n" "$*" > "'"${TEST_TMP}"'/gh_args"; printf "[]"'
    run list_bot_created_open_prs "org/repo" false
    [ "${status}" -eq 0 ]
    grep -q -- "--limit 200" "${TEST_TMP}/gh_args"
}

@test "list_bot_created_open_prs returns PRs authored by the AI agent or the PR create bot, and none by anyone else (#1517)" {
    _GH_ME="testuser"
    printf '%s' '[{"number":1,"labels":[],"author":{"login":"testuser"}},{"number":2,"labels":[],"author":{"login":"prpixie"}},{"number":3,"labels":[],"author":{"login":"credfeto"}},{"number":4,"labels":[],"author":{"login":"app/dependabot"}}]' > "${TEST_TMP}/prlist.json"
    make_stub gh 'cat "'"${TEST_TMP}"'/prlist.json"'
    run list_bot_created_open_prs "org/repo" false
    [ "${status}" -eq 0 ]
    [ "${output}" = $'1\n2' ]
}

@test "list_bot_created_open_prs still leaves out a Blocked PR by the PR create bot unless asked (#1517)" {
    _GH_ME="testuser"
    printf '%s' '[{"number":2,"labels":[{"name":"Blocked"}],"author":{"login":"prpixie"}}]' > "${TEST_TMP}/prlist.json"
    make_stub gh 'cat "'"${TEST_TMP}"'/prlist.json"'
    run list_bot_created_open_prs "org/repo" false
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    run list_bot_created_open_prs "org/repo" true
    [ "${output}" = "2" ]
}

@test "PR_CREATOR_LOGIN defaults to prpixie, can be overridden, and falls back to the default when invalid (#1517)" {
    [ "${PR_CREATOR_LOGIN}" = "prpixie" ]
    run bash -c 'PR_CREATOR_LOGIN=some-bot; BASEDIR=/x; source "$1"; printf "%s" "${PR_CREATOR_LOGIN}"' _ "${REPO_ROOT}/lib/globals"
    [ "${output}" = "some-bot" ]
    run bash -c 'PR_CREATOR_LOGIN="not a login"; BASEDIR=/x; source "$1"; printf "%s" "${PR_CREATOR_LOGIN}"' _ "${REPO_ROOT}/lib/globals"
    [ "${output}" = "prpixie" ]
    # The forms gh reports an author in are accepted: an app slug, an Enterprise Managed User login.
    run bash -c 'PR_CREATOR_LOGIN=app/some-bot; BASEDIR=/x; source "$1"; printf "%s" "${PR_CREATOR_LOGIN}"' _ "${REPO_ROOT}/lib/globals"
    [ "${output}" = "app/some-bot" ]
    run bash -c 'PR_CREATOR_LOGIN=Some_Bot; BASEDIR=/x; source "$1"; printf "%s" "${PR_CREATOR_LOGIN}"' _ "${REPO_ROOT}/lib/globals"
    [ "${output}" = "Some_Bot" ]
}

@test "list_bot_created_open_prs compares the author without regard to case, as GitHub logins are case-insensitive (#1517)" {
    _GH_ME="TestUser"
    printf '%s' '[{"number":1,"labels":[],"author":{"login":"testuser"}},{"number":2,"labels":[],"author":{"login":"PRPixie"}},{"number":3,"labels":[],"author":{"login":"someone"}}]' > "${TEST_TMP}/prlist.json"
    make_stub gh 'cat "'"${TEST_TMP}"'/prlist.json"'
    run list_bot_created_open_prs "org/repo" false
    [ "${output}" = $'1\n2' ]
}

@test "pr_is_human_driven compares the PR author without regard to case (#1517)" {
    _GH_ME="testuser"
    run pr_is_human_driven '{"labels":[],"author":{"login":"PrPixie"},"commits":[{"authors":[{"login":"credfeto"}]}]}' '["credfeto"]'
    [ "${status}" -eq 0 ]
}

@test "list_bot_created_open_prs follows an overridden PR_CREATOR_LOGIN (#1517)" {
    _GH_ME="testuser"
    PR_CREATOR_LOGIN="other-bot"
    printf '%s' '[{"number":2,"labels":[],"author":{"login":"prpixie"}},{"number":3,"labels":[],"author":{"login":"other-bot"}}]' > "${TEST_TMP}/prlist.json"
    make_stub gh 'cat "'"${TEST_TMP}"'/prlist.json"'
    run list_bot_created_open_prs "org/repo" false
    [ "${output}" = "3" ]
}

# --- tag_pr_closed_issue result contract (#1134) --------------------------------

@test "tag_pr_closed_issue returns 0 when at least one gh action lands" {
    make_stub gh 'case "$*" in *"pr comment"*) exit 0 ;; *) exit 1 ;; esac'
    run tag_pr_closed_issue 42 164
    [ "${status}" -eq 0 ]
}

@test "tag_pr_closed_issue returns 1 when every gh action fails" {
    make_stub gh 'exit 1'
    run tag_pr_closed_issue 42 164
    [ "${status}" -eq 1 ]
}

@test "tag_pr_closed_issue still tags a PR that is already Blocked for an unrelated reason (#1103 review)" {
    # tag_pr_closed_issue itself must not special-case an existing Blocked label — the PR may be
    # blocked for a totally unrelated reason (CI timeout, a human block) and still need the
    # closed-issue investigation comment posted for the first time. Deduplication against
    # repeated calls belongs to the caller (a marker file), not this function.
    local gh_log="${TEST_TMP}/gh.log"
    cat > "${STUB_BIN}/gh" << STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${gh_log}"
case "\$*" in
    *"pr view"*) printf '{"labels":[{"name":"Blocked"}]}' ;;
    *"pr comment"*) exit 0 ;;
    *) exit 1 ;;
esac
STUBEOF
    chmod +x "${STUB_BIN}/gh"
    run tag_pr_closed_issue 42 164
    [ "${status}" -eq 0 ]
    grep -q "pr comment" "${gh_log}"
}

# --- resolve_resumable_issue_branch (#1262) -------------------------------------

@test "resolve_resumable_issue_branch returns 1 when find_stale_issue_branch finds no candidate" {
    REPO_FULL="org/repo"
    find_stale_issue_branch() { return 1; }
    run resolve_resumable_issue_branch 42
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
}

@test "resolve_resumable_issue_branch returns the branch when no PR covers it" {
    REPO_FULL="org/repo"
    find_stale_issue_branch() { printf 'chore/42-fix\n'; return 0; }
    make_stub gh 'case "$*" in
        "pr list --repo org/repo --head chore/42-fix --state open --json number --jq length") printf "0\n" ;;
        *) exit 1 ;;
    esac'
    run resolve_resumable_issue_branch 42
    [ "${status}" -eq 0 ]
    [ "${output}" = "chore/42-fix" ]
}

@test "resolve_resumable_issue_branch returns 1 when a PR already covers the candidate branch (#1262)" {
    REPO_FULL="org/repo"
    find_stale_issue_branch() { printf 'chore/42-fix\n'; return 0; }
    make_stub gh 'case "$*" in
        "pr list --repo org/repo --head chore/42-fix --state open --json number --jq length") printf "1\n" ;;
        *) exit 1 ;;
    esac'
    run resolve_resumable_issue_branch 42
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
}

@test "resolve_resumable_issue_branch returns 1 (fails safe) when the gh pr list check itself fails" {
    REPO_FULL="org/repo"
    find_stale_issue_branch() { printf 'chore/42-fix\n'; return 0; }
    make_stub gh 'exit 1'
    run resolve_resumable_issue_branch 42
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
}

# --- pr_is_human_driven (#1131) -------------------------------------------------
# Operates on the caller's pr_json (author/commits included by fetch_pr_json, #1134) — no gh
# fetch of its own; the stubs below exist only to prove no call happens or to fail resolve_gh_me.

@test "pr_is_human_driven exempts a dependencies-labelled dependency PR even after a trusted human pushed to it" {
    _GH_ME="testuser"
    # No gh call should be needed — everything comes from the passed pr_json.
    make_stub gh 'exit 1'
    run pr_is_human_driven '{"labels":[{"name":"Dependencies"}],"author":{"login":"app/dependabot"},"commits":[{"authors":[{"login":"credfeto"}]}]}' '["credfeto"]'
    [ "${status}" -eq 1 ]
}

@test "pr_is_human_driven exempts customised dependency label variants like 'npm dependencies' (#1134)" {
    _GH_ME="testuser"
    run pr_is_human_driven '{"labels":[{"name":"npm dependencies"}],"author":{"login":"app/dependabot"},"commits":[{"authors":[{"login":"app/dependabot"}]}]}' '["credfeto"]'
    [ "${status}" -eq 1 ]
}

@test "pr_is_human_driven stands off a taken-over bot PR regardless of a dependencies-ish label (#1134)" {
    _GH_ME="testuser"
    # Issue-label sync can put any label on a bot-created PR — a takeover must win over the
    # label exemption (the author check runs first).
    run pr_is_human_driven '{"labels":[{"name":"update-dependencies-major"}],"author":{"login":"testuser"},"commits":[{"authors":[{"login":"credfeto"}]}]}' '["credfeto"]'
    [ "${status}" -eq 0 ]
}

# --- resolve_gh_me (#1085) ----------------------------------------------------

@test "resolve_gh_me sets _GH_ME and returns 0 when gh api user succeeds (#1085)" {
    _GH_ME=""
    GH_USER_RETRY_DELAY_SECS=0
    make_stub gh 'printf "testuser\n"'
    run resolve_gh_me
    [ "${status}" -eq 0 ]
    resolve_gh_me
    [ "${_GH_ME}" = "testuser" ]
}

@test "resolve_gh_me short-circuits and returns 0 when _GH_ME is already cached (#1085)" {
    _GH_ME="cacheduser"
    GH_USER_RETRY_DELAY_SECS=0
    make_stub gh 'exit 1'
    run resolve_gh_me
    [ "${status}" -eq 0 ]
}

@test "resolve_gh_me retries and succeeds after a transient failure (#1085)" {
    _GH_ME=""
    GH_USER_RETRY_ATTEMPTS=3
    GH_USER_RETRY_DELAY_SECS=0
    # shellcheck disable=SC2016  # $n/$(...) are intentionally literal — evaluated inside the stub at run time
    make_stub gh 'n=$(cat "'"${TEST_TMP}"'/ghuser" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "'"${TEST_TMP}"'/ghuser"; [ "$n" -lt 2 ] && exit 1; printf "testuser\n"'
    resolve_gh_me
    [ "${_GH_ME}" = "testuser" ]
}

@test "resolve_gh_me returns 1 without dying after exhausting retries (#1085)" {
    _GH_ME=""
    GH_USER_RETRY_ATTEMPTS=2
    GH_USER_RETRY_DELAY_SECS=0
    make_stub gh 'exit 1'
    run resolve_gh_me
    [ "${status}" -ne 0 ]
    [ -z "${_GH_ME}" ]
}

@test "find_open_nonblocked_pr_for_repo returns 1 (not fatal) when identity lookup fails (#1085)" {
    _GH_ME=""
    GH_USER_RETRY_ATTEMPTS=1
    GH_USER_RETRY_DELAY_SECS=0
    make_stub gh 'exit 1'
    run find_open_nonblocked_pr_for_repo "org/repo"
    [ "${status}" -ne 0 ]
}

# --- fetch_pr_json / fetch_issue_json retry (#1090) ---------------------------

@test "fetch_pr_json retries and succeeds after a transient gh failure (#1090)" {
    GH_ITEM_FETCH_RETRY_ATTEMPTS=3
    GH_ITEM_FETCH_RETRY_DELAY_SECS=0
    # shellcheck disable=SC2016  # $n/$(...) are intentionally literal — evaluated inside the stub at run time
    make_stub gh 'n=$(cat "'"${TEST_TMP}"'/ghcount" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "'"${TEST_TMP}"'/ghcount"; [ "$n" -lt 2 ] && exit 1; printf "{}\n"'
    run fetch_pr_json 5
    [ "${status}" -eq 0 ]
    [ "${output}" = "{}" ]
}

@test "fetch_pr_json returns 1 without dying after exhausting retries (#1090)" {
    GH_ITEM_FETCH_RETRY_ATTEMPTS=2
    GH_ITEM_FETCH_RETRY_DELAY_SECS=0
    make_stub gh 'exit 1'
    run fetch_pr_json 5
    [ "${status}" -ne 0 ]
}

@test "fetch_issue_json retries and succeeds after a transient gh failure (#1090)" {
    GH_ITEM_FETCH_RETRY_ATTEMPTS=3
    GH_ITEM_FETCH_RETRY_DELAY_SECS=0
    # shellcheck disable=SC2016  # $n/$(...) are intentionally literal — evaluated inside the stub at run time
    make_stub gh 'n=$(cat "'"${TEST_TMP}"'/ghcount" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "'"${TEST_TMP}"'/ghcount"; [ "$n" -lt 2 ] && exit 1; printf "{}\n"'
    run fetch_issue_json 5
    [ "${status}" -eq 0 ]
    [ "${output}" = "{}" ]
}

@test "fetch_issue_json returns 1 without dying after exhausting retries (#1090)" {
    GH_ITEM_FETCH_RETRY_ATTEMPTS=2
    GH_ITEM_FETCH_RETRY_DELAY_SECS=0
    make_stub gh 'exit 1'
    run fetch_issue_json 5
    [ "${status}" -ne 0 ]
}

# --- the orchestrator's own comments are not trusted activity -----------------------------------

@test "pr_json_latest_trusted_comment_timestamp ignores the excluded login on every comment surface" {
    local pr='{"comments":[{"author":{"login":"credfeto"},"createdAt":"2026-10-01T10:00:00Z"},{"author":{"login":"bot"},"createdAt":"2026-10-01T11:00:00Z"}],"reviews":[{"author":{"login":"bot"},"submittedAt":"2026-10-01T12:00:00Z"}]}'
    local rc='[{"user":{"login":"bot"},"updated_at":"2026-10-01T13:00:00Z"}]'
    local ic='[{"user":{"login":"bot"},"updated_at":"2026-10-01T14:00:00Z"}]'
    run pr_json_latest_trusted_comment_timestamp "${pr}" '["credfeto","bot"]' "${rc}" "${ic}" "bot"
    [ "${status}" -eq 0 ]
    [ "${output}" = "2026-10-01T10:00:00Z" ]
}

@test "pr_json_latest_trusted_comment_timestamp counts every trusted login when no login is excluded" {
    local pr='{"comments":[{"author":{"login":"credfeto"},"createdAt":"2026-10-01T10:00:00Z"},{"author":{"login":"bot"},"createdAt":"2026-10-01T11:00:00Z"}],"reviews":[]}'
    run pr_json_latest_trusted_comment_timestamp "${pr}" '["credfeto","bot"]' '[]' '[]' ""
    [ "${status}" -eq 0 ]
    [ "${output}" = "2026-10-01T11:00:00Z" ]
}

@test "pr_json_has_unaddressed_trusted_comment ignores the orchestrator's own comment newer than the marker" {
    local pr='{"comments":[{"author":{"login":"credfeto"},"createdAt":"2026-10-01T10:00:00Z"}],"reviews":[]}'
    local ic='[{"user":{"login":"bot"},"updated_at":"2026-10-01T12:00:00Z"}]'
    run pr_json_has_unaddressed_trusted_comment "${pr}" '["credfeto","bot"]' "2026-10-01T10:00:00Z" '[]' "${ic}" "bot"
    [ "${status}" -eq 1 ]
    run pr_json_has_unaddressed_trusted_comment "${pr}" '["credfeto","bot"]' "2026-10-01T10:00:00Z" '[]' "${ic}" ""
    [ "${status}" -eq 0 ]
}

@test "set_pr_has_unaddressed_comment excludes _GH_ME" {
    pr_json='{"comments":[{"author":{"login":"bot"},"createdAt":"2026-10-01T12:00:00Z"}],"reviews":[]}'
    trusted_logins='["credfeto","bot"]'
    pr_review_comments='[]'
    pr_issue_comments='[]'
    save_pr_last_agent_comment_seen 42 "2026-10-01T10:00:00Z"
    _GH_ME="bot"
    set_pr_has_unaddressed_comment 42 || true
    [ "${pr_has_unaddressed_comment}" = "false" ]
    _GH_ME=""
    set_pr_has_unaddressed_comment 42
    [ "${pr_has_unaddressed_comment}" = "true" ]
}

@test "fetch_pr_latest_trusted_comment_timestamp ignores the orchestrator's own newer comment" {
    fetch_pr_json() { printf '{"comments":[{"author":{"login":"credfeto"},"createdAt":"2026-10-01T10:00:00Z"},{"author":{"login":"bot"},"createdAt":"2026-10-01T12:00:00Z"}],"reviews":[]}\n'; }
    get_trusted_logins() { printf '["credfeto","bot"]\n'; }
    fetch_pr_review_comments() { printf '[]\n'; }
    fetch_pr_issue_comments() { printf '[]\n'; }
    run fetch_pr_latest_trusted_comment_timestamp 42 "bot"
    [ "${status}" -eq 0 ]
    [ "${output}" = "2026-10-01T10:00:00Z" ]
}

@test "fetch_pr_latest_trusted_comment_timestamp uses the PR state it is given instead of fetching it" {
    fetch_pr_json() { return 1; }
    get_trusted_logins() { printf '["credfeto"]\n'; }
    fetch_pr_review_comments() { printf '[]\n'; }
    fetch_pr_issue_comments() { printf '[]\n'; }
    run fetch_pr_latest_trusted_comment_timestamp 42 "" '{"comments":[{"author":{"login":"credfeto"},"createdAt":"2026-10-01T10:00:00Z"}],"reviews":[]}'
    [ "${status}" -eq 0 ]
    [ "${output}" = "2026-10-01T10:00:00Z" ]
}

@test "_jq_pr_json_with_comment_arrays binds both comment arrays and passes the jq options through" {
    # shellcheck disable=SC2016  # jq variables, not shell expansions
    run _jq_pr_json_with_comment_arrays '{"n":1}' '[{"id":2}]' '[{"id":3},{"id":4}]' \
        '"\($tag):\(.n),\($reviewComments | length),\($issueComments | length)"' -r --arg tag "t"
    [ "${status}" -eq 0 ]
    [ "${output}" = "t:1,1,2" ]
    run _jq_pr_json_with_comment_arrays '{}' '[]' '[]' 'error("x")'
    [ "${status}" -eq 1 ]
}

# --- required checks come from GitHub's own isRequired, not an assumed field -----------------------

@test "fetch_pr_required_check_names returns the unique names GitHub marks required" {
    cat > "${TEST_TMP}/graphql.json" <<'JSON'
{"data":{"repository":{"pullRequest":{"commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"pageInfo":{"hasNextPage":false},"nodes":[{"__typename":"CheckRun","name":"build","isRequired":true},{"__typename":"CheckRun","name":"build","isRequired":true},{"__typename":"CheckRun","name":"badge","isRequired":false},{"__typename":"StatusContext","context":"legacy/ci","isRequired":true}]}}}}]}}}}}
JSON
    make_stub gh "cat '${TEST_TMP}/graphql.json'"
    run fetch_pr_required_check_names 42 "org/repo"
    [ "${status}" -eq 0 ]
    [ "${output}" = '["build","legacy/ci"]' ]
}

@test "fetch_pr_required_check_names returns an empty list when the head commit has no checks" {
    make_stub gh "printf '%s' '{\"data\":{\"repository\":{\"pullRequest\":{\"commits\":{\"nodes\":[{\"commit\":{\"statusCheckRollup\":null}}]}}}}}'"
    run fetch_pr_required_check_names 42 "org/repo"
    [ "${status}" -eq 0 ]
    [ "${output}" = '[]' ]
}

@test "fetch_pr_required_check_names fails when the contexts do not fit in one page" {
    make_stub gh "printf '%s' '{\"data\":{\"repository\":{\"pullRequest\":{\"commits\":{\"nodes\":[{\"commit\":{\"statusCheckRollup\":{\"contexts\":{\"pageInfo\":{\"hasNextPage\":true},\"nodes\":[]}}}}]}}}}}'"
    run fetch_pr_required_check_names 42 "org/repo"
    [ "${status}" -ne 0 ]
}

@test "fetch_pr_required_check_names fails on a gh failure or a response with no pull request" {
    make_stub gh 'exit 1'
    run fetch_pr_required_check_names 42 "org/repo"
    [ "${status}" -ne 0 ]
    make_stub gh "printf '{}'"
    run fetch_pr_required_check_names 42 "org/repo"
    [ "${status}" -ne 0 ]
}

@test "fetch_branch_requires_status_checks reads classic protection and rulesets for the encoded branch (#1557)" {
    # shellcheck disable=SC2016  # expanded by the stub, not here
    make_stub gh 'printf "%s\n" "$*" >> "'"${TEST_TMP}"'/gh_args"
case "$*" in
    *"/rules/branches/"*) cat "'"${TEST_TMP}"'/rules.json" ;;
    *"/branches/"*) cat "'"${TEST_TMP}"'/branch.json" ;;
    *) exit 1 ;;
esac'
    printf '%s' '{"name":"release/1.0","protection":{"enabled":true,"required_status_checks":{"enforcement_level":"non_admins","contexts":["build"],"checks":[{"context":"build","app_id":1}]}}}' > "${TEST_TMP}/branch.json"
    printf '%s' '[]' > "${TEST_TMP}/rules.json"
    run fetch_branch_requires_status_checks "release/1.0" "org/repo"
    [ "${status}" -eq 0 ]
    [ "${output}" = "true" ]
    grep -qF 'api repos/org/repo/branches/release%2F1.0' "${TEST_TMP}/gh_args"
    grep -qF 'api repos/org/repo/rules/branches/release%2F1.0?per_page=100' "${TEST_TMP}/gh_args"

    printf '%s' '{"name":"main","protected":false,"protection":{"enabled":false,"required_status_checks":{"enforcement_level":"off","contexts":[],"checks":[]}}}' > "${TEST_TMP}/branch.json"
    run fetch_branch_requires_status_checks "main" "org/repo"
    [ "${status}" -eq 0 ]
    [ "${output}" = "false" ]

    printf '%s' '[{"type":"pull_request"},{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"build"}]}}]' > "${TEST_TMP}/rules.json"
    run fetch_branch_requires_status_checks "main" "org/repo"
    [ "${status}" -eq 0 ]
    [ "${output}" = "true" ]
}

@test "fetch_branch_requires_status_checks fails on an empty base, a failed call or an unexpected response (#1557)" {
    run fetch_branch_requires_status_checks "" "org/repo"
    [ "${status}" -ne 0 ]
    make_stub gh 'case "$*" in *"/rules/branches/"*) exit 1 ;; *) printf "%s" "{\"name\":\"main\"}" ;; esac'
    run fetch_branch_requires_status_checks "main" "org/repo"
    [ "${status}" -ne 0 ]
    make_stub gh 'case "$*" in *"/rules/branches/"*) printf "[]" ;; *) exit 1 ;; esac'
    run fetch_branch_requires_status_checks "main" "org/repo"
    [ "${status}" -ne 0 ]
    make_stub gh 'case "$*" in *"/rules/branches/"*) printf "{}" ;; *) printf "%s" "{\"name\":\"main\"}" ;; esac'
    run fetch_branch_requires_status_checks "main" "org/repo"
    [ "${status}" -ne 0 ]
    make_stub gh 'case "$*" in *"/rules/branches/"*) printf "[]" ;; *) printf "{}" ;; esac'
    run fetch_branch_requires_status_checks "main" "org/repo"
    [ "${status}" -ne 0 ]
}

# --- re-arming a missing auto-merge (#1798) -------------------------------------------------------

ARM_SHA="1111111111111111111111111111111111111111"

@test "repo_allows_auto_merge reads allow_auto_merge once per repo, and returns 2 when it cannot be read (#1798)" {
    # shellcheck disable=SC2016  # expanded by the stub, not here
    make_stub gh 'printf "%s\n" "$*" >> "'"${TEST_TMP}"'/gh_args"; cat "'"${TEST_TMP}"'/allowed"'
    printf 'true' > "${TEST_TMP}/allowed"
    repo_allows_auto_merge "org/repo"
    repo_allows_auto_merge "org/repo"
    [ "$(grep -c 'api repos/org/repo --jq .allow_auto_merge // false' "${TEST_TMP}/gh_args")" -eq 1 ]
    printf 'false' > "${TEST_TMP}/allowed"
    run repo_allows_auto_merge "org/other"
    [ "${status}" -eq 1 ]
    printf 'surprise' > "${TEST_TMP}/allowed"
    run repo_allows_auto_merge "org/third"
    [ "${status}" -eq 2 ]
    make_stub gh 'exit 1'
    run repo_allows_auto_merge "org/fourth"
    [ "${status}" -eq 2 ]
}

@test "pr_should_arm_missing_auto_merge arms a finished PR on a repo that allows auto-merge when a review or a required check gates the merge (#1798)" {
    repo_allows_auto_merge() { return 0; }
    fetch_branch_requires_status_checks() { printf 'false'; }
    run pr_should_arm_missing_auto_merge '{"isDraft":false,"statusCheckRollup":[],"autoMergeRequest":null,"reviewDecision":"REVIEW_REQUIRED"}' "org/repo"
    [ "${status}" -eq 0 ]
    run pr_should_arm_missing_auto_merge '{"isDraft":false,"statusCheckRollup":[],"autoMergeRequest":null,"reviewDecision":"APPROVED"}' "org/repo"
    [ "${status}" -eq 0 ]
    fetch_branch_requires_status_checks() { [ "$1" = main ] && [ "$2" = org/repo ] && printf 'true'; }
    run pr_should_arm_missing_auto_merge '{"isDraft":false,"statusCheckRollup":[],"autoMergeRequest":null,"reviewDecision":null,"baseRefName":"main"}' "org/repo"
    [ "${status}" -eq 0 ]
}

@test "pr_should_arm_missing_auto_merge does not arm a PR already armed, not finished, on a repo without auto-merge, or whose base requires nothing (#1798)" {
    repo_allows_auto_merge() { return 0; }
    fetch_branch_requires_status_checks() { printf 'false'; }
    local ok='"isDraft":false,"statusCheckRollup":[],"reviewDecision":"REVIEW_REQUIRED"'
    run pr_should_arm_missing_auto_merge "{${ok},\"autoMergeRequest\":{\"enabledAt\":\"now\"}}" "org/repo"
    [ "${status}" -eq 1 ]
    run pr_should_arm_missing_auto_merge '{"isDraft":true,"statusCheckRollup":[],"autoMergeRequest":null,"reviewDecision":"REVIEW_REQUIRED"}' "org/repo"
    [ "${status}" -eq 1 ]
    run pr_should_arm_missing_auto_merge '{"isDraft":false,"statusCheckRollup":[],"autoMergeRequest":null,"reviewDecision":"CHANGES_REQUESTED"}' "org/repo"
    [ "${status}" -eq 1 ]
    run pr_should_arm_missing_auto_merge '{"isDraft":false,"statusCheckRollup":[{"__typename":"CheckRun","name":"build","isRequired":true,"status":"COMPLETED","conclusion":"FAILURE"}],"autoMergeRequest":null,"reviewDecision":"REVIEW_REQUIRED"}' "org/repo"
    [ "${status}" -eq 1 ]
    # No review policy, and a base that requires no check, or whose checks cannot be read.
    run pr_should_arm_missing_auto_merge '{"isDraft":false,"statusCheckRollup":[],"autoMergeRequest":null,"reviewDecision":null,"baseRefName":"main"}' "org/repo"
    [ "${status}" -eq 1 ]
    fetch_branch_requires_status_checks() { return 1; }
    run pr_should_arm_missing_auto_merge '{"isDraft":false,"statusCheckRollup":[],"autoMergeRequest":null,"reviewDecision":"","baseRefName":"main"}' "org/repo"
    [ "${status}" -eq 1 ]
    # A repo that disallows auto-merge, or whose setting cannot be read, keeps the #1479 fallback.
    repo_allows_auto_merge() { return 1; }
    run pr_should_arm_missing_auto_merge "{${ok},\"autoMergeRequest\":null}" "org/repo"
    [ "${status}" -eq 1 ]
    repo_allows_auto_merge() { return 2; }
    run pr_should_arm_missing_auto_merge "{${ok},\"autoMergeRequest\":null}" "org/repo"
    [ "${status}" -eq 1 ]
}

@test "arm_missing_auto_merge requests a merge-commit auto-merge pinned to the head, never --admin, and confirms it by re-reading the PR (#1798)" {
    # shellcheck disable=SC2016  # expanded by the stub, not here
    make_stub gh 'printf "%s\n" "$*" >> "'"${TEST_TMP}"'/gh_args"
case "$1 $2" in
    "pr merge") exit 0 ;;
    "pr view") cat "'"${TEST_TMP}"'/armed" ;;
    *) exit 1 ;;
esac'
    printf 'true' > "${TEST_TMP}/armed"
    run arm_missing_auto_merge 42 "org/repo" "{\"headRefOid\":\"${ARM_SHA}\"}"
    [ "${status}" -eq 0 ]
    grep -qxF "pr merge 42 --repo org/repo --auto --merge --match-head-commit ${ARM_SHA}" "${TEST_TMP}/gh_args"
    grep -qxF "pr view 42 --repo org/repo --json autoMergeRequest --jq .autoMergeRequest != null" "${TEST_TMP}/gh_args"
    [ "$(grep -c -- "--admin" "${TEST_TMP}/gh_args")" -eq 0 ]

    # The re-read does not show the request.
    printf 'false' > "${TEST_TMP}/armed"
    run arm_missing_auto_merge 42 "org/repo" "{\"headRefOid\":\"${ARM_SHA}\"}"
    [ "${status}" -eq 1 ]
}

@test "arm_missing_auto_merge fails without a merge request for a head that is not a commit SHA, and when the request fails (#1798)" {
    # shellcheck disable=SC2016  # expanded by the stub, not here
    make_stub gh 'printf "%s\n" "$*" >> "'"${TEST_TMP}"'/gh_args"; exit 1'
    run arm_missing_auto_merge 42 "org/repo" '{"headRefOid":"abc"}'
    [ "${status}" -eq 1 ]
    [ ! -f "${TEST_TMP}/gh_args" ]
    run arm_missing_auto_merge 42 "org/repo" "{\"headRefOid\":\"${ARM_SHA}\"}"
    [ "${status}" -eq 1 ]
    [ "$(grep -c "pr merge" "${TEST_TMP}/gh_args")" -eq 1 ]
    [ "$(grep -c "pr view" "${TEST_TMP}/gh_args")" -eq 0 ]
}

@test "annotate_pr_json_required_checks marks each check required or not by name or context" {
    local pr='{"statusCheckRollup":[{"name":"build","conclusion":"FAILURE","status":"COMPLETED"},{"name":"badge","conclusion":"FAILURE","status":"COMPLETED"},{"context":"legacy/ci","state":"SUCCESS"}]}'
    run annotate_pr_json_required_checks "${pr}" '["build","legacy/ci"]'
    [ "${status}" -eq 0 ]
    [ "$(printf '%s' "${output}" | jq -c '[.statusCheckRollup[].isRequired]')" = '[true,false,true]' ]
}

@test "annotate_pr_json_required_checks leaves pr_json untouched when required-ness is unknown" {
    local pr='{"statusCheckRollup":[{"name":"build","conclusion":"FAILURE","status":"COMPLETED"}]}'
    run annotate_pr_json_required_checks "${pr}" ""
    [ "${output}" = "${pr}" ]
}

@test "annotate_pr_json_required_checks marks every check required when the base branch requires none (#1557)" {
    local pr='{"statusCheckRollup":[{"name":"build","conclusion":"FAILURE","status":"COMPLETED"},{"context":"legacy/ci","state":"PENDING"}]}'
    run annotate_pr_json_required_checks "${pr}" "[]" false
    [ "${status}" -eq 0 ]
    [ "$(printf '%s' "${output}" | jq -c '[.statusCheckRollup[].isRequired]')" = '[true,true]' ]
    [ "$(printf '%s' "${output}" | jq -r '.requiredChecksNotYetReported // "unset"')" = "unset" ]
}

@test "annotate_pr_json_required_checks marks every present check optional when the base branch requires checks none of which has reported (#1557)" {
    local pr='{"statusCheckRollup":[{"name":"badge","conclusion":"FAILURE","status":"COMPLETED"},{"context":"bot/status","state":"FAILURE"}]}'
    run annotate_pr_json_required_checks "${pr}" "[]" true
    [ "${status}" -eq 0 ]
    [ "$(printf '%s' "${output}" | jq -c '[.statusCheckRollup[].isRequired]')" = '[false,false]' ]
    [ "$(printf '%s' "${output}" | jq -r '.requiredChecksNotYetReported')" = "true" ]
}

@test "annotate_pr_json_required_checks leaves pr_json untouched for an empty list when whether the base branch requires checks is unknown (#1557)" {
    local pr='{"statusCheckRollup":[{"name":"build","conclusion":"FAILURE","status":"COMPLETED"}]}'
    run annotate_pr_json_required_checks "${pr}" "[]" ""
    [ "${output}" = "${pr}" ]
    run annotate_pr_json_required_checks "${pr}" "[]"
    [ "${output}" = "${pr}" ]
}

@test "a failing optional check on a branch whose required checks have not reported is not failed-required and still waits for CI (#1557)" {
    local pr
    pr=$(annotate_pr_json_required_checks '{"isDraft":false,"autoMergeRequest":null,"reviewDecision":"REVIEW_REQUIRED","statusCheckRollup":[{"name":"badge","status":"COMPLETED","conclusion":"FAILURE"}]}' "[]" true)
    run pr_json_has_failed_required_check "${pr}"
    [ "${status}" -eq 1 ]
    run pr_json_has_failed_check_of_unknown_requiredness "${pr}"
    [ "${status}" -eq 1 ]
    run pr_json_has_pending_ci_checks "${pr}"
    [ "${status}" -eq 0 ]
    run pr_next_phase_for_board_status "Human Review" "${pr}"
    [ "${output}" = "PHASE H (finalize)" ]
}

@test "pr_json_has_pending_ci_checks is false for finished optional checks without the not-yet-reported marker" {
    run pr_json_has_pending_ci_checks '{"statusCheckRollup":[{"name":"badge","status":"COMPLETED","conclusion":"FAILURE","isRequired":false}]}'
    [ "${status}" -eq 1 ]
}

@test "a failing check on a repo with no required checks is failed-required, non-terminal and routed to PHASE C (#1557)" {
    local pr
    pr=$(annotate_pr_json_required_checks '{"isDraft":false,"autoMergeRequest":null,"reviewDecision":"REVIEW_REQUIRED","statusCheckRollup":[{"name":"build","status":"COMPLETED","conclusion":"FAILURE"}]}' "[]" false)
    run pr_json_has_failed_required_check "${pr}"
    [ "${status}" -eq 0 ]
    run pr_json_is_terminal "${pr}" true
    [ "${status}" -eq 1 ]
    run pr_next_phase_for_board_status "Human Review" "${pr}"
    [ "${output}" = "PHASE C (fix the failed required check)" ]
    run pr_next_phase_for_board_status "Complete" "${pr}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "PHASE C (fix the failed required check)" ]
}

@test "a failing check GitHub says is optional is not failed-required and does not block terminal (#1557)" {
    local pr
    pr=$(annotate_pr_json_required_checks '{"isDraft":false,"autoMergeRequest":null,"reviewDecision":"REVIEW_REQUIRED","statusCheckRollup":[{"name":"build","status":"COMPLETED","conclusion":"SUCCESS"},{"name":"badge","status":"COMPLETED","conclusion":"FAILURE"}]}' '["build"]')
    run pr_json_has_failed_required_check "${pr}"
    [ "${status}" -eq 1 ]
    run pr_json_has_failed_check_of_unknown_requiredness "${pr}"
    [ "${status}" -eq 1 ]
    run pr_json_is_terminal "${pr}" true
    [ "${status}" -eq 0 ]
    run pr_next_phase_for_board_status "Human Review" "${pr}" true
    [ "${output}" = "PHASE H (finalize)" ]
}

@test "pr_json_has_only_passed_checks is true only when every check has finished and passed" {
    pr_json_has_only_passed_checks '{"statusCheckRollup":[]}'
    pr_json_has_only_passed_checks '{}'
    pr_json_has_only_passed_checks '{"statusCheckRollup":[{"name":"a","status":"COMPLETED","conclusion":"SUCCESS"},{"name":"b","status":"COMPLETED","conclusion":"SKIPPED"},{"name":"c","status":"COMPLETED","conclusion":"NEUTRAL"},{"context":"d","state":"SUCCESS"}]}'
    run pr_json_has_only_passed_checks '{"statusCheckRollup":[{"name":"a","status":"COMPLETED","conclusion":"SUCCESS"},{"name":"b","status":"COMPLETED","conclusion":"FAILURE"}]}'
    [ "${status}" -eq 1 ]
    run pr_json_has_only_passed_checks '{"statusCheckRollup":[{"name":"a","status":"IN_PROGRESS","conclusion":""}]}'
    [ "${status}" -eq 1 ]
    run pr_json_has_only_passed_checks '{"statusCheckRollup":[{"context":"d","state":"PENDING"}]}'
    [ "${status}" -eq 1 ]
}

@test "set_pr_required_checks skips the lookup when every check passed, and annotates otherwise" {
    fetch_pr_required_check_names() { printf 'called\n' >> "${TEST_TMP}/lookups"; printf '["build"]'; }
    local pr_required_checks="stale"
    local pr_json='{"statusCheckRollup":[{"name":"build","status":"COMPLETED","conclusion":"SUCCESS"}]}'
    set_pr_required_checks 42
    [ -z "${pr_required_checks}" ]
    [ ! -f "${TEST_TMP}/lookups" ]
    pr_json='{"statusCheckRollup":[{"name":"build","status":"COMPLETED","conclusion":"FAILURE"}]}'
    set_pr_required_checks 42
    [ "${pr_required_checks}" = '["build"]' ]
    [ "$(printf '%s' "${pr_json}" | jq -r '.statusCheckRollup[0].isRequired')" = "true" ]
    fetch_pr_required_check_names() { printf '[]'; }
    fetch_branch_requires_status_checks() { printf '%s\n' "$1" >> "${TEST_TMP}/base_lookups"; printf 'false'; }
    pr_json='{"baseRefName":"main","statusCheckRollup":[{"name":"lint","status":"COMPLETED","conclusion":"FAILURE"}]}'
    set_pr_required_checks 42
    [ "${pr_required_checks}" = '[]' ]
    [ "${pr_base_requires_checks}" = "false" ]
    [ "${pr_required_checks_lookup_failed}" = "false" ]
    [ "$(printf '%s' "${pr_json}" | jq -r '.statusCheckRollup[0].isRequired')" = "true" ]
    [ "$(cat "${TEST_TMP}/base_lookups")" = "main" ]
}

@test "set_pr_required_checks asks the base branch only when nothing on the commit is required (#1557)" {
    fetch_branch_requires_status_checks() { printf 'called\n' >> "${TEST_TMP}/base_lookups"; printf 'true'; }
    local pr_required_checks="" pr_base_requires_checks="stale" pr_required_checks_lookup_failed=false
    local pr_json='{"baseRefName":"main","statusCheckRollup":[{"name":"badge","status":"COMPLETED","conclusion":"FAILURE"}]}'
    fetch_pr_required_check_names() { printf '["build"]'; }
    set_pr_required_checks 42
    [ -z "${pr_base_requires_checks}" ]
    [ ! -f "${TEST_TMP}/base_lookups" ]
    fetch_pr_required_check_names() { printf '[]'; }
    pr_json='{"baseRefName":"main","statusCheckRollup":[{"name":"badge","status":"COMPLETED","conclusion":"FAILURE"}]}'
    set_pr_required_checks 42
    [ "${pr_base_requires_checks}" = "true" ]
    [ "${pr_required_checks_lookup_failed}" = "false" ]
    [ "$(printf '%s' "${pr_json}" | jq -r '.statusCheckRollup[0].isRequired')" = "false" ]
    [ "$(printf '%s' "${pr_json}" | jq -r '.requiredChecksNotYetReported')" = "true" ]
}

@test "set_pr_required_checks warns and flags a failed base-branch lookup, leaving pr_json unannotated (#1557)" {
    fetch_pr_required_check_names() { printf '[]'; }
    fetch_branch_requires_status_checks() { return 1; }
    local pr_required_checks="stale" pr_base_requires_checks="stale" pr_required_checks_lookup_failed=false
    local pr_json='{"baseRefName":"main","statusCheckRollup":[{"name":"badge","status":"COMPLETED","conclusion":"FAILURE"}]}'
    set_pr_required_checks 42 2> "${TEST_TMP}/stderr"
    [ -z "${pr_required_checks}" ]
    [ -z "${pr_base_requires_checks}" ]
    [ "${pr_required_checks_lookup_failed}" = "true" ]
    grep -q 'Failed to look up whether the base branch of PR #42 requires any check' "${TEST_TMP}/stderr"
    [ "$(printf '%s' "${pr_json}" | jq -r '.statusCheckRollup[0].isRequired // "unset"')" = "unset" ]
    [ "$(printf '%s' "${pr_json}" | jq -r '.requiredChecksNotYetReported // "unset"')" = "unset" ]
}

@test "set_pr_required_checks warns and flags a failed lookup, leaving pr_json unannotated (#1557)" {
    fetch_pr_required_check_names() { return 1; }
    local pr_required_checks="stale" pr_required_checks_lookup_failed=false
    local pr_json='{"statusCheckRollup":[{"name":"build","status":"COMPLETED","conclusion":"FAILURE"}]}'
    set_pr_required_checks 42 2> "${TEST_TMP}/stderr"
    [ -z "${pr_required_checks}" ]
    [ "${pr_required_checks_lookup_failed}" = "true" ]
    grep -q 'Failed to look up the required checks for PR #42: a failed required check cannot be detected this tick' "${TEST_TMP}/stderr"
    [ "$(printf '%s' "${pr_json}" | jq -r '.statusCheckRollup[0].isRequired // "unset"')" = "unset" ]
    fetch_pr_required_check_names() { printf '["build"]'; }
    set_pr_required_checks 42 2> "${TEST_TMP}/stderr"
    [ "${pr_required_checks_lookup_failed}" = "false" ]
    [ ! -s "${TEST_TMP}/stderr" ]
}

@test "pr_json_has_failed_required_check is false for a failing check whose required-ness is unknown" {
    run pr_json_has_failed_required_check '{"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"FAILURE"}]}'
    [ "${status}" -eq 1 ]
    run pr_json_has_failed_required_check '{"statusCheckRollup":[{"name":"legacy","state":"ERROR"}]}'
    [ "${status}" -eq 1 ]
}

@test "pr_json_has_failed_required_check agrees with the annotated required set" {
    local pr='{"statusCheckRollup":[{"name":"lint","status":"COMPLETED","conclusion":"FAILURE"},{"name":"build","status":"COMPLETED","conclusion":"SUCCESS"}]}'
    run pr_json_has_failed_required_check "$(annotate_pr_json_required_checks "${pr}" '["build"]')"
    [ "${status}" -eq 1 ]
    run pr_json_has_failed_required_check "$(annotate_pr_json_required_checks "${pr}" '["lint"]')"
    [ "${status}" -eq 0 ]
}

@test "pr_json_has_failed_required_check ignores a failed run a later run of the same check superseded" {
    run pr_json_has_failed_required_check '{"statusCheckRollup":[{"name":"ci","workflowName":"CI","status":"COMPLETED","conclusion":"FAILURE","isRequired":true,"startedAt":"2026-10-01T10:00:00Z"},{"name":"ci","workflowName":"CI","status":"COMPLETED","conclusion":"SUCCESS","isRequired":true,"startedAt":"2026-10-01T11:00:00Z"}]}'
    [ "${status}" -eq 1 ]
    run pr_json_has_failed_required_check '{"statusCheckRollup":[{"name":"ci","workflowName":"CI","status":"COMPLETED","conclusion":"SUCCESS","isRequired":true,"startedAt":"2026-10-01T10:00:00Z"},{"name":"ci","workflowName":"CI","status":"COMPLETED","conclusion":"FAILURE","isRequired":true,"startedAt":"2026-10-01T11:00:00Z"}]}'
    [ "${status}" -eq 0 ]
}

@test "pr_json_has_failed_required_check keeps same-named checks from different workflows apart" {
    run pr_json_has_failed_required_check '{"statusCheckRollup":[{"name":"build","workflowName":"A","status":"COMPLETED","conclusion":"FAILURE","isRequired":true,"startedAt":"2026-10-01T10:00:00Z"},{"name":"build","workflowName":"B","status":"COMPLETED","conclusion":"SUCCESS","isRequired":true,"startedAt":"2026-10-01T11:00:00Z"}]}'
    [ "${status}" -eq 0 ]
}

@test "pr_json_is_terminal ignores a failed run a later run of the same check superseded" {
    run pr_json_is_terminal '{"autoMergeRequest":{"enabledAt":"now"},"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-10-01T10:00:00Z"},{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-10-01T11:00:00Z"}]}'
    [ "${status}" -eq 0 ]
}

@test "pr_json_is_terminal still treats a failing check of unknown required-ness as blocking" {
    run pr_json_is_terminal '{"autoMergeRequest":{"enabledAt":"now"},"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"FAILURE"}]}'
    [ "${status}" -eq 1 ]
}
