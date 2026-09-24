#!/usr/bin/env bats

# The development guides under docs/development only help if they exist for every script and
# their links work, so this suite fails when a script has no guide, a lib module or hook is not
# covered, a relative link is broken, or the local AI instructions stop pointing at the guides.
# CONTRIBUTING.md is deliberately not checked: it is rewritten from a template by an external sync
# (the "[Documentation] Updated CONTRIBUTING.md" commits), so nothing here can rely on its content.

load test_helper

GUIDES="${REPO_ROOT}/docs/development"
IMAGE_SCRIPTS="${REPO_ROOT}/containers/base/development-full/scripts"
HOOKS="${REPO_ROOT}/containers/base/development-full/claude-hooks"

# Prints the name of every script in the repository: executables with a shebang at the repository
# root, and the ones baked into the agent image.
script_names() {
    local file
    for file in "${REPO_ROOT}"/* "${IMAGE_SCRIPTS}"/*; do
        [ -f "${file}" ] && [ -x "${file}" ] || continue
        [ "$(head -c 2 "${file}")" = "#!" ] || continue
        basename "${file}"
    done
}

# Prints "<file>: <target>" for every relative link in the given markdown files whose target does
# not exist. Links to a URL, a mail address or a heading in the same file are skipped, and a
# "#heading" suffix is ignored.
broken_links() {
    local file target path
    for file in "$@"; do
        while IFS= read -r target; do
            case "${target}" in
                http://* | https://* | mailto:* | '#'*) continue ;;
            esac
            path="${target%%#*}"
            [ -n "${path}" ] || continue
            [ -e "$(dirname "${file}")/${path}" ] || printf '%s: %s\n' "${file#"${REPO_ROOT}"/}" "${target}"
        done < <(grep -o '\]([^)]*)' "${file}" | sed -e 's/^](//' -e 's/)$//')
    done
}

@test "the scripts are found, so the guide checks below are not vacuous" {
    local names
    names=$(script_names)
    [[ "${names}" == *"oneshot"* ]]
    [[ "${names}" == *"cfwf"* ]]
    [ "$(printf '%s\n' "${names}" | wc -l)" -ge 12 ]
}

@test "every script has a guide under docs/development/scripts" {
    local name missing=""
    while IFS= read -r name; do
        [ -f "${GUIDES}/scripts/${name}.md" ] || missing+="${name} "
    done < <(script_names)
    [ -z "${missing}" ] || { printf 'no guide for: %s\n' "${missing}" >&2; return 1; }
}

@test "every script guide is listed in the development guide" {
    local name missing=""
    while IFS= read -r name; do
        grep -qF "(scripts/${name}.md)" "${GUIDES}/README.md" || missing+="${name} "
    done < <(script_names)
    [ -z "${missing}" ] || { printf 'not listed in docs/development/README.md: %s\n' "${missing}" >&2; return 1; }
}

@test "every file under docs/development/scripts is a guide for a script that exists" {
    local guide name extra=""
    for guide in "${GUIDES}"/scripts/*.md; do
        name=$(basename "${guide}" .md)
        script_names | grep -qxF "${name}" || extra+="${name} "
    done
    [ -z "${extra}" ] || { printf 'guide without a script: %s\n' "${extra}" >&2; return 1; }
}

@test "the lib guide covers every module under lib/" {
    local file missing=""
    for file in "${REPO_ROOT}"/lib/*; do
        grep -qF "lib/$(basename "${file}")" "${GUIDES}/lib.md" || grep -qF "\`$(basename "${file}")\`" "${GUIDES}/lib.md" || missing+="$(basename "${file}") "
    done
    [ -z "${missing}" ] || { printf 'not covered in lib.md: %s\n' "${missing}" >&2; return 1; }
}

@test "the hooks guide covers every hook and permission file" {
    local file missing=""
    for file in "${HOOKS}"/*; do
        grep -qF "$(basename "${file}")" "${GUIDES}/claude-hooks.md" || missing+="$(basename "${file}") "
    done
    [ -z "${missing}" ] || { printf 'not covered in claude-hooks.md: %s\n' "${missing}" >&2; return 1; }
}

@test "every relative link in the development guides and the guides instruction file resolves" {
    local broken
    broken=$(broken_links "${GUIDES}/README.md" "${GUIDES}/lib.md" "${GUIDES}/claude-hooks.md" "${GUIDES}"/scripts/*.md \
        "${REPO_ROOT}/ai/local/development-guides.instructions.md")
    [ -z "${broken}" ] || { printf 'broken links:\n%s\n' "${broken}" >&2; return 1; }
}

@test "the link checker reports a link to a file that does not exist" {
    local file="${BATS_TEST_TMPDIR}/probe.md"
    printf '[gone](does-not-exist.md) and [here](probe.md) and [web](https://example.com) and [anchor](#top)\n' > "${file}"
    run broken_links "${file}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"does-not-exist.md"* ]]
    [[ "${output}" != *"probe.md)"* ]]
    [ "$(printf '%s\n' "${output}" | wc -l)" -eq 1 ]
}

@test "the local AI instructions index the guides instruction file, and the README points at the guides" {
    grep -qF "(development-guides.instructions.md)" "${REPO_ROOT}/ai/local/index.md"
    grep -qF "docs/development/README.md" "${REPO_ROOT}/README.md"
    grep -qF "docs/development/README.md" "${REPO_ROOT}/ai/local/development-guides.instructions.md"
}
