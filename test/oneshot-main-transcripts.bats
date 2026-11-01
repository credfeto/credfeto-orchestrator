#!/usr/bin/env bats
# shellcheck disable=SC2329  # functions in @test bodies are invoked indirectly via 'run'
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are used inside run() subshells where shellcheck cannot trace them

bats_require_minimum_version 1.5.0

load test_helper
load oneshot_helper

# --- session transcripts: per-item mount and age-based retention purge ----------------------

make_transcript_dir() {
    local item_name="$1"
    mkdir -p "${SESSION_BASE_DIR}/transcripts/${item_name}/-workspace-repo"
    printf '{}\n' > "${SESSION_BASE_DIR}/transcripts/${item_name}/-workspace-repo/session.jsonl"
}

# Sets every file under an item's transcript directory (not the directories) to the given age.
age_transcript_files() {
    local item_name="$1" days="$2"
    find "${SESSION_BASE_DIR}/transcripts/${item_name}" -type f -exec touch -d "${days} days ago" {} +
}

# The PR is open and Blocked, so main stops at the Blocked check without a container launch.
stub_pr_open_blocked() {
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[{"name":"Blocked"}],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[],"closingIssuesReferences":[{"number":10}]}\n'; }
    pr_json_has_blocked_label() { return 0; }
    try_auto_unblock_env_diagnosed_pr() { return 1; }
}

@test "transcripts_root_path is the transcripts directory under SESSION_BASE_DIR" {
    [ "$(transcripts_root_path)" = "${SESSION_BASE_DIR}/transcripts" ]
}

@test "transcript_dir_path is per work item, under SESSION_BASE_DIR/transcripts" {
    [ "$(transcript_dir_path Issue 42)" = "${SESSION_BASE_DIR}/transcripts/Issue_42" ]
    [ "$(transcript_dir_path PullRequest 7)" = "${SESSION_BASE_DIR}/transcripts/PullRequest_7" ]
}

@test "invoke_claude mounts the item's own transcript directory at ~/.claude/projects with mode 0700" {
    local args_log="${TEST_TMP}/podman_args"
    stub_podman_run_logging_args "${args_log}"
    invoke_claude "test prompt" "Issue" "42" "# per-item instructions" 2>/dev/null
    local transcript_dir="${SESSION_BASE_DIR}/transcripts/Issue_42"
    grep -qx "${transcript_dir}:/home/developer/.claude/projects:rw" "${args_log}"
    [ "$(grep -c ':/home/developer/.claude/projects:rw$' "${args_log}")" -eq 1 ]
    [ "$(stat -c %a "${transcript_dir}")" = "700" ]
    [ "$(stat -c %a "${SESSION_BASE_DIR}/transcripts")" = "700" ]
}

@test "invoke_claude tightens an existing transcript directory to mode 0700" {
    local args_log="${TEST_TMP}/podman_args"
    stub_podman_run_logging_args "${args_log}"
    mkdir -p "${SESSION_BASE_DIR}/transcripts/PullRequest_7"
    chmod 0755 "${SESSION_BASE_DIR}/transcripts" "${SESSION_BASE_DIR}/transcripts/PullRequest_7"
    invoke_claude "test prompt" "PullRequest" "7" "# per-item instructions" 2>/dev/null
    [ "$(stat -c %a "${SESSION_BASE_DIR}/transcripts/PullRequest_7")" = "700" ]
    [ "$(stat -c %a "${SESSION_BASE_DIR}/transcripts")" = "700" ]
}

@test "invoke_claude dies without launching the container when the transcript directory cannot be created" {
    local args_log="${TEST_TMP}/podman_args"
    stub_podman_run_logging_args "${args_log}"
    mkdir -p "${SESSION_BASE_DIR}"
    printf 'not a directory\n' > "${SESSION_BASE_DIR}/transcripts"
    run invoke_claude "test prompt" "Issue" "42" "# per-item instructions"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Failed to create transcript directory: ${SESSION_BASE_DIR}/transcripts/Issue_42"* ]]
    [ "$(grep -cx 'run' "${args_log}")" -eq 0 ]
}

@test "invoke_claude purges an idle item's transcripts before launching" {
    local args_log="${TEST_TMP}/podman_args"
    stub_podman_run_logging_args "${args_log}"
    make_transcript_dir "Issue_5"
    age_transcript_files "Issue_5" 15
    invoke_claude "test prompt" "Issue" "42" "# per-item instructions" 2>/dev/null
    [ ! -e "${SESSION_BASE_DIR}/transcripts/Issue_5" ]
    [ -d "${SESSION_BASE_DIR}/transcripts/Issue_42" ]
}

@test "prune_transcripts is a no-op that succeeds when the transcripts tree does not exist" {
    rm -rf "${SESSION_BASE_DIR}"
    run prune_transcripts
    [ "${status}" -eq 0 ]
    [ ! -e "${SESSION_BASE_DIR}" ]
}

@test "prune_transcripts keeps an item directory with a recently modified file" {
    make_transcript_dir "Issue_10"
    run prune_transcripts
    [ "${status}" -eq 0 ]
    [ -f "${SESSION_BASE_DIR}/transcripts/Issue_10/-workspace-repo/session.jsonl" ]
}

