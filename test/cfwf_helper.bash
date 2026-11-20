#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034  # the constants here are read by the cfwf-*.bats files that load this one
#
# Shared setup/teardown, the gh stub, fixture writers and constants for the test/cfwf-*.bats
# files (split out of the former test/cfwf.bats, #1982). Each cfwf-*.bats file loads
# test_helper, then this. A helper or constant used by only one cfwf-*.bats file lives in
# that file instead.

#!/usr/bin/env bats
# shellcheck disable=SC2154  # stderr is set by run --separate-stderr

bats_require_minimum_version 1.5.0

load test_helper

SCRIPT="${REPO_ROOT}/containers/base/development-full/scripts/cfwf"

REPO="credfeto/credfeto-orchestrator"
ISSUE_URL="https://github.com/credfeto/credfeto-orchestrator/issues/1346"

setup() {
    setup_isolated_env
    # The suite may itself run inside an agent session; tests that need one set CLAUDECODE=1.
    unset CLAUDECODE
    export GH_LOG="${TEST_TMP}/gh.log"
    export GH_FIXTURES="${TEST_TMP}/fixtures"
    mkdir -p "${GH_FIXTURES}"

    # A gh stand-in that applies each call's --jq filter to a fixture with the real jq, so the
    # filters cfwf hands to gh are exercised against real-shaped JSON, not just recorded.
    # The stub body is deliberately single-quoted: it must expand when the stub runs, not here.
    # shellcheck disable=SC2016
    make_stub_multiline gh \
        'printf "%s\n" "$*" >> "${GH_LOG}"' \
        'jq_expr=""; prev=""' \
        'for arg in "$@"; do [ "${prev}" = "--jq" ] && jq_expr="${arg}"; prev="${arg}"; done' \
        'emit() { if [ -n "${jq_expr}" ]; then jq -r "${jq_expr}" < "$1"; else cat "$1"; fi; }' \
        'emit_asked() { f="$1"; shift; asked=""; prev=""; for arg in "$@"; do [ "${prev}" = "--json" ] && asked="${arg}"; prev="${arg}"; done; jq --arg asked "${asked}" "with_entries(select(.key as \$key | (\$asked | split(\",\")) | index(\$key)))" < "${f}.json" > "${f}.asked.json" || exit 1; emit "${f}.asked.json"; }' \
        'case " $* " in " repo view "*" --json defaultBranchRef,"*) v="${3,,}"; f="${GH_FIXTURES}/repository-${v//\//_}"; [ -f "${f}.fail" ] && { cat "${f}.fail" >&2; exit 1; }; [ -f "${f}.out" ] && { cat "${f}.out"; exit 0; }; [ -f "${f}.json" ] || { echo "GraphQL: Could not resolve to a Repository with the name ${3}. (repository)" >&2; exit 1; }; emit_asked "${f}" "$@"; exit ;; esac' \
        'case "$1 $2" in' \
        '  "pr list") f="${GH_FIXTURES}/pr-list"; [ -f "${f}.rewrite" ] && printf "%s\n" "rewritten with /tmp/leak" > "$(cat "${f}.rewrite")"; [ -f "${f}.fail" ] && { cat "${f}.fail" >&2; exit 1; }; [ -f "${f}.out" ] && { cat "${f}.out"; exit 0; }; lim=30; hd=""; lb=""; prev=""; for arg in "$@"; do [ "${prev}" = "--limit" ] && lim="${arg}"; [ "${prev}" = "--head" ] && hd="${arg}"; [ "${prev}" = "--label" ] && lb="${lb}${arg}|"; prev="${arg}"; done; [ -f "${f}.ignore-head" ] && hd=""; [ -f "${f}.ignore-label" ] && lb=""; jq --arg hd "${hd}" --arg lb "${lb}" --argjson lim "${lim}" "(\$lb | split(\"|\") | map(select(. != \"\"))) as \$want | [.[] | select(\$hd == \"\" or .headRefName == \$hd) | select(. as \$pr | all(\$want[]; . as \$w | any((\$pr.labels // [])[]; (.name | ascii_downcase) == (\$w | ascii_downcase))))] | .[:\$lim]" "${f}.json" > "${f}.asked.json" || exit 1; emit "${f}.asked.json" ;;' \
        '  "release list") f="${GH_FIXTURES}/release-list"; [ -f "${f}.fail" ] && { cat "${f}.fail" >&2; exit 1; }; [ -f "${f}.out" ] && { cat "${f}.out"; exit 0; }; lim=30; drafts=true; asked=""; prev=""; for arg in "$@"; do [ "${prev}" = "--limit" ] && lim="${arg}"; [ "${prev}" = "--json" ] && asked="${arg}"; [ "${arg}" = "--exclude-drafts" ] && drafts=false; prev="${arg}"; done; [ -f "${f}.keep-drafts" ] && drafts=true; jq --argjson drafts "${drafts}" --argjson lim "${lim}" --arg asked "${asked}" "[.[] | select(\$drafts or .isDraft != true)] | .[:\$lim] | map(with_entries(select(.key as \$key | (\$asked | split(\",\")) | index(\$key))))" "${f}.json" > "${f}.asked.json" || exit 1; emit "${f}.asked.json" ;;' \
        '  "repo view") case " $* " in *" --json visibility "*) v="${3,,}"; f="${GH_FIXTURES}/visibility-${v//\//_}"; [ -f "${f}.fail" ] && { if [ -s "${f}.fail" ]; then cat "${f}.fail" >&2; else echo "HTTP 502: Bad Gateway" >&2; fi; exit 1; }; [ -f "${f}.json" ] || { echo "GraphQL: Could not resolve to a Repository with the name ${3}. (repository)" >&2; exit 1; }; emit "${f}.json"; exit 0 ;; esac; [ -f "${GH_FIXTURES}/repo-view.fail" ] && { echo "boom" >&2; exit 1; }; emit "${GH_FIXTURES}/repo-view.json" ;;' \
        '  "project field-list") emit "${GH_FIXTURES}/field-list.json" ;;' \
        '  "project item-add") [ -f "${GH_FIXTURES}/item-add.fail" ] && { echo "boom" >&2; exit 1; }; emit "${GH_FIXTURES}/item-add.json" ;;' \
        '  "project item-edit") [ -f "${GH_FIXTURES}/item-edit.fail" ] && { echo "boom" >&2; exit 1; }; exit 0 ;;' \
        '  "project item-list") [ -f "${GH_FIXTURES}/item-list.fail" ] && { echo "boom" >&2; exit 1; }; emit "${GH_FIXTURES}/item-list.json" ;;' \
        '  "api graphql") [ -f "${GH_FIXTURES}/graphql.fail" ] && { cat "${GH_FIXTURES}/graphql.fail" >&2; exit 1; }; [ -f "${GH_FIXTURES}/graphql.failout" ] && { cat "${GH_FIXTURES}/graphql.failout"; exit 1; }; [ -f "${GH_FIXTURES}/graphql.stderr" ] && cat "${GH_FIXTURES}/graphql.stderr" >&2; emit "${GH_FIXTURES}/graphql-target.json" ;;' \
        '  "pr view") [ -f "${GH_FIXTURES}/pr-view.fail" ] && { cat "${GH_FIXTURES}/pr-view.fail" >&2; exit 1; }; [ -f "${GH_FIXTURES}/pr-view.json" ] || exit 1; emit_asked "${GH_FIXTURES}/pr-view" "$@" ;;' \
        '  "pr diff") f="${GH_FIXTURES}/pr-diff"; [ -f "${f}.fail" ] && { cat "${f}.fail" >&2; exit 1; }; [ -f "${f}.out" ] || { echo "GraphQL: Could not resolve to a PullRequest with the number of $3. (repository.pullRequest)" >&2; exit 1; }; cat "${f}.out" ;;' \
        '  "pr ready") [ -f "${GH_FIXTURES}/pr-ready.fail" ] && { cat "${GH_FIXTURES}/pr-ready.fail" >&2; exit 1; }; [ -d "${GH_FIXTURES}/pr-ready.then" ] && cp "${GH_FIXTURES}/pr-ready.then/"* "${GH_FIXTURES}/"; exit 0 ;;' \
        '  "pr merge") [ -f "${GH_FIXTURES}/pr-merge.fail" ] && { cat "${GH_FIXTURES}/pr-merge.fail" >&2; exit 1; }; exit 0 ;;' \
        '  "label list") [ -f "${GH_FIXTURES}/label-list.rewrite" ] && printf "%s\n" "rewritten with /tmp/leak" > "$(cat "${GH_FIXTURES}/label-list.rewrite")"; [ -f "${GH_FIXTURES}/label-list.fail" ] && { echo "boom" >&2; exit 1; }; emit "${GH_FIXTURES}/label-list.json" ;;' \
        '  "label create") [ -f "${GH_FIXTURES}/label-create.fail" ] && { cat "${GH_FIXTURES}/label-create.fail" >&2; exit 1; }; exit 0 ;;' \
        '  "issue create") prev=""; for arg in "$@"; do [ "${prev}" = "--body-file" ] && cp "${arg}" "${GH_FIXTURES}/issue-body.txt"; prev="${arg}"; done; [ -f "${GH_FIXTURES}/issue-create.fail" ] && { echo "boom" >&2; exit 1; }; cat "${GH_FIXTURES}/issue-create.out" ;;' \
        '  "pr create") f="${GH_FIXTURES}/pr-create"; prev=""; for arg in "$@"; do [ "${prev}" = "--body-file" ] && cp "${arg}" "${GH_FIXTURES}/pr-body.txt"; prev="${arg}"; done; readlink /proc/self/fd/0 > "${f}.stdin.txt"; [ -f "${f}.fail" ] && { [ -f "${f}.then-list.json" ] && cp "${f}.then-list.json" "${GH_FIXTURES}/pr-list.json"; [ -f "${f}.then-list.fail" ] && cp "${f}.then-list.fail" "${GH_FIXTURES}/pr-list.fail"; cat "${f}.fail" >&2; exit 1; }; cat "${f}.out" ;;' \
        '  "issue list") f="${GH_FIXTURES}/issue-list"; [ -f "${f}.fail" ] && { cat "${f}.fail" >&2; exit 1; }; [ -f "${f}.out" ] && { cat "${f}.out"; exit 0; }; lim=30; st=open; asked=""; prev=""; for arg in "$@"; do [ "${prev}" = "--limit" ] && lim="${arg}"; [ "${prev}" = "--state" ] && st="${arg}"; [ "${prev}" = "--json" ] && asked="${arg}"; prev="${arg}"; done; jq --arg st "${st}" --argjson lim "${lim}" --arg asked "${asked}" "[.[] | select(\$st == \"all\" or (.state | ascii_downcase) == \$st)] | .[:\$lim] | map(with_entries(select(.key as \$key | (\$asked | split(\",\")) | index(\$key))))" "${f}.json" > "${f}.asked.json" || exit 1; emit "${f}.asked.json" ;;' \
        '  "issue view") f="${GH_FIXTURES}/issue-view-$3"; [ -f "${f}.fail" ] && { cat "${f}.fail" >&2; exit 1; }; [ -f "${f}.json" ] || { echo "GraphQL: Could not resolve to an issue or pull request with the number of $3. (repository.issue)" >&2; exit 1; }; emit "${f}.json" ;;' \
        '  "api repos/"* | "api advisories/"* | "api users/"*) e="${2%%\?*}"; f="${GH_FIXTURES}/api-${e//\//_}"; [ -f "${f}.fail" ] && { cat "${f}.fail" >&2; exit 1; }; [ -f "${f}.out" ] && { cat "${f}.out"; exit 0; }; [ -f "${f}.pages" ] && { jq -c ".[]" "${f}.pages" | while IFS= read -r page; do printf "%s\n" "${page}" > "${f}.page.json"; emit "${f}.page.json" || exit 1; done; exit; }; [ -f "${f}.json" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }; emit "${f}.json" ;;' \
        '  "pr comment" | "issue comment") prev=""; for arg in "$@"; do [ "${prev}" = "--body-file" ] && cp "${arg}" "${GH_FIXTURES}/comment-body.txt"; prev="${arg}"; done; readlink /proc/self/fd/0 > "${GH_FIXTURES}/comment-stdin.txt"; [ -f "${GH_FIXTURES}/comment.fail" ] && { echo "boom" >&2; exit 1; }; cat "${GH_FIXTURES}/comment.out" ;;' \
        '  "api user" | "api rate_limit") f="${GH_FIXTURES}/api-$2"; [ -f "${f}.fail" ] && { [ -f "${f}.failout" ] && cat "${f}.failout"; cat "${f}.fail" >&2; exit 1; }; emit "${f}.json" ;;' \
        '  "--version ") f="${GH_FIXTURES}/gh-version"; [ -f "${f}.fail" ] && { cat "${f}.fail" >&2; exit 1; }; cat "${f}.out" ;;' \
        '  "issue reopen" | "issue close" | "pr close" | "pr reopen") [ -f "${GH_FIXTURES}/state-change.fail" ] && { cat "${GH_FIXTURES}/state-change.fail" >&2; exit 1; }; exit 0 ;;' \
        '  "run rerun") [ -f "${GH_FIXTURES}/run-rerun.fail" ] && { cat "${GH_FIXTURES}/run-rerun.fail" >&2; exit 1; }; echo "stub: requested a rerun"; exit 0 ;;' \
        '  "pr edit") prev=""; for arg in "$@"; do [ "${prev}" = "--body-file" ] && cp "${arg}" "${GH_FIXTURES}/edit-body.txt"; prev="${arg}"; done; [ -f "${GH_FIXTURES}/pr-edit.fail" ] && { cat "${GH_FIXTURES}/pr-edit.fail" >&2; exit 1; }; echo "https://github.com/credfeto/credfeto-orchestrator/pull/0" ;;' \
        '  "issue edit") prev=""; for arg in "$@"; do [ "${prev}" = "--body-file" ] && cp "${arg}" "${GH_FIXTURES}/edit-body.txt"; prev="${arg}"; done; [ -f "${GH_FIXTURES}/issue-edit.fail" ] && { cat "${GH_FIXTURES}/issue-edit.fail" >&2; exit 1; }; echo "https://github.com/credfeto/credfeto-orchestrator/issues/0" ;;' \
        '  "run list") f="${GH_FIXTURES}/run-list"; [ -f "${f}.fail" ] && { cat "${f}.fail" >&2; exit 1; }; [ -f "${f}.out" ] && { cat "${f}.out"; exit 0; }; lim=30; asked=""; prev=""; for arg in "$@"; do [ "${prev}" = "--limit" ] && lim="${arg}"; [ "${prev}" = "--json" ] && asked="${arg}"; prev="${arg}"; done; jq --argjson lim "${lim}" --arg asked "${asked}" ".[:\$lim] | map(with_entries(select(.key as \$key | (\$asked | split(\",\")) | index(\$key))))" "${f}.json" > "${f}.asked.json" || exit 1; emit "${f}.asked.json" ;;' \
        '  "run view") job=""; prev=""; for arg in "$@"; do [ "${prev}" = "--job" ] && job="${arg}"; prev="${arg}"; done; if [ -n "${job}" ]; then f="${GH_FIXTURES}/run-log-job-${job}"; else f="${GH_FIXTURES}/run-log-$3"; fi; [ -f "${f}.fail" ] && { cat "${f}.fail" >&2; exit 1; }; [ -f "${f}.txt" ] || { echo "stub: no log" >&2; exit 1; }; cat "${f}.txt" ;;' \
        '  "api --method") e="${4%%\?*}"; f="${GH_FIXTURES}/api-${3}-${e//\//_}"; for arg in "$@"; do case "${arg}" in body=@*) cp "${arg#body=@}" "${f}.body.txt" ;; esac; done; [ -f "${f}.fail" ] && { [ -d "${f}.then" ] && cp "${f}.then/"* "${GH_FIXTURES}/"; cat "${f}.fail" >&2; exit 1; }; [ -f "${f}.json" ] || { echo "gh stub: no fixture for $*" >&2; exit 99; }; emit "${f}.json" ;;' \
        '  "repo list") f="${GH_FIXTURES}/repo-list"; [ -f "${f}.fail" ] && { cat "${f}.fail" >&2; exit 1; }; [ -f "${f}.out" ] && { cat "${f}.out"; exit 0; }; arch=true; for arg in "$@"; do [ "${arg}" = "--no-archived" ] && arch=false; done; jq --argjson arch "${arch}" "[.[] | select(\$arch or .isArchived != true)]" "${f}.json" > "${f}.asked.json" || exit 1; emit "${f}.asked.json" ;;' \
        '  "search repos" | "search code") f="${GH_FIXTURES}/search-$2"; [ -f "${f}.fail" ] && { cat "${f}.fail" >&2; exit 1; }; [ -f "${f}.out" ] && { cat "${f}.out"; exit 0; }; lim=30; prev=""; for arg in "$@"; do [ "${prev}" = "--limit" ] && lim="${arg}"; prev="${arg}"; done; jq --argjson lim "${lim}" ".[:\$lim]" "${f}.json" > "${f}.asked.json" || exit 1; emit "${f}.asked.json" ;;' \
        '  *) echo "gh stub: unexpected call: $*" >&2; exit 99 ;;' \
        'esac'

    write_repo_view "/users/credfeto/projects/74"
    write_field_list
    jq -n '{id: "PVTI_target"}' > "${GH_FIXTURES}/item-add.json"
    write_item_list "Approved"
    write_graphql_target
}
teardown() {
    cleanup_stubs
}
# Writes the repo's linked-projects fixture: the Workflow project at the given path, plus a
# decoy project that is not titled Workflow.
write_repo_view() {
    jq -n --arg path "$1" '{projectsV2: {Nodes: [
        {id: "PVT_other", title: "Roadmap", number: 9, resourcePath: "/users/credfeto/projects/9", closed: false},
        {id: "PVT_proj", title: "Workflow", number: ($path | capture("/projects/(?<n>[0-9]+)$").n | tonumber), resourcePath: $path, closed: false}
    ]}}' > "${GH_FIXTURES}/repo-view.json"
}
# Writes the pr-view fixture: each argument is "owner/repo number" for one closing issue.
write_pr_view() {
    local ref
    for ref in "$@"; do
        jq -n --arg repo "${ref% *}" --arg number "${ref#* }" \
            '{repository: {owner: {login: ($repo | split("/")[0])}, name: ($repo | split("/")[1])}, number: ($number | tonumber)}'
    done | jq -s '{closingIssuesReferences: .}' > "${GH_FIXTURES}/pr-view.json"
}
# The ten workflow states, in board order, one per line.
workflow_states() {
    printf '%s\n' "Not Started" Planning Approved Development "AI Simplify" "AI Review" "AI Security Review" "AI Coverage" "Human Review" Complete
}
# Writes the field-list fixture for a converted board (#1519): the built-in Status field
# (PVTSSF_status) carries the ten workflow states with ids st_1 to st_10 in board order, so Approved
# is st_3 and AI Security Review st_7, and there is no Workflow Status field.
write_field_list() {
    workflow_states | jq -R -s '[split("\n")[:-1] | to_entries[] | {id: ("st_" + (.key + 1 | tostring)), name: .value}]' > "${GH_FIXTURES}/st-options.json"
    jq -n --slurpfile st "${GH_FIXTURES}/st-options.json" '{fields: [
        {id: "PVTF_title", name: "Title", type: "ProjectV2Field"},
        {id: "PVTSSF_status", name: "Status", options: $st[0], type: "ProjectV2SingleSelectField"}
    ], totalCount: 2}' > "${GH_FIXTURES}/field-list.json"
}
# Writes the field-list fixture for a board not converted yet: the built-in Status field still has
# Todo, In Progress and Done, and the old Workflow Status field (PVTSSF_wf) carries the ten states
# with ids wf_1 to wf_10 in board order.
write_legacy_field_list() {
    workflow_states | jq -R -s '[split("\n")[:-1] | to_entries[] | {id: ("wf_" + (.key + 1 | tostring)), name: .value}]' > "${GH_FIXTURES}/wf-options.json"
    jq -n --slurpfile wf "${GH_FIXTURES}/wf-options.json" '{fields: [
        {id: "PVTF_title", name: "Title", type: "ProjectV2Field"},
        {id: "PVTSSF_status", name: "Status", options: [{id: "b_todo", name: "Todo"}, {id: "b_progress", name: "In Progress"}, {id: "b_done", name: "Done"}], type: "ProjectV2SingleSelectField"},
        {id: "PVTSSF_wf", name: "Workflow Status", options: $wf[0], type: "ProjectV2SingleSelectField"}
    ], totalCount: 3}' > "${GH_FIXTURES}/field-list.json"
}
# Writes an item-list fixture for a converted board whose target item (issue 1346 of this repo) has
# the given status. Includes decoys that share the number in another repo, a PR, an item with no
# status and a draft item.
write_item_list() {
    local status="$1" file="${GH_FIXTURES}/item-list.json"
    jq -n --arg s "${status}" '{items: [
        {id: "PVTI_other", content: {number: 1346, repository: "credfeto/other-repo", type: "Issue"}, status: "Human Review"},
        {id: "PVTI_target", content: {number: 1346, repository: "credfeto/credfeto-orchestrator", type: "Issue"}, status: $s},
        {id: "PVTI_pr", content: {number: 1481, repository: "credfeto/credfeto-orchestrator", type: "PullRequest"}, status: "AI Review"},
        {id: "PVTI_nostatus", content: {number: 1500, repository: "credfeto/credfeto-orchestrator", type: "Issue"}},
        {id: "PVTI_draft", content: {type: "DraftIssue", title: "an idea with no repository"}}
    ]}' > "${file}"
}
# Writes the answer to the by-number query for an issue and for a pull request on a converted board.
# Each has an item on a decoy project as well as one on the Workflow project (PVT_proj), so the
# project filter matters.
write_graphql_target() {
    jq -n '{data: {repository: {
        issue: {projectItems: {nodes: [
            {project: {id: "PVT_other"}, legacy: null, status: {name: "Human Review"}},
            {project: {id: "PVT_proj"}, legacy: null, status: {name: "Approved"}}]}},
        pullRequest: {projectItems: {nodes: [
            {project: {id: "PVT_proj"}, legacy: null, status: {name: "AI Review"}}]}}}}}' > "${GH_FIXTURES}/graphql-target.json"
}
# Writes the by-number answer for issue 1346 on the Workflow project, with the given Workflow Status
# and built-in Status values ("null" for none): the item of a board not converted yet.
write_graphql_item() {
    jq -n --argjson legacy "$1" --argjson status "$2" \
        '{data: {repository: {issue: {projectItems: {nodes: [{project: {id: "PVT_proj"}, legacy: $legacy, status: $status}]}}}}}' \
        > "${GH_FIXTURES}/graphql-target.json"
}
# Makes every gh api graphql call fail with the given error text, so cfwf falls back to listing the board.
use_fallback() {
    printf '%s\n' "${1:-GraphQL: something went wrong}" > "${GH_FIXTURES}/graphql.fail"
}
set_args() {
    SET_ARGS=(workflow-status --set --repo "${REPO}" --issue 1346 --status Approved)
}
gh_call_count() {
    grep -cF -- "$1" "${GH_LOG}" || true
}
# Succeeds when gh was called with exactly the arguments $1, where BODY stands for the --body-file
# path: cfwf hands gh its private copy of the body, whose name mktemp chooses.
issue_create_called_with() {
    sed -E 's/ --body-file [^ ]+( |$)/ --body-file BODY\1/' "${GH_LOG}" | grep -qxF -- "$1"
}
gh_line_of() {
    grep -nF -- "$1" "${GH_LOG}" | head -1 | cut -d: -f1
}
# Writes a body file for each character that shows nothing although it is not ASCII whitespace,
# U+3000, U+00A0, U+200B and U+FEFF, each as the only text on its lines (invisible-<name>.md), one
# that mixes all four with ASCII whitespace (invisible-mixed.md), and the same mix with a single
# visible character (visible-among-invisible.md). Each body must be refused as empty, the last one
# taken.
write_invisible_bodies() {
    printf '\343\200\200\343\200\200\n\343\200\200\n' > "${TEST_TMP}/invisible-ideographic-space.md" \
        && printf '\302\240\n\302\240\302\240\n' > "${TEST_TMP}/invisible-no-break-space.md" \
        && printf '\342\200\213\n\342\200\213\342\200\213\n' > "${TEST_TMP}/invisible-zero-width-space.md" \
        && printf '\357\273\277\n\357\273\277\n' > "${TEST_TMP}/invisible-byte-order-mark.md" \
        && printf ' \343\200\200\t\302\240\n\342\200\213\357\273\277\n' > "${TEST_TMP}/invisible-mixed.md" \
        && printf ' \343\200\200\t\302\240\n\342\200\213x\357\273\277\n' > "${TEST_TMP}/visible-among-invisible.md"
}

