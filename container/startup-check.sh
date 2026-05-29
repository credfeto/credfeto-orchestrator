#!/bin/bash
#
# Container startup self-test. Runs before the agent-runner so no agent
# tokens are spent on a broken container.
#
# Always runs to completion (no short-circuit on first failure) so the
# Discord report shows the *full* picture every time.
#
# Outputs:
#   1. Per-check ✓ / ✗ lines into /tmp/startup-check.log
#   2. A summary message into /workspace/outbound.db on EVERY run (success
#      or failure) — picked up by the host's delivery loop and posted to
#      the channel that woke this session.
#   3. On failure: the full log to stderr (visible via `docker logs` and
#      the host stderr forward).
#
# Exit:
#   0  — every check passed; entrypoint.sh continues to `exec bun run …`
#   42 — at least one check failed; entrypoint.sh's `set -e` aborts the
#        agent so no Claude tokens are spent on a broken container.
#
set -u

LOG=/tmp/startup-check.log
# JSONL of per-check records (one JSON object per line). Built up as checks
# run, then transformed into a single JSON document at end-of-script and
# written to /workspace/.startup-check.json for the agent + host + operator
# to read. Per-check append is bash-only (sed escape) so we don't pay
# Python startup latency per check.
RESULTS_JSONL=/tmp/startup-check.jsonl
RESULTS_JSON=/workspace/.startup-check.json
: > "$LOG"
: > "$RESULTS_JSONL"

PASS=0
FAIL=0

say()  { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >> "$LOG"; }
# JSON string escape — \ and " only; control chars are pre-stripped by
# tr in `check`, and bash strings can't contain literal NUL anyway.
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
pass() {
  say "✓ $1"; PASS=$((PASS+1))
  printf '{"name":"%s","status":"pass"}\n' "$(json_escape "$1")" >> "$RESULTS_JSONL"
}
fail() {
  say "✗ $1 — $2"; FAIL=$((FAIL+1))
  printf '{"name":"%s","status":"fail","reason":"%s"}\n' \
    "$(json_escape "$1")" "$(json_escape "$2")" >> "$RESULTS_JSONL"
}
# Record a check that was intentionally NOT run because a prerequisite
# capability is absent by design — not a failure. Logged and emitted to
# the structured results as status:"skip" (the JSON builder keeps every
# record regardless of status, so the operator can still see *what* was
# skipped and *why* in /workspace/.startup-check.json), but it increments
# neither PASS nor FAIL, so EXIT_CODE stays 0. The "⊘ " log prefix is
# deliberately not "✗ " so the Discord report's fail filter ignores it —
# a by-design skip is not channel noise. A delegating agent with no git
# path must boot, not crash-loop.
skip() {
  say "⊘ $1 — $2"
  printf '{"name":"%s","status":"skip","reason":"%s"}\n' \
    "$(json_escape "$1")" "$(json_escape "$2")" >> "$RESULTS_JSONL"
}

# Run a command; pass/fail based on exit code; capture last 3 lines of
# combined stdout+stderr as the failure reason.
check() {
  local name="$1"; shift
  local out
  if out=$("$@" 2>&1); then
    pass "$name"
  else
    fail "$name" "$(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
  fi
}

# Forwarder used by lib/image-state-checks.sh. base.Dockerfile's build-time
# sanity block defines its own fail-fast `check_image`; here we just feed
# the shared list through the regular runtime check infrastructure so
# results land in the structured report alongside everything else.
check_image() { check "$@"; }

# Verify a binary is on PATH AND its version flag returns clean. Logs the
# first line of `--version` output as a non-tracked log line so the
# operator can eyeball actual versions in the container log without
# bloating the Discord summary.
binary_ok() {
  local bin="$1"; shift
  if ! command -v "$bin" >/dev/null 2>&1; then
    fail "binary: $bin" "not on PATH"
    return
  fi
  local out rc
  out=$("$bin" "$@" 2>&1); rc=$?
  if [ $rc -eq 0 ]; then
    pass "binary: $bin"
    say "    → $(printf '%s' "$out" | head -1 | tr -d '\r')"
  else
    fail "binary: $bin" "$(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
  fi
}

