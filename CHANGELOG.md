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
### Fixed
- oneshot prompt now delivered to Claude via stdin, fixing empty-prompt error when using --print
### Changed
- oneshot session management now stores one session file per issue or pull request and falls back to a linked issue session when working on a PR with no existing session
- oneshot now saves Claude output to a temp file and displays the text response after each session, making it possible to review what Claude did
- oneshot session prompts now instruct Claude to reply to every actioned comment and add the Blocked label before asking questions
### Deprecated
### Removed
### Deployment Changes
<!--
Releases that have at least been deployed to staging, BUT NOT necessarily released to live.  Changes should be moved from [Unreleased] into here as they are merged into the appropriate release branch
-->
## [0.0.0] - Project created