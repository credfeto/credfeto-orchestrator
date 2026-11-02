#!/usr/bin/env bats
# shellcheck disable=SC2329  # functions in @test bodies are invoked indirectly via 'run'
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are used inside run() subshells where shellcheck cannot trace them
#
# The non-agentic pre-commit-check run before a session (#1785): run_precommit_precheck,
# ensure_precheck_result, prepare_precheck_section, summarise_precheck_log (lib/podman), the
# result cache (lib/state), build_precheck_section (lib/prompts) and the main() wiring (oneshot).

bats_require_minimum_version 1.5.0

load test_helper
load oneshot_helper

# Writes a podman stub. "podman run" logs its argv (one per line, then a "----" separator) to
# ${TEST_TMP}/podman_run_args, counts itself in ${TEST_TMP}/podman_runs, and runs
# ${TEST_TMP}/run_body.sh (write_run_body) with the argv; every other subcommand succeeds,
# except inspect (no leftover container) and rm, which is logged to ${TEST_TMP}/podman_rm.
stub_precheck_podman() {
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
case "$1" in
    inspect) exit 1 ;;
    rm) printf '%s\n' "$*" >> "${TEST_TMP}/podman_rm"; exit 0 ;;
    run)
        printf '%s\n' "$@" >> "${TEST_TMP}/podman_run_args"
        printf -- '----\n' >> "${TEST_TMP}/podman_run_args"
        printf 'run\n' >> "${TEST_TMP}/podman_runs"
        [ -f "${TEST_TMP}/run_body.sh" ] && exec bash "${TEST_TMP}/run_body.sh" "$@"
        exit 0
        ;;
    *) exit 0 ;;
esac
STUBEOF
    chmod +x "${STUB_BIN}/podman"
}

# What the stubbed "podman run" does, as a bash script body.
write_run_body() {
    printf '%s\n' "$@" > "${TEST_TMP}/run_body.sh"
}

podman_run_count() {
    if [ -f "${TEST_TMP}/podman_runs" ]; then
        wc -l < "${TEST_TMP}/podman_runs" | tr -d ' '
    else
        printf '0'
    fi
}

# A real clone at REPO_WORK_DIR (on main) of a local bare remote, plus a pushed PR branch
# feat/x one commit ahead. Sets MAIN_SHA and HEAD_SHA.
setup_precheck_repo() {
    setup_local_git_remote > /dev/null
    printf 'hello\n' > "${REPO_WORK_DIR}/file.txt"
    git -C "${REPO_WORK_DIR}" add file.txt
    git -C "${REPO_WORK_DIR}" -c commit.gpgsign=false commit -q -m "add file"
    git -C "${REPO_WORK_DIR}" push -q origin main
    MAIN_SHA=$(git -C "${REPO_WORK_DIR}" rev-parse HEAD)
    git -C "${REPO_WORK_DIR}" checkout -q -b feat/x
    printf 'change\n' >> "${REPO_WORK_DIR}/file.txt"
    git -C "${REPO_WORK_DIR}" -c commit.gpgsign=false commit -q -am "pr change"
    git -C "${REPO_WORK_DIR}" push -q origin feat/x
    HEAD_SHA=$(git -C "${REPO_WORK_DIR}" rev-parse HEAD)
    git -C "${REPO_WORK_DIR}" checkout -q main
    mkdir -p "${RULES_DIR}"
}

