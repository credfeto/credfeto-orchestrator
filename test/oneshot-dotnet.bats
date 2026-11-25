#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are read by the sourced oneshot functions, where shellcheck cannot trace them
# shellcheck disable=SC2016  # stub bodies are expanded by the stub, not here
# shellcheck disable=SC2329  # functions in @test bodies are invoked indirectly via 'run'

# The strangler switches that hand an area of oneshot to Credfeto.Orchestrator.Cmd (#252): each is
# off by default, and when on the shell function delegates to ORCHESTRATOR_CMD with the same
# inputs, output and failure contract.

bats_require_minimum_version 1.5.0

load test_helper
load oneshot_helper

PR_JSON='{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}'
ISSUE_JSON='{"title":"T","body":"B","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}'

# A stand-in for the tool: records its arguments, its stdin and the content of every file it was
# given, then prints a fixed fingerprint (or fails, when ${TEST_TMP}/fail exists).
make_orchestrator_cmd_stub() {
    make_stub_multiline fake-orchestrator \
        'printf "%s\n" "$@" > "${TEST_TMP}/cmd_args"' \
        'cat > "${TEST_TMP}/cmd_stdin"' \
        'while [ "$#" -gt 0 ]; do' \
        '    case "$1" in' \
        '        --trusted-file) cat "$2" > "${TEST_TMP}/cmd_trusted"; printf "%s\n" "$2" >> "${TEST_TMP}/cmd_files" ;;' \
        '        --review-comments-file) cat "$2" > "${TEST_TMP}/cmd_review_comments"; printf "%s\n" "$2" >> "${TEST_TMP}/cmd_files" ;;' \
        '    esac' \
        '    shift' \
        'done' \
        '[ -f "${TEST_TMP}/fail" ] && exit 1' \
        'printf "9:from-the-tool"'
    export ORCHESTRATOR_CMD=fake-orchestrator
}

@test "ORCHESTRATOR_DOTNET_FINGERPRINTS defaults to off and ORCHESTRATOR_CMD to credfeto-orchestrator (#252)" {
    run env -u ORCHESTRATOR_DOTNET_FINGERPRINTS -u ORCHESTRATOR_CMD bash -c 'source "'"${REPO_ROOT}"'/oneshot"; printf "%s|%s" "${ORCHESTRATOR_DOTNET_FINGERPRINTS}" "${ORCHESTRATOR_CMD}"'
    [ "${status}" -eq 0 ]
    [ "${output}" = "0|credfeto-orchestrator" ]
}

@test "fingerprint_pr_json and fingerprint_issue_json never run ORCHESTRATOR_CMD while ORCHESTRATOR_DOTNET_FINGERPRINTS is off (#252)" {
    make_orchestrator_cmd_stub
    ORCHESTRATOR_DOTNET_FINGERPRINTS=0
    run fingerprint_pr_json "${PR_JSON}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == "${FINGERPRINT_SCHEMA_VERSION}:"* ]]
    run fingerprint_issue_json "${ISSUE_JSON}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${FINGERPRINT_SCHEMA_VERSION}:36d5acf9d9297f831145e17ec71ce45fcbd20d60b9af5b25ef6773cacbdc5116" ]
    [ ! -f "${TEST_TMP}/cmd_args" ]
}

@test "fingerprint_pr_json hands the PR JSON, trusted logins and inline review comments to ORCHESTRATOR_CMD when switched on (#252)" {
    make_orchestrator_cmd_stub
    ORCHESTRATOR_DOTNET_FINGERPRINTS=1
    run fingerprint_pr_json "${PR_JSON}" '["owner"]' '[{"user":{"login":"owner"},"updated_at":"t"}]'
    [ "${status}" -eq 0 ]
    [ "${output}" = "9:from-the-tool" ]
    [ "$(sed -n '1,4p' "${TEST_TMP}/cmd_args" | tr '\n' ' ')" = "fingerprint pr --schema-version ${FINGERPRINT_SCHEMA_VERSION} " ]
    grep -qx -- '--trusted-file' "${TEST_TMP}/cmd_args"
    grep -qx -- '--review-comments-file' "${TEST_TMP}/cmd_args"
    [ "$(cat "${TEST_TMP}/cmd_stdin")" = "${PR_JSON}" ]
    [ "$(cat "${TEST_TMP}/cmd_trusted")" = '["owner"]' ]
    [ "$(cat "${TEST_TMP}/cmd_review_comments")" = '[{"user":{"login":"owner"},"updated_at":"t"}]' ]
    local file
    while IFS= read -r file; do
        [ ! -e "${file}" ]
    done < "${TEST_TMP}/cmd_files"
}