@test "prune_transcripts keeps an item directory whose files are days old but still within the retention window" {
    make_transcript_dir "Issue_10"
    age_transcript_files "Issue_10" 8
    run prune_transcripts
    [ "${status}" -eq 0 ]
    [ -f "${SESSION_BASE_DIR}/transcripts/Issue_10/-workspace-repo/session.jsonl" ]
}

@test "prune_transcripts removes an item directory whose files are all older than the item window, whatever the directory's own mtime" {
    make_transcript_dir "Issue_10"
    printf '{}\n' > "${SESSION_BASE_DIR}/transcripts/Issue_10/-workspace-repo/other.jsonl"
    age_transcript_files "Issue_10" 15
    # The directories stay fresh: appending to a transcript does not change them, so they are
    # not evidence of recent work.
    touch "${SESSION_BASE_DIR}/transcripts/Issue_10" "${SESSION_BASE_DIR}/transcripts/Issue_10/-workspace-repo"
    run prune_transcripts
    [ "${status}" -eq 0 ]
    [ ! -e "${SESSION_BASE_DIR}/transcripts/Issue_10" ]
}

@test "prune_transcripts keeps an item directory with one recent file among old ones" {
    make_transcript_dir "Issue_10"
    age_transcript_files "Issue_10" 15
    printf '{}\n' > "${SESSION_BASE_DIR}/transcripts/Issue_10/-workspace-repo/new.jsonl"
    run prune_transcripts
    [ "${status}" -eq 0 ]
    [ -f "${SESSION_BASE_DIR}/transcripts/Issue_10/-workspace-repo/session.jsonl" ]
    [ -f "${SESSION_BASE_DIR}/transcripts/Issue_10/-workspace-repo/new.jsonl" ]
}

@test "prune_transcripts ages an item directory with no files by its own mtime" {
    mkdir -p "${SESSION_BASE_DIR}/transcripts/Issue_10" "${SESSION_BASE_DIR}/transcripts/Issue_11/-workspace-repo" \
        "${SESSION_BASE_DIR}/transcripts/Issue_12"
    touch -d '15 days ago' "${SESSION_BASE_DIR}/transcripts/Issue_10" "${SESSION_BASE_DIR}/transcripts/Issue_11"
    run prune_transcripts
    [ "${status}" -eq 0 ]
    [ ! -e "${SESSION_BASE_DIR}/transcripts/Issue_10" ]
    [ ! -e "${SESSION_BASE_DIR}/transcripts/Issue_11" ]
    [ -d "${SESSION_BASE_DIR}/transcripts/Issue_12" ]
}

@test "prune_transcripts does not follow a link inside an item directory when ageing it, and never deletes through it" {
    make_transcript_dir "Issue_10"
    age_transcript_files "Issue_10" 15
    local outside="${TEST_TMP}/outside"
    mkdir -p "${outside}"
    printf 'keep\n' > "${outside}/fresh.jsonl"
    ln -s "${outside}" "${SESSION_BASE_DIR}/transcripts/Issue_10/-workspace-repo/elsewhere"
    run prune_transcripts
    [ "${status}" -eq 0 ]
    [ ! -e "${SESSION_BASE_DIR}/transcripts/Issue_10" ]
    [ -f "${outside}/fresh.jsonl" ]
}

@test "prune_transcripts never fails the run when a purge cannot delete" {
    make_transcript_dir "Issue_15"
    age_transcript_files "Issue_15" 15
    # Defined inside the function so the failing rm only exists in run's subshell and never
    # reaches teardown, which needs the real rm.
    prune_with_failing_deletes() {
        rm() { [ "$1" = "-rf" ] && return 1; command rm "$@"; }
        prune_transcripts
    }
    run prune_with_failing_deletes
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Failed to purge transcripts at ${SESSION_BASE_DIR}/transcripts/Issue_15 - will retry on the next launch"* ]]
    [ -d "${SESSION_BASE_DIR}/transcripts/Issue_15" ]
}

@test "prune_transcripts warns and keeps an item directory when its age cannot be read" {
    make_transcript_dir "Issue_15"
    age_transcript_files "Issue_15" 15
    # A failing find prints nothing, which must not be read as "nothing recent".
    prune_with_failing_find() {
        find() { return 1; }
        prune_transcripts
    }
    run prune_with_failing_find
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Failed to read transcripts at ${SESSION_BASE_DIR}/transcripts/Issue_15 to check their age - keeping them until the next launch"* ]]
    [ -f "${SESSION_BASE_DIR}/transcripts/Issue_15/-workspace-repo/session.jsonl" ]
}

# --- session transcripts: pivoted PR linked to its Issue's directory --------------------------

@test "link_pivot_pr_transcripts links the PR's transcript directory to the Issue's with a relative symlink" {
    run link_pivot_pr_transcripts "10" "99"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    [ -L "${SESSION_BASE_DIR}/transcripts/PullRequest_99" ]
    [ "$(readlink "${SESSION_BASE_DIR}/transcripts/PullRequest_99")" = "Issue_10" ]
    [ -d "${SESSION_BASE_DIR}/transcripts/Issue_10" ]
    [ ! -L "${SESSION_BASE_DIR}/transcripts/Issue_10" ]
    [ "$(stat -c %a "${SESSION_BASE_DIR}/transcripts/Issue_10")" = "700" ]
    [ "$(stat -c %a "${SESSION_BASE_DIR}/transcripts")" = "700" ]
}

