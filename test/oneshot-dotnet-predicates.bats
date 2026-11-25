#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are read by the sourced oneshot functions, where shellcheck cannot trace them
# shellcheck disable=SC2016  # stub bodies are expanded by the stub, not here

# The ORCHESTRATOR_DOTNET_PREDICATES switch (#252): off by default, and when on each ported
# lib/github-status predicate or read hands its JSON to `ORCHESTRATOR_CMD predicate <name>` with the
# same inputs, output and failure contract. test/oneshot-predicates-parity.bats checks what both sides
# answer; this file checks the hand-over.

bats_require_minimum_version 1.5.0

load test_helper
load oneshot_helper

PR_JSON='{"title":"T","isDraft":false,"statusCheckRollup":[{"name":"build","status":"COMPLETED","conclusion":"SUCCESS"}]}'
ISSUE_JSON='{"title":"T","comments":[{"author":{"login":"planner"},"body":"## Implementation Plan"}]}'

# A stand-in for the tool: records its arguments, its stdin, the content of every --*-file it was given
# (in ${TEST_TMP}/file<option>) and the paths of those files, prints ${TEST_TMP}/predicate_output when
# there is one, and exits with ${TEST_TMP}/predicate_rc (0 when it is missing).
make_orchestrator_predicate_stub() {
    make_stub_multiline fake-orchestrator \
        'printf "%s\n" "$@" > "${TEST_TMP}/cmd_args"' \
        'cat > "${TEST_TMP}/cmd_stdin"' \
        'while [ "$#" -gt 0 ]; do' \
        '    case "$1" in' \
        '        --*-file) cat "$2" > "${TEST_TMP}/file$1"; printf "%s\n" "$2" >> "${TEST_TMP}/cmd_files"; shift ;;' \
        '    esac' \
        '    shift' \
        'done' \
        '[ -f "${TEST_TMP}/stderr" ] && printf "from the tool\n" >&2' \
        '[ -f "${TEST_TMP}/predicate_output" ] && cat "${TEST_TMP}/predicate_output"' \
        'exit "$(cat "${TEST_TMP}/predicate_rc" 2> /dev/null || echo 0)"'
    export ORCHESTRATOR_CMD=fake-orchestrator
}

# Fails when a temporary file handed to the tool is still there.
assert_predicate_files_removed() {
    local file
    [ -f "${TEST_TMP}/cmd_files" ] || return 0
    while IFS= read -r file; do
        [ ! -e "${file}" ]
    done < "${TEST_TMP}/cmd_files"
}

@test "ORCHESTRATOR_DOTNET_PREDICATES defaults to off (#252)" {
    run env -u ORCHESTRATOR_DOTNET_PREDICATES bash -c 'source "'"${REPO_ROOT}"'/oneshot"; printf "%s" "${ORCHESTRATOR_DOTNET_PREDICATES}"'
    [ "${status}" -eq 0 ]
    [ "${output}" = "0" ]
}

@test "the lib/github-status predicates never run ORCHESTRATOR_CMD while ORCHESTRATOR_DOTNET_PREDICATES is off (#252)" {
    make_orchestrator_predicate_stub
    ORCHESTRATOR_DOTNET_PREDICATES=0
    run pr_json_has_only_passed_checks "${PR_JSON}"
    [ "${status}" -eq 0 ]
    run pr_json_is_terminal "${PR_JSON}" true
    [ "${status}" -eq 0 ]
    run pr_json_has_pending_ci_checks "${PR_JSON}"
    [ "${status}" -eq 1 ]
    run issue_json_has_plan_comment "${ISSUE_JSON}"
    [ "${status}" -eq 0 ]
    run issue_json_has_human_plan_approval "${ISSUE_JSON}" me '["owner"]'
    [ "${status}" -eq 1 ]
    run pr_json_latest_trusted_comment_timestamp "${PR_JSON}"
    [ "${status}" -eq 0 ]
    run annotate_pr_json_required_checks "${PR_JSON}" '["build"]'
    [ "${output}" = '{"title":"T","isDraft":false,"statusCheckRollup":[{"name":"build","status":"COMPLETED","conclusion":"SUCCESS","isRequired":true}]}' ]
    run pr_json_lowest_closing_issue '{"closingIssuesReferences":[{"number":3}]}' org/repo
    [ "${output}" = "3" ]
    [ ! -f "${TEST_TMP}/cmd_args" ]
}

