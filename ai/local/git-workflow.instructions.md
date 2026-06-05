<!-- Locally Maintained -->
# Git Workflow Instructions

[Back to Local Instructions Index](index.md)

> Load when: doing any git work in this repository — committing, branching, rebasing, or opening PRs.

## Branch State Check (MANDATORY before any commit)

Before making any commit, check the current branch:

```bash
git branch --show-current
```

- **If on `main`**: create a new feature branch immediately — never commit directly to main.
- **If on a feature branch**: check whether main has moved ahead (`git fetch origin main && git log HEAD..origin/main --oneline`). If it has, rebase proactively before doing more work — do not wait to be asked.

## Creating a New Branch

When on `main` with uncommitted changes (e.g. after a PR has been merged and the user has switched back):

```bash
git checkout -b feat/<short-description>
```

Do **not** stash → switch to the old (now merged) branch → unstash. That branch is gone. Create a fresh one from the current state of main.

## After a PR Merges

When a PR is merged the working copy typically lands on `main`. The correct sequence for continuing work is:

1. `git fetch origin main` — update the remote reference
2. `git checkout -b feat/<next-thing>` — start a new branch
3. Continue working on the new branch

Do **not** attempt to push to or reuse the merged branch name.

## Rebasing

Rebase onto `origin/main` before opening a PR and whenever main has moved ahead:

```bash
git fetch origin main
git rebase origin/main
git push --force-with-lease origin <branch>
```

Do this proactively — the user should not need to ask.
