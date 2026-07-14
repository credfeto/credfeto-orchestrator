#!/usr/bin/env bats
# shellcheck disable=SC2329  # functions in @test bodies are invoked indirectly via 'run'
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped

load test_helper

# Installs a gh stub that fakes the GraphQL endpoint create-project drives.  It branches on
# the operation in the call and emits the already-jq-filtered value the script expects, while
# appending every mutation to ${CREATE_PROJECT_GH_LOG} so tests can assert which steps ran.
# ${DISCOVERY_RESULT} controls what the repo-scoped "Workflow" project lookup returns.
install_gh_stub() {
    export CREATE_PROJECT_GH_LOG="${TEST_TMP}/gh.log"
    export CREATE_PROJECT_GH_INPUT_LOG="${TEST_TMP}/gh-input.log"
    : > "${CREATE_PROJECT_GH_LOG}"
    : > "${CREATE_PROJECT_GH_INPUT_LOG}"
    export FIELD_CREATE_RESULT='{"data":{"createProjectV2Field":{"projectV2Field":{"id":"F_NEW","name":"Workflow Status","options":[{"id":"OPT_NS","name":"Not Started"}]}}}}'
    export FIELD_OPTION_UPDATE_RESULT='{"data":{"updateProjectV2Field":{"projectV2Field":{"id":"F1","name":"Workflow Status","options":[{"id":"O1","name":"Not Started"},{"id":"O_NEW","name":"AI Simplify"}]}}}}'
    # shellcheck disable=SC2016  # stub body: $* / ${...} must stay literal and expand at stub runtime
    make_stub gh '
op="$*"
log="${CREATE_PROJECT_GH_LOG}"
case "${op}" in
    *--input*)
        body=$(cat)
        printf "%s" "${body}" >> "${CREATE_PROJECT_GH_INPUT_LOG}"
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
    export DISCOVERY_RESULT='{"id":"P_EXIST","fields":{"nodes":[{"id":"F1","name":"Workflow Status","options":[{"id":"O1","name":"Not Started"}]}]}}'
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
    export DISCOVERY_RESULT='{"id":"P_EXIST","fields":{"nodes":[{"id":"F1","name":"Workflow Status","options":[]}]}}'

    run provision_project credfeto scripts
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"already linked"* ]]

    run cat "${CREATE_PROJECT_GH_LOG}"
    [[ "${output}" != *"createProjectV2"* ]]
    [[ "${output}" != *"linkProjectV2ToRepository"* ]]
    [[ "${output}" == *"updateProjectV2Description"* ]]
    [[ "${output}" == *"updateProjectV2Collaborators"* ]]
}

@test "provision_project creates, sets description, adds field and grants access when no project exists" {
    install_gh_stub
    export DISCOVERY_RESULT=""

    run provision_project credfeto scripts
    [ "${status}" -eq 0 ]

    run cat "${CREATE_PROJECT_GH_LOG}"
    [[ "${output}" == *"createProjectV2"* ]]
    [[ "${output}" == *"updateProjectV2Description"* ]]
    [[ "${output}" == *"createProjectV2Field"* ]]
    [[ "${output}" == *"updateProjectV2Collaborators"* ]]
    # repositoryId is passed to createProjectV2 so no separate link call is needed
    [[ "${output}" != *"linkProjectV2ToRepository"* ]]
}

@test "provision_project adds a missing status field on an existing project" {
    install_gh_stub
    export DISCOVERY_RESULT='{"id":"P_EXIST","fields":{"nodes":[]}}'

    run provision_project credfeto scripts
    [ "${status}" -eq 0 ]

    run cat "${CREATE_PROJECT_GH_LOG}"
    [[ "${output}" != *"createProjectV2 "* ]]
    [[ "${output}" == *"createProjectV2Field"* ]]
    [[ "${output}" == *"updateProjectV2Collaborators"* ]]
}

@test "ensure_status_field_option adds a missing option to an existing field" {
    install_gh_stub
    local field_node='{"id":"F1","name":"Workflow Status","options":[{"id":"O1","name":"Not Started","color":"GRAY","description":""}]}'

    run ensure_status_field_option "${field_node}" "AI Simplify" PURPLE "Development"
    [ "${status}" -eq 0 ]

    run cat "${CREATE_PROJECT_GH_LOG}"
    [[ "${output}" == *"updateProjectV2FieldOptions"* ]]
}

@test "ensure_status_field_option is a no-op when the option is already present" {
    install_gh_stub
    local field_node='{"id":"F1","name":"Workflow Status","options":[{"id":"O1","name":"Not Started","color":"GRAY","description":""},{"id":"O2","name":"AI Simplify","color":"PURPLE","description":""}]}'

    run ensure_status_field_option "${field_node}" "AI Simplify" PURPLE "Development"
    [ "${status}" -eq 0 ]
    [[ "${output}" == "${field_node}" ]]

    run cat "${CREATE_PROJECT_GH_LOG}"
    [[ "${output}" != *"updateProjectV2FieldOptions"* ]]
}