@test "fingerprint_pr_json passes the jq path's defaults to ORCHESTRATOR_CMD when the optional arguments are omitted (#252)" {
    make_orchestrator_cmd_stub
    ORCHESTRATOR_DOTNET_FINGERPRINTS=1
    run fingerprint_pr_json "${PR_JSON}"
    [ "${status}" -eq 0 ]
    [ "$(cat "${TEST_TMP}/cmd_trusted")" = 'null' ]
    [ "$(cat "${TEST_TMP}/cmd_review_comments")" = '[]' ]
}

@test "fingerprint_issue_json hands the issue JSON, trusted logins and plan approval to ORCHESTRATOR_CMD when switched on (#252)" {
    make_orchestrator_cmd_stub
    ORCHESTRATOR_DOTNET_FINGERPRINTS=1
    run fingerprint_issue_json "${ISSUE_JSON}" '["owner"]' true
    [ "${status}" -eq 0 ]
    [ "${output}" = "9:from-the-tool" ]
    [ "$(tr '\n' ' ' < "${TEST_TMP}/cmd_args")" = "fingerprint issue --schema-version ${FINGERPRINT_SCHEMA_VERSION} --trusted-file $(cat "${TEST_TMP}/cmd_files") --plan-approved true " ]
    [ "$(cat "${TEST_TMP}/cmd_stdin")" = "${ISSUE_JSON}" ]
    [ "$(cat "${TEST_TMP}/cmd_trusted")" = '["owner"]' ]
    [ ! -e "$(cat "${TEST_TMP}/cmd_files")" ]

    run fingerprint_issue_json "${ISSUE_JSON}"
    [ "${status}" -eq 0 ]
    [ "$(cat "${TEST_TMP}/cmd_trusted")" = 'null' ]
    grep -qx -- 'false' "${TEST_TMP}/cmd_args"
}

@test "fingerprint_pr_json and fingerprint_issue_json fail when ORCHESTRATOR_CMD fails, prints nothing or is missing (#252)" {
    make_orchestrator_cmd_stub
    ORCHESTRATOR_DOTNET_FINGERPRINTS=1
    touch "${TEST_TMP}/fail"
    run fingerprint_pr_json "${PR_JSON}"
    [ "${status}" -ne 0 ]
    [ -z "${output}" ]
    run fingerprint_issue_json "${ISSUE_JSON}"
    [ "${status}" -ne 0 ]
    [ -z "${output}" ]

    make_stub silent-orchestrator 'cat > /dev/null'
    ORCHESTRATOR_CMD=silent-orchestrator
    run fingerprint_pr_json "${PR_JSON}"
    [ "${status}" -ne 0 ]

    ORCHESTRATOR_CMD=no-such-orchestrator-command
    run --separate-stderr fingerprint_issue_json "${ISSUE_JSON}"
    [ "${status}" -ne 0 ]
    [ -z "${output}" ]
}

# A stand-in for the tool's github reads: records its arguments and the cfwf MCP URL it was given,
# then prints ${TEST_TMP}/github_output (or fails, when ${TEST_TMP}/fail exists).
make_orchestrator_github_stub() {
    make_stub_multiline fake-orchestrator \
        'printf "%s\n" "$@" > "${TEST_TMP}/cmd_args"' \
        'printf "%s" "${ORCHESTRATOR_CFWF_MCP_URL}" > "${TEST_TMP}/cmd_url"' \
        '[ -f "${TEST_TMP}/fail" ] && exit 1' \
        'cat "${TEST_TMP}/github_output"'
    export ORCHESTRATOR_CMD=fake-orchestrator
}