INVISIBLE_BODIES=(ideographic-space no-break-space zero-width-space byte-order-mark mixed)

DISCUSSION_URL="https://github.com/credfeto/credfeto-orchestrator/pull/42"
TAB=$'\t'

# Replaces the gh stand-in of setup, for these tests only, with one that answers what pr comments
# and pr reply call. It logs each call on one line. A GraphQL call is answered only when its query
# reads review threads, from the fixture named after the cursors it was given (discussion.json for
# the first page, discussion-reviews-r2.json for the page of reviews after the cursor r2), so each
# page is a call of its own; a GET of an inline comment is answered as setup's stand-in answers any
# API path; a POST to .../replies copies the file it is given as the body to reply-body.txt and
# answers from reply.json, and a POST of a new inline comment (.../pulls/<n>/comments) copies it to
# review-comment-body.txt and answers from review-comment.json. An answer is the fixture with the call's own --jq filter applied by the
# real jq; beside a fixture, .fail is the stderr of a failed call (.failout its stdout), .raw an
# answer printed as it is, and .stderr noise on a call that works. When the file rewrite exists,
# the read of an inline comment overwrites the file it names, so a test can change the body file
# after the check. It never reads stdin.
prepare_pr_comments() {
    # shellcheck disable=SC2016  # the stub body must expand when the stub runs, not here
    make_stub_multiline gh \
        'log="$*"; printf "%s\n" "${log//[[:cntrl:]]/ }" >> "${GH_LOG}"' \
        'jq_expr=""; prev=""; body=""; cursors=""' \
        'for arg in "$@"; do' \
        '  [ "${prev}" = "--jq" ] && jq_expr="${arg}"' \
        '  case "${arg}" in' \
        '    body=@*) body="${arg#body=@}" ;;' \
        '    commentsAfter=* | reviewsAfter=* | threadsAfter=*) cursors+="-${arg%%After=*}-${arg#*=}" ;;' \
        '  esac' \
        '  prev="${arg}"' \
        'done' \
        'answer() {' \
        '  if [ -f "$1.fail" ]; then [ ! -f "$1.failout" ] || cat "$1.failout"; cat "$1.fail" >&2; exit 1; fi' \
        '  if [ -f "$1.raw" ]; then cat "$1.raw"; exit 0; fi' \
        '  [ ! -f "$1.stderr" ] || cat "$1.stderr" >&2' \
        '  [ -f "$1.json" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }' \
        '  jq -r "${jq_expr}" < "$1.json"' \
        '  exit "$?"' \
        '}' \
        'case "$1 $2" in' \
        '  "api graphql") case "$*" in *reviewThreads*) answer "${GH_FIXTURES}/discussion${cursors}" ;; esac ;;' \
        '  "api --method") case "$3 $4" in "POST repos/"*"/replies") cp "${body}" "${GH_FIXTURES}/reply-body.txt"; answer "${GH_FIXTURES}/reply" ;;' \
        '    "POST repos/"*"/comments") cp "${body}" "${GH_FIXTURES}/review-comment-body.txt"; answer "${GH_FIXTURES}/review-comment" ;; esac ;;' \
        '  "api repos/"*) [ ! -f "${GH_FIXTURES}/rewrite" ] || printf "%s\n" "rewritten with /tmp/leak" > "$(cat "${GH_FIXTURES}/rewrite")"; answer "${GH_FIXTURES}/api-${2//\//_}" ;;' \
        '  "repo view") case " $* " in *" --json visibility "*) v="${3,,}"; f="${GH_FIXTURES}/visibility-${v//\//_}"; [ -f "${f}.fail" ] && { if [ -s "${f}.fail" ]; then cat "${f}.fail" >&2; else echo "HTTP 502: Bad Gateway" >&2; fi; exit 1; }; [ -f "${f}.json" ] || { echo "GraphQL: Could not resolve to a Repository with the name ${3}. (repository)" >&2; exit 1; }; jq -r "${jq_expr}" < "${f}.json"; exit 0 ;; esac ;;' \
        'esac' \
        'echo "gh stub: unexpected call: $*" >&2; exit 99'
}
# One item of a discussion as GraphQL gives it: $1 the start of its URL fragment, $2 its id, $3 its
# author's login and $4 the author's __typename (none for a deleted account, which has no author),
# $5 its body and $6 its other fields, as JSON. databaseId is a decoy: only fullDatabaseId is read.
discussion_node() {
    jq -n --arg fragment "$1" --arg id "$2" --arg login "$3" --arg type "$4" --arg body "$5" --argjson more "$6" --arg url "${DISCUSSION_URL}" \
        '{fullDatabaseId: $id, databaseId: 1, url: ($url + "#" + $fragment + $id), body: $body,
          author: (if $type == "none" then null else {__typename: $type, login: $login} end),
          authorAssociation: (if $type == "User" then "OWNER" else "NONE" end)} + $more'
}
# A top-level comment: id, login, __typename, body.
issue_comment_node() {
    discussion_node issuecomment- "$1" "$2" "$3" "$4" '{"createdAt": "2026-10-08T10:17:52Z", "isMinimized": false}'
}
# A review: id, login, __typename, state, body.
review_node() {
    discussion_node pullrequestreview- "$1" "$2" "$3" "$5" "{\"state\": \"$4\", \"submittedAt\": \"2026-10-08T14:44:59Z\"}"
}
# An inline comment: id, the id it answers ("" for the first of a thread), its review's id, login,
# __typename, body.
inline_node() {
    local reply_to=null
    [ -z "$2" ] || reply_to="{\"fullDatabaseId\": \"$2\"}"
    discussion_node discussion_r "$1" "$4" "$5" "$6" \
        "{\"replyTo\": ${reply_to}, \"pullRequestReview\": {\"fullDatabaseId\": \"$3\"}, \"createdAt\": \"2026-10-08T15:12:05Z\", \"isMinimized\": false}"
}
# A review thread: resolved and outdated (true or false), path, line (null for none), original
# line, then its inline comments, each an inline_node object.
thread_node() {
    local resolved="$1" outdated="$2" path="$3" line="$4" original="$5"
    shift 5
    printf '%s\n' "$@" | jq -s --argjson resolved "${resolved}" --argjson outdated "${outdated}" --arg path "${path}" \
        --argjson line "${line}" --argjson original "${original}" \
        '{isResolved: $resolved, isOutdated: $outdated, path: $path, line: $line, originalLine: $original,
          comments: {totalCount: length, pageInfo: {hasNextPage: false, endCursor: null}, nodes: .}}'
}
# One list of a page: GitHub's count of the whole list, whether another page follows (true or
# false), that page's cursor ("" for none), then the nodes on this page.
discussion_list() {
    local total="$1" more="$2" cursor="$3"
    shift 3
    printf '%s\n' "$@" | jq -s --argjson total "${total}" --argjson more "${more}" --arg cursor "${cursor}" \
        '{totalCount: $total, pageInfo: {hasNextPage: $more, endCursor: (if $cursor == "" then null else $cursor end)}, nodes: .}'
}
# A list with nothing in it and no other page.
empty_list() {
    discussion_list 0 false ""
}
# Sets INVISIBLE_ONLY_VALUES to values that show nothing: one of each kind of character in
# INVISIBLE_CHARACTERS alone, then mixes of them with ASCII spaces and U+3000. Built from printf
# escapes, so this file stays ASCII.
invisible_only_values() {
    local escape
    INVISIBLE_ONLY_VALUES=()
    # U+00A0, U+2007, U+202F, U+2800, U+00AD, U+034F, U+061C, U+115F, U+1160, U+17B4, U+17B5,
    # U+180B, U+180F, U+200B, U+200F, U+202A, U+202E, U+2060, U+206F, U+3164, U+FE00, U+FE0F,
    # U+FEFF, U+FFA0, U+FFF0, U+FFF8, U+1BCA0, U+1BCA3, U+1D173, U+1D17A, U+E0000, U+E0FFF, then
    # mixes.
    for escape in '\302\240' '\342\200\207' '\342\200\257' '\342\240\200' '\302\255' '\315\217' '\330\234' \
        '\341\205\237' '\341\205\240' '\341\236\264' '\341\236\265' '\341\240\213' '\341\240\217' '\342\200\213' \
        '\342\200\217' '\342\200\252' '\342\200\256' '\342\201\240' '\342\201\257' '\343\205\244' '\357\270\200' \
        '\357\270\217' '\357\273\277' '\357\276\240' '\357\277\260' '\357\277\270' '\360\233\262\240' \
        '\360\233\262\243' '\360\235\205\263' '\360\235\205\272' '\363\240\200\200' '\363\240\277\277' \
        ' \302\240 \342\200\207\342\200\257 ' '\343\200\200\357\273\277\342\200\213 \302\240\343\200\200'; do
        INVISIBLE_ONLY_VALUES+=("$(printf '%b' "${escape}")")
    done
}
# Given a run's status, stdout and stderr, the flag $4, its limit $5 and the value $6: it was
# refused as blank, with exit 2, nothing on stdout, the value never echoed and no gh call. The
# checks are chained because a caller's || turns set -e off here, so only the last would count.
assert_refused_as_blank() {
    [ "$1" -eq 2 ] \
        && [ -z "$2" ] \
        && [[ "$3" == "cfwf: invalid value for $4: it must not be blank or longer than $5 characters"$'\n'* ]] \
        && [[ "$3" != *"$6"* ]] \
        && [ ! -f "${GH_LOG}" ]
}
# Writes the answer to a visibility lookup of the repository $1 (PUBLIC, PRIVATE or INTERNAL). A
# repository with no answer written is one GitHub does not show the caller.
write_visibility() {
    jq -n --arg v "$2" '{visibility: $v}' > "$(visibility_fixture "$1").json"
}
# Makes the visibility lookup of the repository $1 fail the way a proxy or network fault would, or
# with the error $2 when one is given.
fail_visibility() {
    printf '%s' "${2:-}" > "$(visibility_fixture "$1").fail"
}
# Prints the fixture path, without extension, that the gh stub reads for a visibility lookup of
# the repository $1: lower-cased, with the slash turned into an underscore.
visibility_fixture() {
    local name="${1,,}"
    printf '%s' "${GH_FIXTURES}/visibility-${name//\//_}"
}
visibility_lookups() {
    gh_call_count "repo view $1 --json visibility"
}
# Writes the body file: two clean lines, then the given text as line 3, then a clean last line.
write_leak_body() {
    printf 'A clean first line.\n\n%s\nA clean last line.\n' "$1" > "${TEST_TMP}/leak.md"
}
run_body_check() {
    run --separate-stderr "${SCRIPT}" body check --repo "${REPO}" --body-file "${TEST_TMP}/leak.md"
}
# Given a run's status, stdout and stderr: it exited 8 naming the rule $4 and line 3, printed
# nothing on stdout, and did not echo the text $5 that matched.
assert_refused() {
    local run_status="$1" run_output="$2" run_stderr="$3" rule="$4" secret="$5"
    [ "${run_status}" -eq 8 ]
    [ "${run_stderr}" = "cfwf: body refused: ${rule} (line 3)" ]
    [ -z "${run_output}" ]
    [[ "${run_stderr}" != *"${secret}"* ]]
}
# The token forms, built from pieces so that no secret scanner flags this file.
leak_tokens() {
    local tail="LEAKMARKER0123456789"
    printf '%s\n' "gh""p_${tail}" "gh""o_${tail}" "gh""s_${tail}" "gh""u_${tail}" "gh""r_${tail}" "github""_pat_${tail}" "gl""pat-${tail}" \
        "AKI""A$(printf 'Q%.0s' {1..16})" "-----BEGIN RSA PRIV""ATE KEY-----" "-----BEGIN PRIV""ATE KEY-----" \
        "xo""xb-${tail}" "xo""xa-${tail}" "xo""xp-${tail}" "xo""xr-${tail}" "xo""xs-${tail}" \
        "sk-""ant-api03-${tail}" "sk-""proj-${tail}" "https://disc""ord.com/api/webhooks/123456/${tail}" \
        "disc""ordapp.com/api/webhooks/1/${tail}" "Discord.com/api/web""hooks/42/x" \
        "Authorization: Bear""er abc" "-H 'authorization: bear""er ${tail}'" "{\"Authorization\": \"Bear""er ${tail}\"}" \
        "AUTHORIZATION: BEAR""ER x" "Bear""er ${tail}${tail}" "(bear""er ${tail}${tail})" \
        "Bear""er 0abcdefghijklmnopqrst" "Bear""er abcdefghijklmnopqrs9" "BEAR""ER abcdefghijklmnopqrstuvwxyz-7" \
        "GH_TO""KEN=${tail}" "export DB_PASS""WORD=${tail}" "MY_SEC""RET=${tail}" "(API_K""EY=${tail})" \
        "TO""KEN=${tail}" "K""EY=${tail}" "GH_TO""KEN=\"${tail}\"" "GH_TO""KEN='${tail}'" "AWS_2_SEC""RET=${tail}"
    leak_credential_forms
}
# Prints the character $1 repeated $2 times.
run_of() {
    local padding
    printf -v padding '%*s' "$2" ''
    printf '%s' "${padding// /$1}"
}
# Prints a URL of the scheme $1 whose user is $2 and whose password is $3, built from pieces so
# that no secret scanner takes this file to hold a URL with a password.
url_with_password() {
    printf '%s:/%s/%s:%s@%s' "$1" "" "$2" "$3" "example.com/path"
}
# The keys of an exact length, the Authorization headers, the URL passwords and the x-access-token
# user, built from pieces for the same reason as leak_tokens, which ends with them. A header is
# refused for having a value and a URL for having a password, so a placeholder is here too.
leak_credential_forms() {
    local tail="LEAKMARKER0123456789"
    printf '%s\n' "np""m_$(run_of a 36)" "AI""za$(run_of b 33)_-" "sk""-$(run_of c 48)" "ASI""A$(run_of Q 16)" \
        "np""m_$(run_of a 37)" "AI""za$(run_of b 36)" "sk""-$(run_of c 49)" \
        "Authorization: Bas""ic ${tail}=" "-H 'authorization: bas""ic ${tail}'" "{\"Authorization\": \"Bas""ic ${tail}\"}" \
        "AUTHORIZATION=BAS""IC x" "Authorization: Bas""ic <base64>" "Authorization: Bas""ic \$CREDENTIALS" \
        "-H \"Authorization: Bas""ic \${{ secrets.CREDENTIALS }}\"" \
        "Authorization: Bear""er <token>" "Authorization: Bear""er \$GH_TOKEN" \
        "-H \"Authorization: Bear""er \${{ secrets.GITHUB_TOKEN }}\"" \
        "Authorization: Dig""est username=\"user\", response=\"${tail}\"" "Authorization: Negot""iate ${tail}" \
        "Authorization: tok""en ${tail}" "authorization: AWS4-HMAC-SHA256 Credential=${tail}/aws4_request" \
        "Authorization: ${tail}" "Authorization:${tail}" "authorization=x" "Authorization: <value>" \
        "{\"Authorization\": \"\"}" "\`Authorization:\` is the header" \
        "-d \"{\\\"Authorization\\\": \\\"Bas""ic ${tail}\\\"}\"" "{\\\"Proxy-Authorization\\\":\\\"Dig""est ${tail}\\\"}" \
        "Proxy-Authorization: Bas""ic ${tail}" "-H 'proxy-authorization: bear""er x'" "PROXY-AUTHORIZATION=${tail}" \
        "{\"Proxy-Authorization\": \"Dig""est ${tail}\"}" "Proxy-Authorization: <value>" \
        "$(url_with_password https user "${tail}")" "$(url_with_password postgres app hunter)" \
        "$(url_with_password https "" "${tail}")" "$(url_with_password https user "${tail}:xxx")" \
        "$(url_with_password https user password)" "$(url_with_password https user PASSWORD)" \
        "$(url_with_password https user Password)" "$(url_with_password https user "<password>")" \
        "$(url_with_password https user "***")" "$(url_with_password https user xxx)" "$(url_with_password https user XXXX)" \
        "$(url_with_password https user "\$DB_PASSWORD")" "$(url_with_password postgres app "\${DB_PASSWORD}")" \
        "$(url_with_password https user "<password>")?to=someone@example.com" \
        "$(url_with_password https x-access-token "${tail}")" "x-access-token"":${tail}@""example.com" \
        "$(url_with_password https x-access-token "\${{secrets.GITHUB_TOKEN}}")" \
        "$(url_with_password https x-access-token "<token>")" "x-access-token"":<token>@""example.com" \
        "x-access-token"":\$GH_TOKEN@""example.com" "x-access-token"":***@""example.com" \
        "{\"url\":\"$(url_with_password postgres app "${tail}")\",\"email\":\"someone@example.com\"}" \
        "{\"url\":\"https:/""/user:password@localhost\",\"email\":\"someone@example.com\"}" \
        "\`https:/""/user:xxx@localhost:8080\`,\`someone@example.com\`" \
        "https:/""/user:${tail}@localhost?at=12:30" "https:/""/user:${tail}@localhost#line:5" \
        "http://localhost:8080,someone@example.com" "'http://localhost:8080','someone@example.com'" \
        "ssh:/""/git@localhost:22,someone@example.com" "https:/""/user:@localhost,someone@example.com" \
        "docker:/""/alpine:3.20@sha256:0123abcd" \
        "$(url_with_password https user "password@${tail}")" "x-access-token"":xxx@${tail}@""example.com" \
        "$(url_with_password https user "@${tail}")" "$(url_with_password https user "@@${tail}")" \
        "$(url_with_password https "" "@${tail}")" "$(url_with_password https x-access-token "@${tail}")" \
        "x-access-token"":@${tail}@""example.com" \
        "$(url_with_password smtp "someone@example.com" "${tail}")" "$(url_with_password imap "a@b@example.com" hunter)" \
        "$(url_with_password smtp "someone@example.com" "<password>")" "$(url_with_password smtp "someone@example.com" "@hunter")"
}

