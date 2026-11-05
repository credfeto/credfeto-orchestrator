#!/usr/bin/env bats
# shellcheck disable=SC2329  # functions in @test bodies are invoked indirectly via 'run'
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are used inside run() subshells where shellcheck cannot trace them

# Tests lib/github-health and the GitHub health gate at the start of a oneshot tick (#1846).
# GITHUB_STATUS_URL points at a fixture file (file://), so curl never reaches githubstatus.com.

load test_helper
load oneshot_helper

# Writes a githubstatus.com unresolved-incidents body to a fixture file and points
# GITHUB_STATUS_URL at it.
use_status_fixture() {
    printf '%s' "$1" >"${TEST_TMP}/github-status.json"
    GITHUB_STATUS_URL="file://${TEST_TMP}/github-status.json"
}

# One unresolved incident named $1, created at $3, on the single component $2.
incident_json() {
    printf '{"incidents":[{"name":"%s","status":"investigating","created_at":"%s","components":[{"name":"%s"}]}]}' \
        "$1" "$3" "$2"
}

# main() with one open Issue in the feed. Each call that matters to the gate logs to
# ${TEST_TMP}/calls: the priorities fetch, the agent launch and the idle-budget writes.
setup_gate_main() {
    setup_main_mocks
    CALLS="${TEST_TMP}/calls"
    : >"${CALLS}"
    resolve_gh_me() {
        printf 'resolve_gh_me\n' >>"${CALLS}"
        _GH_ME=testuser
        return 0
    }
    fetch_all_priorities() {
        printf 'fetch_all_priorities\n' >>"${CALLS}"
        printf '%s\n' '[{"id":1,"itemType":"Issue","repository":"org/repo","priority":1,"status":"Open","isOnHold":false}]'
    }
    invoke_claude() {
        printf 'invoke_claude\n' >>"${CALLS}"
        return 0
    }
    save_pr_invocation_counts() { printf 'save_pr_invocation_counts\n' >>"${CALLS}"; }
    save_issue_invocation_counts() { printf 'save_issue_invocation_counts\n' >>"${CALLS}"; }
    block_pr_for_idle_exhausted_no_progress() { printf 'block_pr_for_idle_exhausted_no_progress\n' >>"${CALLS}"; }
    find_open_nonblocked_pr_for_repo() { printf ''; }
    fetch_issue_json() { printf '{"title":"T","body":"","state":"OPEN","labels":[{"name":"Blocked"}],"comments":[],"assignees":[],"milestone":null}\n'; }
    issue_json_has_blocked_label() { return 0; }
}

# --- github_incident_open ----------------------------------------------------

@test "GITHUB_STATUS_URL defaults to the githubstatus.com unresolved-incidents feed" {
    # shellcheck disable=SC2016  # expands in the child shell
    run env -u GITHUB_STATUS_URL BASEDIR="${REPO_ROOT}" bash -c 'source "${BASEDIR}/lib/globals"; printf "%s\n" "${GITHUB_STATUS_URL}"'
    [ "${status}" -eq 0 ]
    [ "${output}" = "https://www.githubstatus.com/api/v2/incidents/unresolved.json" ]
}

