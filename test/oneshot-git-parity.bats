#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are read by the sourced oneshot functions, where shellcheck cannot trace them

# Golden parity cases for the read-only lib/git queries in the .NET rewrite (#252). test/fixtures/git-parity.json holds
# scenario scripts that build throwaway repositories (origin, clones in every state the queries tell apart: dirty,
# staged, untracked, renamed, conflicted, detached, with stashes; a directory that is not a repository), and for each case the lib/git function, its REPO_WORK_DIR and arguments, and
# what the function prints and returns there. The prelude pins the identity, dates and config, so the commit ids are
# the same on every machine. This file checks the shell functions against the fixture, and
# Credfeto.Orchestrator.Git.Tests (src/) runs the tool's git queries over the same repositories and checks them
# against the same file. A case marked "refuses" is one the tool must refuse, so bash answers it; "not-called" is one
# bash answers before it would ask the tool.
#
# To regenerate the fixture after a change to its scenario or cases, run the last test with GIT_PARITY_REGENERATE
# set to the file to write; it keeps the fixture's prelude, scenarios and cases and records what the shell prints.

bats_require_minimum_version 1.5.0

load test_helper
load oneshot_helper

GIT_FIXTURE="${BATS_TEST_DIRNAME}/fixtures/git-parity.json"

# Runs a script ($2) with the fixture's environment, from directory $1
_git_parity_env_run() {
    local dir="$1" script="$2" name
    (
        while IFS= read -r name; do
            unset "${name}"
        done < <(jq -r '.unset[]' "${GIT_FIXTURE}")
        while IFS= read -r -d '' name; do
            export "${name?}"
        done < <(jq -j '.environment | to_entries[] | "\(.key)=\(.value)\u0000"' "${GIT_FIXTURE}")
        cd "${dir}" || exit 1
        eval "${script}"
    )
}

# Builds the scenario's repositories under the empty directory $1 (each scenario in a directory of its own name)
_git_parity_build() {
    local root="$1" prelude name setup
    prelude=$(jq -r '.prelude' "${GIT_FIXTURE}")
    while IFS= read -r name; do
        setup=$(jq -r --arg n "${name}" '.scenarios[] | select(.name == $n) | .setup' "${GIT_FIXTURE}")
        mkdir -p "${root}/${name}"
        _git_parity_env_run "${root}/${name}" "set -e
${prelude}
${setup}" > /dev/null || return 1
    done < <(jq -r '.scenarios[].name' "${GIT_FIXTURE}")
}

# Runs case $2's lib/git function in its scenario's directory under root $1, with REPO_WORK_DIR set to the case's
# repository (empty when the case's repo is empty) and @ROOT@ in an argument replaced by that directory, in the
# fixture's environment. Prints the function's output, then a dot and its status; its stderr goes to $3.
_git_parity_call() {
    local root="$1" index="$2" stderr_file="$3" function scenario repo arg
    local -a args=()
    function=$(jq -r --argjson i "${index}" '.cases[$i].function' "${GIT_FIXTURE}")
    scenario=$(jq -r --argjson i "${index}" '.cases[$i].scenario' "${GIT_FIXTURE}")
    repo=$(jq -r --argjson i "${index}" '.cases[$i].repo' "${GIT_FIXTURE}")
    while IFS= read -r -d '' arg; do
        args+=("${arg//@ROOT@/${root}/${scenario}}")
    done < <(jq -j --argjson i "${index}" '.cases[$i].args[] | "\(.)\u0000"' "${GIT_FIXTURE}")
    case "${function}" in
        checkout_head_sha | checkout_current_branch | checkout_has_uncommitted_changes | origin_branch_exists | git_commits_behind | find_stale_issue_branch) ;;
        checkout_porcelain_status | checkout_changed_file_count | checkout_stash_head | autostashes_beyond_keep) ;;
        *) return 1 ;;
    esac
    REPO_WORK_DIR=""
    if [ -n "${repo}" ]; then
        REPO_WORK_DIR="${root}/${scenario}/${repo}"
    fi
    # shellcheck disable=SC2016  # expanded by the eval in _git_parity_env_run's subshell
    _git_parity_env_run "${root}/${scenario}" '"${function}" "${args[@]}"; printf ".%s" "$?"' 2> "${stderr_file}"
}