# A failing pre-commit-check log: two framework hooks fail (shellcheck with 15 error lines,
# yamllint with 2), one passes, then the hook dies and pre-commit-check reports the failure.
write_failing_run_body() {
    # shellcheck disable=SC2016  # the body is a script for the stub, expanded when it runs
    write_run_body \
        'printf "\n→ orchestrator-precheck: running pre-commit-check\n"' \
        'printf "→ Running /opt/git-global-hooks/pre-commit --all-files\n"' \
        'printf "\n\033[32m→\033[0m Running global linters (pre-commit)...\n"' \
        'printf "trim trailing whitespace.................................................Passed\n"' \
        'printf "shellcheck...............................................................Failed\n"' \
        'printf -- "- hook id: shellcheck\n- exit code: 1\n\n"' \
        'for i in $(seq 1 15); do printf "lib/x:%s: SC2086 error-line-%s\n" "${i}" "${i}"; done' \
        'printf "yamllint.................................................................Failed\n"' \
        'printf -- "- hook id: yamllint\n- exit code: 1\n\n"' \
        'printf "a.yml:1:1 [error] yaml-one\na.yml:2:1 [error] yaml-two\n"' \
        'printf "check json...........................................(no files to check)Skipped\n"' \
        'printf "\n\033[31m✗\033[0m pre-commit (global linters)\n" >&2' \
        'printf "\n✗ pre-commit hook failed\n" >&2' \
        'exit 1'
}

# --- a new head ------------------------------------------------------------------------------

@test "a new PR head runs pre-commit-check once in the agent image and the prompt section names that exact SHA (#1785)" {
    setup_precheck_repo
    stub_precheck_podman
    write_run_body \
        'printf "\n→ orchestrator-precheck: running pre-commit-check\n"' \
        'printf "✓ Pre-commit checks passed\n"' \
        'exit 0'

    prepare_precheck_section pr "PullRequest_7" "${HEAD_SHA}" PullRequest 7 2> /dev/null

    [ "$(podman_run_count)" = "1" ]
    [ "${PRECHECK_STATUS}" = "pass" ]
    [[ "${PRECHECK_SECTION}" == *"PRE-COMMIT RESULTS for ${HEAD_SHA}"* ]]
    [[ "${PRECHECK_SECTION}" == *"- Passed: every hook passed on ${HEAD_SHA}."* ]]
    [[ "${PRECHECK_SECTION}" == *"These are the results for the head as it was when this session started; after you change code, re-run only the checks that cover your change."* ]]
    # The agent's own image, mounts and environment, plus the pre-check switch, and no model.
    local args="${TEST_TMP}/podman_run_args"
    grep -qx -- "--env" "${args}"
    grep -qx -- "ORCHESTRATOR_PRECHECK=1" "${args}"
    grep -qx -- "${REPO_WORK_DIR}:${CONTAINER_REPO_PATH}:rw" "${args}"
    grep -qx -- "${RULES_DIR}:${CONTAINER_RULES_PATH}:ro" "${args}"
    grep -q -- ":/home/developer/.claude/CLAUDE.md:ro$" "${args}"
    grep -qx -- "${ORCHESTRATOR_IMAGE}" "${args}"
    grep -qx -- "--version" "${args}"
    run grep -qx -- "--model" "${args}"
    [ "${status}" -eq 1 ]
    run grep -qx -- "opusplan" "${args}"
    [ "${status}" -eq 1 ]
    # Cached by SHA in the per-item state directory, with the log for the session.
    [ "$(sed -n 1p "${SESSION_BASE_DIR}/PullRequest_7.precheck")" = "${HEAD_SHA}" ]
    [ "$(sed -n 2p "${SESSION_BASE_DIR}/PullRequest_7.precheck")" = "pass" ]
    [ "${PRECHECK_SESSION_LOG}" = "${SESSION_BASE_DIR}/PullRequest_7.precheck.log" ]
    grep -qF "Pre-commit checks passed" "${PRECHECK_SESSION_LOG}"
    # The clone is back on main afterwards.
    [ "$(git -C "${REPO_WORK_DIR}" branch --show-current)" = "main" ]
}

