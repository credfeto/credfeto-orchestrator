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