# Runs every case, as the caller has set ORCHESTRATOR_DOTNET_GIT, and prints one line for each whose output or status
# differs from the fixture. Switched on, it also checks that the tool answered exactly the "answers" cases (lib/git
# warns when bash answers instead) and that git's stderr matches what the switched-off run left in $2/<case>.stderr.
_check_git_parity_cases() {
    local root="$1" count index name tool result expected expected_status failures=0 warned
    count=$(jq '.cases | length' "${GIT_FIXTURE}")
    [ "${count}" -gt 0 ] || return 1
    for ((index = 0; index < count; index++)); do
        name=$(jq -r --argjson i "${index}" '.cases[$i].name' "${GIT_FIXTURE}")
        tool=$(jq -r --argjson i "${index}" '.cases[$i].tool' "${GIT_FIXTURE}")
        expected=$(
            jq -j --argjson i "${index}" '.cases[$i].stdout' "${GIT_FIXTURE}"
            printf x
        )
        expected_status=$(jq -r --argjson i "${index}" '.cases[$i].status' "${GIT_FIXTURE}")
        result=$(_git_parity_call "${root}" "${index}" "${root}/stderr-${ORCHESTRATOR_DOTNET_GIT}-${index}")
        if [ "${result%.*}x" != "${expected}" ] || [ "${result##*.}" != "${expected_status}" ]; then
            printf 'case %d (%s): printed [%s] status %s, expected [%s] status %s\n' "${index}" "${name}" \
                "${result%.*}" "${result##*.}" "${expected%x}" "${expected_status}"
            failures=$((failures + 1))
        fi
        if [ "${ORCHESTRATOR_DOTNET_GIT}" = 1 ]; then
            warned=answers
            if grep -q 'running git in bash instead' "${root}/stderr-1-${index}"; then
                warned=refuses
            fi
            if [ "${tool}" = not-called ]; then
                tool=answers
            fi
            if [ "${warned}" != "${tool}" ]; then
                printf 'case %d (%s): the tool %s it, not %s\n' "${index}" "${name}" "${warned}" "${tool}"
                failures=$((failures + 1))
            fi
            if [ "${warned}" = answers ] && ! cmp -s "${root}/stderr-0-${index}" "${root}/stderr-1-${index}"; then
                printf 'case %d (%s): stderr differs from bash\n' "${index}" "${name}"
                failures=$((failures + 1))
            fi
        fi
    done
    [ "${failures}" -eq 0 ]
}

@test "the lib/git queries print and return what the fixture records for every git parity case (#252)" {
    local root="${BATS_TEST_TMPDIR}/root"
    _git_parity_build "${root}"
    ORCHESTRATOR_DOTNET_GIT=0
    run _check_git_parity_cases "${root}"
    if [ "${status}" -ne 0 ]; then
        printf '%s\n' "${output}"
    fi
    [ "${status}" -eq 0 ]
}

# The end-to-end check the plan asks for before each phase's PR: the same cases through the freshly built tool, given
# as ORCHESTRATOR_PARITY_CMD (for example a wrapper running the Release build of src/Credfeto.Orchestrator.Cmd), with
# git's stderr compared with the switched-off run's. Skipped when it is not set, as in CI, which has no tool on PATH.
@test "every git parity case prints and returns the same through ORCHESTRATOR_CMD when switched on (#252)" {
    [ -n "${ORCHESTRATOR_PARITY_CMD:-}" ] || skip "ORCHESTRATOR_PARITY_CMD is not set"
    local root="${BATS_TEST_TMPDIR}/root"
    _git_parity_build "${root}"
    ORCHESTRATOR_DOTNET_GIT=0
    run _check_git_parity_cases "${root}"
    [ "${status}" -eq 0 ]
    ORCHESTRATOR_DOTNET_GIT=1
    ORCHESTRATOR_CMD="${ORCHESTRATOR_PARITY_CMD}"
    run _check_git_parity_cases "${root}"
    if [ "${status}" -ne 0 ]; then
        printf '%s\n' "${output}"
    fi
    [ "${status}" -eq 0 ]
}

@test "the git parity fixture covers every lib/git query the tool answers, each answered and refused where it can be (#252)" {
    local function
    for function in checkout_head_sha checkout_current_branch checkout_has_uncommitted_changes origin_branch_exists \
        git_commits_behind find_stale_issue_branch checkout_porcelain_status checkout_changed_file_count checkout_stash_head \
        autostashes_beyond_keep; do
        [ "$(jq --arg f "${function}" '[.cases[] | select(.function == $f and .tool == "answers")] | length' "${GIT_FIXTURE}")" -gt 0 ]
    done
    [ "$(jq '[.cases[] | select(.tool == "refuses")] | length' "${GIT_FIXTURE}")" -gt 0 ]
    [ "$(jq '[.cases[] | select(.stdout == null or .status == null)] | length' "${GIT_FIXTURE}")" -eq 0 ]
}

# Rewrites the fixture's recorded results from the shell functions: GIT_PARITY_REGENERATE names the file to write.
@test "regenerate the git parity fixture when GIT_PARITY_REGENERATE is set (#252)" {
    [ -n "${GIT_PARITY_REGENERATE:-}" ] || skip "GIT_PARITY_REGENERATE is not set"
    local root="${BATS_TEST_TMPDIR}/root" count index result results="${BATS_TEST_TMPDIR}/results"
    _git_parity_build "${root}"
    ORCHESTRATOR_DOTNET_GIT=0
    count=$(jq '.cases | length' "${GIT_FIXTURE}")
    : > "${results}"
    for ((index = 0; index < count; index++)); do
        result=$(_git_parity_call "${root}" "${index}" /dev/null)
        jq -n -c --arg stdout "${result%.*}" --argjson status "${result##*.}" '{stdout: $stdout, status: $status}' >> "${results}"
    done
    jq --slurpfile r "${results}" '.cases |= [to_entries[] | .value + $r[.key]]' "${GIT_FIXTURE}" > "${GIT_PARITY_REGENERATE}"
}
