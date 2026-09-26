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
- GitHub's own Advanced Security (code scanning) bot.
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

"The bot" here means either of two accounts: the AI agent (the account the orchestrator's token
belongs to) and the PR create bot (`PR_CREATOR_LOGIN`, `prpixie` by default), which opens the
Pull Requests for the agent's work but never commits to them. A Pull Request authored by either
is the bot's own; commit authorship then decides whether it is still bot-driven. The PR create
bot is never a trusted login, so a comment of its own can never count as a human's approval.

The rule that only one branch or Pull Request is active at a time applies **per user**, so it is
about the bot's own Pull Requests only. A Pull Request from a person, or from a dependency bot, is
not the bot's and does not stop it working on other Issues in the same repository; an Issue whose
own Pull Request a human is developing is stood off, and reported as human-driven.

Dependency-update Pull Requests (from tools like Dependabot) are a deliberate exception: they
never contain bot-authored commits by design, so they're recognised by their branch-naming
convention (`depends/` or `dependabot/`, on a branch in the same repository: a fork PR is never
recognised by its branch name) or, for the human-takeover and assignee stand-off checks only, a
`dependencies` label instead, and are not treated as a human takeover.

The prompt itself is chosen by branch prefix only (`depends/` or `dependabot/`, see
`pr_should_use_dependency_prompt` in lib/github), never by the `dependencies` label, because
issue-label sync copies that label onto any bot PR. A dependency-prefixed PR still gets the full
phase flow when a reviewer has requested changes or the branch still carries the `.deleteme.now`
placeholder, and a PR from a fork never gets that prompt whatever its branch is called. A PR
whose diff includes `.deleteme.now` is never treated as settled, and the prompts refuse to enable
auto-merge or mark it ready while it is listed (the full flow removes the placeholder when the real
change has landed next to it; an auto-merge already armed on a placeholder-only PR is disarmed).

The trickiest case: an Issue whose linked Pull Request has been taken over by a human is
otherwise *invisible* to the normal pivot into the bot's own Pull Request (it has no
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
- A plan-approved Issue keeps getting re-invoked with no durable progress (no new Pull Request,
  comment, or state change) past the idle-invocation budget (see [oneshot.md](oneshot.md)).
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
  simply not counted as anyone's, rather than guessed at. One narrow exception: detecting the
  bot's *own* commits also accepts a raw commit-author email match against the orchestrator's
  configured `GIT_USER_EMAIL`, but only for a commit where GitHub's mapping hasn't resolved
  *any* author on that commit yet — a resolved login (the bot's, a human's, or anyone else's)
  always wins over an email match on that same commit. This closes a real lag window (GitHub's
  mapping is asynchronous and can take over an hour after a push) without weakening the
  commit-to-account trust model for any identity other than the bot's own (#1294).
