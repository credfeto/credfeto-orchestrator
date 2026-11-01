#!/usr/bin/env bats
# shellcheck disable=SC2329  # functions in @test bodies are invoked indirectly via 'run'
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are used inside run() subshells where shellcheck cannot trace them

bats_require_minimum_version 1.5.0

load test_helper
load oneshot_helper

# Builds a repository tree under REPO_WORK_DIR holding files that match the
# shipped patterns, files that do not, and a matching file under .git that
# must be left alone, and points SECRET_FILES_DIR at a private copy of the
# shipped pattern list.
make_secret_fixture() {
    mkdir -p "${REPO_WORK_DIR}/cfg" "${REPO_WORK_DIR}/src" "${REPO_WORK_DIR}/.git"
    printf 'TOKEN=x\n' > "${REPO_WORK_DIR}/.env"
    printf 'TOKEN=x\n' > "${REPO_WORK_DIR}/cfg/.env"
    printf 'TOKEN=x\n' > "${REPO_WORK_DIR}/.env.example"
    printf 'TOKEN=x\n' > "${REPO_WORK_DIR}/app.env"
    printf '{}\n' > "${REPO_WORK_DIR}/.database"
    printf 'hello\n' > "${REPO_WORK_DIR}/src/readme.txt"
    printf 'x\n' > "${REPO_WORK_DIR}/.git/x.env"
    SECRET_FILES_DIR="${TEST_TMP}/secret-list"
    mkdir -p "${SECRET_FILES_DIR}"
    cp "${REPO_ROOT}/containers/base/development-full/claude-hooks/secret-files" "${SECRET_FILES_DIR}/secret-files"
}

has_mask() {
    local want="/dev/null:${CONTAINER_REPO_PATH}/$1:ro" arg
    for arg in "${PODMAN_RUN_ARGS[@]}"; do
        [ "${arg}" = "${want}" ] && return 0
    done
    return 1
}

@test "every file matching a shipped pattern is masked with a read-only /dev/null mount" {
    make_secret_fixture
    PODMAN_RUN_ARGS=()
    add_secret_mask_podman_args 2>/dev/null
    has_mask ".env"
    has_mask "cfg/.env"
    has_mask ".env.example"
    has_mask "app.env"
    has_mask ".database"
    [ "${#PODMAN_RUN_ARGS[@]}" -eq 10 ]
}

@test "a file matching no pattern, and anything under .git, is not masked" {
    make_secret_fixture
    PODMAN_RUN_ARGS=()
    add_secret_mask_podman_args 2>/dev/null
    run ! has_mask "src/readme.txt"
    run ! has_mask ".git/x.env"
}

@test "each mask is passed as a --volume argument" {
    make_secret_fixture
    PODMAN_RUN_ARGS=()
    add_secret_mask_podman_args 2>/dev/null
    local i
    for (( i = 0; i < ${#PODMAN_RUN_ARGS[@]}; i += 2 )); do
        [ "${PODMAN_RUN_ARGS[$i]}" = "--volume" ]
        [[ "${PODMAN_RUN_ARGS[$((i + 1))]}" == /dev/null:* ]]
    done
}

@test "the masked paths are reported in a warning" {
    make_secret_fixture
    PODMAN_RUN_ARGS=()
    run add_secret_mask_podman_args
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Masking secret-bearing files in the agent container:"* ]]
    [[ "${output}" == *"cfg/.env"* ]]
    [[ "${output}" == *".database"* ]]
}

@test "a repository with no secret file adds no mount and no warning" {
    mkdir -p "${REPO_WORK_DIR}/src"
    printf 'hello\n' > "${REPO_WORK_DIR}/src/readme.txt"
    SECRET_FILES_DIR="${TEST_TMP}/secret-list"
    mkdir -p "${SECRET_FILES_DIR}"
    cp "${REPO_ROOT}/containers/base/development-full/claude-hooks/secret-files" "${SECRET_FILES_DIR}/secret-files"
    PODMAN_RUN_ARGS=()
    run add_secret_mask_podman_args
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    add_secret_mask_podman_args
    [ "${#PODMAN_RUN_ARGS[@]}" -eq 0 ]
}

@test "secret-files.local takes precedence over secret-files" {
    make_secret_fixture
    printf 'x\n' > "${REPO_WORK_DIR}/cfg/key.secret"
    printf '%s\n' '# local only' '' '  *.secret  ' > "${SECRET_FILES_DIR}/secret-files.local"
    PODMAN_RUN_ARGS=()
    add_secret_mask_podman_args 2>/dev/null
    has_mask "cfg/key.secret"
    run ! has_mask ".env"
    [ "${#PODMAN_RUN_ARGS[@]}" -eq 2 ]
}

@test "a missing pattern list stops the launch" {
    make_secret_fixture
    rm "${SECRET_FILES_DIR}/secret-files"
    PODMAN_RUN_ARGS=()
    run add_secret_mask_podman_args
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"is missing or unreadable"* ]]
}

@test "a pattern list with no pattern stops the launch" {
    make_secret_fixture
    printf '# nothing\n\n' > "${SECRET_FILES_DIR}/secret-files"
    PODMAN_RUN_ARGS=()
    run add_secret_mask_podman_args
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"lists no pattern"* ]]
}

@test "invoke_claude masks a secret file in the repository when it starts the container" {
    local args_log="${TEST_TMP}/podman_args"
    stub_podman_run_logging_args "${args_log}"
    printf 'TOKEN=x\n' > "${REPO_WORK_DIR}/.env"
    invoke_claude "test prompt" "Issue" "42" "# mock CLAUDE.md" 2>/dev/null
    grep -qx "/dev/null:${CONTAINER_REPO_PATH}/.env:ro" "${args_log}"
}