@test "link_pivot_pr_transcripts keeps the Issue's existing transcripts and is idempotent" {
    make_transcript_dir "Issue_10"
    link_pivot_pr_transcripts "10" "99"
    run link_pivot_pr_transcripts "10" "99"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    [ "$(readlink "${SESSION_BASE_DIR}/transcripts/PullRequest_99")" = "Issue_10" ]
    [ -f "${SESSION_BASE_DIR}/transcripts/PullRequest_99/-workspace-repo/session.jsonl" ]
}

@test "link_pivot_pr_transcripts keeps a non-empty real PR transcript directory and says so" {
    make_transcript_dir "PullRequest_99"
    run link_pivot_pr_transcripts "10" "99"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PR #99 already has transcripts of its own at ${SESSION_BASE_DIR}/transcripts/PullRequest_99, so they are kept and not linked to Issue #10"* ]]
    [ ! -L "${SESSION_BASE_DIR}/transcripts/PullRequest_99" ]
    [ -f "${SESSION_BASE_DIR}/transcripts/PullRequest_99/-workspace-repo/session.jsonl" ]
}

@test "link_pivot_pr_transcripts keeps a real PR transcript directory holding only a dot-file" {
    mkdir -p "${SESSION_BASE_DIR}/transcripts/PullRequest_99"
    printf '{}\n' > "${SESSION_BASE_DIR}/transcripts/PullRequest_99/.hidden"
    run link_pivot_pr_transcripts "10" "99"
    [ "${status}" -eq 0 ]
    [ ! -L "${SESSION_BASE_DIR}/transcripts/PullRequest_99" ]
    [ -f "${SESSION_BASE_DIR}/transcripts/PullRequest_99/.hidden" ]
}

@test "link_pivot_pr_transcripts replaces an empty real PR transcript directory with the link" {
    mkdir -p "${SESSION_BASE_DIR}/transcripts/PullRequest_99"
    run link_pivot_pr_transcripts "10" "99"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    [ -L "${SESSION_BASE_DIR}/transcripts/PullRequest_99" ]
    [ "$(readlink "${SESSION_BASE_DIR}/transcripts/PullRequest_99")" = "Issue_10" ]
}

@test "link_pivot_pr_transcripts warns and still succeeds when an empty real PR transcript directory cannot be removed" {
    mkdir -p "${SESSION_BASE_DIR}/transcripts/PullRequest_99"
    make_stub rmdir "exit 1"
    run link_pivot_pr_transcripts "10" "99"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Failed to remove empty transcript directory ${SESSION_BASE_DIR}/transcripts/PullRequest_99, so PR #99 transcripts will not be linked to Issue #10"* ]]
    [ -d "${SESSION_BASE_DIR}/transcripts/PullRequest_99" ]
    [ ! -L "${SESSION_BASE_DIR}/transcripts/PullRequest_99" ]
}

@test "link_pivot_pr_transcripts leaves an existing non-directory PR transcript entry untouched" {
    mkdir -p "${SESSION_BASE_DIR}/transcripts"
    printf 'not a directory\n' > "${SESSION_BASE_DIR}/transcripts/PullRequest_99"
    run link_pivot_pr_transcripts "10" "99"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    [ -f "${SESSION_BASE_DIR}/transcripts/PullRequest_99" ]
    [ ! -L "${SESSION_BASE_DIR}/transcripts/PullRequest_99" ]
}

@test "link_pivot_pr_transcripts leaves an existing link to another Issue untouched" {
    make_transcript_dir "Issue_7"
    ln -s "Issue_7" "${SESSION_BASE_DIR}/transcripts/PullRequest_99"
    run link_pivot_pr_transcripts "10" "99"
    [ "${status}" -eq 0 ]
    [ "$(readlink "${SESSION_BASE_DIR}/transcripts/PullRequest_99")" = "Issue_7" ]
}

@test "link_pivot_pr_transcripts leaves a dangling link untouched" {
    mkdir -p "${SESSION_BASE_DIR}/transcripts"
    ln -s "Issue_7" "${SESSION_BASE_DIR}/transcripts/PullRequest_99"
    run link_pivot_pr_transcripts "10" "99"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    [ "$(readlink "${SESSION_BASE_DIR}/transcripts/PullRequest_99")" = "Issue_7" ]
    [ ! -e "${SESSION_BASE_DIR}/transcripts/Issue_7" ]
}

@test "link_pivot_pr_transcripts recreates the Issue directory a dangling link to it points at" {
    mkdir -p "${SESSION_BASE_DIR}/transcripts"
    ln -s "Issue_10" "${SESSION_BASE_DIR}/transcripts/PullRequest_99"
    run link_pivot_pr_transcripts "10" "99"
    [ "${status}" -eq 0 ]
    [ -d "${SESSION_BASE_DIR}/transcripts/PullRequest_99" ]
    [ "$(readlink "${SESSION_BASE_DIR}/transcripts/PullRequest_99")" = "Issue_10" ]
}

@test "link_pivot_pr_transcripts warns and still succeeds when the Issue directory cannot be created" {
    mkdir -p "${SESSION_BASE_DIR}"
    printf 'not a directory\n' > "${SESSION_BASE_DIR}/transcripts"
    run link_pivot_pr_transcripts "10" "99"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Failed to create transcript directory ${SESSION_BASE_DIR}/transcripts/Issue_10, so PR #99 transcripts will not be linked to Issue #10"* ]]
}