@test "ORCHESTRATOR_DOTNET_GITHUB defaults to off and ORCHESTRATOR_CFWF_MCP_URL to the cfwf MCP server (#252)" {
    run env -u ORCHESTRATOR_DOTNET_GITHUB -u ORCHESTRATOR_CFWF_MCP_URL bash -c 'source "'"${REPO_ROOT}"'/oneshot"; printf "%s|%s" "${ORCHESTRATOR_DOTNET_GITHUB}" "${ORCHESTRATOR_CFWF_MCP_URL}"'
    [ "${status}" -eq 0 ]
    [ "${output}" = "0|https://workflow-mcp.markridgwell.com/mcp" ]
}

@test "the lib/github reads never run ORCHESTRATOR_CMD while ORCHESTRATOR_DOTNET_GITHUB is off (#252)" {
    make_orchestrator_github_stub
    ORCHESTRATOR_DOTNET_GITHUB=0
    make_stub gh 'case "$*" in
        "pr list --repo org/repo --head fix/7-typo --state open --json number --jq .[].number") printf "12\n" ;;
        "pr list --repo org/repo --head fix/7-typo --state open --json number --jq length") printf "1\n" ;;
        *"/rules/branches/"*) printf "[]" ;;
        *"/branches/"*) printf "%s" "{\"name\":\"main\"}" ;;
        *) exit 1 ;;
    esac'
    run fetch_open_pr_numbers_on_head org/repo fix/7-typo
    [ "${status}" -eq 0 ]
    [ "${output}" = "12" ]
    run fetch_open_pr_count_on_head org/repo fix/7-typo
    [ "${status}" -eq 0 ]
    [ "${output}" = "1" ]
    run fetch_branch_requires_status_checks main org/repo
    [ "${status}" -eq 0 ]
    [ "${output}" = "false" ]
    [ ! -f "${TEST_TMP}/cmd_args" ]
}

@test "the lib/github reads hand the repository and branch to ORCHESTRATOR_CMD github when switched on (#252)" {
    make_orchestrator_github_stub
    make_stub gh 'exit 1'
    ORCHESTRATOR_DOTNET_GITHUB=1
    ORCHESTRATOR_CFWF_MCP_URL=https://mcp.example.test/mcp

    printf '31\n12\n' > "${TEST_TMP}/github_output"
    run fetch_open_pr_numbers_on_head org/repo fix/7-typo
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '31\n12')" ]
    [ "$(tr '\n' ' ' < "${TEST_TMP}/cmd_args")" = "github open-prs --repo org/repo --head fix/7-typo " ]
    [ "$(cat "${TEST_TMP}/cmd_url")" = "https://mcp.example.test/mcp" ]

    printf '2\n' > "${TEST_TMP}/github_output"
    run fetch_open_pr_count_on_head org/repo fix/7-typo
    [ "${status}" -eq 0 ]
    [ "${output}" = "2" ]
    [ "$(tr '\n' ' ' < "${TEST_TMP}/cmd_args")" = "github open-pr-count --repo org/repo --head fix/7-typo " ]

    printf 'true\n' > "${TEST_TMP}/github_output"
    run fetch_branch_requires_status_checks release/1.0 org/repo
    [ "${status}" -eq 0 ]
    [ "${output}" = "true" ]
    [ "$(tr '\n' ' ' < "${TEST_TMP}/cmd_args")" = "github branch-requires-status-checks --repo org/repo --branch release/1.0 " ]

    REPO_FULL=org/other
    run fetch_branch_requires_status_checks main
    [ "$(tr '\n' ' ' < "${TEST_TMP}/cmd_args")" = "github branch-requires-status-checks --repo org/other --branch main " ]
}

