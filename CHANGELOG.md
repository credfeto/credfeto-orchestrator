# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

<!--
Please ADD ALL Changes to the UNRELEASED SECTION and not a specific release
-->

## [Unreleased]
### Security
- Replace host ~/.gitconfig volume mount in invoke_claude with a generated minimal gitconfig built from the host git global config, avoiding exposure of the full host gitconfig inside the container
- Replace ~/.gitconfig volume mount with git identity env vars (GIT_USER_NAME, GIT_USER_EMAIL, GIT_SIGNING_KEY) passed into the container; entrypoint.sh now configures git from those vars and dies if any required value is absent
- Replace ~/.gnupg read-write volume mount with GPG agent extra-socket forwarding; a public-key-only gnupghome tmpdir is created per invocation so no private key material enters the container
- Verify SHA-256 checksums for hadolint, dotenv-linter, and sqlcmd binary downloads in development-tools container to detect supply chain tampering at build time
- Replace curl|bash installer patterns for actionlint and trufflehog in development-tools container with direct binary downloads and pinned SHA-256 verification
- Pin all external GitHub repository clones in development-full container to specific commit hashes; build fails if upstream HEAD diverges from the expected SHA
- Add CPU, memory, and PID resource limits to agent container invocation to prevent a compromised container from exhausting host resources
- Added Trivy vulnerability scanning to development base image build workflows to detect CVEs in pushed Docker images
- Replace ~/.ssh volume mount with SSH agent socket forwarding so private key files are never exposed inside the agent container
- Bump sqlfluff from 4.1.0 to 4.2.2 to resolve CVE-2026-46374
- Skip sqlcmd, actionlint, and composite-action-lint in Trivy scan until upstream releases new builds compiled against the patched Go stdlib (CVE-2026-42504, CVE-2026-39820, CVE-2026-33810, CVE-2026-32280 et al.)
- Validate SSH agent is forwarded and can sign commits at container startup — fails fast if SSH_AUTH_SOCK is missing, agent has no keys, or signing test fails
- Disable Trivy secret scanning for image scans to eliminate false positive from gcp-service-account pattern in /opt/pre-commit/.gitleaks.toml (secret scanning already covered by TruffleHog in pre-commit hooks)
- Skip trufflehog in Trivy scan until upstream releases a build compiled against the patched Go stdlib (same Go CVEs as sqlcmd/actionlint/composite-action-lint)
- Replace rooted Docker with rootless Podman for agent container execution
- Revoke sudo access granted by setup-owner — no longer required with rootless Podman
- Remove insecure ~/.gnupg:rw fallback mount — hard-fail when GPG agent extra socket is absent
- Pass Claude OAuth token via Podman secret (claude-oauth-<owner>) instead of --env flag to hide it from podman inspect
- Add NoNewPrivileges, PrivateTmp, ProtectSystem, CapabilityBoundingSet, AmbientCapabilities, LockPersonality, and MemoryDenyWriteExecute hardening to systemd service unit
- Pass GH_ENTERPRISE_TOKEN via Podman secret (gh-enterprise-token) instead of --env flag to hide it from podman inspect
### Added
- ai/local/docker-images.instructions.md: documented agent container image hierarchy, build contexts, and the SSH rewriting strategy
- oneshot: include Git transport information in agent prompts to provide context on how git is configured in the environment
- Generate per-item CLAUDE.md and mount it read-only at /home/developer/.claude/CLAUDE.md in the agent container so each invocation gets structured role and work-item context without polluting the bootstrap prompt
- SSH agent validation on container start: verify SSH_AUTH_SOCK socket exists, agent has keys loaded, and signing with the loaded key succeeds
- GPG agent validation on container start: verify gpg-agent is responding, GIT_SIGNING_KEY is present in the keyring, and a test sign with the key succeeds
- Set limit-severities-for-sarif on Trivy scan so exit-code 1 only fires when CRITICAL findings exist in the SARIF; without this, non-critical dotnet/gh findings filled the SARIF and triggered a false failure
- Mount $HOME/.database read-only into the agent container at /home/developer/.database so database credentials are available to the agent; warns and skips if the file is absent
- setup-owner script to provision a system user for the orchestrator with sudo, dotfiles, repo clone, and systemd timer
- setup-owner: validate required config files (.config/gh, .config/orchestrator/.env, .config/orchestrator/tokens/<owner>) before provisioning and copy them into the new user's home
- oneshot: validate required config at startup (.config/orchestrator/.env, gh/hosts.yml, per-owner token) with clear errors before starting work
- document absolute path requirement and gpg socket permission rationale as comments in generated systemd service unit
- Run git clean -fdX after each work session to remove build artefacts
- Sync PR labels from all linked closing issues before each work session, adding any missing labels
- Suppress repeated Discord no-work notifications: same message is suppressed within 1 hour; different message sends immediately; re-sends hourly at most
- Dependency PRs now enable auto-merge (or mark Blocked on CI failure) instead of leaving a stale comment; autoMergeRequest added to PR fingerprint to force one-time re-run of stuck PRs
- Disk space guard: check available space before launching a container and notify Discord when below 10 GB
- Prune dangling (untagged) container images before each pull and after each container run to reclaim disk space; preserves the current tagged image so the next pull requires only new layers
- Plan-first approval workflow, AI review loop, and Workflow board (GitHub Projects v2) integration for issue orchestration
- Board-based plan approval: orchestrator queries Workflow board for issues in Approved status and passes plan_approved flag to agent; comment-based approval comment fallback when no board is configured
- Whitelist trusted commenters: only comments and reviews from the repo owner, collaborators, GitHub Copilot, or WHITELISTED_USERS are included when computing issue/PR fingerprints
- Auto-report unparseable Claude 429 rate-limit reset messages to a GitHub tracking issue so the parser can be extended
### Fixed
- oneshot: force origin URL to SSH and unset `pushurl` before push attempts to ensure agent pushes use SSH even if the host environment has HTTPS configured
- development-full: baked SSH rewriting rules for GitHub, GitLab, and Bitbucket into the image at `/etc/gitconfig` to ensure all agent git operations use SSH
- containers/agent/entrypoint.sh: added startup validation to verify all repository remotes use SSH and no `url.*.insteadOf` rules are present in the user's git config to prevent conflicts with system-wide SSH enforcement
- oneshot: reset origin remote URL to SSH before every host-side fetch so that HTTPS URLs the agent may have stored in .git/config do not break the service-user fetch
- development-full system-gitconfig: add pushInsteadOf alongside insteadOf so push operations are also rewritten to SSH when the agent stores an HTTPS push URL
- oneshot: prefer XDG_RUNTIME_DIR gpg-agent extra socket over the gpgconf-listed path; prevents stale socket files left in ~/.gnupg by a SIGKILL'd agent being mounted into the container where they appear live but are unresponsive
- oneshot: fix rate-limit reset time parsing to handle minutes and colons (e.g. 7:10pm), ensuring backoff correctly persists when Claude returns a non-hour-aligned reset time
- oneshot: fix subshell leak in invoke_claude when handle_claude_is_error fails; now correctly exits the subshell instead of continuing to subsequent jq calls on a deleted temp file
- oneshot: suppress repeated rate-limit skip messages in the main loop, only reporting once per owner per run
- setup-owner: write ~/.gitconfig for the owner with user identity and GPG signing config from .env so non-agentic git operations (e.g. rebase) can commit without requiring global git config on the host
- setup-owner: remove stale gpg-agent socket files from ~/.gnupg after killing the agent so they cannot be mistaken for live sockets by subsequent oneshot runs
- setup-owner: sync GPG keyring by export/import rather than directory copy; avoids keyboxd database lock (source PID embedded in lock file) that caused owner keyboxd to hang indefinitely
- setup-owner: replace .gnupg by killing owner keyboxd/gpg-agent then doing a clean directory copy, bypassing keyboxd import which fails when systemd socket-activates the daemon before the write completes
- setup-owner: use sudo -u to check clone directory existence so permission checks run as the owner user (fixes false negative when owner home dir is mode 700)
- Docker .claude directory created as root-owned causing EACCES on every Bash tool call — now mounted as a host-owned temp directory
- Issue comment changes ignored when linked PR fingerprint was unchanged — orchestrator now re-runs when the issue fingerprint changes even if the PR has not
- Dirty main in working tree now hands off to agent instead of aborting
- Dirty working tree on any branch now hands off to agent with full state context including branch name and merge state
- Agent now explicitly checks out PR branch as first git action, preventing accidental changes on main
- Issue agent now explicitly required to create branch before making any repo changes
- PR with BEHIND or DIRTY merge state no longer skipped when fingerprint is unchanged
- Rebase and dirty-branch recovery instructions embedded directly in numbered steps rather than floating IMPORTANT blocks
- Orchestrator now automatically recovers when a managed repo is left on a branch that has been deleted from origin, instead of silently skipping the work item on every subsequent run
- Add jq to development-tools container image so bats tests and scripts that require it do not fail
- Add /opt/pre-commit/src/scripts to PATH in development-full so run-bats and other hook helpers are found by pre-commit
- Handle docker pull subcommand in bats test stubs so invoke_claude tests pass after PR #155 added a pull before every run
- Validate session ID read from file in load_session; discard and reset if content is not a valid UUID to prevent corrupted session files from causing repeated failures
- recover_orphaned_branch now uses git checkout -f to discard unstaged changes when switching to main, preventing indefinite retry loops when the working tree is dirty
- Fix dotenv-linter ARM64 asset name from arm64 to aarch64 to match the actual release filename on the dotenv-linter GitHub releases page
- Pass CREDFETO_PRECOMMIT_COMMIT build arg from workflow to development-full Dockerfile so the supply chain commit hash check uses the dynamically fetched HEAD rather than the stale hardcoded default
- Add systemctl stub to install-timer and uninstall-timer bats tests so they pass in environments without systemd
- Start gpg-agent before running oneshot in the systemd service so that commit signing works in headless scheduled-task environments
- Fast-fail before launching the agent container if gpg-agent is not running or the signing key is absent, and post a Blocked comment on the GitHub work item
- Die at startup if GIT_SIGNING_KEY is configured but the key is absent from the GPG keyring
- Require all four environment variables (CLAUDE_CODE_OAUTH_TOKEN, GIT_USER_NAME, GIT_USER_EMAIL, GIT_SIGNING_KEY) in the agent entrypoint — die immediately if any are missing
- Check pre-commit rules freshness in agent entrypoint on startup; die if the installed SHA in /workspace/rules/.env differs from the published SHA at pre-commit.markridgwell.com so stale hooks are caught before any work begins
- Regenerate pre-commit hook script at image build time using the container's own pre-commit binary so the embedded version SHA always matches the installed package; prevents "Hooks installation is out of date" errors caused by the upstream-committed hook being stale after a pre-commit package update
- Build development-agent image immediately when development-full finishes even when the Trivy scan fails — the base image is already pushed before Trivy runs so the conclusion=failure check was incorrectly suppressing the chain
- Trigger development-full image rebuild immediately via repository_dispatch when credfeto-global-pre-commit is pushed to main, eliminating the up-to-one-hour delay from the hourly schedule
- Add .github/actions/trivy-scan/** to paths trigger for all image build workflows so trivy action changes trigger image rebuilds
- systemd service unit embedded wrong UID in SSH_AUTH_SOCK and ssh-agent socket path: %U in a system service expands to the service manager UID (root=0), not the User= directive UID; install-timer now embeds the real UID via id -u at install time and cleans any stale socket before starting ssh-agent
- systemd service unit cleanup step used rm -f which cannot remove a directory; changed to rm -rf so a stale directory at the ssh-agent socket path (created by docker when a bind-mount source went missing mid-run) is cleared before each ssh-agent start
- validate all docker bind-mount source paths exist with the correct type immediately before calling sudo docker run; docker silently creates missing sources as root-owned directories which then block ssh-agent from binding a socket at the same path on the next service start
- two owner services on the same host raced on the shared ssh-agent socket path; each owner now gets a dedicated socket at /run/user/<uid>/ssh-agent-<owner>.socket so simultaneous starts cannot interfere
- Docker build: clone pre-commit hook repo directly and wire shims from it rather than regenerating the hook script via a temp install
- Output helpers (info/success/die/warn) now suppress ANSI escape codes when stdout/stderr is not a terminal, fixing grep-based task-completion polling inside Docker containers
- agent-entrypoint pre-seeds ~/.claude.json on startup to suppress the configuration-file-not-found warning from Claude Code
- Update pids-limit test assertion from 1024 to 4096 to match the increased resource limit, and replace run ! negation syntax with compatible two-line equivalents to fix bats version compatibility
- ssh-agent socket path now uses systemd RuntimeDirectory so the service starts correctly when no user session is active
- Monitor loop no longer hangs forever when the branch name contains a slash — the generated CLAUDE.md now explicitly warns agents that poll patterns derived from branch prefixes (e.g. \[perf\]) cannot match branches like perf/my-branch, and instructs agents to run git commit/push in the foreground
- Agent container is now bounded by a configurable timeout (default 90 minutes, overridable via AGENT_TIMEOUT_MINUTES); on expiry the container is killed, Discord is notified, and the orchestrator exits cleanly so the next timer tick retries
- setup-owner: always overwrite config files on re-run so token rotation and .env changes propagate; die with clear error when clone destination exists but is not a git repo
- oneshot tests: stub validate_config in setup_main_mocks and supply full env in GPG keyring test so tests pass with the new startup validation
- use 0660 group permissions on gpg-agent extra socket and pass owner GID to container via --group-add for secure socket access
- abort setup-owner with a clear error when run as root
- abort install-timer with a clear error when run as root
- use absolute home directory path in service unit chmod instead of %h specifier which expands to root home
- Rootless Podman now works in system services: added Delegate=yes for cgroup delegation and configured overlay driver on btrfs ~/work mounts (vfs fallback for ext4)
- containers config directory is now owned by the service user so Podman can read storage.conf
- GPG agent socket path in install-timer now resolved dynamically via gpgconf rather than a hardcoded ~/.gnupg path, preventing failures when loginctl enable-linger relocates sockets to XDG_RUNTIME_DIR
- setup-owner now calls loginctl enable-linger so the service owner always has a persistent systemd user session available for rootless Podman
- XDG_RUNTIME_DIR in the systemd service unit now points to the real user session (/run/user/<uid>) so rootless Podman can locate the systemd cgroup manager socket; the ssh-agent socket stays isolated in RuntimeDirectory via SSH_AUTH_SOCK
- Podman storage uses fuse-overlayfs (overlay driver) when available, falling back to vfs — removes the incorrect btrfs-detection logic that caused overlay-over-btrfs failures on the hardened kernel
- setup-owner: place Podman graphroot in ~/work/.containers/storage when ~/work is a btrfs mount, avoiding VFS layer copies from filling the ext4 home partition
- setup-owner: write containers.conf with cgroup_manager=cgroupfs; the systemd cgroup manager requires runc to create libpod scope units via D-Bus which is denied from inside a system service even with Delegate=yes
- install-timer: add DBUS_SESSION_BUS_ADDRESS to generated service unit so Podman finds the user session D-Bus socket for other D-Bus operations
- setup-owner: set cgroup_parent in containers.conf to user@<uid>.service so cgroupfs containers have write permission to their cgroup directory
- rootless Podman container launch from system service: move oneshot into a cgroup leaf before running podman so resource limits work without cgroup permission errors
- enable pids/memory/cpu/io controllers in service cgroup subtree_control after moving to proc leaf so container cgroups get resource-limit files
- use Delegate=cpu memory pids io in service unit so systemd enables cgroup domain controllers before process starts and places it in a leaf sub-cgroup; update setup_cgroup_leaf to strip the systemd leaf suffix from the cgroup path
- Restore process-to-leaf-cgroup move in setup_cgroup_leaf so containers can be created under the service cgroup
- Write cpu memory pids io to service cgroup subtree_control after leaf move so container cgroups have resource limit files
- Move all service cgroup processes (not just $$) to init leaf so subtree_control write succeeds even with left-over processes
- fix rootless Podman user namespace mapping so container developer user can access host-owned GPG and SSH agent sockets
- Correctly handle HTTP 429 rate-limit when Claude CLI exits non-zero but has written valid error JSON, so the rate-limit file is persisted and Discord is notified
- Kill any existing ssh-agent process before starting a new one in the service unit to prevent left-over process warnings on every timer firing
- Kill ssh-agent via EXIT trap in oneshot so the service cgroup is clean before the next timer firing, preventing systemd left-over process warnings
- Create bind-mounted temp directories under XDG_RUNTIME_DIR instead of /tmp so they remain visible to rootless podman when PrivateTmp=yes is set in the service unit
- Pre-populate ~/.ssh/known_hosts with github.com host key on container startup if not already present
- Corrected plan self-approval from boilerplate 'proceed' text; enforced temporal ordering for plan approval detection; fixed Workflow project cache poisoning on transient API failure; added plan-approval unblock path when open PR already exists; fixed CI gate text; fixed heredoc blank-line separator before Steps; fixed SC2016 shellcheck warnings in GraphQL query strings; fixed update_workflow_status test stub
- Removed automatic plan-approval detection and Blocked-label removal from orchestrator — removing Blocked is always a human action; simplified main loop blocked handling; updated agent instructions to make clear that humans remove the Blocked label to approve a plan
- Include trusted commenters list in generated CLAUDE.md for both issue and PR agents, instructing the agent to ignore comments from untrusted users
- oneshot: remove the per-invocation temp file on Claude rate-limit and error paths so it is no longer leaked into TMPDIR when the run aborts
- Log GitHub Projects GraphQL errors with actual error content and call update_workflow_status before invoking Claude
- Use 'Workflow Status' field name instead of 'Status' to avoid conflict with GitHub's auto-created Status field, and replace invalid TEAL color with PINK
- Move ensure_github_known_hosts before verify_ssh_signing so the GitHub SSH auth probe does not fail with a host-key error on fresh containers
- Skip board status reset to 'Not Started' when resuming a Claude session so previously advanced statuses are preserved
- Use separate stderr temp files for org and user owner-node-id lookups so both errors are preserved when both fail
- Guard against jq outputting the string 'null' when the org GraphQL query returns null data, ensuring the user-account fallback always runs
- Capture stderr from createProjectV2Field and repo-node-id lookup calls so auth errors in those paths are surfaced
### Changed
- Always pull the latest container image before starting each run
- Increase agent container resource limits from 2 CPU/4 GB RAM to 4 CPU/12 GB RAM to support longer-running agent sessions
- Configure Trivy to suppress vulnerability reports where no fix is available
- Extract Trivy vulnerability scan and SARIF upload into a shared composite action used by all container image build workflows including development-agent
- Pre-load SSH keys into the agent at startup so they are available before the container is launched
- Increased container pids-limit from 1024 to 4096 to prevent fork failures during parallel BenchmarkDotNet artifact compilation
- Timer interval configurable via ORCHESTRATOR_TIMER_INTERVAL env var, defaulting to 30sec
- Improve git configuration: add standard settings to setup-owner and system-gitconfig
- Suppress SC2016 in shellcheck — single-quoted GraphQL query strings are intentional
### Deprecated
### Removed
### Deployment Changes
<!--
Releases that have at least been deployed to staging, BUT NOT necessarily released to live.  Changes should be moved from [Unreleased] into here as they are merged into the appropriate release branch
-->
## [0.0.1] - 2026-06-11
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
- Docker container execution for oneshot: named orchestrator-<owner>, uses development-agent image, mounts repo rw, rules ro, ssh ro, gnupg rw, passes Claude and GitHub CLI tokens
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
- Orchestrator now evaluates all open PRs in a repository independently; previously a second PR in the same repo was silently skipped when an earlier PR had already been seen in the priority list
- Use sudo docker for container invocations in invoke_claude
- Pass GH_ENTERPRISE_TOKEN (not GH_TOKEN) to the agent container so the GitHub API proxy authenticates correctly; fall back to GH_TOKEN in orchestrator .env when no per-owner token file exists
- Configure host-side gh CLI with GH_HOST and GH_ENTERPRISE_TOKEN from orchestrator .env so oneshot uses the same proxy as the agent container
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
- Replace pre-run container removal with existence check — die if named container already exists; detect name-in-use race in docker run; remove host ~/.claude mount from container
- SDK - Updated DotNet SDK to 10.0.301
### Removed
- Remove unused NanoClaw container/ directory and its dependabot tracking — never deployed, superseded by containers/ base images and oneshot

## [0.0.0] - Project created