@test "link_pivot_pr_transcripts warns and still succeeds when the link cannot be created" {
    make_stub ln "exit 1"
    run link_pivot_pr_transcripts "10" "99"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Failed to link PR #99 transcripts to Issue #10, so they will be kept in a directory of their own"* ]]
    [ ! -e "${SESSION_BASE_DIR}/transcripts/PullRequest_99" ]
    [ ! -L "${SESSION_BASE_DIR}/transcripts/PullRequest_99" ]
}

@test "link_pivot_pr_transcripts records pivot activity in the Issue directory and refreshes it on each call" {
    local activity_file="${SESSION_BASE_DIR}/transcripts/Issue_10/${TRANSCRIPT_PIVOT_ACTIVITY_FILE_NAME}"
    link_pivot_pr_transcripts "10" "99"
    [ -f "${activity_file}" ]
    touch -d '15 days ago' "${activity_file}"
    run link_pivot_pr_transcripts "10" "99"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    [ -n "$(find "${activity_file}" -mmin -1 -print)" ]
}

@test "link_pivot_pr_transcripts keeps an idle Issue directory alive through the prune that follows the pivot" {
    make_transcript_dir "Issue_10"
    # Aged before the pivot: ageing after it would age the activity file too.
    age_transcript_files "Issue_10" 15
    link_pivot_pr_transcripts "10" "99"
    run prune_transcripts
    [ "${status}" -eq 0 ]
    [ -f "${SESSION_BASE_DIR}/transcripts/Issue_10/-workspace-repo/session.jsonl" ]
    [ "$(readlink "${SESSION_BASE_DIR}/transcripts/PullRequest_99")" = "Issue_10" ]
    [ -f "${SESSION_BASE_DIR}/transcripts/PullRequest_99/-workspace-repo/session.jsonl" ]
}

@test "link_pivot_pr_transcripts warns and still links when pivot activity cannot be recorded" {
    make_stub touch "exit 1"
    run link_pivot_pr_transcripts "10" "99"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Failed to record pivot activity in ${SESSION_BASE_DIR}/transcripts/Issue_10, so Issue #10 transcripts may be purged as idle"* ]]
    [ "$(readlink "${SESSION_BASE_DIR}/transcripts/PullRequest_99")" = "Issue_10" ]
}

@test "main links the transcripts of the PR an Issue pivots to into the Issue's directory" {
    setup_main_pivot_mocks
    stub_pr_open_blocked

    run main
    [ "${status}" -eq 0 ]
    [ "$(readlink "${SESSION_BASE_DIR}/transcripts/PullRequest_99")" = "Issue_10" ]
    [ -d "${SESSION_BASE_DIR}/transcripts/Issue_10" ]
}

@test "main links a pivoted PR's transcripts to the Issue it closes, not the Issue being processed" {
    setup_main_pivot_mocks
    stub_pr_open_blocked
    # The feed lists Issue #10, but the repository's open bot PR #99 closes #20.
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[{"name":"Blocked"}],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[],"closingIssuesReferences":[{"number":20}]}\n'; }

    run main
    [ "${status}" -eq 0 ]
    [ "$(readlink "${SESSION_BASE_DIR}/transcripts/PullRequest_99")" = "Issue_20" ]
    [ -d "${SESSION_BASE_DIR}/transcripts/Issue_20" ]
    [ ! -e "${SESSION_BASE_DIR}/transcripts/Issue_10" ]
}

@test "main does not link a pivoted PR's transcripts when the PR closes no Issue" {
    setup_main_pivot_mocks
    stub_pr_open_blocked
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[{"name":"Blocked"}],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[],"closingIssuesReferences":[]}\n'; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PR #99 in org/repo does not close any Issue in the repository, so its transcripts are not linked to an Issue's"* ]]
    [[ "${output}" == *"PR #99 in org/repo is blocked"* ]]
    [ ! -e "${SESSION_BASE_DIR}/transcripts/PullRequest_99" ]
    [ ! -L "${SESSION_BASE_DIR}/transcripts/PullRequest_99" ]
    [ ! -e "${SESSION_BASE_DIR}/transcripts/Issue_10" ]
}

@test "main links a pivoted PR's transcripts to the lowest-numbered Issue when the PR closes more than one" {
    setup_main_pivot_mocks
    stub_pr_open_blocked
    fetch_pr_json() { printf '{"state":"OPEN","title":"T","body":"","isDraft":false,"labels":[{"name":"Blocked"}],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[],"closingIssuesReferences":[{"number":30},{"number":20},{"number":25}]}\n'; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"does not close any Issue in the repository"* ]]
    [ "$(readlink "${SESSION_BASE_DIR}/transcripts/PullRequest_99")" = "Issue_20" ]
    [ -d "${SESSION_BASE_DIR}/transcripts/Issue_20" ]
    [ ! -e "${SESSION_BASE_DIR}/transcripts/Issue_25" ]
    [ ! -e "${SESSION_BASE_DIR}/transcripts/Issue_30" ]
}

