#!/usr/bin/env bats
# shellcheck disable=SC2329  # functions in @test bodies are invoked indirectly via 'run'
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped

load test_helper

# Installs a gh stub that fakes the GraphQL endpoint create-project drives.  It branches on
# the operation in the call and emits the already-jq-filtered value the script expects, while
# appending every mutation to ${CREATE_PROJECT_GH_LOG} so tests can assert which steps ran.
# ${DISCOVERY_RESULT} controls what the repo-scoped "Workflow" project lookup returns.
# ${CREATE_PROJECT_GH_FAIL} names a mutation (a substring of the call, or of the JSON body for
# --input calls) whose gh call should fail with "boom: <name>" on stderr and exit status 1.
install_gh_stub() {
    export CREATE_PROJECT_GH_LOG="${TEST_TMP}/gh.log"
    export CREATE_PROJECT_GH_INPUT_LOG="${TEST_TMP}/gh-input.log"
    : > "${CREATE_PROJECT_GH_LOG}"
    : > "${CREATE_PROJECT_GH_INPUT_LOG}"
    # The conversion of the Status field is tested on its own in test/project-status.bats, so
    # here project_status_convert is replaced: it logs its call and sets PROJECT_STATUS_FIELD to
    # ${CONVERT_RESULT}, or, when ${CONVERT_FAIL_STEP} is set, fails with that step, as
    # lib/project-status does.
    export CONVERT_RESULT='{"id":"F_STATUS","name":"Status","options":[{"id":"OPT_NS","name":"Not Started"}]}'
    project_status_convert() {
        echo "project_status_convert $1" >> "${CREATE_PROJECT_GH_LOG}"
        if [ -n "${CONVERT_FAIL_STEP:-}" ]; then
            # shellcheck disable=SC2034  # read by create-project's ensure_status_field
            PROJECT_STATUS_FAILED_STEP="${CONVERT_FAIL_STEP}"
            return 1
        fi
        # shellcheck disable=SC2034  # read by create-project's ensure_status_field
        PROJECT_STATUS_FIELD="${CONVERT_RESULT}"
    }
    # shellcheck disable=SC2016  # stub body: $* / ${...} must stay literal and expand at stub runtime
    make_stub gh '
op="$*"
log="${CREATE_PROJECT_GH_LOG}"
fail="${CREATE_PROJECT_GH_FAIL:-}"
if [ -n "${fail}" ] && [[ "${op}" == *"${fail}"* ]]; then
    echo "boom: ${fail}" >&2
    exit 1
fi
case "${op}" in
    *--input*)
        body=$(cat)
        printf "%s" "${body}" >> "${CREATE_PROJECT_GH_INPUT_LOG}"
        if [ -n "${fail}" ] && [[ "${body}" == *"${fail}"* ]]; then
            echo "boom: ${fail}" >&2
            exit 1
        fi
        case "${body}" in
            *updateProjectV2Field*)   echo "updateProjectV2FieldOptions" >> "${log}"; printf "%s" "${FIELD_OPTION_UPDATE_RESULT}" ;;
            *)                        echo "updateProjectV2Collaborators" >> "${log}"; printf "{}" ;;
        esac
        ;;
    *"issue list"*)                     printf "%b\n" "${BOOT_ISSUE_IDS:-}" ;;
    *"pr list"*)                        printf "%b\n" "${BOOT_PR_IDS:-}" ;;
    *addProjectV2ItemById*)             echo "addProjectV2ItemById" >> "${log}"; printf "ITEM_NODE" ;;
    *updateProjectV2ItemFieldValue*)    echo "updateProjectV2ItemFieldValue" >> "${log}"; printf "{}" ;;
    *updateProjectV2*)                  echo "updateProjectV2Description" >> "${log}"; printf "{}" ;;
    *shortDescription*)                 printf "%s" "${PROJECT_SHORT_DESC:-}" ;;
    *projectsV2*)                       printf "%s" "${DISCOVERY_RESULT}" ;;
    *createProjectV2Field*)             echo "createProjectV2Field" >> "${log}"; printf "%s" "${FIELD_CREATE_RESULT}" ;;
    *createProjectV2*)                  echo "createProjectV2" >> "${log}"; printf "P_NEW" ;;
    *hasProjectsEnabled*)               printf "%s" "${PROJECTS_ENABLED:-true}" ;;
    *"repo edit"*"--enable-projects"*)  echo "enableProjects" >> "${log}" ;;
    *organization*)                     printf "" ;;
    *user*)                             printf "U_NODE" ;;
    *repository*)                       printf "R_NODE" ;;
    *)                                  printf "" ;;
esac
'
}

setup() {
    setup_isolated_env
    source_create_project
}

teardown() {
    cleanup_stubs
}

@test "sourcing create-project defines main without executing it" {
    run declare -F main
    [ "${status}" -eq 0 ]
    run declare -F provision_project
    [ "${status}" -eq 0 ]
}

@test "main dies with usage when --repo is omitted" {
    run main
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Usage:"* ]]
}

@test "main dies when --repo has no value" {
    run main --repo
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"--repo requires a value"* ]]
}

