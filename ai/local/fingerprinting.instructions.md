<!-- Locally Maintained -->
# Fingerprinting Instructions

[Back to Local Instructions Index](index.md)

> Load when: adding, removing, or changing which fields `fingerprint_issue_json` or `fingerprint_pr_json` (`lib/fingerprints`) hash, or when investigating why an Issue/PR is stuck as "unchanged".

For a plain-English explanation of what fingerprinting is and why it exists, see [docs/fingerprinting.md](../../docs/fingerprinting.md).

## Schema Version (MANDATORY)

`FINGERPRINT_SCHEMA_VERSION` (`lib/globals`) is prepended to every fingerprint `oneshot` computes (`<version>:<sha256-hash>`), for both Issues and PRs.

**Bump `FINGERPRINT_SCHEMA_VERSION` by exactly 1 whenever you add or remove a field from the list of things `fingerprint_issue_json` or `fingerprint_pr_json` hashes.** This applies to both functions even if only one of them changed — they share one version counter.

Examples of changes that require a bump:

- Adding a new field to hash (e.g. #1204's `plan_approved`).
- Removing a field that used to be hashed.
- Changing what a field represents (e.g. switching from "only trusted comments" to "all comments").

Examples that do **not** require a bump (the hashed *meaning* is unchanged):

- Reformatting the jq filter (whitespace, field order in the `jq` program itself — the `,`-separated list of hashed values must stay in the same order for the hash to mean the same thing, but tidying the surrounding jq syntax without changing that list does not).
- Renaming a local shell variable.
- Adding a comment.

### Why this matters

Bumping the version is the *only* deliberate way to force every cached fingerprint, for every open Issue and PR across every owner's repos, to be treated as "changed" and re-checked on the next tick. Without an explicit version:

- A schema change that happens to produce different jq output text would silently invalidate every cache anyway — but so would an *accidental*, purely cosmetic edit to the jq filter, causing a surprise mass re-invocation wave with no way to tell whether it was intended.
- A schema change that happens to produce output text that's coincidentally unchanged (unlikely with SHA-256, but not something to rely on) would silently fail to invalidate stale caches at all.

An explicit version makes the invalidation decision visible in the diff and independent of incidental formatting.

### If you forget

If a schema field changes without a version bump, the practical symptom is exactly the bug fixed in #1204: some already-cached Issues/PRs never notice the new field's effect until something else about them changes, potentially staying stuck for days. There is no automated check for this (see [debugging.instructions.md](debugging.instructions.md) for how to recognise and investigate the symptom on a live host) — reviewers must check for a version bump whenever a PR touches the hashed field list in `lib/fingerprints`.

## What Gets Hashed

Keep this section in sync with `fingerprint_issue_json`/`fingerprint_pr_json`'s actual field lists (`lib/fingerprints`) — if you add a field there, add it here too, in the same PR.

- **Issue**: title, body, state, labels (sorted), trusted-filtered comments (count + timestamp/body pairs), assignees, milestone title, plan-approval status (whether the Workflow board's Workflow Status field currently reads "Approved" for this item — see `fetch_board_approved_items`, `lib/workflow-board`).
- **PR**: title, body, draft state, labels (sorted), head commit SHA, base branch, trusted-filtered comments, trusted-filtered reviews (state, latest timestamp, body pairs), review decision, review requests, assignees, milestone title, trusted-filtered inline review comments, status check rollup (each check's name plus its `.conclusion`, falling back to `.status`, falling back to `.state` for legacy StatusContext checks that have neither — #1210), mergeable/mergeStateStatus, whether auto-merge is enabled.

Plan-approval status is the one field sourced from somewhere other than the Issue/PR object itself (a separate GitHub Project board) — see [docs/fingerprinting.md](../../docs/fingerprinting.md) for why that made it easy to miss originally.