@test "each boolean predicate hands its JSON to ORCHESTRATOR_CMD predicate and answers from the exit status when switched on (#252)" {
    make_orchestrator_predicate_stub
    ORCHESTRATOR_DOTNET_PREDICATES=1
    local pair function name
    for pair in pr_json_has_placeholder_file:pr-has-placeholder-file \
        pr_json_has_only_passed_checks:pr-has-only-passed-checks \
        pr_json_has_failed_required_check:pr-has-failed-required-check \
        pr_json_has_failed_check_of_unknown_requiredness:pr-has-failed-check-of-unknown-requiredness \
        pr_json_has_pending_ci_checks:pr-has-pending-ci-checks \
        pr_json_has_unaddressed_review_request:pr-has-unaddressed-review-request \
        pr_json_needs_review_approval:pr-needs-review-approval \
        issue_json_has_plan_comment:issue-has-plan-comment; do
        function="${pair%%:*}"
        name="${pair#*:}"
        rm -f "${TEST_TMP}/predicate_rc"
        printf 'true\n' > "${TEST_TMP}/predicate_output"
        run "${function}" "${PR_JSON}"
        [ "${status}" -eq 0 ]
        [ -z "${output}" ]
        [ "$(tr '\n' ' ' < "${TEST_TMP}/cmd_args")" = "predicate ${name} " ]
        [ "$(cat "${TEST_TMP}/cmd_stdin")" = "${PR_JSON}" ]

        printf 'false\n' > "${TEST_TMP}/predicate_output"
        printf '3' > "${TEST_TMP}/predicate_rc"
        run "${function}" "${PR_JSON}"
        [ "${status}" -eq 1 ]
        [ -z "${output}" ]

        rm -f "${TEST_TMP}/predicate_output"
        printf '1' > "${TEST_TMP}/predicate_rc"
        run "${function}" "${PR_JSON}"
        [ "${status}" -eq 1 ]
    done
}

@test "pr_json_is_terminal hands the review-pipeline-finished value to ORCHESTRATOR_CMD, false by default, when switched on (#252)" {
    make_orchestrator_predicate_stub
    ORCHESTRATOR_DOTNET_PREDICATES=1
    run pr_json_is_terminal "${PR_JSON}" true
    [ "${status}" -eq 0 ]
    [ "$(tr '\n' ' ' < "${TEST_TMP}/cmd_args")" = "predicate pr-is-terminal --review-pipeline-finished true " ]
    run pr_json_is_terminal "${PR_JSON}"
    [ "$(tr '\n' ' ' < "${TEST_TMP}/cmd_args")" = "predicate pr-is-terminal --review-pipeline-finished false " ]
    printf '3' > "${TEST_TMP}/predicate_rc"
    run pr_json_is_terminal "${PR_JSON}" true
    [ "${status}" -eq 1 ]
}

@test "issue_json_has_human_plan_approval hands the login and trusted logins to ORCHESTRATOR_CMD and removes the file when switched on (#252)" {
    make_orchestrator_predicate_stub
    ORCHESTRATOR_DOTNET_PREDICATES=1
    run issue_json_has_human_plan_approval "${ISSUE_JSON}" steward-warden '["owner","member"]'
    [ "${status}" -eq 0 ]
    [ "$(sed -n '1,4p' "${TEST_TMP}/cmd_args" | tr '\n' ' ')" = "predicate issue-has-human-plan-approval --me steward-warden " ]
    grep -qx -- '--trusted-file' "${TEST_TMP}/cmd_args"
    [ "$(cat "${TEST_TMP}/cmd_stdin")" = "${ISSUE_JSON}" ]
    [ "$(cat "${TEST_TMP}/file--trusted-file")" = '["owner","member"]' ]
    assert_predicate_files_removed

    run issue_json_has_human_plan_approval "${ISSUE_JSON}" steward-warden ""
    [ "$(cat "${TEST_TMP}/file--trusted-file")" = 'null' ]

    printf '3' > "${TEST_TMP}/predicate_rc"
    run issue_json_has_human_plan_approval "${ISSUE_JSON}" steward-warden '["owner"]'
    [ "${status}" -eq 1 ]
    assert_predicate_files_removed
}