PR_LIST_UNEXPECTED="cfwf: gh returned an unexpected result for the open pull requests of ${REPO}"

# One open pull request as gh pr list --json gives it: number, head branch, base branch, author
# login ("" for an author with no login), draft (true or false), cross-repository (true or false)
# and title, then optionally its head commit, left out when not given. The number is JSON, so a
# test can give one that is not a number.
pull_request() {
    jq -n --argjson number "$1" --arg head "$2" --arg base "$3" --arg author "$4" --argjson draft "$5" \
        --argjson fork "$6" --arg title "$7" --arg oid "${8:-}" --arg repo "${REPO}" \
        '{number: $number, title: $title, headRefName: $head, baseRefName: $base, isDraft: $draft, isCrossRepository: $fork,
          author: (if $author == "" then {} else {login: $author, is_bot: ($author | startswith("app/"))} end),
          url: "https://github.com/\($repo)/pull/\($number)"} + (if $oid == "" then {} else {headRefOid: $oid} end)'
}
# Writes the open pull requests of the repository, in the order given: each argument a pull_request
# object. With no argument the repository has none.
write_pr_list() {
    printf '%s\n' "$@" | jq -s '.' > "${GH_FIXTURES}/pr-list.json"
}
# Succeeds when the text $1 has $2 lines, each of exactly $3 tab-separated fields, none empty.
has_field_lines() {
    awk -F '\t' -v expected="$2" -v fields="$3" '
        NF != fields { bad = 1 }
        { for (i = 1; i <= NF; i++) if ($i == "") bad = 1 }
        END { exit (bad || NR != expected) ? 1 : 0 }' <<< "$1"
}
# Prints one expected row of a tab-separated listing: the fields given, joined with tabs.
tab_row() {
    local IFS=$'\t'
    printf '%s\n' "$*"
}