# ── 1. Binaries (presence + version probe) ───────────────────────────
binary_ok git              --version
binary_ok ssh              -V
binary_ok gh               --version
binary_ok dotnet           --version
binary_ok node             --version
binary_ok bun              --version
binary_ok python3          --version
binary_ok gpg              --version
binary_ok curl             --version
binary_ok pnpm             --version
binary_ok sqlite3          --version
binary_ok claude           --version
# Skill-kit companion CLIs
binary_ok shellcheck       --version
binary_ok bats             --version
binary_ok shfmt            --version
binary_ok checkbashisms    --version
# `dash` has no --version flag — its presence + ability to execute is the check.
check "binary: dash works" bash -c 'command -v dash >/dev/null && dash -c true'
binary_ok uv               --version
binary_ok ruff             --version
binary_ok sqlfluff         --version
binary_ok actionlint       -version
binary_ok markdownlint-cli2 --version
binary_ok pre-commit       --version
binary_ok trufflehog       --version
binary_ok hadolint         --version
binary_ok dotenv-linter    --version
binary_ok sqlcmd           --version
check "binary: sqlpackage" bash -c "command -v sqlpackage >/dev/null"
binary_ok pwsh             --version
binary_ok yamllint         --version
binary_ok ansible-lint     --version
binary_ok flake8           --version
binary_ok pylint           --version
binary_ok cfn-lint         --version
binary_ok markdownlint     --version
binary_ok stylelint        --version
binary_ok eslint           --version
binary_ok block-no-verify  --version
# composite-action-lint has no --version / --help in older revisions, so it's
# excluded from the binary_ok loop above. Its on-PATH + provenance checks
# live in lib/image-state-checks.sh (loaded below in section 1b).

# block-no-verify is wired into the agent-runner's PreToolUse hook chain
# (claude.ts → blockNoVerifyHook). Surface that the binary returns the
# expected exit codes so a packaging regression is caught at boot rather
# than the first time someone tries to run `git --no-verify`.
check "block-no-verify allows safe commands" bash -c '
    out=$(echo "git status" | block-no-verify --format claude-code 2>&1); rc=$?
    [ "$rc" = "0" ] || { echo "expected exit 0, got $rc — $out" >&2; exit 1; }
'
check "block-no-verify blocks --no-verify" bash -c '
    out=$(echo "{\"tool_input\":{\"command\":\"git commit --no-verify -m x\"}}" | block-no-verify --format claude-code 2>&1); rc=$?
    [ "$rc" = "2" ] || { echo "expected exit 2, got $rc — $out" >&2; exit 1; }
'

# ── 1b. Image-state checks (shared with build-time sanity) ───────────
# Sources the same canonical list of /opt/* layout + binary-on-PATH checks
# that container/base.Dockerfile runs at build time. Single source of truth
# at /usr/local/lib/nanoclaw/image-state-checks.sh — see
# container/lib/image-state-checks.sh in the repo. Anything that depends on
# per-session mounts (creds, agent group folder, workspace, session DB)
# stays in the runtime-only sections below.
. /usr/local/lib/nanoclaw/image-state-checks.sh
image_state_checks

# ── 2. Credential mounts (host dotfiles) ─────────────────────────────
# ~/.config/gh is INTENTIONALLY NOT mounted — its hosts.yml contains the
# real GitHub PAT, which we keep out of the container. gh CLI auth comes
# from the GH_ENTERPRISE_TOKEN env var (Dockerfile placeholder, OneCLI
# substitutes the real fake-proxy-token at egress). See container/entrypoint.sh.
#
# Capability env vars (set by host container-runner.ts from container.json's
# `excludeDotMounts`) gate which mounts we expect. A peer agent that gave
# up SSH (e.g. Changelog) reports `NANOCLAW_HAS_SSH=0` and we skip the SSH
# checks rather than report false failures.
say "capabilities: HAS_SSH=${NANOCLAW_HAS_SSH:-1} HAS_GNUPG=${NANOCLAW_HAS_GNUPG:-1} HAS_GITCONFIG=${NANOCLAW_HAS_GITCONFIG:-1} GH_CHECK_DISABLED=${NANOCLAW_GH_CHECK_DISABLED:-0}"
if [ "${NANOCLAW_HAS_SSH:-1}" = "1" ]; then
  check "mount: ~/.ssh/id_ed25519 readable" test -r /home/node/.ssh/id_ed25519
  check "mount: ~/.ssh/known_hosts or accept-new" bash -c "test -r /home/node/.ssh/known_hosts || true"
fi
if [ "${NANOCLAW_HAS_GNUPG:-1}" = "1" ]; then
  check "mount: ~/.gnupg/ exists"           test -d /home/node/.gnupg