@test "list_bot_created_open_prs hands the repository, logins and Blocked choice to ORCHESTRATOR_CMD github when switched on (#252)" {
    make_orchestrator_github_stub
    make_stub gh 'exit 1'
    ORCHESTRATOR_DOTNET_GITHUB=1
    _GH_ME=bot-user
    PR_CREATOR_LOGIN=app/prpixie

    printf '31\n5\n' > "${TEST_TMP}/github_output"
    run list_bot_created_open_prs org/repo
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '31\n5')" ]
    [ "$(tr '\n' ' ' < "${TEST_TMP}/cmd_args")" = "github own-open-prs --repo org/repo --me bot-user --creator app/prpixie --include-blocked false " ]

    run list_bot_created_open_prs org/repo true
    [ "$(tr '\n' ' ' < "${TEST_TMP}/cmd_args")" = "github own-open-prs --repo org/repo --me bot-user --creator app/prpixie --include-blocked true " ]

    touch "${TEST_TMP}/fail"
    run list_bot_created_open_prs org/repo
    [ "${status}" -ne 0 ]
    [ -z "${output}" ]
}

@test "list_bot_created_open_prs never runs ORCHESTRATOR_CMD while ORCHESTRATOR_DOTNET_GITHUB is off (#252)" {
    make_orchestrator_github_stub
    ORCHESTRATOR_DOTNET_GITHUB=0
    _GH_ME=bot-user
    PR_CREATOR_LOGIN=app/prpixie
    make_stub gh 'case "$*" in
        "pr list --repo org/repo --state open --limit 200 --json number,labels,author") printf "%s" "[{\"number\":4,\"author\":{\"login\":\"bot-user\"},\"labels\":[]}]" ;;
        *) exit 1 ;;
    esac'
    run list_bot_created_open_prs org/repo
    [ "${status}" -eq 0 ]
    [ "${output}" = "4" ]
    [ ! -f "${TEST_TMP}/cmd_args" ]
}

@test "fetch_branch_requires_status_checks still fails on an empty base without running ORCHESTRATOR_CMD (#252)" {
    make_orchestrator_github_stub
    ORCHESTRATOR_DOTNET_GITHUB=1
    run fetch_branch_requires_status_checks "" org/repo
    [ "${status}" -ne 0 ]
    [ ! -f "${TEST_TMP}/cmd_args" ]
}

@test "the lib/github reads and their callers fail safe when ORCHESTRATOR_CMD fails or is missing (#252)" {
    make_orchestrator_github_stub
    make_stub gh 'exit 1'
    ORCHESTRATOR_DOTNET_GITHUB=1
    touch "${TEST_TMP}/fail"
    run fetch_open_pr_numbers_on_head org/repo fix/7-typo
    [ "${status}" -ne 0 ]
    [ -z "${output}" ]
    run fetch_branch_requires_status_checks main org/repo
    [ "${status}" -ne 0 ]
    [ -z "${output}" ]

    REPO_FULL=org/repo
    find_stale_issue_branch() { printf 'chore/42-fix\n'; }
    run resolve_resumable_issue_branch 42
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]

    run --separate-stderr dirty_branch_owned_by_queued_item '[{"repository":"org/repo","itemType":"PullRequest","id":7}]' org/repo fix/7-typo Issue 42
    [ "${status}" -eq 2 ]
    [ -z "${output}" ]

    ORCHESTRATOR_CMD=no-such-orchestrator-command
    run -127 --separate-stderr fetch_open_pr_count_on_head org/repo fix/7-typo
    [ "${status}" -ne 0 ]
    [ -z "${output}" ]
}

@test "resolve_resumable_issue_branch and dirty_branch_owned_by_queued_item use the tool's reads when switched on (#252)" {
    make_orchestrator_github_stub
    make_stub gh 'exit 1'
    ORCHESTRATOR_DOTNET_GITHUB=1
    REPO_FULL=org/repo
    find_stale_issue_branch() { printf 'chore/42-fix\n'; }
    printf '0\n' > "${TEST_TMP}/github_output"
    run resolve_resumable_issue_branch 42
    [ "${status}" -eq 0 ]
    [ "${output}" = "chore/42-fix" ]

    printf '9\n7\n' > "${TEST_TMP}/github_output"
    run dirty_branch_owned_by_queued_item '[{"repository":"org/repo","itemType":"PullRequest","id":7}]' org/repo fix/7-typo Issue 42
    [ "${status}" -eq 0 ]
    [ "${output}" = "PullRequest #7" ]
}