@test "pr_json_latest_trusted_comment_timestamp hands the trusted logins, comments and own login to ORCHESTRATOR_CMD when switched on (#252)" {
    make_orchestrator_predicate_stub
    ORCHESTRATOR_DOTNET_PREDICATES=1
    printf '2026-01-02T00:00:00Z' > "${TEST_TMP}/predicate_output"
    run pr_json_latest_trusted_comment_timestamp "${PR_JSON}" '["owner"]' '[{"user":{"login":"owner"}}]' '[{"id":1}]' steward
    [ "${status}" -eq 0 ]
    [ "${output}" = "2026-01-02T00:00:00Z" ]
    [ "$(sed -n '1,2p' "${TEST_TMP}/cmd_args" | tr '\n' ' ')" = "predicate pr-latest-trusted-comment-timestamp " ]
    [ "$(sed -n '9,10p' "${TEST_TMP}/cmd_args" | tr '\n' ' ')" = "--exclude-login steward " ]
    [ "$(cat "${TEST_TMP}/file--trusted-file")" = '["owner"]' ]
    [ "$(cat "${TEST_TMP}/file--review-comments-file")" = '[{"user":{"login":"owner"}}]' ]
    [ "$(cat "${TEST_TMP}/file--issue-comments-file")" = '[{"id":1}]' ]
    assert_predicate_files_removed

    run pr_json_latest_trusted_comment_timestamp "${PR_JSON}"
    [ "$(cat "${TEST_TMP}/file--trusted-file")" = 'null' ]
    [ "$(cat "${TEST_TMP}/file--review-comments-file")" = '[]' ]
    [ "$(cat "${TEST_TMP}/file--issue-comments-file")" = '[]' ]

    printf '1' > "${TEST_TMP}/predicate_rc"
    run pr_json_latest_trusted_comment_timestamp "${PR_JSON}"
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
}

@test "pr_json_has_unaddressed_trusted_comment compares the tool's timestamp with the last one seen when switched on (#252)" {
    make_orchestrator_predicate_stub
    ORCHESTRATOR_DOTNET_PREDICATES=1
    printf '2026-01-05T00:00:00Z' > "${TEST_TMP}/predicate_output"
    run pr_json_has_unaddressed_trusted_comment "${PR_JSON}" '["owner"]' 2026-01-04T00:00:00Z
    [ "${status}" -eq 0 ]
    run pr_json_has_unaddressed_trusted_comment "${PR_JSON}" '["owner"]' 2026-01-05T00:00:00Z
    [ "${status}" -eq 1 ]
    printf '1' > "${TEST_TMP}/predicate_rc"
    run pr_json_has_unaddressed_trusted_comment "${PR_JSON}" '["owner"]' ""
    [ "${status}" -eq 1 ]
}

@test "pr_json_unaddressed_trusted_comments_text hands every input to ORCHESTRATOR_CMD and caps the tool's text when switched on (#252)" {
    make_orchestrator_predicate_stub
    ORCHESTRATOR_DOTNET_PREDICATES=1
    PR_UNADDRESSED_COMMENT_MAX_CHARS=7
    PR_UNADDRESSED_COMMENTS_MAX_CHARS=12
    printf -- '- owner (comment, t):\nhello' > "${TEST_TMP}/predicate_output"
    run pr_json_unaddressed_trusted_comments_text "${PR_JSON}" '["owner"]' 2026-01-01T00:00:00Z '[]' '[{"id":2}]' steward
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf -- '- owner (com\n[further comments truncated: read the rest on the PR]')" ]
    [ "$(sed -n '1,2p' "${TEST_TMP}/cmd_args" | tr '\n' ' ')" = "predicate pr-unaddressed-trusted-comments " ]
    [ "$(sed -n '9,14p' "${TEST_TMP}/cmd_args" | tr '\n' ' ')" = "--exclude-login steward --last-seen 2026-01-01T00:00:00Z --per-comment-max 7 " ]
    [ "$(cat "${TEST_TMP}/file--issue-comments-file")" = '[{"id":2}]' ]
    assert_predicate_files_removed

    PR_UNADDRESSED_COMMENTS_MAX_CHARS=8000
    run pr_json_unaddressed_trusted_comments_text "${PR_JSON}"
    [ "${output}" = "$(printf -- '- owner (comment, t):\nhello')" ]

    printf '1' > "${TEST_TMP}/predicate_rc"
    run pr_json_unaddressed_trusted_comments_text "${PR_JSON}"
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
}