fi
if [ "${NANOCLAW_HAS_GITCONFIG:-1}" = "1" ]; then
  check "mount: ~/.gitconfig readable"      test -r /home/node/.gitconfig
fi
check "mount: ~/.database readable"       test -r /home/node/.database
check "no leak: ~/.config/gh NOT mounted" bash -c "[ ! -e /home/node/.config/gh/hosts.yml ]"

# ── 3. Agent-runner mounts (host → /app overlay) ─────────────────────
check "mount: /app/src/index.ts present"     test -f /app/src/index.ts
check "mount: /app/skills/ non-empty"        bash -c '[ -n "$(ls -A /app/skills 2>/dev/null)" ]'
check "mount: /app/CLAUDE.md present"        test -f /app/CLAUDE.md

# ── 4. Session DB I/O ────────────────────────────────────────────────
check "/workspace/inbound.db readable"  bash -c "sqlite3 -readonly /workspace/inbound.db 'SELECT 1' >/dev/null"
check "/workspace/outbound.db readable" bash -c "sqlite3 -readonly /workspace/outbound.db 'SELECT 1' >/dev/null"
check "/workspace/outbound.db writable" bash -c '[ -w /workspace/outbound.db ]'

# ── 5. Environment ───────────────────────────────────────────────────
check "env: TZ set"                bash -c '[ -n "${TZ:-}" ]'
check "env: HOME=/home/node"       bash -c '[ "${HOME:-}" = "/home/node" ]'
say "    → TZ=${TZ:-} HOME=${HOME:-}"

# ── 6. Git config — identity & signing ───────────────────────────────
# Identity is gated by NANOCLAW_HAS_GITCONFIG (a peer that excluded the
# gitconfig mount obviously can't have a configured user.name).
# Signing keys are additionally gated by NANOCLAW_HAS_GNUPG.
if [ "${NANOCLAW_HAS_GITCONFIG:-1}" = "1" ]; then
  NAME=$(git config --global --get user.name 2>/dev/null || true)
  EMAIL=$(git config --global --get user.email 2>/dev/null || true)
  SIGNKEY=$(git config --global --get user.signingkey 2>/dev/null || true)
  GPGSIGN=$(git config --global --get commit.gpgsign 2>/dev/null || true)
  GPGPROG=$(git config --global --get gpg.program 2>/dev/null || true)
  say "git config: user.name='$NAME' user.email='$EMAIL' user.signingkey='$SIGNKEY' commit.gpgsign='$GPGSIGN' gpg.program='$GPGPROG'"

  if [ -n "$NAME" ];    then pass "git config user.name set ($NAME)"; else fail "git config user.name set" "empty"; fi
  if [[ "$EMAIL" == *@*.* ]]; then pass "git config user.email valid ($EMAIL)"; else fail "git config user.email valid" "got '$EMAIL'"; fi
  if [ "${NANOCLAW_HAS_GNUPG:-1}" = "1" ]; then
    if [ -n "$SIGNKEY" ]; then pass "git config user.signingkey set ($SIGNKEY)"; else fail "git config user.signingkey set" "empty"; fi
    if [ "$GPGSIGN" = "true" ]; then pass "git config commit.gpgsign=true"; else fail "git config commit.gpgsign=true" "got '$GPGSIGN'"; fi
    if [ -n "$GPGPROG" ]; then
      if [ -x "$GPGPROG" ]; then pass "git config gpg.program executable ($GPGPROG)"; else fail "git config gpg.program executable" "$GPGPROG missing or not executable"; fi
    else
      fail "git config gpg.program set" "empty"
    fi
  fi
fi

# ── 6b. Git config defaults (overlaid via GIT_CONFIG_* env vars) ────
# Confirms entrypoint.sh's overlay actually took effect — host gitconfig
# may differ, so we test the *resolved* config git sees.
git_eq() {
  local key="$1" expected="$2"
  local actual
  actual=$(git config --get "$key" 2>/dev/null || true)
  if [ "$actual" = "$expected" ]; then
    pass "git config $key=$expected"
  else
    fail "git config $key=$expected" "got '$actual'"
  fi
}
git_eq core.autocrlf            false
git_eq core.fscache             true
git_eq core.ignorecase          false
git_eq core.preloadIndex        true
git_eq feature.manyFiles        true
git_eq fetch.parallel           16
git_eq fetch.prune              true
git_eq merge.ff                 false
git_eq pull.rebase              true
git_eq push.autoSetupRemote     true
git_eq rebase.autosquash        true
git_eq core.packedGitLimit      512m
git_eq core.packedGitWindowSize 512m
git_eq core.hooksPath           /opt/git-global-hooks
git_eq url.git@github.com:.insteadOf    https://github.com/
git_eq url.git@gitlab.com:.insteadOf    https://gitlab.com/
git_eq url.git@bitbucket.org:.insteadOf https://bitbucket.org/

