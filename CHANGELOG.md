# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

<!--
Please ADD ALL Changes to the UNRELEASED SECTION and not a specific release
-->

## [Unreleased]
### Security
### Added
- oneshot script to fetch the top-priority work item from the priorities API and drive a Claude Code session to work on it
- loop script: continuous wrapper that runs oneshot every 5 minutes
- oneshot now clones both cs-template rules and the target repo into $XDG_PROJECTS_DIR (or $HOME/work) before each Claude session, keeping both up-to-date
- Support for specifying a Claude OAuth token per repo owner so work can be billed to the appropriate account
- Non-agentic PR status check to avoid burning tokens on up-to-date PRs
- Non-agentic issue status check to skip unchanged issues without burning tokens
- Active GitHub query for linked PRs when the priorities API has none, ensuring a recently-created PR is detected and worked on rather than the issue
- Bats-based test suite for the oneshot and loop shell scripts
- Add install-timer script to install a system-level systemd service and timer that runs the orchestrator every 5 minutes as the invoking user, self-updates via git pull before each run, and persists across reboots without requiring an active login session
- Layered development base Docker images (development-tools, development-node, development-python, development-full) with per-stage self-checks for modular, independently-rebuildable agent container layers
- Discord webhook notifications on work start, resume, and no-work — configurable via DISCORD_WEBHOOK in ~/.config/orchestrator/.env
- Discord webhook notification when an issue or PR is found to be blocked, including a direct link to the blocked item
- GitHub Actions workflow to run bats shell test suite in CI on every push and pull request
- Label management guidance added to both issue and PR prompts in oneshot — GitHub workflow classification labels are preserved when adding new labels
- Discord notification when Claude returns an application-level error (is_error: true), including the error message and a link to the affected issue or PR
- Automatic session reset when a resumed Claude session exceeds the context limit (terminal_reason=blocking_limit) — retries as a new session, overwriting the stored session ID to break the stuck loop
- Pre-send prompt length guard (MAX_PROMPT_CHARS=100000) that fails fast and notifies Discord before invoking Claude if the initial prompt is grossly oversized
- Discord notification and automatic rate-limit backoff when Claude returns HTTP 429, with non-agentic parsing of the reset time from the error message
- Exclusive per-owner flock lock in oneshot to prevent concurrent invocations racing on the same git working directories when a Claude session outlasts the timer interval
- Log current HEAD SHA on startup so the running version is visible in systemd journal output
- notify_discord_no_work now accepts an optional owner argument; when --owner is set the Discord message is prefixed with [owner] to distinguish multiple orchestrator instances (fixes #90)
- Non-agentic PR rebases now proceed even when the owner is rate-limited — only invoke_claude is blocked during the rate-limit window
- development-agent Docker image based on development-full with package-management and privilege-escalation tools removed, and a build workflow that triggers every 30 minutes or when development-full is updated
### Fixed
- oneshot prompt now delivered to Claude via stdin, fixing empty-prompt error when using --print
- oneshot now skips items from the priorities API that are already closed or merged on GitHub
- bats test stubs now created in repo tree so they are executable in sandboxes where /tmp is mounted noexec, fixing load_session PR fallback test failures
- development-node Docker image: add CLAUDE_CODE_CACHE_BUST ARG so npm @latest installs are rebuilt when a new version is published
- load_token_for_owner now exits 0 when no token is configured, preventing spurious failures under set -e callers
- Avoid gh pr list --author flag broken in gh 2.93.0 by filtering open PRs by author client-side using gh api user
- Include Draft PRs in priority scan — Draft status indicates work still needed
- Preserve /priorities API order — remove sort_by(.priority) that was overriding the server-defined priority ordering
- Log claude output before dying on failed invocation
- Replaced 'git pull --ff-only' in systemd ExecStartPre with explicit 'git fetch origin' then 'git merge --ff-only origin/main' to avoid failure when pull.rebase=true is configured
- Retry as a new session when Claude reports the stored session ID no longer exists ('No conversation found with session ID')
- Stored session expired retry no longer sends a Discord notification — this is a recoverable transient state already logged to the console
- Draft PRs no longer skipped when fingerprint is unchanged — a draft PR always has pending work
### Changed
- oneshot session management now stores one session file per issue or pull request and falls back to a linked issue session when working on a PR with no existing session
- oneshot now saves Claude output to a temp file and displays the text response after each session, making it possible to review what Claude did
- oneshot session prompts now instruct Claude to reply to every actioned comment and add the Blocked label before asking questions
- oneshot issue prompt now instructs Claude to create a branch, add a placeholder CHANGELOG entry, push upstream, and open a draft PR when starting work on an issue
- Claude sessions now run against the XDG-based repo clone; prompts specify .ai-instructions loading order (repo then rules fallback, error if neither found)
- oneshot prompt builders rewritten as heredocs with direct variable expansion; instructions are read first, followed by numbered task steps, making both source and rendered prompts easier to review
- oneshot now resolves the .ai-instructions path before building prompts via find_ai_instructions(), dying immediately if neither repo nor rules dir contains the file
- Claude sessions now use --model opusplan, giving smarter model selection: Opus for plan-mode reasoning, Sonnet for execution
- oneshot now iterates through all priorities entries across all repos, working on the first actionable item rather than being restricted to a single hardcoded repository
- oneshot now respects the one-PR-per-repo constraint correctly: skip_repos is only marked busy after a PR is confirmed open and non-blocked, and the is_skipped flag is explicitly reset between loop iterations
- docker-images.instructions.md updated to specify :latest only for container image tags; development-tools README and Dockerfile updated accordingly
- PR prompt now includes explicit gh pr ready command to mark PR as ready for review
- Issue and PR prompts now include GitHub CLI markdown formatting guidance to prevent escaped newlines rendering as literal characters in comments
- docker: base images: switch claude code install from npm to apt
- PR prompt now instructs Claude to check CI state once with gh pr checks and stop immediately if checks are pending, rather than polling in a loop — prevents sessions hanging indefinitely when Build: Pre-Release is absent from the most-recent workflow runs window
- Moved GitHub CLI comment body, label management, and CI check-once rules to cs-template global instructions; prompts now reference AI instructions instead of repeating inline rule blocks
- Refactored invoke_claude into run_claude_fresh, run_claude_resumed, and handle_claude_is_error helpers for readability
- Rate-limit backoff now waits until 1 hour past the token reset time (RATE_LIMIT_RESUME_BUFFER_SECS=3600) to avoid immediately hitting the limit again
- No-work notification now includes counts of blocked, unchanged, and repo-active skips
### Deprecated
### Removed
### Deployment Changes
<!--
Releases that have at least been deployed to staging, BUT NOT necessarily released to live.  Changes should be moved from [Unreleased] into here as they are merged into the appropriate release branch
-->
## [0.0.0] - Project created