@test "annotate_pr_json_required_checks prints the tool's JSON as it is, or the input when the tool fails, when switched on (#252)" {
    make_orchestrator_predicate_stub
    ORCHESTRATOR_DOTNET_PREDICATES=1
    printf '{"annotated":true}\n' > "${TEST_TMP}/predicate_output"
    local printed
    printed=$(
        annotate_pr_json_required_checks "${PR_JSON}" '["build"]' true
        printf x
    )
    [ "${printed}" = $'{"annotated":true}\nx' ]
    [ "$(sed -n '1,2p;5,6p' "${TEST_TMP}/cmd_args" | tr '\n' ' ')" = "predicate pr-annotate-required-checks --base-requires-checks true " ]
    [ "$(cat "${TEST_TMP}/file--required-file")" = '["build"]' ]
    assert_predicate_files_removed

    run annotate_pr_json_required_checks "${PR_JSON}"
    [ "$(cat "${TEST_TMP}/file--required-file")" = '' ]
    grep -qx -- '--base-requires-checks' "${TEST_TMP}/cmd_args"

    printf '1' > "${TEST_TMP}/predicate_rc"
    printed=$(
        annotate_pr_json_required_checks "${PR_JSON}" '["build"]'
        printf x
    )
    [ "${printed}" = "${PR_JSON}x" ]

    ORCHESTRATOR_CMD=no-such-orchestrator-command
    printed=$(
        annotate_pr_json_required_checks "${PR_JSON}" '["build"]'
        printf x
    )
    [ "${printed}" = "${PR_JSON}x" ]
}

@test "pr_json_env_block_image_sha and pr_json_lowest_closing_issue print what the tool finds when switched on (#252)" {
    make_orchestrator_predicate_stub
    ORCHESTRATOR_DOTNET_PREDICATES=1
    printf 'abc123' > "${TEST_TMP}/predicate_output"
    run pr_json_env_block_image_sha "${PR_JSON}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "abc123" ]
    [ "$(tr '\n' ' ' < "${TEST_TMP}/cmd_args")" = "predicate pr-env-block-image-sha " ]

    printf '7' > "${TEST_TMP}/predicate_output"
    run pr_json_lowest_closing_issue "${PR_JSON}" org/repo
    [ "${status}" -eq 0 ]
    [ "${output}" = "7" ]
    [ "$(tr '\n' ' ' < "${TEST_TMP}/cmd_args")" = "predicate pr-lowest-closing-issue --repo org/repo " ]

    printf '7.0' > "${TEST_TMP}/predicate_output"
    run pr_json_lowest_closing_issue "${PR_JSON}" org/repo
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]

    rm "${TEST_TMP}/predicate_output"
    run pr_json_env_block_image_sha "${PR_JSON}"
    [ "${status}" -eq 1 ]
    printf '3' > "${TEST_TMP}/predicate_rc"
    run pr_json_env_block_image_sha "${PR_JSON}"
    [ "${status}" -eq 1 ]
    run pr_json_lowest_closing_issue "${PR_JSON}" org/repo
    [ "${status}" -eq 1 ]
}

@test "the predicates fail closed and keep pr_json_has_pending_ci_checks' stderr when ORCHESTRATOR_CMD is missing or complains (#252)" {
    make_orchestrator_predicate_stub
    ORCHESTRATOR_DOTNET_PREDICATES=1
    touch "${TEST_TMP}/stderr"
    printf '1' > "${TEST_TMP}/predicate_rc"
    run --separate-stderr pr_json_has_pending_ci_checks "${PR_JSON}"
    [ "${status}" -eq 1 ]
    [ "${stderr}" = "from the tool" ]
    run --separate-stderr pr_json_is_terminal "${PR_JSON}"
    [ "${status}" -eq 1 ]
    [ -z "${stderr}" ]

    ORCHESTRATOR_CMD=no-such-orchestrator-command
    run issue_json_has_human_plan_approval "${ISSUE_JSON}" steward-warden '["owner"]'
    [ "${status}" -eq 1 ]
    run issue_json_has_plan_comment "${ISSUE_JSON}"
    [ "${status}" -eq 1 ]
    run pr_json_is_terminal "${PR_JSON}" true
    [ "${status}" -eq 1 ]
    run pr_json_has_failed_required_check "${PR_JSON}"
    [ "${status}" -eq 1 ]
    run --separate-stderr pr_json_latest_trusted_comment_timestamp "${PR_JSON}"
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
}