HEAD_SHA="1111111111111111111111111111111111111111"
OLD_SHA="2222222222222222222222222222222222222222"
COMPLETED_AT="2026-10-01T12:00:00Z"

# The fixture path (without .json or .fail) the gh stub reads for the API endpoint $1, query left out.
api_fixture() {
    local endpoint="${1%%\?*}"
    printf '%s/api-%s' "${GH_FIXTURES}" "${endpoint//\//_}"
}
# Writes the JSON on stdin as the answer to the API endpoint $1.
write_api() {
    cat > "$(api_fixture "$1").json"
}
# Makes the API endpoint $1 fail with the error text $2 (a proxy's 502 by default).
fail_api() {
    printf '%s\n' "${2:-gh: Bad Gateway (HTTP 502)}" > "$(api_fixture "$1").fail"
}
# One check run: name, conclusion ("" for none), id, then optionally its status (completed when it
# has a conclusion, in_progress otherwise; "" for that default), the commit it ran on (HEAD_SHA), the
# id of the app that made it (GitHub Actions, 15368) and the id of its check suite (1).
check_run() {
    local status="${4:-}"
    [ -n "${status}" ] || { [ -n "$2" ] && status=completed || status=in_progress; }
    jq -n --arg name "$1" --arg conclusion "$2" --argjson id "$3" --arg status "${status}" \
        --arg sha "${5:-${HEAD_SHA}}" --arg at "${COMPLETED_AT}" --argjson app "${6:-15368}" --argjson suite "${7:-1}" \
        '{name: $name, id: $id, head_sha: $sha, status: $status,
          conclusion: (if $conclusion == "" then null else $conclusion end),
          completed_at: (if $conclusion == "" then null else $at end),
          app: {id: $app, slug: "app-\($app)"}, check_suite: {id: $suite}}'
}
# Writes the check runs of the commit $1: the rest of the arguments, each a check_run object.
write_check_runs() {
    local sha="$1"
    shift
    printf '%s\n' "$@" | jq -s '{total_count: length, check_runs: .}' | write_api "repos/${REPO}/commits/${sha}/check-runs"
}
# One commit status: context, state, id.
commit_status() {
    jq -n --arg context "$1" --arg state "$2" --argjson id "$3" --arg at "${COMPLETED_AT}" \
        '{context: $context, state: $state, id: $id, updated_at: $at}'
}
# Writes the combined status of the commit $1: the rest of the arguments, each a commit_status object.
write_statuses() {
    local sha="$1"
    shift
    printf '%s\n' "$@" | jq -s '{state: "pending", sha: "'"${sha}"'", statuses: .}' \
        | write_api "repos/${REPO}/commits/${sha}/status"
}
# Writes the branch $1, its tip at HEAD_SHA, with no branch protection, as GitHub shows it to a
# caller with read access.
write_branch() {
    jq -n --arg name "$1" --arg sha "${HEAD_SHA}" '{name: $name, commit: {sha: $sha}, protected: false,
        protection: {enabled: false, required_status_checks: {enforcement_level: "off", contexts: [], checks: []}}}' \
        | write_api "repos/${REPO}/branches/$1"
}
# Writes the branch $1, its tip at HEAD_SHA, with classic branch protection requiring the checks
# named by the rest of the arguments, each name or name#<app id>. As GitHub lists them, contexts
# repeats every name, and checks has each but the first (one set up before checks existed) with its
# app id, or null for any source.
write_protection() {
    local branch="$1"
    shift
    jq -n --arg name "${branch}" --arg sha "${HEAD_SHA}" --args '{name: $name, commit: {sha: $sha}, protected: true,
        protection: {enabled: true, required_status_checks: {enforcement_level: "non_admins",
            contexts: ($ARGS.positional | map(split("#")[0])),
            checks: ($ARGS.positional[1:] | map(split("#") | {context: .[0], app_id: (.[1] // null | if . == null then null else tonumber end)}))}}}' "$@" \
        | write_api "repos/${REPO}/branches/${branch}"
}
# Writes the rules that apply to the branch $1: a required_status_checks rule naming the rest of
# the arguments, each name or name#<integration id>, beside a rule of another type.
write_rulesets() {
    local branch="$1"
    shift
    jq -n --args '[{type: "pull_request", parameters: {required_approving_review_count: 1}},
        {type: "required_status_checks", parameters: {required_status_checks: ($ARGS.positional
            | map(split("#") | {context: .[0]} + (if .[1] == null then {} else {integration_id: (.[1] | tonumber)} end)))}}]' "$@" \
        | write_api "repos/${REPO}/rules/branches/${branch}"
}
# Writes the rules that apply to the branch $1 as GitHub answers a branch no ruleset applies to:
# an empty list, never a 404.
write_no_rulesets() {
    printf '[]\n' | write_api "repos/${REPO}/rules/branches/$1"
}
# PR 42, whose head is HEAD_SHA and whose base, main, requires build; build passed and nothing else
# ran. Each test changes what it needs.
prepare_pr_checks() {
    jq -n --arg sha "${HEAD_SHA}" '{number: 42, head: {sha: $sha}, base: {ref: "main"}}' | write_api "repos/${REPO}/pulls/42"
    write_protection main build
    write_no_rulesets main
    write_check_runs "${HEAD_SHA}" "$(check_run build success 11)"
    write_statuses "${HEAD_SHA}"
}
run_pr_checks() {
    run --separate-stderr "${SCRIPT}" pr checks --repo "${REPO}" "$@"
}

COMMENT_PR_URL="https://github.com/credfeto/credfeto-orchestrator/pull/1623#issuecomment-4242"
COMMENT_ISSUE_URL="https://github.com/credfeto/credfeto-orchestrator/issues/1585#issuecomment-4343"

prepare_comment() {
    printf 'A comment.\n\nWith a second paragraph.\n' > "${TEST_TMP}/comment.md"
    printf '%s\n' "${1-${COMMENT_PR_URL}}" > "${GH_FIXTURES}/comment.out"
}
run_comment_add() {
    run --separate-stderr "${SCRIPT}" comment add --repo "${REPO}" "$@"
}

ISSUE_READ_USAGE="--repo <owner/repo> --issue <n>"
VIEW_FIELDS="url,title,state,labels,assignees,body"
PLAN_STATUS_FIELDS="url,labels,comments"
PLAN_HEADING="## Implementation Plan"

# The two plan sign-off keywords, one per line, each built from pieces so that this file never
# holds one as a word.
sign_off_keywords() {
    printf '%s%s\n' appr oved lg tm
}
# The fixture path (without .json or .fail) the gh stub reads for gh issue view $1.
issue_fixture() {
    printf '%s/issue-view-%s' "${GH_FIXTURES}" "$1"
}
# Writes issue $1 as gh issue view --json answers it: its title $2, state $3 and body $4, then its
# label names, then -- and its assignee logins. The comments are empty; write_comments sets them.
write_issue() {
    local number="$1" title="$2" state="$3" body="$4"
    shift 4
    local -a labels=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
        labels+=("$1")
        shift
    done
    [ "$#" -eq 0 ] || shift
    jq -n --arg url "https://github.com/${REPO}/issues/${number}" --arg title "${title}" --arg state "${state}" \
        --arg body "${body}" --arg labels "$(printf '%s\037' "${labels[@]}")" --args \
        '{url: $url, title: $title, state: $state, body: $body, comments: [],
          labels: ($labels | split("\u001f") | map(select(. != "") | {id: "LA_x", name: ., color: "ffffff", description: ""})),
          assignees: ($ARGS.positional | map({id: "U_x", login: ., name: ""}))}' "$@" > "$(issue_fixture "${number}").json"
}
# The createdAt of the comment whose number in the thread is $1: one day for each, so thread order
# and time order agree.
comment_time() {
    printf '2026-10-%02dT10:00:00Z' "$1"
}
# The URL of the comment whose number in the thread is $1. Every comment fixture belongs to issue 7.
comment_url() {
    printf 'https://github.com/%s/issues/7#issuecomment-%s' "${REPO}" "$1"
}
# One comment as gh issue view --json comments lists it: its number in the thread $1 (which gives
# its time and URL), author login $2 ("" for a deleted account, whose author GitHub leaves null),
# author association $3 and body $4.
issue_comment() {
    jq -n --argjson n "$1" --arg login "$2" --arg association "$3" --arg body "$4" \
        --arg time "$(comment_time "$1")" --arg url "$(comment_url "$1")" \
        '{id: "IC_\($n)", author: (if $login == "" then null else {login: $login} end), authorAssociation: $association,
          body: $body, createdAt: $time, isMinimized: false, url: $url}'
}
# Sets the comments of issue $1, already written, to the rest of the arguments, each an
# issue_comment object, in thread order.
write_comments() {
    local file
    file="$(issue_fixture "$1").json"
    shift
    printf '%s\n' "$@" | jq -s --slurpfile issue "${file}" '$issue[0] + {comments: .}' > "${file}.new"
    mv "${file}.new" "${file}"
}
run_issue_read() {
    local subcommand="$1"
    shift
    run --separate-stderr "${SCRIPT}" issue "${subcommand}" --repo "${REPO}" "$@"
}
# gh was called once and only once: the gh issue view of issue $1 for exactly the fields $2.
assert_one_issue_read() {
    [ "$(grep -cE '^(issue|pr|repo|api|project|label) ' "${GH_LOG}")" -eq 1 ]
    [ "$(gh_call_count "issue view $1 --repo ${REPO} --json $2 --jq ")" -eq 1 ]
}

ISSUE_LIST_USAGE="Usage: cfwf issue list --repo <owner/repo>"
ISSUE_SEARCH_USAGE="Usage: cfwf issue search --repo <owner/repo> --text <words> [--state open|closed|all] [--limit <n>]"
ISSUE_LIST_UNEXPECTED="cfwf: gh returned an unexpected result for the open issues of ${REPO}"
ISSUE_SEARCH_UNEXPECTED="cfwf: gh returned an unexpected result for the search of the issues of ${REPO}"
# The only qualifier cfwf adds: gh adds the repository itself.
SEARCH_PREFIX="in:title,body"
SEARCH_WARNING_OF_2="cfwf: warning: more than 2 issues match; only the first 2 are printed"

REPO_VIEW_JSON_FIELDS="defaultBranchRef,description,visibility,mergeCommitAllowed,squashMergeAllowed,rebaseMergeAllowed"
REPO_MISSING="cfwf: the repository ${REPO} was not found, or the caller cannot see it"
COLLABORATORS_ENDPOINT="repos/${REPO}/collaborators"
ADVISORIES_ENDPOINT="repos/${REPO}/security-advisories"
PUSH_ACCESS_ERROR="gh: Must have push access to view repository collaborators. (HTTP 403)"
# The resets of the rate limit fixture, as GitHub gives them and as auth status prints them.
CORE_RESET=1767225600
CORE_RESET_AT="2026-01-01T00:00:00Z"
GRAPHQL_RESET=1767229200
GRAPHQL_RESET_AT="2026-01-01T01:00:00Z"

# One collaborator as the REST API lists it: login $1 and role name $2, left out when it is empty.
collaborator() {
    jq -n --arg login "$1" --arg role "${2:-}" \
        '{login: $login, id: 1, type: "User", permissions: {admin: false, push: true, pull: true}}
         + (if $role == "" then {} else {role_name: $role} end)'
}
# Writes the collaborators of REPO: each argument a collaborator object, in the order given, none
# for an empty list.
write_collaborators() {
    printf '%s\n' "$@" | jq -s '.' | write_api "${COLLABORATORS_ENDPOINT}"
}

PR_URL="https://github.com/credfeto/credfeto-orchestrator/pull/42"
CREATED_AT="2026-10-01T08:00:00Z"
MERGED_AT="2026-10-02T09:30:00Z"
MERGE_SHA="3333333333333333333333333333333333333333"
DEFAULT_JSON_FIELDS="state,isDraft,title,url,baseRefName,headRefName,headRefOid,autoMergeRequest,reviewDecision,mergeStateStatus,mergeable,createdAt,mergedAt,mergeCommit,labels,assignees,author,commits"
# The fields printed as a key and value line, in the order they are printed.
VIEW_LINE_FIELDS=(state draft title url base head head-sha auto-merge review-decision merge-state mergeable
    created-at merged-at merge-commit labels assignees author commit-authors)

# The three commands only read, and are for a repository the caller does not work in, such as that
# of a GitHub Action, so their tests name one.
LOOKUP_REPO="actions/checkout"
TAGGED_COMMIT="3333333333333333333333333333333333333333"
TAG_OBJECT="4444444444444444444444444444444444444444"
RELEASE_VIEW_USAGE="Usage: cfwf release view --repo <owner/repo>"
RELEASE_LIST_USAGE="Usage: cfwf release list --repo <owner/repo>"
TAG_VIEW_USAGE="Usage: cfwf tag view --repo <owner/repo> --tag <tag>"
RELEASE_LIST_UNEXPECTED="cfwf: gh returned an unexpected result for the releases of ${LOOKUP_REPO}"
TAG_UNEXPECTED="cfwf: gh returned an unexpected result for the --tag of ${LOOKUP_REPO}"
REPOSITORY_MISSING="cfwf: the repository ${LOOKUP_REPO} was not found, or the caller cannot see it"

# Writes the answer to the read of the repository $1 (LOOKUP_REPO by default) itself, which is how it
# is seen to be there.
write_repository() {
    local repo="${1:-${LOOKUP_REPO}}"
    jq -n --arg repo "${repo}" '{id: 197814629, full_name: $repo, default_branch: "main"}' | write_api "repos/${repo}"
}
# One release as gh release list --json gives it: tag, publication time, name, and any of the words
# latest, prerelease and draft in $4. It also has a field release list never asks for.
release() {
    jq -n --arg tag "$1" --arg at "$2" --arg name "$3" --arg flags "${4:-}" \
        '{tagName: $tag, name: $name, publishedAt: $at, createdAt: "2020-01-01T00:00:00Z", isLatest: ($flags | contains("latest")),
          isPrerelease: ($flags | contains("prerelease")), isDraft: ($flags | contains("draft"))}'
}
# Prints one expected line, its arguments joined by tabs.
tab_line() {
    local IFS=$'\t'
    printf '%s\n' "$*"
}

CREATED_AT="2026-10-01T09:00:00Z"
LABEL_HISTORY_USAGE="Usage: cfwf issue label-history --repo <owner/repo> (--issue <n> | --pr <n>) [--label <name>]"
READY_AT_USAGE="Usage: cfwf pr ready-at --repo <owner/repo> --pr <n>"
TIMELINE_UNEXPECTED="cfwf: gh returned an unexpected result for the timeline of ${REPO}#"

# Writes the answer to the read of REPO itself, which is how it is seen to be there.
write_this_repository() {
    jq -n --arg repo "${REPO}" '{id: 1, full_name: $repo, default_branch: "main"}' | write_api "repos/${REPO}"
}
# Writes the number $1 as the issues endpoint gives it: an issue or a pull request ($2, issue or
# pull), created at $3 (CREATED_AT by default), with fields the commands never ask for.
write_issue_kind() {
    jq -n --argjson n "$1" --arg kind "$2" --arg at "${3:-${CREATED_AT}}" \
        '{number: $n, title: "a title", state: "open", created_at: $at, updated_at: "2026-10-09T00:00:00Z"}
         + (if $kind == "pull" then {pull_request: {url: "https://api.github.com/repos/x/y/pulls/\($n)", merged_at: null}} else {} end)' \
        | write_api "repos/${REPO}/issues/$1"
}
# One timeline event as the REST API gives it: the event $1, the actor's login $2 (none for a null
# actor), the label's name $3 (empty for an event with no label) and its time $4.
timeline_event() {
    jq -n --arg event "$1" --arg login "$2" --arg label "$3" --arg at "$4" \
        '{id: 1, event: $event, created_at: $at, commit_id: null,
          actor: (if $login == "none" then null else {login: $login, type: "User"} end)}
         + (if $label == "" then {} else {label: {name: $label, color: "ff0000"}} end)'
}
# Writes the timeline of the number $1 as one page: each further argument an event, in the order
# given, none for an empty timeline.
write_timeline() {
    local number="$1"
    shift
    timeline_page "$@" | write_api "repos/${REPO}/issues/${number}/timeline"
}
# One page of a timeline: each argument an event, in the order given.
timeline_page() {
    printf '%s\n' "$@" | jq -c -s '.'
}

RUN_SHA="5555555555555555555555555555555555555555"
MOVED_SHA="6666666666666666666666666666666666666666"
RUN_RERUN_USAGE="Usage: cfwf run rerun --repo <owner/repo> --run <id>"
RUN_RERUN_CALL="run rerun 123 --failed --repo ${REPO}"
RUN_UNEXPECTED="cfwf: gh returned an unexpected result for the run 123 of ${REPO}"
RUN_PRS_UNEXPECTED="cfwf: gh returned an unexpected result for the open pull requests of ${REPO}"

# Writes the run list answer: each argument is "id|workflow|status|conclusion|sha|branch|event|created".
write_run_list() {
    local row
    for row in "$@"; do
        IFS='|' read -r id workflow status conclusion sha branch event created <<< "${row}"
        jq -n --argjson id "${id}" --arg workflow "${workflow}" --arg status "${status}" --arg conclusion "${conclusion}" \
            --arg sha "${sha}" --arg branch "${branch}" --arg event "${event}" --arg created "${created}" \
            '{databaseId: $id, workflowName: $workflow, status: $status, conclusion: (if $conclusion == "" then null else $conclusion end),
              headSha: $sha, headBranch: $branch, event: $event, createdAt: $created, url: "https://example.invalid", number: 9}'
    done | jq -s . > "${GH_FIXTURES}/run-list.json"
}

