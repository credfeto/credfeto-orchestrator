#!/usr/bin/env bats
# shellcheck disable=SC2329  # functions in @test bodies are invoked indirectly via 'run'
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are used inside run() subshells where shellcheck cannot trace them
#
# The per-work-item CodeGraph index directory (#1882): codegraph_index_dir_path and
# link_pivot_pr_codegraph_index (lib/state), add_codegraph_index_podman_args and
# prune_codegraph_indexes (lib/podman), and the pivot wiring in main (oneshot). The index follows
# the transcript lifecycle, whose shared helpers test/oneshot-main-transcripts.bats covers in full.

bats_require_minimum_version 1.5.0

load test_helper
load oneshot_helper

CODEGRAPH_MOUNT_SUFFIX=":/workspace/repo/.codegraph:rw"

# Writes an index database into an item's CodeGraph index directory.
make_codegraph_index() {
    local item_name="$1"
    mkdir -p "${SESSION_BASE_DIR}/codegraph/${item_name}"
    printf 'index\n' > "${SESSION_BASE_DIR}/codegraph/${item_name}/codegraph.db"
}

# Sets an item's CodeGraph index directory and everything under it to the given age; the
# directory's own mtime counts as use in this tree (prune_codegraph_indexes).
age_codegraph_index_files() {
    local item_name="$1" days="$2"
    find "${SESSION_BASE_DIR}/codegraph/${item_name}" -exec touch -d "${days} days ago" {} +
}

# The CodeGraph index mounts in a podman args log, one line each.
codegraph_mounts() {
    local args_log="$1"
    grep -- "${CODEGRAPH_MOUNT_SUFFIX}\$" "${args_log}" || true
}

@test "codegraph_index_dir_path is per work item, under SESSION_BASE_DIR/codegraph" {
    [ "$(codegraph_index_root_path)" = "${SESSION_BASE_DIR}/codegraph" ]
    [ "$(codegraph_index_dir_path Issue 42)" = "${SESSION_BASE_DIR}/codegraph/Issue_42" ]
    [ "$(codegraph_index_dir_path PullRequest 7)" = "${SESSION_BASE_DIR}/codegraph/PullRequest_7" ]
}

@test "invoke_claude creates the item's CodeGraph index directory with mode 0700 and mounts it at the checkout's .codegraph" {
    local args_log="${TEST_TMP}/podman_args"
    stub_podman_run_logging_args "${args_log}"
    invoke_claude "test prompt" "Issue" "42" "# per-item instructions" 2>/dev/null
    local index_dir="${SESSION_BASE_DIR}/codegraph/Issue_42"
    [ "$(codegraph_mounts "${args_log}")" = "${index_dir}${CODEGRAPH_MOUNT_SUFFIX}" ]
    [ -d "${index_dir}" ]
    [ "$(stat -c %a "${index_dir}")" = "700" ]
    [ "$(stat -c %a "${SESSION_BASE_DIR}/codegraph")" = "700" ]
}

@test "the index is kept across runs of the same item and survives the checkout's git clean -fdX" {
    local args_log="${TEST_TMP}/podman_args"
    stub_podman_run_logging_args "${args_log}"
    git -C "${REPO_WORK_DIR}" init -q
    printf '.codegraph/\n' > "${REPO_WORK_DIR}/.gitignore"
    make_codegraph_index "Issue_42"

    invoke_claude "test prompt" "Issue" "42" "# per-item instructions" 2>/dev/null
    # The empty mountpoint podman leaves in the checkout is what the clean after a session removes.
    mkdir -p "${REPO_WORK_DIR}/.codegraph"
    git -C "${REPO_WORK_DIR}" clean -q -fdX
    invoke_claude "test prompt" "Issue" "42" "# per-item instructions" 2>/dev/null

    [ ! -e "${REPO_WORK_DIR}/.codegraph" ]
    [ "$(cat "${SESSION_BASE_DIR}/codegraph/Issue_42/codegraph.db")" = "index" ]
    [ "$(codegraph_mounts "${args_log}" | sort -u)" = "${SESSION_BASE_DIR}/codegraph/Issue_42${CODEGRAPH_MOUNT_SUFFIX}" ]
    [ "$(codegraph_mounts "${args_log}" | wc -l)" -eq 2 ]
}