# A stand-in for the tool that answers each github read differently: records its arguments (one
# line per call, joined with spaces) and prints ${TEST_TMP}/github_<read>, or fails when that file
# is missing.
make_orchestrator_github_reads_stub() {
    make_stub_multiline fake-orchestrator \
        'printf "%s\n" "$*" >> "${TEST_TMP}/cmd_calls"' \
        '[ -f "${TEST_TMP}/github_$2" ] || exit 1' \
        'cat "${TEST_TMP}/github_$2"'
    export ORCHESTRATOR_CMD=fake-orchestrator
}

@test "the stand-off reads use gh, never ORCHESTRATOR_CMD, while ORCHESTRATOR_DOTNET_GITHUB is off (#252)" {
    make_orchestrator_github_reads_stub
    ORCHESTRATOR_DOTNET_GITHUB=0
    make_stub gh 'case "$*" in
        "api user --jq .login") printf "bot-user\n" ;;
        "pr list --repo org/repo --state open --limit 200 --json number,author,closingIssuesReferences,headRefName") printf "%s" "[{\"number\":7,\"author\":{\"login\":\"x\",\"is_bot\":false},\"closingIssuesReferences\":[{\"id\":\"I\",\"number\":3}],\"headRefName\":\"fix/3-a\"}]" ;;
        "pr view 7 --repo org/repo --json commits") printf "%s" "{\"commits\":[{\"oid\":\"a\",\"authors\":[{\"id\":\"U\",\"login\":\"x\",\"email\":\"x@example.test\",\"name\":\"X\"}]}]}" ;;
        "api repos/org/repo/compare/main...fix%2F3-a --jq .behind_by") printf "4\n" ;;
        *) exit 1 ;;
    esac'
    run fetch_current_login
    [ "${status}" -eq 0 ]
    [ "${output}" = "bot-user" ]
    run fetch_open_prs_with_closing_issues org/repo
    [ "${status}" -eq 0 ]
    [ "${output}" = '[{"number":7,"author":{"login":"x"},"closingIssuesReferences":[{"number":3}],"headRefName":"fix/3-a"}]' ]
    run fetch_pr_commit_authors_json org/repo 7
    [ "${status}" -eq 0 ]
    [ "${output}" = '{"commits":[{"authors":[{"login":"x","email":"x@example.test"}]}]}' ]
    run fetch_branch_behind_by org/repo main fix/3-a
    [ "${status}" -eq 0 ]
    [ "${output}" = "4" ]
    [ ! -f "${TEST_TMP}/cmd_calls" ]
}

@test "the stand-off reads hand their arguments to ORCHESTRATOR_CMD github when switched on (#252)" {
    make_orchestrator_github_reads_stub
    make_stub gh 'exit 1'
    ORCHESTRATOR_DOTNET_GITHUB=1
    printf 'bot-user\n' > "${TEST_TMP}/github_whoami"
    printf '[]\n' > "${TEST_TMP}/github_open-prs-closing-issues"
    printf '{"commits":[]}\n' > "${TEST_TMP}/github_pr-commit-authors"
    printf '0\n' > "${TEST_TMP}/github_branch-behind-by"

    run fetch_current_login
    [ "${status}" -eq 0 ]
    [ "${output}" = "bot-user" ]
    run fetch_open_prs_with_closing_issues org/repo
    [ "${status}" -eq 0 ]
    [ "${output}" = "[]" ]
    run fetch_pr_commit_authors_json org/repo 7
    [ "${status}" -eq 0 ]
    [ "${output}" = '{"commits":[]}' ]
    run fetch_branch_behind_by org/repo "release/1.0" "fix/3 a#b"
    [ "${status}" -eq 0 ]
    [ "${output}" = "0" ]
    [ "$(cat "${TEST_TMP}/cmd_calls")" = "$(printf '%s\n' \
        'github whoami' \
        'github open-prs-closing-issues --repo org/repo' \
        'github pr-commit-authors --repo org/repo --pr 7' \
        'github branch-behind-by --repo org/repo --base release/1.0 --head fix/3 a#b')" ]
}