@test "the test environment points GITHUB_STATUS_URL at a healthy fixture, never the network" {
    [[ "${GITHUB_STATUS_URL}" == file://* ]]
    run github_incident_open
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
}

@test "github_incident_open reports an open Git Operations incident with its name and start time" {
    use_status_fixture "$(incident_json "Disruption with some GitHub services" "Git Operations" "2026-11-04T10:15:00Z")"
    run github_incident_open
    [ "${status}" -eq 0 ]
    [ "${output}" = $'Disruption with some GitHub services\t2026-11-04T10:15:00Z' ]
}

@test "github_incident_open reports an incident on each component a session depends on" {
    local component
    for component in "Git Operations" "Pull Requests" "Issues" "API Requests" "Webhooks"; do
        use_status_fixture "$(incident_json "Outage" "${component}" "2026-11-04T10:15:00Z")"
        run github_incident_open
        if [ "${status}" -ne 0 ]; then
            printf 'not reported for component: %s (rc %s)\n' "${component}" "${status}" >&2
            return 1
        fi
    done
}

@test "github_incident_open ignores an incident only on unrelated components" {
    use_status_fixture '{"incidents":[{"name":"Copilot is slow","status":"investigating","created_at":"2026-11-04T10:15:00Z","components":[{"name":"Copilot"},{"name":"Codespaces"}]}]}'
    run github_incident_open
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
}

@test "github_incident_open ignores an incident without components" {
    use_status_fixture '{"incidents":[{"name":"Investigating","status":"investigating","created_at":"2026-11-04T10:15:00Z","components":[]},{"name":"Other","created_at":"2026-11-04T10:16:00Z","components":null}]}'
    run github_incident_open
    [ "${status}" -eq 1 ]
}

@test "github_incident_open returns 1 when there are no unresolved incidents" {
    use_status_fixture '{"page":{"id":"x"},"incidents":[]}'
    run github_incident_open
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
}

@test "github_incident_open reports the relevant incident when an unrelated one is listed first" {
    use_status_fixture '{"incidents":[{"name":"Copilot is slow","created_at":"2026-11-04T09:00:00Z","components":[{"name":"Copilot"}]},{"name":"Git is down","created_at":"2026-11-04T10:00:00Z","components":[{"name":"Codespaces"},{"name":"Git Operations"}]}]}'
    run github_incident_open
    [ "${status}" -eq 0 ]
    [ "${output}" = $'Git is down\t2026-11-04T10:00:00Z' ]
}

@test "github_incident_open flattens tabs and newlines in the incident name to one line" {
    use_status_fixture '{"incidents":[{"name":"Git\tis\ndown","created_at":"2026-11-04T10:00:00Z","components":[{"name":"Git Operations"}]}]}'
    run github_incident_open
    [ "${status}" -eq 0 ]
    [ "${output}" = $'Git is down\t2026-11-04T10:00:00Z' ]
}

@test "github_incident_open fails open (returns 2) when the status endpoint cannot be reached" {
    GITHUB_STATUS_URL="file://${TEST_TMP}/does-not-exist.json"
    run github_incident_open
    [ "${status}" -eq 2 ]
    [ -z "${output}" ]
}

@test "github_incident_open fails open (returns 2) on invalid JSON" {
    use_status_fixture '<html>502 Bad Gateway</html>'
    run github_incident_open
    [ "${status}" -eq 2 ]
    [ -z "${output}" ]
}

@test "github_incident_open fails open (returns 2) on JSON without an incidents array" {
    local body
    for body in '[]' 'null' '{"incidents":"none"}' '{"page":{}}'; do
        use_status_fixture "${body}"
        run github_incident_open
        if [ "${status}" -ne 2 ]; then
            printf 'body %s gave rc %s\n' "${body}" "${status}" >&2
            return 1
        fi
    done
}

@test "github_incident_open bounds the status request with a connect and a total timeout" {
    # shellcheck disable=SC2016  # the stub body expands at stub run time
    make_stub curl 'printf "%s\n" "$@" > "${TEST_TMP}/curl-args"; exit 28'
    run github_incident_open
    [ "${status}" -eq 2 ]
    grep -qx -- '--connect-timeout' "${TEST_TMP}/curl-args"
    grep -qx -- '--max-time' "${TEST_TMP}/curl-args"
    grep -qx -- '--fail' "${TEST_TMP}/curl-args"
    grep -qxF -- "${GITHUB_STATUS_URL}" "${TEST_TMP}/curl-args"
}

# --- main: the GitHub health gate ---------------------------------------------

@test "main skips all work and exits 0 while a Git Operations incident is open" {
    setup_gate_main
    use_status_fixture "$(incident_json "Incident with Git Operations" "Git Operations" "2026-11-04T10:15:00Z")"

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"GitHub incident open (Incident with Git Operations, since 2026-11-04T10:15:00Z) — skipping work this tick"* ]]
    [ "$(grep -c 'skipping work this tick' <<<"${output}")" -eq 1 ]
    # No priorities fetch, no gh call, no session, and so no idle budget charged.
    [ ! -s "${CALLS}" ]
}

@test "main skips all work while an Issues incident is open" {
    setup_gate_main
    use_status_fixture "$(incident_json "Issues degraded" "Issues" "2026-11-04T10:15:00Z")"

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"GitHub incident open (Issues degraded"* ]]
    [ ! -s "${CALLS}" ]
}

@test "main carries on when the only open incident is on an unrelated component" {
    setup_gate_main
    use_status_fixture "$(incident_json "Copilot is slow" "Copilot" "2026-11-04T10:15:00Z")"

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"skipping work this tick"* ]]
    grep -qx 'fetch_all_priorities' "${CALLS}"
}

@test "main carries on (fails open) when the status endpoint cannot be reached" {
    setup_gate_main
    GITHUB_STATUS_URL="file://${TEST_TMP}/does-not-exist.json"

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"skipping work this tick"* ]]
    [[ "${output}" == *"Could not read GitHub status"* ]]
    grep -qx 'fetch_all_priorities' "${CALLS}"
}

@test "main carries on (fails open) when the status endpoint returns invalid JSON" {
    setup_gate_main
    use_status_fixture 'not json'

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"skipping work this tick"* ]]
    grep -qx 'fetch_all_priorities' "${CALLS}"
}

@test "main checks GitHub's status before resolving the login or fetching priorities" {
    setup_gate_main
    github_incident_open() {
        printf 'github_incident_open\n' >>"${CALLS}"
        return 1
    }

    run main
    [ "${status}" -eq 0 ]
    [ "$(head -n 1 "${CALLS}")" = "github_incident_open" ]
    grep -qx 'fetch_all_priorities' "${CALLS}"
}