@test "ensure_status_field_option sends existing option ids and their color/description so item field values and appearance are preserved" {
    install_gh_stub
    local field_node='{"id":"F1","name":"Workflow Status","options":[{"id":"O1","name":"Not Started","color":"GRAY","description":"start here"},{"id":"O2","name":"Development","color":"PURPLE","description":""}]}'

    run ensure_status_field_option "${field_node}" "AI Simplify" PURPLE "Development"
    [ "${status}" -eq 0 ]

    run cat "${CREATE_PROJECT_GH_INPUT_LOG}"
    [[ "${output}" == *'"id":"O1"'* ]]
    [[ "${output}" == *'"id":"O2"'* ]]
    [[ "${output}" == *'"color":"GRAY"'* ]]
    [[ "${output}" == *'"description":"start here"'* ]]
    [[ "${output}" == *'"name":"AI Simplify"'* ]]
}

@test "ensure_status_field_option inserts the new option immediately after after_name instead of appending at the end" {
    install_gh_stub
    local field_node='{"id":"F1","name":"Workflow Status","options":[{"id":"O1","name":"Not Started","color":"GRAY","description":""},{"id":"O2","name":"Development","color":"PURPLE","description":""},{"id":"O3","name":"AI Review","color":"ORANGE","description":""}]}'

    run ensure_status_field_option "${field_node}" "AI Simplify" PURPLE "Development"
    [ "${status}" -eq 0 ]

    run cat "${CREATE_PROJECT_GH_INPUT_LOG}"
    [[ "${output}" == *'"name":"Development"'*'"name":"AI Simplify"'*'"name":"AI Review"'* ]]
}

@test "ensure_status_field_option falls back to appending when after_name is not found among the existing options" {
    install_gh_stub
    local field_node='{"id":"F1","name":"Workflow Status","options":[{"id":"O1","name":"Not Started","color":"GRAY","description":""}]}'

    run ensure_status_field_option "${field_node}" "AI Simplify" PURPLE "Development"
    [ "${status}" -eq 0 ]

    run cat "${CREATE_PROJECT_GH_INPUT_LOG}"
    [[ "${output}" == *'"name":"Not Started"'*'"name":"AI Simplify"'* ]]
}

@test "ensure_status_field_option falls back to the original field_node when the mutation returns no field data" {
    install_gh_stub
    export FIELD_OPTION_UPDATE_RESULT='{"data":{"updateProjectV2Field":{"projectV2Field":null}}}'
    local field_node='{"id":"F1","name":"Workflow Status","options":[{"id":"O1","name":"Not Started","color":"GRAY","description":""}]}'

    run ensure_status_field_option "${field_node}" "AI Simplify" PURPLE "Development"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"returned no field data"* ]]
    [[ "${output}" == *"${field_node}" ]]
}

@test "provision_project adds the AI Simplify option to an existing field that lacks it" {
    install_gh_stub
    export DISCOVERY_RESULT='{"id":"P_EXIST","fields":{"nodes":[{"id":"F1","name":"Workflow Status","options":[{"id":"O1","name":"Not Started","color":"GRAY","description":""}]}]}}'

    run provision_project credfeto scripts
    [ "${status}" -eq 0 ]

    run cat "${CREATE_PROJECT_GH_LOG}"
    [[ "${output}" != *"createProjectV2Field"* ]]
    [[ "${output}" == *"updateProjectV2FieldOptions"* ]]
}

@test "provision_project does not touch the field when AI Simplify option already present" {
    install_gh_stub
    export DISCOVERY_RESULT='{"id":"P_EXIST","fields":{"nodes":[{"id":"F1","name":"Workflow Status","options":[{"id":"O1","name":"Not Started","color":"GRAY","description":""},{"id":"O2","name":"AI Simplify","color":"PURPLE","description":""}]}]}}'

    run provision_project credfeto scripts
    [ "${status}" -eq 0 ]

    run cat "${CREATE_PROJECT_GH_LOG}"
    [[ "${output}" != *"createProjectV2Field"* ]]
    [[ "${output}" != *"updateProjectV2FieldOptions"* ]]
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
    export DISCOVERY_RESULT='{"id":"P_EXIST","fields":{"nodes":[{"id":"F1","name":"Workflow Status","options":[{"id":"O1","name":"Not Started"}]}]}}'
    export BOOT_ISSUE_IDS='I_1\nI_2'
    export BOOT_PR_IDS='PR_9'

    run provision_project credfeto scripts
    [ "${status}" -eq 0 ]

    run cat "${CREATE_PROJECT_GH_LOG}"
    [[ "${output}" != *"addProjectV2ItemById"* ]]
}

@test "provision_project with --force-bootstrap reseeds board on existing project" {
    install_gh_stub
    export DISCOVERY_RESULT='{"id":"P_EXIST","fields":{"nodes":[{"id":"F1","name":"Workflow Status","options":[{"id":"O1","name":"Not Started"}]}]}}'
    export BOOT_ISSUE_IDS='I_1\nI_2'
    export BOOT_PR_IDS='PR_9'

    run provision_project credfeto scripts true
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Added 3 open item(s)"* ]]

    run grep -c addProjectV2ItemById "${CREATE_PROJECT_GH_LOG}"
    [ "${output}" -eq 3 ]
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
