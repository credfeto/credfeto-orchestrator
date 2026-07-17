# How fingerprinting works

## The simplest possible explanation

Imagine a GitHub Issue is a photograph. Every time the orchestrator looks at
an Issue, it doesn't remember the whole photo — that would be slow and
wasteful. Instead it takes a tiny, unique "fingerprint" of the photo: a short
code that changes if even one pixel changes, but stays exactly the same if
nothing changed at all.

Each time the orchestrator checks an Issue or Pull Request, it:

1. Takes a fresh fingerprint of what the Issue/PR looks like right now.
2. Compares it to the fingerprint it saved last time.
3. If they're the same: **nothing has changed**, so there's no point doing
   any work — it skips this item and moves on.
4. If they're different: **something changed**, so it wakes up the AI agent
   to go look at it and do the next bit of work, then saves the new
   fingerprint for next time.

This is why the orchestrator can check hundreds of Issues and PRs across
dozens of repositories every few minutes without actually running an AI
agent on every single one — most of them haven't changed since last time, so
they're skipped almost instantly.

## What actually makes the fingerprint

A fingerprint is a [SHA-256](https://en.wikipedia.org/wiki/SHA-2) hash — a
one-way scrambling function that turns any amount of text into a fixed-length
code. Feed it the same text twice, get the same code twice. Change one
character, get a totally different code.

The orchestrator builds the "text" it feeds into that scrambler out of the
parts of an Issue or PR that actually matter for deciding whether to act:

- **For an Issue**: its title, body, open/closed state, labels, comments (only
  from people the orchestrator trusts — see below), who it's assigned to, and
  its milestone. Since [#1204](https://github.com/credfeto/credfeto-orchestrator/issues/1204),
  it also includes whether the Issue's plan has been **Approved** on the
  repo's Workflow board.
- **For a Pull Request**: all of the above, plus draft status, the current
  commit, its target branch, code reviews, review requests, CI check results,
  and whether it's mergeable.

The code that does this lives in `lib/fingerprints` — the functions
`fingerprint_issue_json` and `fingerprint_pr_json`. See
[fingerprinting.instructions.md](../ai/local/fingerprinting.instructions.md)
for the exact, currently-maintained list of what's included.

### Why only trusted comments?

If literally anyone's comment could change the fingerprint, a random stranger
leaving a comment on a public Issue could trigger the AI agent to spend time
and money re-checking it. So untrusted comments are filtered out before the
fingerprint is computed — only comments from people the repo actually trusts
count as "something changed".

## Where the saved fingerprint lives

After the orchestrator finishes looking at an Issue or PR, it writes the
fingerprint to a small file on disk, one file per item:

```text
~/.orchestrator/<owner>/<repo>/Issue_<number>.fingerprint
~/.orchestrator/<owner>/<repo>/PullRequest_<number>.fingerprint
```

Next time around, it reads that file back and compares.

## The tricky bit: the Workflow board isn't part of the Issue

Here's the thing that caused a real bug ([#1204](https://github.com/credfeto/credfeto-orchestrator/issues/1204)):
approving a plan happens on a *separate* GitHub object — the repo's
"Workflow" [GitHub Project board](https://docs.github.com/en/issues/planning-and-tracking-with-projects) —
not on the Issue itself. A human can flip an Issue's card from "Planning" to
"Approved" on that board without adding any comment or label to the Issue.

Before the fix, the fingerprint had no idea the board even existed. So:

1. The AI agent posts a plan and marks the Issue `Blocked`.
2. A human reviews it, sets the board to **Approved**, and removes `Blocked`.
3. The orchestrator notices the label change, computes a fresh fingerprint,
   and saves it.
4. From that point on, if nothing about the Issue's own title/body/labels/
   comments/etc. ever changes again, the fingerprint stays exactly the same
   forever — even though the board still says "Approved" and nobody has ever
   actually started the work.
5. The Issue sits there, silently skipped as "unchanged", potentially for
   days, looking exactly like a fresh, untouched Issue to a human glancing at
   it — because nothing about it *had* changed since the last check. The
   approval was real; the fingerprint just couldn't see it.

The fix: the fingerprint now also includes a `true`/`false` flag for "is this
item's plan Approved on the board right now". So the moment a human approves
it, that flag flips, the fingerprint changes, and the orchestrator notices
and acts — exactly once, then it goes quiet again until something else
changes.

## The version number: how we change the recipe safely

The "recipe" for what goes into a fingerprint (the list above) can change
over time — like when the board-approval flag was added. But there's a
problem: if the recipe changes and a fingerprint that was saved under the
*old* recipe gets compared against one computed with the *new* recipe, are
they supposed to match or not? There's no way to tell just by looking at the
two hashes — they're just scrambled codes.

So every fingerprint now starts with a small version number, like `1:8f2a91…`.
Whenever the recipe changes, that number goes up by one. A saved fingerprint
starting with an old number will never match a freshly computed one starting
with a new number — no matter what the rest of the text says — which forces
*every* Issue and PR, across every repository, to be freshly re-checked
exactly once after the recipe changes.

This is deliberate: it means "we changed what counts as unchanged" is always
a clear, single-line decision (bump the number), not something that happens
by accident just because someone tidied up the code that builds the
fingerprint text. See
[fingerprinting.instructions.md](../ai/local/fingerprinting.instructions.md)
for the exact rule on when to bump it.

## Summary

| Question | Answer |
| --- | --- |
| What is a fingerprint? | A short code that changes only if the Issue/PR's important details change. |
| Why have one? | So the orchestrator can skip work on things that haven't changed, instead of re-checking everything, every time. |
| Where's it stored? | One small file per Issue/PR under `~/.orchestrator/<owner>/<repo>/`. |
| What's in it? | Title, body, state, labels, trusted comments, assignees, milestone (+ reviews/CI/mergeability for PRs) — and now, board approval status for Issues. |
| What's the version number for? | A safety switch so changing the recipe always forces a fresh, deliberate re-check everywhere, instead of maybe silently doing nothing. |