@test "a different work item gets its own empty index directory, so the entrypoint runs a fresh init" {
    local args_log="${TEST_TMP}/podman_args"
    stub_podman_run_logging_args "${args_log}"
    make_codegraph_index "Issue_42"

    invoke_claude "test prompt" "Issue" "43" "# per-item instructions" 2>/dev/null

    [ "$(codegraph_mounts "${args_log}")" = "${SESSION_BASE_DIR}/codegraph/Issue_43${CODEGRAPH_MOUNT_SUFFIX}" ]
    [ ! -e "${SESSION_BASE_DIR}/codegraph/Issue_43/codegraph.db" ]
    [ -f "${SESSION_BASE_DIR}/codegraph/Issue_42/codegraph.db" ]
}

@test "invoke_claude warns and launches without the index mount when the index directory cannot be created" {
    local args_log="${TEST_TMP}/podman_args"
    stub_podman_run_logging_args "${args_log}"
    mkdir -p "${SESSION_BASE_DIR}"
    printf 'not a directory\n' > "${SESSION_BASE_DIR}/codegraph"
    run invoke_claude "test prompt" "Issue" "42" "# per-item instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Failed to create CodeGraph index directory: ${SESSION_BASE_DIR}/codegraph/Issue_42 - this session's index will not be kept"* ]]
    [ "$(grep -cx 'run' "${args_log}")" -eq 1 ]
    [ -z "$(codegraph_mounts "${args_log}")" ]
}

@test "invoke_claude warns and launches without the index mount when the checkout tracks files under .codegraph" {
    local args_log="${TEST_TMP}/podman_args"
    stub_podman_run_logging_args "${args_log}"
    git -C "${REPO_WORK_DIR}" init -q
    mkdir -p "${REPO_WORK_DIR}/.codegraph"
    printf '*\n' > "${REPO_WORK_DIR}/.codegraph/.gitignore"
    # -f because the file ignores itself, as the one codegraph init writes does.
    git -C "${REPO_WORK_DIR}" add -f .codegraph/.gitignore
    run invoke_claude "test prompt" "Issue" "42" "# per-item instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"The checkout tracks files under .codegraph, so the CodeGraph index is not mounted over them - this session runs without a CodeGraph index"* ]]
    [ "$(grep -cx 'run' "${args_log}")" -eq 1 ]
    [ -z "$(codegraph_mounts "${args_log}")" ]
    [ ! -e "${SESSION_BASE_DIR}/codegraph/Issue_42" ]
    [ -f "${REPO_WORK_DIR}/.codegraph/.gitignore" ]
}

@test "invoke_claude mounts the index when the checkout has untracked files under .codegraph" {
    local args_log="${TEST_TMP}/podman_args"
    stub_podman_run_logging_args "${args_log}"
    git -C "${REPO_WORK_DIR}" init -q
    mkdir -p "${REPO_WORK_DIR}/.codegraph"
    printf '*\n' > "${REPO_WORK_DIR}/.codegraph/.gitignore"
    run invoke_claude "test prompt" "Issue" "42" "# per-item instructions"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"The checkout tracks files under .codegraph"* ]]
    [ "$(codegraph_mounts "${args_log}")" = "${SESSION_BASE_DIR}/codegraph/Issue_42${CODEGRAPH_MOUNT_SUFFIX}" ]
}

@test "invoke_claude purges an idle item's CodeGraph index before launching and keeps a fresh one" {
    local args_log="${TEST_TMP}/podman_args"
    stub_podman_run_logging_args "${args_log}"
    make_codegraph_index "Issue_5"
    age_codegraph_index_files "Issue_5" 15
    make_codegraph_index "Issue_6"
    age_codegraph_index_files "Issue_6" 8
    invoke_claude "test prompt" "Issue" "42" "# per-item instructions" 2>/dev/null
    [ ! -e "${SESSION_BASE_DIR}/codegraph/Issue_5" ]
    [ -f "${SESSION_BASE_DIR}/codegraph/Issue_6/codegraph.db" ]
    [ -d "${SESSION_BASE_DIR}/codegraph/Issue_42" ]
}

@test "prune_codegraph_indexes keeps an index used within the window whose files are all older" {
    make_codegraph_index "Issue_5"
    age_codegraph_index_files "Issue_5" 20
    # A session that only queries the index writes no file, but its mount touches the directory.
    touch -d '10 days ago' "${SESSION_BASE_DIR}/codegraph/Issue_5"
    run prune_codegraph_indexes
    [ "${status}" -eq 0 ]
    [ -f "${SESSION_BASE_DIR}/codegraph/Issue_5/codegraph.db" ]
}

@test "prune_codegraph_indexes removes an index not used for longer than the window" {
    make_codegraph_index "Issue_5"
    age_codegraph_index_files "Issue_5" 20
    touch -d '15 days ago' "${SESSION_BASE_DIR}/codegraph/Issue_5"
    run prune_codegraph_indexes
    [ "${status}" -eq 0 ]
    [ ! -e "${SESSION_BASE_DIR}/codegraph/Issue_5" ]
}