@test "pr_json_lowest_closing_issue prints the Issue the PR closes when it closes only one" {
    run pr_json_lowest_closing_issue '{"closingIssuesReferences":[{"number":164}]}' "org/repo"
    [ "${status}" -eq 0 ]
    [ "${output}" = "164" ]
}

@test "pr_json_lowest_closing_issue counts a reference in the same repository, matched case-insensitively" {
    run pr_json_lowest_closing_issue '{"closingIssuesReferences":[{"number":164,"repository":{"owner":{"login":"Org"},"name":"Repo"}}]}' "org/repo"
    [ "${status}" -eq 0 ]
    [ "${output}" = "164" ]
}

@test "pr_json_lowest_closing_issue ignores a reference to another repository" {
    run pr_json_lowest_closing_issue '{"closingIssuesReferences":[{"number":7,"repository":{"owner":{"login":"org"},"name":"other"}},{"number":164,"repository":{"owner":{"login":"org"},"name":"repo"}}]}' "org/repo"
    [ "${status}" -eq 0 ]
    [ "${output}" = "164" ]
    run pr_json_lowest_closing_issue '{"closingIssuesReferences":[{"number":7,"repository":{"owner":{"login":"org"},"name":"other"}}]}' "org/repo"
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
}

@test "pr_json_lowest_closing_issue counts the same Issue referenced twice as one" {
    run pr_json_lowest_closing_issue '{"closingIssuesReferences":[{"number":164},{"number":164}]}' "org/repo"
    [ "${status}" -eq 0 ]
    [ "${output}" = "164" ]
}

@test "pr_json_lowest_closing_issue prints the lowest-numbered Issue when the PR closes several" {
    run pr_json_lowest_closing_issue '{"closingIssuesReferences":[{"number":200},{"number":9},{"number":164},{"number":9}]}' "org/repo"
    [ "${status}" -eq 0 ]
    [ "${output}" = "9" ]
}

@test "pr_json_lowest_closing_issue picks the lowest-numbered Issue in this repository, ignoring a lower one elsewhere" {
    run pr_json_lowest_closing_issue '{"closingIssuesReferences":[{"number":3,"repository":{"owner":{"login":"org"},"name":"other"}},{"number":164,"repository":{"owner":{"login":"ORG"},"name":"REPO"}},{"number":50}]}' "org/repo"
    [ "${status}" -eq 0 ]
    [ "${output}" = "50" ]
}

@test "pr_json_lowest_closing_issue fails when the PR closes no Issue, or the field is absent or malformed" {
    local pr_json
    for pr_json in '{"closingIssuesReferences":[]}' '{"closingIssuesReferences":null}' '{}' \
        '{"closingIssuesReferences":[{"number":"x"}]}' '{"closingIssuesReferences":[{}]}' \
        '{"closingIssuesReferences":[{"number":"x"},{"number":5}]}' 'not json'; do
        run pr_json_lowest_closing_issue "${pr_json}" "org/repo"
        [ "${status}" -eq 1 ]
        [ -z "${output}" ]
    done
}

@test "fetch_pr_json asks gh for closingIssuesReferences in the same call" {
    make_stub gh 'printf "%s\n" "$*" >> "'"${TEST_TMP}"'/gh_args"; printf "{}"'
    fetch_pr_json 42 > /dev/null
    [ "$(wc -l < "${TEST_TMP}/gh_args")" -eq 1 ]
    grep -q "closingIssuesReferences" "${TEST_TMP}/gh_args"
}

@test "main still processes a pivoted PR when its transcripts cannot be linked" {
    setup_main_pivot_mocks
    stub_pr_open_blocked
    make_stub ln "exit 1"

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Failed to link PR #99 transcripts to Issue #10"* ]]
    [[ "${output}" == *"PR #99 in org/repo is blocked"* ]]
}

@test "invoke_claude mounts a pivoted PR's linked transcript directory and tightens the Issue directory it points at" {
    local args_log="${TEST_TMP}/podman_args"
    stub_podman_run_logging_args "${args_log}"
    make_transcript_dir "Issue_10"
    ln -s "Issue_10" "${SESSION_BASE_DIR}/transcripts/PullRequest_99"
    chmod 0755 "${SESSION_BASE_DIR}/transcripts" "${SESSION_BASE_DIR}/transcripts/Issue_10"
    invoke_claude "test prompt" "PullRequest" "99" "# per-item instructions" 2>/dev/null
    grep -qx "${SESSION_BASE_DIR}/transcripts/PullRequest_99:/home/developer/.claude/projects:rw" "${args_log}"
    [ -L "${SESSION_BASE_DIR}/transcripts/PullRequest_99" ]
    [ "$(readlink "${SESSION_BASE_DIR}/transcripts/PullRequest_99")" = "Issue_10" ]
    [ "$(stat -c %a "${SESSION_BASE_DIR}/transcripts/Issue_10")" = "700" ]
    [ "$(stat -c %a "${SESSION_BASE_DIR}/transcripts")" = "700" ]
    [ -f "${SESSION_BASE_DIR}/transcripts/Issue_10/-workspace-repo/session.jsonl" ]
}

@test "prune_transcripts removes a dangling link" {
    mkdir -p "${SESSION_BASE_DIR}/transcripts"
    ln -s "Issue_10" "${SESSION_BASE_DIR}/transcripts/PullRequest_99"
    run prune_transcripts
    [ "${status}" -eq 0 ]
    [ ! -L "${SESSION_BASE_DIR}/transcripts/PullRequest_99" ]
}