# Mandatory pre-commit wiring — the hook shim, the orchestrator it delegates
# to, and the upstream config all live in /opt and are asserted by section
# 1b (lib/image-state-checks.sh). /etc/gitconfig points every commit at the
# shim; any of those missing would error out every agent commit. The shim
# delegation check matters in particular because a previous revision
# short-circuited to `pre-commit run --config ...` directly, which silently
# skipped every non-linting stage (branch protection, dotnet buildtest,
# npm test, tsqllint, etc.) — that delegation grep lives in the shared list.

# ── 6c. Tamper-resistance: root-owned, agent-cannot-write ───────────
# Confirms /etc/gitconfig and the /opt/pre-commit install aren't writable
# by the unprivileged `node` user the agent runs as. `[ -w PATH ]` tests
# the *running user's* effective write permission, so this is a direct
# "could the agent modify this?" test.
check_root_ro() {
  local path="$1"
  if [ ! -e "$path" ]; then
    fail "tamper: $path exists" "missing"
    return
  fi
  local owner
  owner=$(stat -c '%U' "$path" 2>/dev/null || true)
  if [ "$owner" != "root" ]; then
    fail "tamper: $path owner=root" "got '$owner'"
    return
  fi
  if [ -w "$path" ]; then
    fail "tamper: $path read-only for node" "still writable"
    return
  fi
  pass "tamper: $path root-owned + read-only"
}
check_root_ro /etc/gitconfig
check_root_ro /opt/pre-commit
check_root_ro /opt/git-global-hooks
check_root_ro /opt/git-global-hooks/pre-commit
check_root_ro /home/node/.nuget
check_root_ro /home/node/.nuget/NuGet
check_root_ro /home/node/.nuget/NuGet/NuGet.Config

# NUGET_PACKAGES must point at a node-writable cache directory because the
# default ~/.nuget/packages location is now root-owned (lockdown above).
# Without the redirect, every `dotnet restore` / `dotnet tool install` would
# fail with permission errors on package extraction.
if [ "$NUGET_PACKAGES" = "/home/node/.nuget-cache" ]; then
  pass "env NUGET_PACKAGES=/home/node/.nuget-cache"
else
  fail "env NUGET_PACKAGES=/home/node/.nuget-cache" "got '${NUGET_PACKAGES:-unset}'"
fi
check "nuget package cache is node-writable" test -w /home/node/.nuget-cache

# npm registry routing. /etc/npmrc + NPM_CONFIG_REGISTRY both must point at
# the local cache mirror — drift between them, or either falling back to
# registry.npmjs.org, means agent installs go out to the public registry.
EXPECTED_NPM_REGISTRY="https://npm.markridgwell.com/"
check "tamper: /etc/npmrc root-owned + read-only" bash -c '
    [ -e /etc/npmrc ] && [ "$(stat -c "%U" /etc/npmrc)" = "root" ] && [ ! -w /etc/npmrc ]
'
if [ "$NPM_CONFIG_REGISTRY" = "$EXPECTED_NPM_REGISTRY" ]; then
  pass "env NPM_CONFIG_REGISTRY=$EXPECTED_NPM_REGISTRY"
else
  fail "env NPM_CONFIG_REGISTRY=$EXPECTED_NPM_REGISTRY" "got '${NPM_CONFIG_REGISTRY:-unset}'"
fi
NPM_RESOLVED=$(npm config get registry 2>/dev/null)
if [ "$NPM_RESOLVED" = "$EXPECTED_NPM_REGISTRY" ]; then
  pass "npm config get registry → $EXPECTED_NPM_REGISTRY"
else
  fail "npm config get registry → $EXPECTED_NPM_REGISTRY" "got '$NPM_RESOLVED'"
fi
PNPM_RESOLVED=$(pnpm config get registry 2>/dev/null)
if [ "$PNPM_RESOLVED" = "$EXPECTED_NPM_REGISTRY" ]; then
  pass "pnpm config get registry → $EXPECTED_NPM_REGISTRY"
else
  fail "pnpm config get registry → $EXPECTED_NPM_REGISTRY" "got '$PNPM_RESOLVED'"