@test "fetch_pr_commit_authors_json retries the tool as fetch_pr_fields_json retries gh (#252)" {
    make_orchestrator_github_reads_stub
    make_stub gh 'exit 1'
    ORCHESTRATOR_DOTNET_GITHUB=1
    GH_ITEM_FETCH_RETRY_ATTEMPTS=3
    GH_ITEM_FETCH_RETRY_DELAY_SECS=0
    run fetch_pr_commit_authors_json org/repo 7
    [ "${status}" -ne 0 ]
    [ -z "${output}" ]
    [ "$(wc -l < "${TEST_TMP}/cmd_calls")" -eq 3 ]
}

@test "the takeover stand-off, the pivot, the identity and the behind check use the tool's reads when switched on (#252)" {
    make_orchestrator_github_reads_stub
    make_stub gh 'exit 1'
    ORCHESTRATOR_DOTNET_GITHUB=1
    REPO_FULL=org/repo
    PR_CREATOR_LOGIN=app/prpixie
    GIT_USER_EMAIL=bot@example.test
    get_trusted_logins() { printf '["owner"]'; }
    _GH_ME=""
    printf 'bot-user\n' > "${TEST_TMP}/github_whoami"
    resolve_gh_me
    [ "${_GH_ME}" = "bot-user" ]

    printf '%s\n' '[{"number":31,"author":{"login":"app/prpixie"},"closingIssuesReferences":[{"number":12}],"headRefName":"feat/12-thing"},{"number":5,"author":{"login":"owner"},"closingIssuesReferences":[],"headRefName":"fix/9-other"}]' \
        > "${TEST_TMP}/github_open-prs-closing-issues"
    printf '%s\n' '{"commits":[{"authors":[{"login":"owner","email":"owner@example.test"}]}]}' > "${TEST_TMP}/github_pr-commit-authors"
    run find_human_taken_over_pr_for_issue 12
    [ "${status}" -eq 0 ]
    [ "${output}" = "31" ]

    printf '%s\n' '{"commits":[{"authors":[{"login":"","email":"Bot@Example.test"}]}]}' > "${TEST_TMP}/github_pr-commit-authors"
    run find_human_taken_over_pr_for_issue 12
    [ "${status}" -eq 1 ]
    run pr_has_bot_authored_commit org/repo 31
    [ "${status}" -eq 0 ]

    printf '31\n' > "${TEST_TMP}/github_own-open-prs"
    run find_open_nonblocked_pr_for_repo org/repo
    [ "${status}" -eq 0 ]
    [ "${output}" = "31" ]

    printf '3\n' > "${TEST_TMP}/github_branch-behind-by"
    run pr_branch_behind_base org/repo '{"baseRefName":"main","headRefName":"feat/12-thing"}'
    [ "${status}" -eq 0 ]
    printf '0\n' > "${TEST_TMP}/github_branch-behind-by"
    run pr_branch_behind_base org/repo '{"baseRefName":"main","headRefName":"feat/12-thing"}'
    [ "${status}" -eq 1 ]
    run pr_branch_behind_base org/repo '{"baseRefName":"main","headRefName":"feat/12-thing","isCrossRepository":true}'
    [ "${status}" -eq 1 ]
}