EDIT_PR=1600
AGENT=dnyw4l3n13
EDIT_PR_URL="https://github.com/${REPO}/pull/${EDIT_PR}"
EDIT_TITLE="feat(cfwf): add pr edit"

# Writes the fixtures of a pr edit run: the agent's login, the pull request opened by $1 (the agent
# by default) of the account type $2 (User by default) with $3 commits (1 by default), and its
# commits, one for each further argument, each the login of that commit's author ("" for none).
# With no commit author given, every commit is the agent's.
prepare_pr_edit() {
    local author="${1:-${AGENT}}" type="${2:-User}" count="${3:-1}"
    shift 3 2> /dev/null || shift "$#"
    jq -n --arg login "${AGENT}" '{login: $login}' > "${GH_FIXTURES}/api-user.json"
    jq -n --arg author "${author}" --arg type "${type}" --arg url "${EDIT_PR_URL}" --argjson count "${count}" \
        '{number: 1600, user: {login: $author, type: $type}, html_url: $url, commits: $count}' \
        | write_api "repos/${REPO}/pulls/${EDIT_PR}"
    local -a authors=("$@")
    if [ "${#authors[@]}" -eq 0 ]; then
        local index
        for ((index = 0; index < count; index++)); do
            authors+=("${AGENT}")
        done
    fi
    printf '%s\n' "${authors[@]}" \
        | jq -R -s 'split("\n")[:-1] | map(if . == "" then {sha: "abc", author: null} else {sha: "abc", author: {login: .}} end)' \
        | write_api "repos/${REPO}/pulls/${EDIT_PR}/commits"
    printf 'The body of the pull request.\n\nCloses #1589\n' > "${TEST_TMP}/edit-body.md"
}
run_pr_edit() {
    run --separate-stderr "${SCRIPT}" pr edit --repo "${REPO}" --pr "${EDIT_PR}" "$@"
}
edits_made() {
    gh_call_count "pr edit ${EDIT_PR} "
}