fi
# Also assert no file under /opt/pre-commit is writable by node — `find
# -writable` runs as the current user, so any hit means the agent could
# tamper with that file.
WRITABLE_HITS=$(find /opt/pre-commit -writable 2>/dev/null | head -3 | tr '\n' ' ')
if [ -z "$WRITABLE_HITS" ]; then
  pass "tamper: no writable files under /opt/pre-commit"
else
  fail "tamper: no writable files under /opt/pre-commit" "$WRITABLE_HITS"
fi

# ── 7. gh + gpg health ───────────────────────────────────────────────
# We do NOT use `gh auth status` here — that probe makes a /user request
# and validates the response shape, which the credfeto/github-api-proxy
# transforms in ways gh interprets as "invalid token" (despite real API
# calls working fine through the same chain). Instead we exercise an
# actual API call: `gh api /rate_limit` returns rate-limit JSON via the
# full chain (gh → OneCLI substitutes Authorization → proxy validates fake
# token → swaps to real PAT → api.github.com → response). If this works,
# the entire egress + auth path is healthy.
#
# Capability gates:
#   - gh check skipped when NANOCLAW_GH_CHECK_DISABLED=1 (e.g. Committer,
#     which has no business calling the GitHub API — actual lockdown is
#     server-side via OneCLI agent secret scoping; this just keeps the
#     check from reporting a false failure).
#   - gpg checks skipped when NANOCLAW_HAS_GNUPG=0 (peer with no keyring).
if [ "${NANOCLAW_GH_CHECK_DISABLED:-0}" != "1" ]; then
  check "gh api /rate_limit (full chain via proxy)" \
      bash -c "gh api /rate_limit --jq .rate.limit | grep -qE '^[0-9]+$'"
fi
if [ "${NANOCLAW_HAS_GNUPG:-1}" = "1" ]; then
  check "gpg secret key present" bash -c 'gpg --list-secret-keys 2>/dev/null | grep -q "^sec"'
  check "gpg-agent / keyboxd responsive" bash -c 'gpg --list-keys >/dev/null 2>&1'

  # Cross-check: the signing key in gitconfig actually exists in the keyring.
  if [ -n "${SIGNKEY:-}" ]; then
    if gpg --list-secret-keys --with-colons 2>/dev/null | awk -F: '/^sec|^fpr|^uid/ {print $5; print $10}' | grep -qF "$SIGNKEY"; then
      pass "gpg keyring has signing key from gitconfig"
    else
      fail "gpg keyring has signing key from gitconfig" "key '$SIGNKEY' not found in secret keyring"
    fi
  fi
fi

# ── 8. OneCLI gateway (proxy + injected CA cert) ─────────────────────
PROXY="${HTTPS_PROXY:-${https_proxy:-}}"
CA="${SSL_CERT_FILE:-}"
say "OneCLI env: HTTPS_PROXY='$PROXY' SSL_CERT_FILE='$CA'"
if [ -n "$PROXY" ]; then pass "OneCLI HTTPS_PROXY set"; else fail "OneCLI HTTPS_PROXY set" "missing — agent will skip the credential-inject proxy"; fi
if [ -n "$CA" ]; then
  if [ -r "$CA" ]; then pass "OneCLI SSL_CERT_FILE readable ($CA)"; else fail "OneCLI SSL_CERT_FILE readable" "$CA missing or unreadable"; fi
else
  fail "OneCLI SSL_CERT_FILE set" "empty — TLS to host gateway will fail"
fi

# ── 9. SSH auth to GitHub ────────────────────────────────────────────
# Skipped for peers that have given up the SSH key (NANOCLAW_HAS_SSH=0).
if [ "${NANOCLAW_HAS_SSH:-1}" = "1" ]; then
  check "ssh auth to github.com" bash -c '
    ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -T git@github.com 2>&1 \
      | grep -q "successfully authenticated"
  '
fi

# ── 10. Round-trip: clone/commit/push (SSH + HTTPS) ──────────────────
#
# One run creates two branches:
#   sanity-runs/ssh/<ts>   — cloned + pushed via SSH, commit GPG-signed
#   sanity-runs/https/<ts> — cloned + pushed via HTTPS (exercises gh's git
#                             credential helper, proving token works)
#
# Cleanup workflow on the sanity repo prunes any sanity-runs/** branch
# older than 7 days.
TS=$(date -u +%Y%m%d%H%M%S)