@test "main dies on a malformed --repo value" {
    run main --repo not-a-repo
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"<owner>/<repo>"* ]]
}

@test "main dies on an unknown argument" {
    run main --bogus
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Unknown argument"* ]]
}

@test "main accepts --force-bootstrap without dying" {
    install_gh_stub
    export DISCOVERY_RESULT='{"id":"P_EXIST","fields":{"nodes":[{"id":"F1","name":"Status","options":[{"id":"O1","name":"Not Started"}]}]}}'
    run main --repo credfeto/scripts --force-bootstrap
    [ "${status}" -eq 0 ]
}

@test "check_required_tools dies when gh is missing" {
    # shellcheck disable=SC2329
    command() {
        if [ "$1" = "-v" ] && [ "$2" = "gh" ]; then
            return 1
        fi
        builtin command "$@"
    }
    run check_required_tools
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"gh"* ]]
}

@test "provision_project skips create when a linked project already exists and updates description" {
    install_gh_stub
    export DISCOVERY_RESULT='{"id":"P_EXIST","fields":{"nodes":[{"id":"F1","name":"Status","options":[]}]}}'

    run provision_project credfeto scripts
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"already linked"* ]]

    run cat "${CREATE_PROJECT_GH_LOG}"
    [[ "${output}" != *"createProjectV2"* ]]
    [[ "${output}" != *"linkProjectV2ToRepository"* ]]
    [[ "${output}" == *"updateProjectV2Description"* ]]
    [[ "${output}" == *"updateProjectV2Collaborators"* ]]
}

@test "provision_project creates, sets description, converts the Status field and grants access when no project exists" {
    install_gh_stub
    export DISCOVERY_RESULT=""

    run provision_project credfeto scripts
    [ "${status}" -eq 0 ]

    run cat "${CREATE_PROJECT_GH_LOG}"
    [[ "${output}" == *"createProjectV2"* ]]
    [[ "${output}" == *"updateProjectV2Description"* ]]
    # The new project's built-in Status field is converted; no custom field is created (#1519).
    [[ "${output}" == *"project_status_convert P_NEW"* ]]
    [[ "${output}" != *"createProjectV2Field"* ]]
    [[ "${output}" == *"updateProjectV2Collaborators"* ]]
    # repositoryId is passed to createProjectV2 so no separate link call is needed
    [[ "${output}" != *"linkProjectV2ToRepository"* ]]
}

@test "provision_project converts the Status field of an existing project (#1519)" {
    install_gh_stub
    export DISCOVERY_RESULT='{"id":"P_EXIST","fields":{"nodes":[]}}'

    run provision_project credfeto scripts
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Status field carries the workflow states"* ]]

    run cat "${CREATE_PROJECT_GH_LOG}"
    [[ "${output}" != *"createProjectV2 "* ]]
    [[ "${output}" == *"project_status_convert P_EXIST"* ]]
    [[ "${output}" == *"updateProjectV2Collaborators"* ]]
}

@test "provision_project exits non-zero naming the failed step when the Status conversion fails, and does not go on (#1519)" {
    install_gh_stub
    export DISCOVERY_RESULT='{"id":"P_EXIST","fields":{"nodes":[]}}'
    export CONVERT_FAIL_STEP="deleting the Workflow Status field"

    run provision_project credfeto scripts true
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Could not set up the Status field: deleting the Workflow Status field failed"* ]]
    [[ "${output}" != *"Status field carries the workflow states"* ]]
    [[ "${output}" != *"Workflow project ready"* ]]

    run cat "${CREATE_PROJECT_GH_LOG}"
    [[ "${output}" != *"updateProjectV2Collaborators"* ]]
    [[ "${output}" != *"addProjectV2ItemById"* ]]
}

@test "provision_project exits non-zero when the conversion returns no field id (#1519)" {
    install_gh_stub
    export DISCOVERY_RESULT='{"id":"P_EXIST","fields":{"nodes":[]}}'
    export CONVERT_RESULT='{"id":null,"options":[]}'

    run provision_project credfeto scripts true
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Could not find the built-in Status field"* ]]
    [[ "${output}" != *"Workflow project ready"* ]]

    run cat "${CREATE_PROJECT_GH_LOG}"
    [[ "${output}" != *"addProjectV2ItemById"* ]]
}

@test "provision_project seeds open issues and PRs as Not Started on creation" {
    install_gh_stub
    export DISCOVERY_RESULT=""
    export BOOT_ISSUE_IDS='I_1\nI_2'
    export BOOT_PR_IDS='PR_9'

    run provision_project credfeto scripts
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Added 3 open item(s)"* ]]

    run grep -c addProjectV2ItemById "${CREATE_PROJECT_GH_LOG}"
    [ "${output}" -eq 3 ]
    run grep -c updateProjectV2ItemFieldValue "${CREATE_PROJECT_GH_LOG}"
    [ "${output}" -eq 3 ]
}

