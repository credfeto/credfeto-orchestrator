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
### Fixed
- oneshot prompt now delivered to Claude via stdin, fixing empty-prompt error when using --print
- oneshot now skips items from the priorities API that are already closed or merged on GitHub
- bats test stubs now created in repo tree so they are executable in sandboxes where /tmp is mounted noexec, fixing load_session PR fallback test failures
- development-node Docker image: add CLAUDE_CODE_CACHE_BUST ARG so npm @latest installs are rebuilt when a new version is published
### Changed
- oneshot session management now stores one session file per issue or pull request and falls back to a linked issue session when working on a PR with no existing session
- oneshot now saves Claude output to a temp file and displays the text response after each session, making it possible to review what Claude did
- oneshot session prompts now instruct Claude to reply to every actioned comment and add the Blocked label before asking questions
- oneshot issue prompt now instructs Claude to create a branch, add a placeholder CHANGELOG entry, push upstream, and open a draft PR when starting work on an issue
- Claude sessions now run against the XDG-based repo clone; prompts specify .ai-instructions loading order (repo then rules fallback, error if neither found)
- oneshot prompt builders rewritten as heredocs with direct variable expansion; instructions are read first, followed by numbered task steps, making both source and rendered prompts easier to review
- oneshot now resolves the .ai-instructions path before building prompts via find_ai_instructions(), dying immediately if neither repo nor rules dir contains the file
- Claude sessions now use --model opusplan, giving smarter model selection: Opus for plan-mode reasoning, Sonnet for execution
### Deprecated
### Removed
### Deployment Changes
<!--
Releases that have at least been deployed to staging, BUT NOT necessarily released to live.  Changes should be moved from [Unreleased] into here as they are merged into the appropriate release branch
-->
## [0.0.0] - Project created