@test "prune_transcripts removes a link left dangling by the same pass's purge of its Issue" {
    make_transcript_dir "Issue_10"
    age_transcript_files "Issue_10" 15
    ln -s "Issue_10" "${SESSION_BASE_DIR}/transcripts/PullRequest_99"
    run prune_transcripts
    [ "${status}" -eq 0 ]
    [ ! -e "${SESSION_BASE_DIR}/transcripts/Issue_10" ]
    [ ! -L "${SESSION_BASE_DIR}/transcripts/PullRequest_99" ]
}

@test "prune_transcripts keeps a live link and its target's files, however old the link is" {
    make_transcript_dir "Issue_10"
    ln -s "Issue_10" "${SESSION_BASE_DIR}/transcripts/PullRequest_99"
    touch -h -d '30 days ago' "${SESSION_BASE_DIR}/transcripts/PullRequest_99"
    run prune_transcripts
    [ "${status}" -eq 0 ]
    [ "$(readlink "${SESSION_BASE_DIR}/transcripts/PullRequest_99")" = "Issue_10" ]
    [ -f "${SESSION_BASE_DIR}/transcripts/Issue_10/-workspace-repo/session.jsonl" ]
}

@test "prune_transcripts never deletes through a live link to a directory outside the transcripts tree" {
    local outside="${TEST_TMP}/outside"
    mkdir -p "${outside}" "${SESSION_BASE_DIR}/transcripts"
    printf '{}\n' > "${outside}/old.jsonl"
    touch -d '30 days ago' "${outside}/old.jsonl" "${outside}"
    ln -s "${outside}" "${SESSION_BASE_DIR}/transcripts/PullRequest_99"
    run prune_transcripts
    [ "${status}" -eq 0 ]
    [ -L "${SESSION_BASE_DIR}/transcripts/PullRequest_99" ]
    [ -f "${outside}/old.jsonl" ]
}

@test "prune_transcripts warns when a dangling link cannot be removed" {
    mkdir -p "${SESSION_BASE_DIR}/transcripts"
    ln -s "Issue_10" "${SESSION_BASE_DIR}/transcripts/PullRequest_99"
    # Defined inside the function so the failing rm only exists in run's subshell and never
    # reaches teardown, which needs the real rm.
    prune_with_failing_link_delete() {
        rm() { [ "$2" = "${SESSION_BASE_DIR}/transcripts/PullRequest_99" ] && return 1; command rm "$@"; }
        prune_transcripts
    }
    run prune_with_failing_link_delete
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Failed to remove transcript link at ${SESSION_BASE_DIR}/transcripts/PullRequest_99 - will retry on the next launch"* ]]
    [ -L "${SESSION_BASE_DIR}/transcripts/PullRequest_99" ]
}

@test "prune_transcripts never calls gh, including when it removes directories and links" {
    local gh_log="${TEST_TMP}/gh_calls"
    make_stub gh "printf '%s\n' \"\$*\" >> \"${gh_log}\"; exit 1"
    make_transcript_dir "Issue_10"
    age_transcript_files "Issue_10" 15
    ln -s "Issue_10" "${SESSION_BASE_DIR}/transcripts/PullRequest_99"
    make_transcript_dir "Issue_11"
    ln -s "Issue_11" "${SESSION_BASE_DIR}/transcripts/PullRequest_100"
    run prune_transcripts
    [ "${status}" -eq 0 ]
    [ ! -e "${gh_log}" ]
    [ ! -e "${SESSION_BASE_DIR}/transcripts/Issue_10" ]
    [ ! -L "${SESSION_BASE_DIR}/transcripts/PullRequest_99" ]
    [ -L "${SESSION_BASE_DIR}/transcripts/PullRequest_100" ]
}

# --- a clean review the session reported but did not record (#1735) ---------------------------

@test "claude_result_indicates_clean_review matches clean security review reports" {
    claude_result_indicates_clean_review "# Security review: no findings  This PR only tightens the hook. It adds no new attack surface."
    claude_result_indicates_clean_review "# Security review: no high-confidence findings  I found no exploitable vulnerabilities in this PR."
    claude_result_indicates_clean_review "I found no high-confidence vulnerabilities in this PR, and there were no candidates to send to the false-positive filter sub-tasks."
    claude_result_indicates_clean_review "The changes only add blocks to the hook checks. I found no high-confidence vulnerabilities.  No findings."
}

@test "claude_result_indicates_clean_review matches a clean code review report" {
    claude_result_indicates_clean_review "Code review found nothing to change in this diff."
    claude_result_indicates_clean_review "No findings were reported by the code review."
}

@test "claude_result_indicates_clean_review ignores negated fixes and pushes" {
    claude_result_indicates_clean_review "Security review: no findings. Nothing was fixed and no commits were pushed."
}

@test "claude_result_indicates_clean_review rejects a review with findings" {
    run claude_result_indicates_clean_review "Security review found 2 findings; I fixed both and pushed."
    [ "${status}" -eq 1 ]
    run claude_result_indicates_clean_review "Code review round: fixed 3 findings"
    [ "${status}" -eq 1 ]
    run claude_result_indicates_clean_review "No findings were new this round, but code review is not converging, so I advanced the board."
    [ "${status}" -eq 1 ]
    run claude_result_indicates_clean_review "Security review: no new findings, but one high-confidence finding remains unresolved."
    [ "${status}" -eq 1 ]
}