@test "the takeover stand-off, the pivot, the identity and the behind check fail safe when ORCHESTRATOR_CMD fails (#252)" {
    make_orchestrator_github_reads_stub
    make_stub gh 'exit 1'
    ORCHESTRATOR_DOTNET_GITHUB=1
    GH_USER_RETRY_ATTEMPTS=2
    GH_USER_RETRY_DELAY_SECS=0
    GH_ITEM_FETCH_RETRY_ATTEMPTS=2
    GH_ITEM_FETCH_RETRY_DELAY_SECS=0
    REPO_FULL=org/repo
    PR_CREATOR_LOGIN=app/prpixie
    get_trusted_logins() { printf '["owner"]'; }
    _GH_ME=""
    run resolve_gh_me
    [ "${status}" -eq 1 ]

    _GH_ME=bot-user
    run find_human_taken_over_pr_for_issue 12
    [ "${status}" -eq 2 ]
    [ -z "${output}" ]

    printf '%s\n' '[{"number":31,"author":{"login":"app/prpixie"},"closingIssuesReferences":[{"number":12}],"headRefName":"feat/12-thing"}]' \
        > "${TEST_TMP}/github_open-prs-closing-issues"
    run find_human_taken_over_pr_for_issue 12
    [ "${status}" -eq 2 ]
    run pr_has_bot_authored_commit org/repo 31
    [ "${status}" -eq 2 ]

    run pr_branch_behind_base org/repo '{"baseRefName":"main","headRefName":"feat/12-thing"}'
    [ "${status}" -eq 2 ]
}

@test "the comment and closing issue reads use gh, never ORCHESTRATOR_CMD, while ORCHESTRATOR_DOTNET_GITHUB is off (#252)" {
    make_orchestrator_github_reads_stub
    ORCHESTRATOR_DOTNET_GITHUB=0
    REPO_FULL=org/repo
    make_stub gh 'case "$*" in
        "api repos/org/repo/pulls/7/comments --paginate --slurp") printf "%s" "[[{\"id\":5,\"user\":{\"login\":\"x\"},\"path\":\"a\",\"body\":\"b\",\"updated_at\":\"t\"}]]" ;;
        "api repos/org/repo/issues/7/comments --paginate --slurp") printf "%s" "[[{\"id\":6,\"user\":{\"login\":\"x\"},\"body\":\"b\",\"created_at\":\"c\",\"updated_at\":\"t\"}]]" ;;
        "pr view 7 --repo org/repo --json closingIssuesReferences --jq .closingIssuesReferences[].number") printf "3\n" ;;
        "pr view 7 --repo org/repo --json closingIssuesReferences --jq "*) printf "org/repo 3\n" ;;
        "issue view 3 --repo org/repo --json labels --jq .labels[].name") printf "Bug\n" ;;
        *) exit 1 ;;
    esac'
    run fetch_pr_review_comments 7
    [ "${status}" -eq 0 ]
    [ "${output}" = '[{"user":{"login":"x"},"path":"a","body":"b","updated_at":"t"}]' ]
    run fetch_pr_issue_comments 7
    [ "${status}" -eq 0 ]
    [ "${output}" = '[{"user":{"login":"x"},"body":"b","created_at":"c","updated_at":"t"}]' ]
    run fetch_pr_closing_issue_numbers org/repo 7
    [ "${status}" -eq 0 ]
    [ "${output}" = "3" ]
    run fetch_closing_issue_labels org/repo 7
    [ "${status}" -eq 0 ]
    [ "${output}" = "Bug" ]
    [ ! -f "${TEST_TMP}/cmd_calls" ]
}