run_protocol() {
  local proto="$1" url="$2"
  local dir=/tmp/sanity-${proto}-$$
  # Branch name must be unique across concurrent spawns. Multiple peer agents
  # cold-spawning at the same second (e.g. when main fans out to several at
  # once) would otherwise all push the same branch name and all but one fail
  # at git push. NANOCLAW_GROUP_FOLDER (set by the host) identifies the agent
  # group; hostname is the docker-assigned per-container ID (always unique
  # per spawn). Both gives both human-readable and bulletproof uniqueness.
  local branch="sanity-runs/${proto}/${TS}-${NANOCLAW_GROUP_FOLDER:-unknown}-$(hostname)"
  local sign_flag=""
  local env_setup=""
  # SSH run is the GPG-sign smoke test (one signed commit is enough; a second
  # would double round-trip time without proving anything new). HTTPS run
  # must explicitly --no-gpg-sign because the host gitconfig sets
  # commit.gpgsign=true unconditionally, so leaving it default would attempt
  # to sign on agents that excluded ~/.gnupg (e.g. PR Submitter) and fail
  # with "gpg: signing failed: No secret key".
  if [ "$proto" = "ssh" ]; then
    sign_flag="-S"
  else
    sign_flag="--no-gpg-sign"
  fi
  # For HTTPS, bypass /etc/gitconfig's url.https→ssh rewrite so we actually
  # exercise the HTTPS auth path (without this, the rewrite would silently
  # turn https://github.com/ into git@github.com: and we'd be re-testing SSH).
  [ "$proto" = "https" ] && env_setup="export GIT_CONFIG_SYSTEM=/dev/null;"

  check "git clone via ${proto^^}" bash -c "
    $env_setup
    rm -rf $dir &&
    git clone --depth 1 '$url' $dir &&
    test -d $dir/.git
  " || { rm -rf "$dir"; return; }

  # core.hooksPath is now baked into /etc/gitconfig, so by default every
  # commit in the container fires the credfeto pre-commit chain. For this
  # meta-test we use --no-verify because the round-trip is testing
  # git/gpg/remote auth, not the linter chain — sanity files like
  # .last-sanity-run aren't lintable input, and we want the test to
  # finish in seconds.
  check "commit + push to $branch" bash -c "
    $env_setup
    cd $dir &&
    git checkout -B '$branch' &&
    printf '%s\\n%s\\n%s\\n' \"$(date -u +'%Y-%m-%dT%H:%M:%SZ')\" \"$(hostname)\" \"$proto\" > .last-sanity-run &&
    git add .last-sanity-run &&
    git commit --no-verify $sign_flag -m 'sanity ($proto): $TS' &&
    git push origin '$branch'
  "
  rm -rf "$dir"
}

# SSH round-trip needs both an SSH key (to push) and a GPG key (the test
# signs the sanity commit). HTTPS round-trip needs the gh credential helper
# (which authenticates via the OneCLI proxy), so it's skipped when
# NANOCLAW_GH_CHECK_DISABLED=1.
if [ "${NANOCLAW_HAS_SSH:-1}" = "1" ] && [ "${NANOCLAW_HAS_GNUPG:-1}" = "1" ]; then
  run_protocol ssh   "git@github.com:dnyw4l3n13/scratch.git"
fi
# HTTPS round-trip. Disabled entirely when NANOCLAW_GH_CHECK_DISABLED=1
# (the agent's container.json set disableGhCheck — it delegates all git).
#
# Crash-loop guard: an agent with no SSH key has no direct git path and
# delegates remote git. Running the HTTPS round-trip for such an agent
# fails the destructive clone, exits 42, and after three spawns the
# host's restart-limiter suspends the session — a silent loop with only
# a generic "correct access rights" line to show for it (this is exactly
# what happened to the Main orchestrator, 2026-05). So when the agent
# has no SSH fallback, first probe HTTPS reachability read-only with
# `git ls-remote` (no clone/branch/push, same GIT_CONFIG_SYSTEM env as
# run_protocol so it predicts the round-trip outcome). If the probe
# can't reach the remote, this agent has no working git path *by design*
# — record a skip with the remedy and keep booting instead of
# crash-looping. Agents that DO have an SSH key keep the original fatal
# behaviour: for them a broken HTTPS path is a real regression worth a
# ✗, and they can't crash-loop here because §10's SSH round-trip already
# proved a working git path.
HTTPS_REPO="https://github.com/dnyw4l3n13/scratch.git"
if [ "${NANOCLAW_GH_CHECK_DISABLED:-0}" = "1" ]; then
  :  # explicitly disabled via disableGhCheck — nothing to do