@test "provision_project does not seed the board when the project already exists" {
    install_gh_stub
    export DISCOVERY_RESULT='{"id":"P_EXIST","fields":{"nodes":[{"id":"F1","name":"Status","options":[{"id":"O1","name":"Not Started"}]}]}}'
    export BOOT_ISSUE_IDS='I_1\nI_2'
    export BOOT_PR_IDS='PR_9'

    run provision_project credfeto scripts
    [ "${status}" -eq 0 ]

    run cat "${CREATE_PROJECT_GH_LOG}"
    [[ "${output}" != *"addProjectV2ItemById"* ]]
}

@test "provision_project with --force-bootstrap reseeds board on existing project" {
    install_gh_stub
    export DISCOVERY_RESULT='{"id":"P_EXIST","fields":{"nodes":[{"id":"F1","name":"Status","options":[{"id":"O1","name":"Not Started"}]}]}}'
    export BOOT_ISSUE_IDS='I_1\nI_2'
    export BOOT_PR_IDS='PR_9'

    run provision_project credfeto scripts true
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Added 3 open item(s)"* ]]

    run grep -c addProjectV2ItemById "${CREATE_PROJECT_GH_LOG}"
    [ "${output}" -eq 3 ]
}

@test "bootstrap_board_items dies when gh issue list fails" {
    make_stub gh '
        case "$*" in
            *"issue list"*) exit 1 ;;
            *)              exit 0 ;;
        esac
    '
    run bootstrap_board_items credfeto scripts P_TEST F_TEST O_TEST
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Failed to list open issues"* ]]
}

@test "bootstrap_board_items dies when gh pr list fails" {
    make_stub gh '
        case "$*" in
            *"issue list"*) exit 0 ;;
            *"pr list"*)    exit 1 ;;
            *)              exit 0 ;;
        esac
    '
    run bootstrap_board_items credfeto scripts P_TEST F_TEST O_TEST
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Failed to list open PRs"* ]]
}

@test "ensure_bot_collaborator warns and continues when bot user cannot be resolved" {
    make_stub gh 'exit 1'
    run ensure_bot_collaborator "P_TEST"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Could not resolve node ID for bot user"* ]]
}

@test "ensure_project_description sets description when not yet set" {
    make_stub gh '
case "$*" in
    *shortDescription*)  printf "" ;;
    *updateProjectV2*)   printf "{}" ;;
    *)                   exit 1 ;;
esac
'
    run ensure_project_description "P_TEST" "credfeto/scripts"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Description set"* ]]
}

@test "ensure_project_description skips update when description is already correct" {
    make_stub gh '
case "$*" in
    *shortDescription*)  printf "Workflow for credfeto/scripts" ;;
    *)                   exit 1 ;;
esac
'
    run ensure_project_description "P_TEST" "credfeto/scripts"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"already correct"* ]]
}

@test "resolve_owner_node_id falls back to user query when org query returns JSON error blob" {
    # gh api graphql outputs the raw JSON response body when there is an error (before --jq runs),
    # so the org query returns a JSON object rather than null.  Verify the user query is tried.
    # shellcheck disable=SC2016  # stub body: $* must stay literal and expand at stub runtime
    make_stub gh '
case "$*" in
    *organization*)  printf '"'"'{"data":{"organization":null},"errors":[{"message":"NOT_FOUND"}]}'"'"' ;;
    *user*)          printf "U_REAL\n" ;;
    *)               exit 1 ;;
esac
'
    run resolve_owner_node_id testowner
    [ "${status}" -eq 0 ]
    [ "${output}" = "U_REAL" ]
}

@test "provision_project exits non-zero when owner node ID cannot be resolved" {
    # shellcheck disable=SC2016  # stub body: $* must stay literal and expand at stub runtime
    make_stub gh '
case "$*" in
    *projectsV2*)    printf "" ;;
    *repository*)    printf "R_NODE" ;;
    *organization*)  printf "" ;;
    *user*)          printf "" ;;
    *)               printf "" ;;
esac
'
    run provision_project noexist scripts
    [ "${status}" -ne 0 ]
}

@test "ensure_projects_enabled enables Projects when hasProjectsEnabled is false" {
    install_gh_stub
    export PROJECTS_ENABLED="false"

    run ensure_projects_enabled credfeto scripts
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Projects enabled"* ]]

    run grep enableProjects "${CREATE_PROJECT_GH_LOG}"
    [ "${status}" -eq 0 ]
}

@test "ensure_projects_enabled skips when hasProjectsEnabled is already true" {
    install_gh_stub
    export PROJECTS_ENABLED="true"

    run ensure_projects_enabled credfeto scripts
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"enabling"* ]]

    run grep -c enableProjects "${CREATE_PROJECT_GH_LOG}"
    [ "${output}" -eq 0 ]
}

@test "provision_project enables Projects when disabled before discovering or creating project" {
    install_gh_stub
    export DISCOVERY_RESULT=""
    export PROJECTS_ENABLED="false"

    run provision_project credfeto scripts
    [ "${status}" -eq 0 ]

    run cat "${CREATE_PROJECT_GH_LOG}"
    [[ "${output}" == *"enableProjects"* ]]
    [[ "${output}" == *"createProjectV2"* ]]
}
