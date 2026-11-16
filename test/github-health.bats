#!/usr/bin/env bats
# shellcheck disable=SC2329  # functions in @test bodies are invoked indirectly via 'run'
# shellcheck disable=SC2030,SC2031  # bats test bodies run in subshells; variable modifications are intentionally scoped
# shellcheck disable=SC2034  # variables set in test bodies are used inside run() subshells where shellcheck cannot trace them

# Tests lib/github-health and the GitHub health gate at the start of a oneshot tick (#1846).
# GITHUB_STATUS_URL points at a fixture file (file://), so curl never reaches githubstatus.com.

load test_helper
load oneshot_helper

# Writes a githubstatus.com status-summary body to a fixture file and points GITHUB_STATUS_URL
# at it.
use_status_fixture() {
    printf '%s' "$1" >"${TEST_TMP}/github-status.json"
    GITHUB_STATUS_URL="file://${TEST_TMP}/github-status.json"
}

# A status summary with one unresolved incident named $1, created at $3, on the single component
# $2, with impact $4 (default major, so the incident is serious) and the component's live status $5
# in the summary's components list (default major_outage when the impact is major or critical,
# degraded_performance otherwise).
incident_json() {
    local impact="${4:-major}" state="${5:-}"
    if [ -z "${state}" ]; then
        state=degraded_performance
        if [ "${impact}" = major ] || [ "${impact}" = critical ]; then
            state=major_outage
        fi
    fi
    printf '{"components":[{"name":"%s","status":"%s"},{"name":"Copilot","status":"operational"}],"incidents":[{"name":"%s","status":"investigating","impact":"%s","created_at":"%s","components":[{"name":"%s"}]}]}' \
        "$2" "${state}" "$1" "${impact}" "$3" "$2"
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

@test "GITHUB_STATUS_URL defaults to the githubstatus.com status summary" {
    # shellcheck disable=SC2016  # expands in the child shell
    run env -u GITHUB_STATUS_URL BASEDIR="${REPO_ROOT}" bash -c 'source "${BASEDIR}/lib/globals"; printf "%s\n" "${GITHUB_STATUS_URL}"'
    [ "${status}" -eq 0 ]
    [ "${output}" = "https://www.githubstatus.com/api/v2/summary.json" ]
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
    use_status_fixture '{"incidents":[{"name":"Copilot is slow","created_at":"2026-11-04T09:00:00Z","components":[{"name":"Copilot"}]},{"name":"Git is down","impact":"major","created_at":"2026-11-04T10:00:00Z","components":[{"name":"Codespaces"},{"name":"Git Operations"}]}]}'
    run github_incident_open
    [ "${status}" -eq 0 ]
    [ "${output}" = $'Git is down\t2026-11-04T10:00:00Z' ]
}

@test "github_incident_open flattens tabs and newlines in the incident name to one line" {
    use_status_fixture '{"incidents":[{"name":"Git\tis\ndown","impact":"critical","created_at":"2026-11-04T10:00:00Z","components":[{"name":"Git Operations"}]}]}'
    run github_incident_open
    [ "${status}" -eq 0 ]
    [ "${output}" = $'Git is down\t2026-11-04T10:00:00Z' ]
}

# --- serious or minor (#1964) -------------------------------------------------

@test "github_incident_open reports a minor degraded incident on a used component as minor (returns 3)" {
    use_status_fixture "$(incident_json "Incident with Pull Requests" "Pull Requests" "2026-11-16T11:59:40Z" minor degraded_performance)"
    run github_incident_open
    [ "${status}" -eq 3 ]
    [ "${output}" = $'Incident with Pull Requests\t2026-11-16T11:59:40Z\tPull Requests: degraded_performance' ]
}

@test "github_incident_open treats an incident with no impact on an operational component as minor" {
    use_status_fixture "$(incident_json "Investigating" "Issues" "2026-11-16T11:59:40Z" none operational)"
    run github_incident_open
    [ "${status}" -eq 3 ]
    [ "${output}" = $'Investigating\t2026-11-16T11:59:40Z\tIssues: operational' ]
}

@test "github_incident_open reports a minor incident as serious when its component is in partial or major outage" {
    local state
    for state in partial_outage major_outage; do
        use_status_fixture "$(incident_json "Git slow" "Git Operations" "2026-11-16T11:59:40Z" minor "${state}")"
        run github_incident_open
        if [ "${status}" -ne 0 ] || [ "${output}" != $'Git slow\t2026-11-16T11:59:40Z' ]; then
            printf 'component status %s gave rc %s, output %s\n' "${state}" "${status}" "${output}" >&2
            return 1
        fi
    done
}

@test "github_incident_open reports a major or critical incident as serious even when the component is only degraded" {
    local impact
    for impact in major critical; do
        use_status_fixture "$(incident_json "Webhooks delayed" "Webhooks" "2026-11-16T11:59:40Z" "${impact}" degraded_performance)"
        run github_incident_open
        if [ "${status}" -ne 0 ]; then
            printf 'impact %s gave rc %s\n' "${impact}" "${status}" >&2
            return 1
        fi
    done
}

@test "github_incident_open reports the serious incident when a minor one on a used component is listed first" {
    use_status_fixture '{"components":[{"name":"Pull Requests","status":"degraded_performance"},{"name":"Git Operations","status":"major_outage"}],"incidents":[{"name":"PRs slow","impact":"minor","created_at":"2026-11-16T11:00:00Z","components":[{"name":"Pull Requests"}]},{"name":"Git is down","impact":"minor","created_at":"2026-11-16T12:00:00Z","components":[{"name":"Git Operations"}]}]}'
    run github_incident_open
    [ "${status}" -eq 0 ]
    [ "${output}" = $'Git is down\t2026-11-16T12:00:00Z' ]
}

@test "github_incident_open only counts the outage of a component the session uses" {
    # Actions is in major outage, but the incident's used component (Issues) is only degraded.
    use_status_fixture '{"components":[{"name":"Issues","status":"degraded_performance"},{"name":"Actions","status":"major_outage"}],"incidents":[{"name":"Mixed","impact":"minor","created_at":"2026-11-16T11:00:00Z","components":[{"name":"Actions"},{"name":"Issues"}]}]}'
    run github_incident_open
    [ "${status}" -eq 3 ]
    [ "${output}" = $'Mixed\t2026-11-16T11:00:00Z\tIssues: degraded_performance' ]
}

@test "github_incident_open ignores a major incident only on unrelated components" {
    use_status_fixture "$(incident_json "Copilot is down" "Copilot" "2026-11-16T11:00:00Z" critical major_outage)"
    run github_incident_open
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
}

@test "github_incident_open reports a minor incident's component status as unknown when the summary does not list it" {
    local body
    for body in \
        '{"incidents":[{"name":"PRs slow","impact":"minor","created_at":"2026-11-16T11:00:00Z","components":[{"name":"Pull Requests"}]}]}' \
        '{"components":"broken","incidents":[{"name":"PRs slow","impact":"minor","created_at":"2026-11-16T11:00:00Z","components":[{"name":"Pull Requests"}]}]}' \
        '{"components":[{"name":"Pull Requests"}],"incidents":[{"name":"PRs slow","impact":"minor","created_at":"2026-11-16T11:00:00Z","components":[{"name":"Pull Requests"}]}]}'; do
        use_status_fixture "${body}"
        run github_incident_open
        if [ "${status}" -ne 3 ] || [ "${output}" != $'PRs slow\t2026-11-16T11:00:00Z\tPull Requests: unknown' ]; then
            printf 'body %s gave rc %s, output %s\n' "${body}" "${status}" "${output}" >&2
            return 1
        fi
    done
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

@test "main carries on with one warning while a minor incident leaves a used component only degraded" {
    setup_gate_main
    use_status_fixture "$(incident_json "Incident with Pull Requests" "Pull Requests" "2026-11-16T11:59:40Z" minor degraded_performance)"

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"skipping work this tick"* ]]
    [[ "${output}" == *"GitHub incident open (Incident with Pull Requests, since 2026-11-16T11:59:40Z, Pull Requests: degraded_performance) — minor, continuing"* ]]
    [ "$(grep -c 'minor, continuing' <<<"${output}")" -eq 1 ]
    grep -qx 'fetch_all_priorities' "${CALLS}"
}

@test "main skips all work while a minor incident has a used component in partial outage" {
    setup_gate_main
    use_status_fixture "$(incident_json "Git slow" "Git Operations" "2026-11-16T11:59:40Z" minor partial_outage)"

    run main
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"GitHub incident open (Git slow, since 2026-11-16T11:59:40Z) — skipping work this tick"* ]]
    [[ "${output}" != *"minor, continuing"* ]]
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