@test "prune_codegraph_indexes judges an index directory with no file by the directory's own age" {
    mkdir -p "${SESSION_BASE_DIR}/codegraph/Issue_5" "${SESSION_BASE_DIR}/codegraph/Issue_6"
    touch -d '15 days ago' "${SESSION_BASE_DIR}/codegraph/Issue_5"
    touch -d '10 days ago' "${SESSION_BASE_DIR}/codegraph/Issue_6"
    run prune_codegraph_indexes
    [ "${status}" -eq 0 ]
    [ ! -e "${SESSION_BASE_DIR}/codegraph/Issue_5" ]
    [ -d "${SESSION_BASE_DIR}/codegraph/Issue_6" ]
}

@test "invoke_claude records the session's use of the index, so an index only queried is not purged as idle" {
    local args_log="${TEST_TMP}/podman_args"
    stub_podman_run_logging_args "${args_log}"
    make_codegraph_index "Issue_42"
    age_codegraph_index_files "Issue_42" 10
    invoke_claude "test prompt" "Issue" "42" "# per-item instructions" 2>/dev/null
    local index_dir="${SESSION_BASE_DIR}/codegraph/Issue_42"
    [ -n "$(find "${index_dir}" -maxdepth 0 -mmin -5)" ]
    # The index's own files are left as CodeGraph wrote them.
    [ -z "$(find "${index_dir}" -type f -mmin -5)" ]
    # Ten more days without a session would otherwise purge it, measured from its files.
    find "${index_dir}" -type f -exec touch -d '20 days ago' {} +
    run prune_codegraph_indexes
    [ "${status}" -eq 0 ]
    [ -f "${index_dir}/codegraph.db" ]
}

@test "invoke_claude records use through a pivoted PR's link on the Issue's index directory" {
    local args_log="${TEST_TMP}/podman_args"
    stub_podman_run_logging_args "${args_log}"
    make_codegraph_index "Issue_42"
    age_codegraph_index_files "Issue_42" 10
    ln -s "Issue_42" "${SESSION_BASE_DIR}/codegraph/PullRequest_7"
    invoke_claude "test prompt" "PullRequest" "7" "# per-item instructions" 2>/dev/null
    [ -n "$(find "${SESSION_BASE_DIR}/codegraph/Issue_42" -maxdepth 0 -mmin -5)" ]
    [ -L "${SESSION_BASE_DIR}/codegraph/PullRequest_7" ]
}

@test "add_codegraph_index_podman_args warns and still mounts the index when its use cannot be recorded" {
    mkdir -p "${TEST_TMP}/failing-touch"
    printf '#!/bin/sh\nexit 1\n' > "${TEST_TMP}/failing-touch/touch"
    chmod +x "${TEST_TMP}/failing-touch/touch"
    mount_with_failing_touch() {
        PATH="${TEST_TMP}/failing-touch:${PATH}"
        PODMAN_RUN_ARGS=()
        add_codegraph_index_podman_args "Issue" "42"
        printf '%s\n' "${PODMAN_RUN_ARGS[@]}"
    }
    run mount_with_failing_touch
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Failed to record use of CodeGraph index directory ${SESSION_BASE_DIR}/codegraph/Issue_42, so it may be purged as idle"* ]]
    [[ "${output}" == *"${SESSION_BASE_DIR}/codegraph/Issue_42${CODEGRAPH_MOUNT_SUFFIX}"* ]]
}

@test "prune_codegraph_indexes warns in CodeGraph terms when a purge or a link removal fails" {
    make_codegraph_index "Issue_15"
    age_codegraph_index_files "Issue_15" 15
    ln -s "Issue_99" "${SESSION_BASE_DIR}/codegraph/PullRequest_98"
    # Defined inside the function so the failing rm only exists in run's subshell and never
    # reaches teardown, which needs the real rm.
    prune_with_failing_deletes() {
        rm() { return 1; }
        prune_codegraph_indexes
    }
    run prune_with_failing_deletes
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Failed to purge CodeGraph index files at ${SESSION_BASE_DIR}/codegraph/Issue_15 - will retry on the next launch"* ]]
    [[ "${output}" == *"Failed to remove CodeGraph index link at ${SESSION_BASE_DIR}/codegraph/PullRequest_98 - will retry on the next launch"* ]]
}