@test "the pre-check runs with the PR head checked out, and fixer changes are reset afterwards (#1785)" {
    setup_precheck_repo
    stub_precheck_podman
    # The stub sees REPO_WORK_DIR through the --volume argument; record its HEAD and dirty a file
    # the way a formatter hook would.
    write_run_body \
        "git -C '${REPO_WORK_DIR}' rev-parse HEAD > '${TEST_TMP}/checked_out'" \
        "printf 'reformatted\n' > '${REPO_WORK_DIR}/file.txt'" \
        'printf "→ orchestrator-precheck: running pre-commit-check\n"' \
        'exit 1'

    prepare_precheck_section pr "PullRequest_7" "${HEAD_SHA}" PullRequest 7 2> /dev/null

    [ "$(cat "${TEST_TMP}/checked_out")" = "${HEAD_SHA}" ]
    [ "$(git -C "${REPO_WORK_DIR}" branch --show-current)" = "main" ]
    [ -z "$(git -C "${REPO_WORK_DIR}" status --porcelain --untracked-files=no)" ]
    [ "$(cat "${REPO_WORK_DIR}/file.txt")" = "hello" ]
}

# --- a cached head ---------------------------------------------------------------------------

@test "a second session on the same PR head reuses the cached result and does not run pre-commit-check again (#1785)" {
    setup_precheck_repo
    stub_precheck_podman
    write_failing_run_body

    prepare_precheck_section pr "PullRequest_7" "${HEAD_SHA}" PullRequest 7 2> /dev/null
    [ "$(podman_run_count)" = "1" ]
    local first_section="${PRECHECK_SECTION}"

    run --separate-stderr prepare_precheck_section pr "PullRequest_7" "${HEAD_SHA}" PullRequest 7
    [ "${status}" -eq 0 ]
    [[ "${stderr}" == *"pre-commit-check result for PullRequest_7 at ${HEAD_SHA} is cached (fail), not running it again"* ]]
    prepare_precheck_section pr "PullRequest_7" "${HEAD_SHA}" PullRequest 7 2> /dev/null

    [ "$(podman_run_count)" = "1" ]
    [ "${PRECHECK_STATUS}" = "fail" ]
    [ "${PRECHECK_SECTION}" = "${first_section}" ]
}

@test "a new head on the same PR replaces the cached result and runs the check again (#1785)" {
    setup_precheck_repo
    stub_precheck_podman
    write_run_body 'printf "→ orchestrator-precheck: running pre-commit-check\n"' 'exit 0'
    prepare_precheck_section pr "PullRequest_7" "${HEAD_SHA}" PullRequest 7 2> /dev/null

    prepare_precheck_section pr "PullRequest_7" "${MAIN_SHA}" PullRequest 7 2> /dev/null

    [ "$(podman_run_count)" = "2" ]
    [ "$(sed -n 1p "${SESSION_BASE_DIR}/PullRequest_7.precheck")" = "${MAIN_SHA}" ]
}

# --- a failing hook --------------------------------------------------------------------------

@test "a failing hook is summarised in the prompt with its error lines truncated, and the log path (#1785)" {
    setup_precheck_repo
    stub_precheck_podman
    write_failing_run_body

    prepare_precheck_section pr "PullRequest_7" "${HEAD_SHA}" PullRequest 7 2> /dev/null

    [ "${PRECHECK_STATUS}" = "fail" ]
    [[ "${PRECHECK_SECTION}" == *"- FAILED on ${HEAD_SHA}. Failing hooks, with up to 10 error lines each:"* ]]
    [[ "${PRECHECK_SECTION}" == *"  - shellcheck"* ]]
    [[ "${PRECHECK_SECTION}" == *"      lib/x:1: SC2086 error-line-1"* ]]
    [[ "${PRECHECK_SECTION}" == *"      lib/x:10: SC2086 error-line-10"* ]]
    [[ "${PRECHECK_SECTION}" != *"error-line-11"* ]]
    [[ "${PRECHECK_SECTION}" == *"      (5 more line(s) in the log)"* ]]
    [[ "${PRECHECK_SECTION}" == *"  - yamllint"* ]]
    [[ "${PRECHECK_SECTION}" == *"      a.yml:2:1 [error] yaml-two"* ]]
    # Passed/skipped hooks, the framework's hook-id lines and the repeated die lines are left out.
    [[ "${PRECHECK_SECTION}" != *"trim trailing whitespace"* ]]
    [[ "${PRECHECK_SECTION}" != *"check json"* ]]
    [[ "${PRECHECK_SECTION}" != *"hook id"* ]]
    [[ "${PRECHECK_SECTION}" != *"pre-commit (global linters)"* ]]
    [[ "${PRECHECK_SECTION}" != *"pre-commit hook failed"* ]]
    [[ "${PRECHECK_SECTION}" == *"- Full log: /workspace/tmp/pre-commit-check.log (read it with the Read tool)."* ]]
}