@test "claude_result_indicates_clean_review rejects unrelated and empty messages" {
    run claude_result_indicates_clean_review "Rebased onto main and resolved the CHANGELOG conflict."
    [ "${status}" -eq 1 ]
    run claude_result_indicates_clean_review "Simplify made no changes to PR #12."
    [ "${status}" -eq 1 ]
    run claude_result_indicates_clean_review ""
    [ "${status}" -eq 1 ]
}

@test "review_result_marker reads a CLEAN or FINDINGS result line, ignoring surrounding whitespace and case" {
    run review_result_marker $'Security review: nothing to fix.\nREVIEW RESULT: CLEAN'
    [ "${output}" = "CLEAN" ]
    run review_result_marker $'Found two issues and fixed them.\n  review result: findings \r'
    [ "${output}" = "FINDINGS" ]
    run review_result_marker $'All good.\n\tReview Result: Clean\t'
    [ "${output}" = "CLEAN" ]
}

@test "review_result_marker prints nothing without a marker line, or when the marker is inside a sentence" {
    run review_result_marker "Code review found nothing to change in this diff."
    [ -z "${output}" ]
    run review_result_marker 'I will end with REVIEW RESULT: CLEAN once the fixes land.'
    [ -z "${output}" ]
    run review_result_marker $'Result:\n`REVIEW RESULT: CLEAN`'
    [ -z "${output}" ]
    run review_result_marker ""
    [ -z "${output}" ]
}

@test "review_result_marker prefers FINDINGS when a message has both lines" {
    run review_result_marker $'REVIEW RESULT: CLEAN\nOn reflection one finding remains.\nREVIEW RESULT: FINDINGS'
    [ "${output}" = "FINDINGS" ]
    run review_result_marker $'REVIEW RESULT: FINDINGS\nREVIEW RESULT: CLEAN'
    [ "${output}" = "FINDINGS" ]
}

@test "claude_result_indicates_clean_review accepts a clean security review worded outside the patterns when it ends with the CLEAN line (#1749)" {
    claude_result_indicates_clean_review $'The change adds a shared pattern list and a redaction step. I found no new attack surface.\nREVIEW RESULT: CLEAN'
    claude_result_indicates_clean_review $'The sed expressions are fixed literals and the input only goes to stdin, so there is no injection path.\n\nREVIEW RESULT: CLEAN'
    claude_result_indicates_clean_review $'If redaction fails, the function returns without sending, so it fails closed. Nothing is redacted less than before.\nREVIEW RESULT: CLEAN\n'
    claude_result_indicates_clean_review $'Code review found no correctness problems worth changing.\nREVIEW RESULT: CLEAN'
}

@test "claude_result_indicates_clean_review rejects a FINDINGS line even when the text matches a clean pattern" {
    run claude_result_indicates_clean_review $'Security review: no findings in the new library.\nREVIEW RESULT: FINDINGS'
    [ "${status}" -eq 1 ]
    run claude_result_indicates_clean_review $'No findings were reported by the code review.\nREVIEW RESULT: CLEAN\nREVIEW RESULT: FINDINGS'
    [ "${status}" -eq 1 ]
}

@test "claude_result_indicates_clean_review trusts a CLEAN line over wording the findings patterns would reject" {
    claude_result_indicates_clean_review $'Nothing to fix; the earlier round already pushed its changes.\nREVIEW RESULT: CLEAN'
}

@test "claude_result_indicates_clean_review falls back to the patterns when there is no result line" {
    claude_result_indicates_clean_review "# Security review: no findings  This PR only tightens the hook."
    run claude_result_indicates_clean_review "I found no new attack surface, and there is no injection path."
    [ "${status}" -eq 1 ]
    run claude_result_indicates_clean_review "The change is fine. I would say REVIEW RESULT: CLEAN here."
    [ "${status}" -eq 1 ]
}