@test "prune_codegraph_indexes removes a dangling link and is a no-op when the tree does not exist" {
    run prune_codegraph_indexes
    [ "${status}" -eq 0 ]
    [ ! -e "${SESSION_BASE_DIR}/codegraph" ]
    mkdir -p "${SESSION_BASE_DIR}/codegraph"
    ln -s "Issue_99" "${SESSION_BASE_DIR}/codegraph/PullRequest_98"
    run prune_codegraph_indexes
    [ "${status}" -eq 0 ]
    [ ! -L "${SESSION_BASE_DIR}/codegraph/PullRequest_98" ]
}

@test "link_pivot_pr_codegraph_index links the PR's index directory to the Issue's and records pivot activity" {
    local issue_dir="${SESSION_BASE_DIR}/codegraph/Issue_10"
    make_codegraph_index "Issue_10"
    age_codegraph_index_files "Issue_10" 15
    run link_pivot_pr_codegraph_index "10" "99"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    [ "$(readlink "${SESSION_BASE_DIR}/codegraph/PullRequest_99")" = "Issue_10" ]
    # The activity is the directory's own mtime: nothing is written into CodeGraph's .codegraph.
    [ -n "$(find "${issue_dir}" -maxdepth 0 -mmin -1 -print)" ]
    [ "$(find "${issue_dir}" -mindepth 1 -printf '%P\n')" = "codegraph.db" ]
    # The pivot's activity keeps the Issue's idle index through the prune before the launch.
    run prune_codegraph_indexes
    [ -f "${SESSION_BASE_DIR}/codegraph/PullRequest_99/codegraph.db" ]
}

@test "link_pivot_pr_codegraph_index keeps a new empty Issue index directory empty" {
    run link_pivot_pr_codegraph_index "10" "99"
    [ "${status}" -eq 0 ]
    [ -d "${SESSION_BASE_DIR}/codegraph/Issue_10" ]
    [ -z "$(find "${SESSION_BASE_DIR}/codegraph/Issue_10" -mindepth 1 -print -quit)" ]
    [ "$(readlink "${SESSION_BASE_DIR}/codegraph/PullRequest_99")" = "Issue_10" ]
}

@test "link_pivot_pr_codegraph_index warns and still links when pivot activity cannot be recorded" {
    make_stub touch "exit 1"
    run link_pivot_pr_codegraph_index "10" "99"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Failed to record pivot activity in ${SESSION_BASE_DIR}/codegraph/Issue_10, so Issue #10 CodeGraph index files may be purged as idle"* ]]
    [ "$(readlink "${SESSION_BASE_DIR}/codegraph/PullRequest_99")" = "Issue_10" ]
}

@test "link_pivot_pr_codegraph_index keeps a PR index of its own and says so in CodeGraph terms" {
    make_codegraph_index "PullRequest_99"
    run link_pivot_pr_codegraph_index "10" "99"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PR #99 already has CodeGraph index files of its own at ${SESSION_BASE_DIR}/codegraph/PullRequest_99, so they are kept and not linked to Issue #10"* ]]
    [ ! -L "${SESSION_BASE_DIR}/codegraph/PullRequest_99" ]
}

@test "invoke_claude mounts a pivoted PR's linked index directory, so the PR reuses the Issue's index" {
    local args_log="${TEST_TMP}/podman_args"
    stub_podman_run_logging_args "${args_log}"
    make_codegraph_index "Issue_10"
    link_pivot_pr_codegraph_index "10" "99"
    invoke_claude "test prompt" "PullRequest" "99" "# per-item instructions" 2>/dev/null
    [ "$(codegraph_mounts "${args_log}")" = "${SESSION_BASE_DIR}/codegraph/PullRequest_99${CODEGRAPH_MOUNT_SUFFIX}" ]
    [ "$(readlink "${SESSION_BASE_DIR}/codegraph/PullRequest_99")" = "Issue_10" ]
    [ -f "${SESSION_BASE_DIR}/codegraph/Issue_10/codegraph.db" ]
}

@test "main links the CodeGraph index of the PR an Issue pivots to into the Issue's directory" {
    setup_main_pivot_mocks
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[{"name":"Blocked"}],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[],"closingIssuesReferences":[{"number":10}]}\n'; }
    pr_json_has_blocked_label() { return 0; }
    try_auto_unblock_env_diagnosed_pr() { return 1; }

    run main
    [ "${status}" -eq 0 ]
    [ "$(readlink "${SESSION_BASE_DIR}/codegraph/PullRequest_99")" = "Issue_10" ]
    [ -d "${SESSION_BASE_DIR}/codegraph/Issue_10" ]
}