@test "the failing-hook summary reaches the generated PR CLAUDE.md (#1785)" {
    setup_precheck_repo
    stub_precheck_podman
    write_failing_run_body
    prepare_precheck_section pr "PullRequest_7" "${HEAD_SHA}" PullRequest 7 2> /dev/null

    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "feat/x" "/workspace/repo" "" "false" "" "false" "" "" "${PRECHECK_SECTION}"

    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PRE-COMMIT RESULTS for ${HEAD_SHA}"* ]]
    [[ "${output}" == *"  - shellcheck"* ]]
    # It sits between the FIRST COMMAND block and PHASE DISCIPLINE.
    local first_line results_line phase_line
    first_line=$(printf '%s\n' "${output}" | grep -n '^FIRST COMMAND' | cut -d: -f1)
    results_line=$(printf '%s\n' "${output}" | grep -n '^PRE-COMMIT RESULTS' | cut -d: -f1)
    phase_line=$(printf '%s\n' "${output}" | grep -n '^PHASE DISCIPLINE' | cut -d: -f1)
    [ "${first_line}" -lt "${results_line}" ]
    [ "${results_line}" -lt "${phase_line}" ]
}

@test "build_pr_claude_md without a pre-check section is unchanged (#1785)" {
    run build_pr_claude_md 7 "/resolved/.ai-instructions" "CLEAN" "feat/x" "/workspace/repo"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"PRE-COMMIT"* ]]
    [[ "${output}" == *$'each as its own Bash call.\n\nPHASE DISCIPLINE'* ]]
}

