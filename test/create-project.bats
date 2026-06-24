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
    : > "${CREATE_PROJECT_GH_LOG}"
    export FIELD_CREATE_RESULT='{"data":{"createProjectV2Field":{"projectV2Field":{"id":"F_NEW","name":"Workflow Status","options":[{"id":"OPT_NS","name":"Not Started"}]}}}}'
    # shellcheck disable=SC2016  # stub body: $* / ${...} must stay literal and expand at stub runtime
    make_stub gh '
op="$*"
log="${CREATE_PROJECT_GH_LOG}"
case "${op}" in
    *--input*)                          echo "updateProjectV2Collaborators" >> "${log}"; cat >/dev/null 2>&1; printf "{}" ;;
    *"issue list"*)                     printf "%b\n" "${BOOT_ISSUE_IDS:-}" ;;
    *"pr list"*)                        printf "%b\n" "${BOOT_PR_IDS:-}" ;;
    *addProjectV2ItemById*)             echo "addProjectV2ItemById" >> "${log}"; printf "ITEM_NODE" ;;
    *updateProjectV2ItemFieldValue*)    echo "updateProjectV2ItemFieldValue" >> "${log}"; printf "{}" ;;
    *projectsV2*)                       printf "%s" "${DISCOVERY_RESULT}" ;;
    *createProjectV2Field*)             echo "createProjectV2Field" >> "${log}"; printf "%s" "${FIELD_CREATE_RESULT}" ;;
    *createProjectV2*)                  echo "createProjectV2" >> "${log}"; printf "P_NEW" ;;
    *linkProjectV2ToRepository*)        echo "linkProjectV2ToRepository" >> "${log}"; printf "{}" ;;
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

@test "provision_project skips create and link when a linked project already exists" {
    install_gh_stub
    export DISCOVERY_RESULT='{"id":"P_EXIST","fields":{"nodes":[{"id":"F1","name":"Workflow Status","options":[]}]}}'

    run provision_project credfeto scripts
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"already linked"* ]]

    run cat "${CREATE_PROJECT_GH_LOG}"
    [[ "${output}" != *"createProjectV2"* ]]
    [[ "${output}" != *"linkProjectV2ToRepository"* ]]
    [[ "${output}" == *"updateProjectV2Collaborators"* ]]
}

@test "provision_project creates, links, adds field and grants access when no project exists" {
    install_gh_stub
    export DISCOVERY_RESULT=""

    run provision_project credfeto scripts
    [ "${status}" -eq 0 ]

    run cat "${CREATE_PROJECT_GH_LOG}"
    [[ "${output}" == *"createProjectV2"* ]]
    [[ "${output}" == *"linkProjectV2ToRepository"* ]]
    [[ "${output}" == *"createProjectV2Field"* ]]
    [[ "${output}" == *"updateProjectV2Collaborators"* ]]
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