elif [ "${NANOCLAW_HAS_SSH:-1}" != "1" ] \
  && ! GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0 \
       timeout 25 git ls-remote --heads "$HTTPS_REPO" >/dev/null 2>&1; then
  skip "git round-trip via HTTPS" \
    "agent has no SSH key and github.com is unreachable over HTTPS — it has no direct git path by design (delegates remote git); set disableGhCheck:true in its container.json to silence this, or provision an SSH key / github.com credential if it must do git itself"
else
  run_protocol https "$HTTPS_REPO"
fi

# ── 11. dotnet global tools ──────────────────────────────────────────
for tool in credfeto.changelog.cmd credfeto.dotnet.code.analysis.overrides.cmd tsqllint funfair.buildcheck funfair.buildversion cwm.roslynnavigator dotnet-ef credfeto.dotnet.repo.formatter; do
  check "dotnet tool: $tool" bash -c "dotnet tool list -g | awk '{print tolower(\$1)}' | grep -Fxq $tool"
done

# ── 11b. dotnet tools visible to LOGIN shells too ─────────────────────
# Without /etc/profile.d/nanoclaw-paths.sh, /home/node/.dotnet/tools and
# /pnpm fall off PATH whenever something spawns a login shell (husky's
# `bash --login`, pre-commit's hook runners, sshd sessions). The agent
# then can't find cscleanup / buildcheck / buildversion etc. exactly when
# the pre-commit hook tries to run them. Catch a regression at boot
# instead of mid-pre-commit.
check "login-shell PATH: dotnet-buildcheck"  bash -lc 'command -v dotnet-buildcheck >/dev/null'
check "login-shell PATH: dotnet-cscleanup"   bash -lc 'command -v dotnet-cscleanup >/dev/null'
check "login-shell PATH: dotnet-ef"          bash -lc 'command -v dotnet-ef >/dev/null'
check "login-shell PATH: dotnet (CLI)"       bash -lc 'command -v dotnet >/dev/null'
check "login-shell PATH: pnpm globals (claude)" bash -lc 'command -v claude >/dev/null'

# ── 12. cwm-roslyn-navigator functional probe ───────────────────────
# Existence + on-PATH for the dotnet-claude-kit plugin tree and the
# cwm-roslyn-navigator binary is asserted in section 1b via the shared
# image-state list. Here we add the one runtime-only check the shared list
# can't carry: a live `--help` exec, in case the binary regresses post-build.
check "dotnet-claude-kit: cwm-roslyn-navigator --help" \
    bash -c "cwm-roslyn-navigator --help >/dev/null 2>&1"

# ── Verdict ──────────────────────────────────────────────────────────
TOTAL=$((PASS + FAIL))
if [ $FAIL -eq 0 ]; then
  HEADER="✅ Container startup OK — $PASS/$TOTAL checks passed"
  EXIT_CODE=0
else
  HEADER="🛑 Container startup FAILED — $PASS/$TOTAL checks passed (agent NOT started)"
  EXIT_CODE=42
fi
say "$HEADER"

# ── Write the structured JSON results file ──────────────────────────
#
# Per-check JSONL records have been accumulating in $RESULTS_JSONL. Wrap
# them in an envelope and write to /workspace/.startup-check.json. This
# file is in the session bind-mount, so:
#   - the agent (running as `node`) can read it: /workspace/.startup-check.json
#   - the host can read it: data/v2-sessions/<group>/<session>/.startup-check.json
#   - the operator can request it via the host or via the agent
# Best-effort: write failures don't abort the container start.
export STARTUP_HEADER="$HEADER" STARTUP_PASS="$PASS" STARTUP_FAIL="$FAIL" STARTUP_TOTAL="$TOTAL" STARTUP_EXIT="$EXIT_CODE" RESULTS_JSONL RESULTS_JSON
python3 - <<'PY' 2>/dev/null || true
import json, os, time, sys

results_jsonl = os.environ["RESULTS_JSONL"]
results_json  = os.environ["RESULTS_JSON"]
header  = os.environ.get("STARTUP_HEADER", "")
pass_n  = int(os.environ.get("STARTUP_PASS", "0"))
fail_n  = int(os.environ.get("STARTUP_FAIL", "0"))
total_n = int(os.environ.get("STARTUP_TOTAL", "0"))
exit_n  = int(os.environ.get("STARTUP_EXIT", "0"))