@test "summarise_precheck_log quotes the last lines before a hook script's die line (#1785)" {
    local log="${TEST_TMP}/die.log"
    {
        printf '\n\033[32m→\033[0m Detected .NET changes — running buildtest...\n'
        for i in $(seq 1 14); do printf 'build-line-%s\n' "${i}"; done
        printf '\n\033[31m✗\033[0m dotnet buildtest\n'
        printf '\n✗ pre-commit hook failed\n'
    } > "${log}"

    run summarise_precheck_log "${log}" 3

    [ "${status}" -eq 0 ]
    [ "${output}" = "  - dotnet buildtest
      build-line-12
      build-line-13
      build-line-14
      (11 earlier line(s) in the log)" ]
}

@test "summarise_precheck_log lists at most the maximum number of hooks (#1785)" {
    local log="${TEST_TMP}/many.log"
    for i in 1 2 3; do printf 'hook-%s.........Failed\nerr-%s\n' "${i}" "${i}"; done > "${log}"

    run summarise_precheck_log "${log}" 5 2

    [ "${status}" -eq 0 ]
    [[ "${output}" == *"  - hook-1"* ]]
    [[ "${output}" == *"  - hook-2"* ]]
    [[ "${output}" != *"hook-3"* ]]
    [[ "${output}" == *"  - ... and 1 more failing hook(s); see the log"* ]]
}

@test "a failure with no recognisable hook quotes the log's last lines instead (#1785)" {
    setup_precheck_repo
    stub_precheck_podman
    write_run_body \
        'printf "→ orchestrator-precheck: running pre-commit-check\n"' \
        'printf "something odd happened\n"' \
        'exit 1'

    prepare_precheck_section pr "PullRequest_7" "${HEAD_SHA}" PullRequest 7 2> /dev/null

    [ "${PRECHECK_STATUS}" = "fail" ]
    [[ "${PRECHECK_SECTION}" == *"      something odd happened"* ]]
}

# --- a timeout -------------------------------------------------------------------------------

@test "a pre-check that runs past PRECHECK_TIMEOUT_MINUTES is stopped, reported and cached as timed out (#1785)" {
    setup_precheck_repo
    stub_precheck_podman
    write_run_body \
        'printf "→ orchestrator-precheck: running pre-commit-check\n"' \
        'printf "→ Detected .NET changes — running buildtest...\n"' \
        'exec sleep 30'
    PRECHECK_TIMEOUT_SECS=1

    prepare_precheck_section pr "PullRequest_7" "${HEAD_SHA}" PullRequest 7 2> /dev/null

    [ "${PRECHECK_STATUS}" = "timeout" ]
    [[ "${PRECHECK_SECTION}" == *"- No result: pre-commit-check did not finish on ${HEAD_SHA} within 20 minutes and was stopped."* ]]
    [[ "${PRECHECK_SECTION}" == *"      → Detected .NET changes — running buildtest..."* ]]
    [[ "${PRECHECK_SECTION}" == *"These are the results for the head as it was when this session started"* ]]
    grep -q "rm -f orchestrator-" "${TEST_TMP}/podman_rm"
    [ "$(sed -n 2p "${SESSION_BASE_DIR}/PullRequest_7.precheck")" = "timeout" ]
    [ "$(git -C "${REPO_WORK_DIR}" branch --show-current)" = "main" ]
}

@test "PRECHECK_TIMEOUT_MINUTES defaults to 20, falls back on a bad value, and 0 turns the pre-check off (#1785)" {
    run bash -c 'BASEDIR="$1"; source "$1/lib/globals"; printf "%s %s" "${PRECHECK_TIMEOUT_MINUTES}" "${PRECHECK_TIMEOUT_SECS}"' _ "${REPO_ROOT}"
    [ "${output}" = "20 1200" ]
    run bash -c 'BASEDIR="$1"; PRECHECK_TIMEOUT_MINUTES=abc; source "$1/lib/globals"; printf "%s" "${PRECHECK_TIMEOUT_MINUTES}"' _ "${REPO_ROOT}"
    [ "${output}" = "20" ]

    setup_precheck_repo
    stub_precheck_podman
    PRECHECK_TIMEOUT_MINUTES=0
    prepare_precheck_section pr "PullRequest_7" "${HEAD_SHA}" PullRequest 7 2> /dev/null
    [ "$(podman_run_count)" = "0" ]
    [ -z "${PRECHECK_SECTION}" ]
    [ -z "${PRECHECK_SESSION_LOG}" ]
}

# --- the check could not run ------------------------------------------------------------------

@test "an image without the pre-check mode is reported as no result and not cached (#1785)" {
    setup_precheck_repo
    stub_precheck_podman
    # An older entrypoint just runs claude --version.
    write_run_body 'printf "2.1.0 (Claude Code)\n"' 'exit 0'

    prepare_precheck_section pr "PullRequest_7" "${HEAD_SHA}" PullRequest 7 2> /dev/null

    [ "${PRECHECK_STATUS}" = "error" ]
    [[ "${PRECHECK_SECTION}" == *"- No result: the pre-check could not run on ${HEAD_SHA} (pre-commit-check did not start in the agent image (exit 0)). Check the head as the AI instructions say."* ]]
    [ ! -f "${SESSION_BASE_DIR}/PullRequest_7.precheck" ]
    [ -z "${PRECHECK_SESSION_LOG}" ]
    prepare_precheck_section pr "PullRequest_7" "${HEAD_SHA}" PullRequest 7 2> /dev/null
    [ "$(podman_run_count)" = "2" ]
}

@test "a head that is not in the clone is reported without launching a container (#1785)" {
    setup_precheck_repo
    stub_precheck_podman

    prepare_precheck_section pr "PullRequest_7" "0123456789abcdef0123456789abcdef01234567" PullRequest 7 2> /dev/null

    [ "$(podman_run_count)" = "0" ]
    [ "${PRECHECK_STATUS}" = "error" ]
    [[ "${PRECHECK_SECTION}" == *"is not in the orchestrator's clone"* ]]
}

# --- issue sessions: the default branch's baseline --------------------------------------------

@test "an issue session on a clean main is told the baseline is clean, and every issue shares one run per SHA (#1785)" {
    setup_precheck_repo
    stub_precheck_podman
    write_run_body 'printf "→ orchestrator-precheck: running pre-commit-check\n"' 'exit 0'

    prepare_precheck_section main main "${MAIN_SHA}" Issue 10 2> /dev/null

    [[ "${PRECHECK_SECTION}" == *"PRE-COMMIT BASELINE for main at ${MAIN_SHA}"* ]]
    [[ "${PRECHECK_SECTION}" == *"- \`pre-commit-check\` passed on \`main\` at \`${MAIN_SHA}\` before this session. The baseline is clean, so don't run a baseline check; any failure after your change comes from your change."* ]]
    [ "$(sed -n 1p "${SESSION_BASE_DIR}/main.precheck")" = "${MAIN_SHA}" ]

    prepare_precheck_section main main "${MAIN_SHA}" Issue 11 2> /dev/null
    [ "$(podman_run_count)" = "1" ]
    [[ "${PRECHECK_SECTION}" == *"The baseline is clean"* ]]

    run build_issue_claude_md 11 "/resolved/.ai-instructions" "/workspace/repo" "true" "" "" "" "false" "${PRECHECK_SECTION}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *$'PRE-COMMIT BASELINE for main at '"${MAIN_SHA}"* ]]
    [[ "${output}" == *"don't run a baseline check"* ]]
}

@test "an issue session on a main with failures lists them as already failing (#1785)" {
    setup_precheck_repo
    stub_precheck_podman
    write_failing_run_body

    prepare_precheck_section main main "${MAIN_SHA}" Issue 10 2> /dev/null

    [ "${PRECHECK_STATUS}" = "fail" ]
    [[ "${PRECHECK_SECTION}" == *"- \`pre-commit-check\` FAILED on \`main\` at \`${MAIN_SHA}\` before this session. The hooks below were already failing before your change: they are pre-existing failures, not yours"* ]]
    [[ "${PRECHECK_SECTION}" == *"Don't run a baseline check. Already failing on main (up to 10 error lines per hook):"* ]]
    [[ "${PRECHECK_SECTION}" == *"  - shellcheck"* ]]
    [[ "${PRECHECK_SECTION}" == *"  - yamllint"* ]]
    [[ "${PRECHECK_SECTION}" == *"- After your change, a failure in any hook not listed above comes from your change."* ]]
    [[ "${PRECHECK_SECTION}" == *"- Full log: /workspace/tmp/pre-commit-check.log"* ]]
}

@test "build_issue_claude_md without a pre-check section is unchanged (#1785)" {
    run build_issue_claude_md 11 "/resolved/.ai-instructions" "/workspace/repo" "true"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"PRE-COMMIT"* ]]
}

