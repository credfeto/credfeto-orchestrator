# How GitHub integration works

## The simplest possible explanation

`oneshot` never keeps its own copy of "what's happening" — every single tick, it asks GitHub
directly: is this open or closed? What labels does it have? Who commented, and what did they
say? Is this person actually trusted? This document covers the pieces that answer those
questions: who counts as "trusted," how a stuck item gets escalated to a human via the `Blocked`
label, and how the orchestrator tells its own work apart from a human's.

## Who counts as "trusted"

A list of trusted GitHub logins is built fresh for each repository, from:

- The repository's owner.
- Every collaborator on the repository (fetched from GitHub directly, not hand-maintained).
- GitHub's own automated Copilot code-review bot.
- An explicit extra allow-list an operator can configure (`WHITELISTED_USERS`).

This list gates two separate things: whether a comment/review counts towards a
[fingerprint](fingerprinting.md) (so a random stranger's comment can't force a re-invocation),
and whether a commit on a Pull Request counts as "a trusted human is genuinely working on this"
(see human-driven detection, below). If the collaborators list can't be fetched at all (a
transient GitHub API hiccup), the whole item is skipped for that one tick rather than proceeding
with a silently-shrunken, wrong trust list — a fingerprint or trust decision made against the
wrong set of people is worse than doing nothing for one tick.

## Telling the bot's own work apart from a human's

The orchestrator must never re-invoke an AI agent on top of a branch a human is actively working
on themselves — that would be actively unhelpful, potentially clobbering their in-progress work.
A Pull Request is treated as **human-driven** (and left alone) when the bot has authored *zero*
commits still on the branch, and either:

- the bot itself created the PR (so a human has since taken over what was originally the agent's
  own draft — most commonly, a human rebased the bot's placeholder commit away), or
- at least one commit on the branch is authored by a trusted human login.

Dependency-update Pull Requests (from tools like Dependabot) are a deliberate exception: they
never contain bot-authored commits by design, so they're recognised by their branch-naming
convention or a `dependencies` label instead, and are still allowed to flow through the
lightweight "check CI, enable auto-merge" path rather than being treated as a human takeover.

The trickiest case: an Issue whose linked Pull Request has been taken over by a human is
otherwise *invisible* to the normal "does this repo already have an active PR" check (it has no
bot-authored commits, so it doesn't look bot-driven at all) — which would make the Issue look
free to re-work from scratch, opening a second, duplicate branch alongside the human's real one.
A separate check specifically looks for this situation (matching the Pull Request back to the
Issue it closes) and stands the Issue off too.

## The `Blocked` label: how a stuck item gets a human's attention

`Blocked` is the single mechanism the orchestrator uses to say "a human needs to look at this
before I do anything further." Every path that applies it also, in the very same action, posts a
comment explaining exactly why — a `Blocked` label with no explanation leaves a human unable to
tell what's wrong or whether their own last action (an approval, a fix, a reply) was even seen.

Applying the label is **verified**, not just fired-and-forgotten: `gh`'s own label-add command
can fail silently (most commonly because the repository doesn't have a `Blocked` label defined
yet at all), and an unverified failure here used to mean the escalation was silently lost
forever — the label never landed, so nothing ever noticed the item was supposed to be blocked,
and it just quietly kept getting re-invoked and re-blocked every single tick. The current
mechanism retries once, self-healing by creating the label if it's missing, and only posts the
explanatory comment once the label is *confirmed* present.

Common reasons an item gets `Blocked` automatically:

- A plan was posted but not yet approved (see [workflow-board.md](workflow-board.md)).
- A required CI check has failed, or stayed pending past a timeout, with nothing progressing it.
- A reviewer requested changes that remain unaddressed past the idle-invocation budget (see
  [oneshot.md](oneshot.md)).
- The item hit its total invocation cap without converging (see [oneshot.md](oneshot.md)).
- The agent container itself failed to even start, repeatedly (an environment/infrastructure
  problem, not a problem with the code).

## Assumptions

- GitHub's own `reviewDecision` field (`CHANGES_REQUESTED`, cleared only by a human re-approving
  or dismissing) is trusted as the signal for "a reviewer is still waiting on something" — it is
  not re-derived from scratch by re-reading every review comment every tick.
- A repository always has (or can have created on the fly) a label literally named `Blocked`;
  nothing here supports a differently-named or differently-configured escalation label.
- Commit authorship, as reported by GitHub's own commit-to-account mapping, is a reliable enough
  signal for "who wrote this" — a commit whose author email maps to no GitHub account at all is
  simply not counted as anyone's, rather than guessed at.
