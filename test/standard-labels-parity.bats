#!/usr/bin/env bats

# cfwf is installed alone and cannot read .github/labels.yml, so the standard labels that
# "cfwf issue create" gives their colour and description when it has to create them are copied
# into cfwf as STANDARD_LABELS. These tests are the only thing stopping that copy and the file
# drifting apart.

bats_require_minimum_version 1.5.0

load test_helper

CFWF="${REPO_ROOT}/containers/base/development-full/scripts/cfwf"
LABELS_FILE="${REPO_ROOT}/.github/labels.yml"

# The labels in .github/labels.yml as name|colour|description lines, in file order. The file is a
# flat list of name/color/description triples, one key per line.
labels_file_lines() {
    awk '
        /^- name:/ { gsub(/^- name: "|"$/, ""); name = $0 }
        /^  color:/ { gsub(/^  color: "|"$/, ""); colour = $0 }
        /^  description:/ { gsub(/^  description: "|"$/, ""); print name "|" colour "|" $0 }
    ' "${LABELS_FILE}"
}

# cfwf's copy, run in a subshell so sourcing cfwf cannot replace this shell's own functions.
cfwf_lines() {
    (
        # shellcheck source=/dev/null
        source "${CFWF}"
        printf '%s\n' "${STANDARD_LABELS}"
    )
}

@test "the parser reads every label in .github/labels.yml" {
    [ "$(labels_file_lines | wc -l)" -eq "$(grep -c '^- name:' "${LABELS_FILE}")" ]
    [ "$(labels_file_lines | wc -l)" -gt 30 ]
}

@test "no standard label has a name or description that contains the | separator" {
    run grep -c '|' "${LABELS_FILE}"
    [ "${output}" -eq 0 ]
}

@test "cfwf's standard labels are exactly the labels in .github/labels.yml, with the same colour and description" {
    run diff <(labels_file_lines) <(cfwf_lines)
    [ "${status}" -eq 0 ] || {
        echo "cfwf's STANDARD_LABELS and .github/labels.yml differ (< labels.yml, > cfwf):" >&2
        echo "${output}" >&2
        return 1
    }
}

@test "every priority label cfwf issue create accepts is a standard label" {
    run bash -c 'source "$1"; [ "${#PRIORITIES[@]}" -gt 0 ] || exit 2; for p in "${PRIORITIES[@]}"; do standard_label "$p" && [ "${STANDARD_NAME}" = "$p" ] || { echo "$p is not a standard label" >&2; exit 1; }; done' _ "${CFWF}"
    [ "${status}" -eq 0 ] || { echo "${output}" >&2; return 1; }
}