# --- the session's container gets the log ------------------------------------------------------

@test "the agent session's container finds the pre-check log in its scratch directory (#1785)" {
    mkdir -p "${REPO_WORK_DIR}" "${RULES_DIR}"
    printf 'the full pre-check log\n' > "${TEST_TMP}/saved.log"
    PRECHECK_SESSION_LOG="${TEST_TMP}/saved.log"
    cat > "${STUB_BIN}/podman" << 'STUBEOF'
#!/usr/bin/env bash
[ "$1" = "pull" ] && exit 0
[ "$1" = "inspect" ] && exit 1
if [ "$1" = "run" ]; then
    for a in "$@"; do
        case "${a}" in
            *:/workspace/tmp:rw) cat "${a%%:*}/pre-commit-check.log" > "${TEST_TMP}/seen_log" ;;
        esac
    done
    printf '{"session_id":"12345678-1234-1234-1234-123456789abc","result":"done"}\n'
fi
exit 0
STUBEOF
    chmod +x "${STUB_BIN}/podman"

    invoke_claude "prompt" "PullRequest" "7" "# mock CLAUDE.md" 2> /dev/null

    [ "$(cat "${TEST_TMP}/seen_log")" = "the full pre-check log" ]
}

# --- main() wiring ------------------------------------------------------------------------------