checks = []
try:
    with open(results_jsonl, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                checks.append(json.loads(line))
            except json.JSONDecodeError as e:
                # Don't lose the whole file because one record is corrupt.
                checks.append({"name": "(corrupt record)", "status": "fail", "reason": str(e)})
except FileNotFoundError:
    pass

doc = {
    "header": header,
    "summary": {"pass": pass_n, "fail": fail_n, "total": total_n, "exit_code": exit_n},
    "finished_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "checks": checks,
}

try:
    with open(results_json, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=2)
        f.write("\n")
except OSError as e:
    print(f"startup-check: JSON write failed: {e}", file=sys.stderr)
PY

# ── Post the report to Discord (always — pass or fail) ──────────────
#
# Report goes to outbound.db, which the host's delivery loop reads and
# posts via the same channel that woke this container. Routing target
# comes from the most recent inbound message with a platform_id set.
#
# Format: code-fenced list of every ✓ / ✗ line. Discord's 2000-char
# message cap is enforced via best-effort truncation in the Python.
export STARTUP_HEADER="$HEADER"
python3 - <<'PY' || true
import sqlite3, time, random, string, os, sys, json

inbound = "/workspace/inbound.db"
outbound = "/workspace/outbound.db"
log_path = "/tmp/startup-check.log"
header = os.environ.get("STARTUP_HEADER", "Container startup check")

# Find a destination — most recent inbound with platform_id.
dest = None
try:
    ic = sqlite3.connect(f"file:{inbound}?mode=ro", uri=True)
    row = ic.execute(
        "SELECT platform_id, channel_type, thread_id FROM messages_in "
        "WHERE platform_id IS NOT NULL AND channel_type IS NOT NULL "
        "ORDER BY seq DESC LIMIT 1"
    ).fetchone()
    ic.close()
    if row:
        dest = {"platform_id": row[0], "channel_type": row[1], "thread_id": row[2]}
except Exception as e:
    print(f"startup-check: inbound.db read failed: {e}", file=sys.stderr)

if not dest:
    print("startup-check: no destination — report not posted to chat", file=sys.stderr)
    sys.exit(0)

# On success, post just the header (one-line OK summary). On failure,
# list only the ✗ lines under the header — passes are noise when
# something's broken, and the full log is in /tmp/startup-check.log
# anyway.
fails = []
try:
    with open(log_path) as f:
        for line in f:
            s = line.rstrip()
            idx = s.find("] ")
            if idx < 0:
                continue
            body_line = s[idx + 2:]
            if body_line.startswith("✗ "):
                fails.append(body_line)
except Exception as e:
    print(f"startup-check: log read failed: {e}", file=sys.stderr)

if not fails:
    body = f"**{header}**"
else:
    # Discord 2000-char limit. Reserve ~200 for header + code-fence markers.
    budget = 1800
    shown, used = [], 0
    for ln in fails:
        if used + len(ln) + 1 > budget:
            shown.append(f"... and {len(fails) - len(shown)} more (see /tmp/startup-check.log)")
            break
        shown.append(ln)
        used += len(ln) + 1
    body = f"**{header}**\n```\n" + "\n".join(shown) + "\n```"

msg_id = "startup-" + "".join(random.choices(string.ascii_lowercase + string.digits, k=10))
now = time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime())

try:
    oc = sqlite3.connect(outbound)
    # seq parity: container-side writes use odd seq; nextOddSeq = max+2 rounded up.
    max_seq = oc.execute("SELECT COALESCE(MAX(seq), -1) FROM messages_out").fetchone()[0]
    next_seq = (max_seq + 2) if max_seq >= 0 else 1
    if next_seq % 2 == 0:
        next_seq += 1
    oc.execute(
        "INSERT INTO messages_out (id, seq, timestamp, kind, platform_id, "
        "channel_type, thread_id, content) VALUES (?, ?, ?, 'chat', ?, ?, ?, ?)",
        (msg_id, next_seq, now, dest["platform_id"], dest["channel_type"], dest["thread_id"],
         json.dumps({"text": body})),
    )
    oc.commit()
    oc.close()
    print(f"startup-check: report posted to {dest['channel_type']}:{dest['platform_id']} as {msg_id}", file=sys.stderr)
except Exception as e:
    print(f"startup-check: outbound.db write failed: {e}", file=sys.stderr)
PY

if [ $EXIT_CODE -ne 0 ]; then
  cat "$LOG" >&2
fi
exit $EXIT_CODE