@test "the comment and closing issue reads hand their arguments to ORCHESTRATOR_CMD github when switched on (#252)" {
    make_orchestrator_github_reads_stub
    make_stub gh 'exit 1'
    ORCHESTRATOR_DOTNET_GITHUB=1
    REPO_FULL=org/repo
    printf '[]\n' > "${TEST_TMP}/github_pr-review-comments"
    printf '[{"user":null,"body":"b","created_at":"c","updated_at":"t"}]\n' > "${TEST_TMP}/github_pr-issue-comments"
    printf '3\n5\n' > "${TEST_TMP}/github_pr-closing-issues"
    printf 'Bug\nEnhancement\n' > "${TEST_TMP}/github_closing-issue-labels"

    run fetch_pr_review_comments 7
    [ "${status}" -eq 0 ]
    [ "${output}" = "[]" ]
    run fetch_pr_issue_comments 8
    [ "${status}" -eq 0 ]
    [ "${output}" = '[{"user":null,"body":"b","created_at":"c","updated_at":"t"}]' ]
    run fetch_pr_closing_issue_numbers org/other 9
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '3\n5')" ]
    run fetch_closing_issue_labels org/other 10
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf 'Bug\nEnhancement')" ]
    [ "$(cat "${TEST_TMP}/cmd_calls")" = "$(printf '%s\n' \
        'github pr-review-comments --repo org/repo --pr 7' \
        'github pr-issue-comments --repo org/repo --pr 8' \
        'github pr-closing-issues --repo org/other --pr 9' \
        'github closing-issue-labels --repo org/other --pr 10')" ]
}

@test "the comment reads retry the tool as they retry gh (#252)" {
    make_orchestrator_github_reads_stub
    make_stub gh 'exit 1'
    ORCHESTRATOR_DOTNET_GITHUB=1
    REPO_FULL=org/repo
    GH_ITEM_FETCH_RETRY_ATTEMPTS=3
    GH_ITEM_FETCH_RETRY_DELAY_SECS=0
    run fetch_pr_review_comments 7
    [ "${status}" -ne 0 ]
    [ -z "${output}" ]
    run fetch_pr_issue_comments 7
    [ "${status}" -ne 0 ]
    [ "$(wc -l < "${TEST_TMP}/cmd_calls")" -eq 6 ]
}

@test "the label and board-status sync use the tool's closing issue reads when switched on (#252)" {
    make_orchestrator_github_reads_stub
    ORCHESTRATOR_DOTNET_GITHUB=1
    set_repo_context "org/repo"
    local call_log="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "'"${call_log}"'"; case "$*" in *"pr edit"*) exit 0 ;; *) exit 1 ;; esac'
    printf 'AI-Work\nBug\n' > "${TEST_TMP}/github_closing-issue-labels"
    sync_pr_labels_from_linked_issues 42 '{"labels":[{"name":"AI-Work"}]}'
    [ "$(cat "${call_log}")" = "pr edit 42 --repo org/repo --add-label Bug" ]

    _WF_PROJECT_ID="PVT_test"
    board_substatus_for_item() {
        case "$1" in
            383) printf 'AI Review' ;;
            *) printf 'Development' ;;
        esac
    }
    local status_log="${TEST_TMP}/status_calls"
    update_workflow_status() { printf '%s %s %s\n' "$1" "$2" "$3" >> "${status_log}"; }
    printf '383\n' > "${TEST_TMP}/github_pr-closing-issues"
    sync_pr_workflow_status_from_linked_issues 412 "false"
    [ "$(cat "${status_log}")" = "PullRequest 412 AI Review" ]
    grep -q -- "github pr-closing-issues --repo org/repo --pr 412" "${TEST_TMP}/cmd_calls"
}

@test "the label and board-status sync change nothing when the tool's closing issue reads fail (#252)" {
    make_orchestrator_github_reads_stub
    ORCHESTRATOR_DOTNET_GITHUB=1
    set_repo_context "org/repo"
    local call_log="${TEST_TMP}/gh_calls"
    # shellcheck disable=SC2016
    make_stub gh 'printf "%s\n" "$*" >> "'"${call_log}"'"; exit 0'
    run sync_pr_labels_from_linked_issues 42 '{"labels":[]}'
    [ "${status}" -eq 0 ]
    [ ! -f "${call_log}" ]

    _WF_PROJECT_ID="PVT_test"
    board_substatus_for_item() { printf 'Development'; }
    local status_log="${TEST_TMP}/status_calls"
    update_workflow_status() { printf '%s %s %s\n' "$1" "$2" "$3" >> "${status_log}"; }
    run sync_pr_workflow_status_from_linked_issues 412 "false"
    [ "${status}" -eq 0 ]
    [ ! -f "${status_log}" ]
}