EDIT_ISSUE=1596
EDIT_ISSUE_URL="https://github.com/${REPO}/issues/${EDIT_ISSUE}"
EDIT_ISSUE_TITLE="tool(cfwf): Edit an issue's title and body"

# Writes the fixtures of an issue edit run: the agent's login, issue EDIT_ISSUE as gh issue view
# answers it, and a body file.
prepare_issue_edit() {
    jq -n --arg login "${AGENT}" '{login: $login}' > "${GH_FIXTURES}/api-user.json"
    write_issue "${EDIT_ISSUE}" "tool(cfwf): an old title" OPEN "The old body."
    printf 'The new body of the issue.\n' > "${TEST_TMP}/edit-body.md"
}
run_issue_edit() {
    run --separate-stderr "${SCRIPT}" issue edit --repo "${REPO}" --issue "${EDIT_ISSUE}" "$@"
}
issue_edits_made() {
    gh_call_count "issue edit ${EDIT_ISSUE} "
}
# Writes the repository's labels, as gh label list --json name answers it: each argument a name.
write_repository_labels() {
    jq -n --args '$ARGS.positional | map({name: .})' "$@" > "${GH_FIXTURES}/label-list.json"
}
write_agent_login() {
    jq -n --arg login "${AGENT}" '{login: $login}' > "${GH_FIXTURES}/api-user.json"
}