@test "the PHASE E and PHASE F prompts ask for the review result line" {
    [ "${REVIEW_RESULT_CLEAN_MARKER}" = "REVIEW RESULT: CLEAN" ]
    [ "${REVIEW_RESULT_FINDINGS_MARKER}" = "REVIEW RESULT: FINDINGS" ]
    local prompts_src
    prompts_src="${BATS_TEST_DIRNAME}/../lib/prompts"
    [ "$(grep -c 'REVIEW_RESULT_CLEAN_MARKER}" when the' "${prompts_src}")" -eq 2 ]
    [ "$(grep -c 'REVIEW_RESULT_FINDINGS_MARKER}" otherwise' "${prompts_src}")" -eq 2 ]
}

@test "pr_clean_review_board_advance names the next review status for a clean report on an unchanged board" {
    _WF_PROJECT_ID="PVT_test"
    run pr_clean_review_board_advance "AI Security Review" "AI Security Review" "Security review: no findings."
    [ "${status}" -eq 0 ]
    [ "${output}" = "AI Coverage" ]
    run pr_clean_review_board_advance "AI Review" "AI Review" "Code review found no issues."
    [ "${status}" -eq 0 ]
    [ "${output}" = "AI Security Review" ]
}

@test "pr_clean_review_board_advance declines without a board, on a moved or unknown board, outside review, or with findings" {
    _WF_PROJECT_ID=""
    run pr_clean_review_board_advance "AI Security Review" "AI Security Review" "Security review: no findings."
    [ "${status}" -eq 1 ]
    _WF_PROJECT_ID="PVT_test"
    run pr_clean_review_board_advance "AI Security Review" "AI Coverage" "Security review: no findings."
    [ "${status}" -eq 1 ]
    run pr_clean_review_board_advance "Unknown" "Unknown" "Security review: no findings."
    [ "${status}" -eq 1 ]
    run pr_clean_review_board_advance "Development" "Development" "Security review: no findings."
    [ "${status}" -eq 1 ]
    run pr_clean_review_board_advance "AI Security Review" "AI Security Review" "Security review found 1 finding; fixed and pushed."
    [ "${status}" -eq 1 ]
}

@test "pr_clean_review_status_comment gives the phase's status comment and notes the orchestrator moved the board" {
    run pr_clean_review_status_comment "AI Coverage"
    [ "${status}" -eq 0 ]
    [[ "${output}" == "Security review clean, advancing to coverage check"* ]]
    [[ "${output}" == *"board moved by the orchestrator"* ]]
    run pr_clean_review_status_comment "AI Security Review"
    [[ "${output}" == "Code review clean - advancing to security review"* ]]
    run pr_clean_review_status_comment "Development"
    [ "${status}" -eq 1 ]
}

# Shared fixture for the main-loop tests below: an unchanged PR reached via issue pivot whose board
# reads final_board before and after the session, and whose session ends on the given final message.
_setup_clean_review_main() {
    local board="$1"
    setup_main_mocks
    _WF_PROJECT_ID="PVT_test"
    discover_or_create_workflow_project() { return 0; }
    sync_pr_workflow_status_from_linked_issues() { return 0; }
    fetch_all_priorities() {
        printf '%s\n' '[{"id":10,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    find_open_nonblocked_pr_for_repo() { printf '99\n'; }
    fetch_issue_json()          { printf '{"title":"T","body":"","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}\n'; }
    fetch_pr_json()             { printf '{"state":"OPEN","title":"T","body":"","isDraft":true,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}\n'; }
    _CLEAN_REVIEW_BOARD="${board}"
    fetch_single_item_workflow_status() { printf '%s' "${_CLEAN_REVIEW_BOARD}"; }
    fetch_pr_latest_trusted_comment_timestamp() { printf ''; }
    pr_json_has_blocked_label() { return 1; }
    fingerprint_pr_json()       { printf 'fp-same\n'; }
    load_pr_fingerprint()       { printf 'fp-same\n'; }
    fingerprint_issue_json()    { printf 'issue-fp-same\n'; }
    load_issue_fingerprint()    { printf 'issue-fp-same\n'; }
    _CLEAN_REVIEW_STATUS_LOG="${TEST_TMP}/status_log"
    _CLEAN_REVIEW_GH_LOG="${TEST_TMP}/gh_log"
    update_workflow_status() { printf '%s %s %s\n' "$1" "$2" "$3" >> "${_CLEAN_REVIEW_STATUS_LOG}"; }
    gh() { printf '%s\n' "$*" >> "${_CLEAN_REVIEW_GH_LOG}"; return 0; }
    save_pr_invocation_counts 99 2 2
}

@test "main advances an unchanged security review board when the session reported a clean review, without charging the idle budget (#1735)" {
    _setup_clean_review_main "AI Security Review"
    invoke_claude() { SESSION_RESULT_TEXT="# Security review: no findings  This PR only tightens the hook."; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PR #99 in org/repo: the session reported a clean review but left the board at AI Security Review"*"advancing it to AI Coverage and not charging the idle budget"* ]]
    [[ "${output}" != *"no progress this session"* ]]
    grep -q '^PullRequest 99 AI Coverage$' "${_CLEAN_REVIEW_STATUS_LOG}"
    grep -q '^pr comment 99 --repo org/repo --body Security review clean, advancing to coverage check' "${_CLEAN_REVIEW_GH_LOG}"
    load_pr_invocation_counts 99
    [ "${PR_INVOCATION_IDLE}" -eq 2 ]
    [ "${PR_INVOCATION_TOTAL}" -eq 3 ]
}

@test "main does not advance the board and still charges the idle budget when the review reported findings (#1735)" {
    _setup_clean_review_main "AI Security Review"
    invoke_claude() { SESSION_RESULT_TEXT="Security review found 2 findings and posted them as a PR comment."; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"no progress this session"* ]]
    [ ! -f "${_CLEAN_REVIEW_STATUS_LOG}" ]
    load_pr_invocation_counts 99
    [ "${PR_INVOCATION_IDLE}" -eq 3 ]
}

@test "main keeps charging the idle budget for an unrelated final message on a review board (#1735)" {
    _setup_clean_review_main "AI Review"
    invoke_claude() { SESSION_RESULT_TEXT="Waited for CI and checked the PR; nothing else to do this session."; printf '12345678-1234-1234-1234-123456789abc\n'; }

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"no progress this session"* ]]
    [ ! -f "${_CLEAN_REVIEW_STATUS_LOG}" ]
    load_pr_invocation_counts 99
    [ "${PR_INVOCATION_IDLE}" -eq 3 ]
}