# main mocks for one open full-flow PR #5 with head abc123; prepare_precheck_section logs its
# arguments and sets a section, and build_pr_claude_md logs its 12th argument.
setup_main_precheck_pr() {
    setup_main_mocks
    local merge_state="${1:-CLEAN}"
    fetch_all_priorities() {
        printf '%s\n' '[{"id":5,"itemType":"PullRequest","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    eval "fetch_pr_json() { printf '%s\n' '{\"state\":\"OPEN\",\"title\":\"T\",\"body\":\"\",\"isDraft\":false,\"labels\":[],\"headRefOid\":\"abc123\",\"headRefName\":\"feat/test\",\"comments\":[],\"reviews\":[],\"statusCheckRollup\":[],\"mergeable\":\"MERGEABLE\",\"mergeStateStatus\":\"${merge_state}\"}'; }"
    fingerprint_pr_json() { printf 'fp-new\n'; }
    load_pr_fingerprint() { printf 'fp-old\n'; }
    prepare_precheck_section() {
        printf '%s\n' "$*" >> "${TEST_TMP}/precheck_calls"
        PRECHECK_SECTION="PRECHECK-SECTION-MARKER"
    }
    build_pr_claude_md() {
        printf '%s\n' "${12:-}" > "${TEST_TMP}/pr_md_precheck_arg"
        printf 'mock-pr-claude-md\n'
    }
}

@test "main runs the pre-check on a full-flow PR's head and passes the section to build_pr_claude_md (#1785)" {
    setup_main_precheck_pr CLEAN

    run main

    [ "${status}" -eq 0 ]
    [ "$(cat "${TEST_TMP}/precheck_calls")" = "pr PullRequest_5 abc123 PullRequest 5" ]
    [ "$(cat "${TEST_TMP}/pr_md_precheck_arg")" = "PRECHECK-SECTION-MARKER" ]
}

@test "main skips the pre-check for a BEHIND PR, whose session rebases first (#1785)" {
    setup_main_precheck_pr BEHIND

    run main

    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/precheck_calls" ]
    [ -z "$(cat "${TEST_TMP}/pr_md_precheck_arg")" ]
}

@test "main skips the pre-check for a dependency PR (#1785)" {
    setup_main_precheck_pr CLEAN
    pr_should_use_dependency_prompt() { return 0; }

    run main

    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/precheck_calls" ]
}

# main mocks for one open Issue #10 with no PR; plan_approved_or_later comes from the stub.
setup_main_precheck_issue() {
    setup_main_mocks
    local approved="$1"
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    issue_json_has_blocked_label() { return 1; }
    eval "issue_plan_approved_or_later() { printf '%s' '${approved}'; }"
    prepare_precheck_section() {
        printf '%s\n' "$*" >> "${TEST_TMP}/precheck_calls"
        PRECHECK_SECTION="PRECHECK-SECTION-MARKER"
    }
    build_issue_claude_md() {
        printf '%s\n' "${9:-}" > "${TEST_TMP}/issue_md_precheck_arg"
        printf 'mock-issue-claude-md\n'
    }
}

@test "main runs the main-branch pre-check for an issue whose plan is approved (#1785)" {
    setup_main_precheck_issue true

    run main

    [ "${status}" -eq 0 ]
    [[ "$(cat "${TEST_TMP}/precheck_calls")" == "main main "*" Issue 10" ]]
    [ "$(cat "${TEST_TMP}/issue_md_precheck_arg")" = "PRECHECK-SECTION-MARKER" ]
}

@test "main skips the pre-check for an issue in plan mode (#1785)" {
    setup_main_precheck_issue false

    run main

    [ "${status}" -eq 0 ]
    [ ! -f "${TEST_TMP}/precheck_calls" ]
    [ -z "$(cat "${TEST_TMP}/issue_md_precheck_arg")" ]
}