OWNER="credfeto"
WORKFLOWS_ENDPOINT="repos/${REPO}/actions/workflows"

# One workflow as the REST API lists it: name $1, path $2 and state $3.
workflow() {
    jq -n --arg name "$1" --arg path "$2" --arg state "$3" '{id: 1, node_id: "decoy", name: $name, path: $path, state: $state, badge_url: "decoy"}'
}

SYNC_USAGE="Usage: cfwf pr sync-labels --repo <owner/repo> --pr <n> [--assign-self]"
SYNC_PR=1481
SYNC_PR_URL="https://github.com/${REPO}/pull/${SYNC_PR}"

# Writes the pull request SYNC_PR as gh pr view answers it: its URL ($SYNC_URL, SYNC_PR_URL by
# default) and its closing issues, each argument "owner/repo number", beside a field not asked for.
write_sync_pr() {
    write_pr_view "$@"
    jq --arg url "${SYNC_URL:-${SYNC_PR_URL}}" '. + {url: $url, title: "feat: a change"}' "${GH_FIXTURES}/pr-view.json" > "${GH_FIXTURES}/pr-view.next.json"
    mv "${GH_FIXTURES}/pr-view.next.json" "${GH_FIXTURES}/pr-view.json"
}
# Writes the labels of the closing issue $1 as gh issue view answers them: each further argument a name.
write_sync_issue_labels() {
    local number="$1"
    shift
    jq -n --args '{labels: ($ARGS.positional | map({name: .}))}' "$@" > "${GH_FIXTURES}/issue-view-${number}.json"
}
run_sync_labels() {
    run --separate-stderr "${SCRIPT}" pr sync-labels --repo "${REPO}" --pr "${SYNC_PR}" "$@"
}
