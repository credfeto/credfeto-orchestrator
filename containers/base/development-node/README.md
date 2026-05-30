# development-node

Base image: `ghcr.io/credfeto/development-tools:latest`

This image extends the `development-tools` base with a Node.js ecosystem: the
Node.js 24.x runtime, the Bun runtime, and a set of globally installed npm
packages used by the credfeto orchestrator and its agents.

---

## What it installs

### Node.js v24.x

Installed via the official [NodeSource](https://nodesource.com/) setup script
(`setup_24.x`) as a Debian package so it receives apt-based updates.

### Bun runtime

Installed from <https://bun.sh/install> at the version pinned by
`BUN_VERSION` (default `1.3.13`). The binary is placed at
`/usr/local/bin/bun` so all users can execute it.

### npm global packages

All packages are installed globally with `npm install -g`. The install order
goes from most stable to most frequently bumped, which keeps Docker layer
cache hits high when only a version near the end changes.

| Package | Build arg | Purpose |
| --- | --- | --- |
| `@anthropic-ai/claude-code` | `CLAUDE_CODE_VERSION` (default `latest`) | Claude Code CLI; its postinstall downloads the native binary |
| `markdownlint-cli2` | `MARKDOWNLINT_CLI2_VERSION` (default `latest`) | Markdown linter/fixer used by the markdown-linter-fixer skill |
| `markdownlint-cli` | `MARKDOWNLINT_CLI_VERSION` (default `latest`) | Companion Markdown CLI (`markdownlint` command) |
| `stylelint` | `STYLELINT_VERSION` (default `latest`) | CSS/SCSS linter |
| `stylelint-config-standard` | `STYLELINT_CONFIG_STANDARD_VERSION` (default `latest`) | Standard rule set for stylelint |
| `eslint` | `ESLINT_VERSION` (default `latest`) | JavaScript/TypeScript linter |
| `block-no-verify` | `BLOCK_NO_VERIFY_VERSION` (default `1.1.5`) | Security guard that blocks `git --no-verify` and `core.hooksPath` overrides |

---

## Users

The `developer` user (uid created by `development-tools`) is inherited
unchanged. This stage makes no additional `useradd`, `usermod`, or home
directory changes.

---

## Locked-down paths

### `/etc/npmrc` (mode `0444`, owned `root:root`)

Created in this stage. Holds:

```ini
registry=https://npm.markridgwell.com/
```

Both build-time and runtime npm installs are routed through the private mirror
at `npm.markridgwell.com`. The file is world-readable but not writable by any
user other than root, so an unprivileged process inside the container cannot
redirect installs to an arbitrary registry. The `NPM_CONFIG_REGISTRY`
environment variable is also set to the same URL to cover tooling that probes
env directly rather than reading `npmrc`.

---

## Self-checks

The final `RUN` step in this stage runs a comprehensive build-time sanity
check that fails the image build (not the consumer at runtime) if anything is
wrong.

### Stage-1 + Stage-2 binary presence and version probe

Every binary listed below is verified to be on `PATH` via `command -v` and
must exit 0 when called with `--version`:

`git`, `gpg`, `curl`, `dotnet`, `shellcheck`, `shfmt`, `bats`, `sqlite3`,
`gh`, `hadolint`, `dotenv-linter`, `sqlcmd`, `actionlint`, `trufflehog`,
`composite-action-lint`, `python3`, `ansible-lint`, `flake8`, `pylint`,
`yamllint`, `pre-commit`, `xmllint`

### Stage-2 specific binary version probes

The following binaries added by this image are probed individually:

- `node --version`
- `bun --version`
- `claude --version` (falls back to `claude --help` because some releases exit
  non-zero for `--version`)
- `markdownlint-cli2 --version`
- `markdownlint --version`
- `stylelint --version`
- `eslint --version`
- `block-no-verify` presence on `PATH` (verified via `command -v`)

### SSH client

`ssh -V` (OpenSSH reports its version to stderr and exits 0) is verified
separately because it does not accept `--version`.

### HTTPS clone

A shallow clone of `https://github.com/dnyw4l3n13/scratch.git` into
`/tmp/sanity-clone-node` is performed (with `GIT_CONFIG_SYSTEM=/dev/null` so
the system gitconfig cannot interfere) and then removed. This verifies that
the TLS certificate chain is intact and that outbound HTTPS git traffic is
working at build time.

---

## Suggestions for further lock-down

- **Pin all npm package versions.** Currently several packages default to
  `latest`. Passing explicit `--build-arg` values for every `*_VERSION` ARG
  removes the non-determinism and prevents silent breakage when a package
  publishes a breaking release.

- **Verify npm package checksums.** Consider adding a pinned `package-lock.json`
  or using `npm ci` with a lock file instead of `npm install -g`, so the
  exact dependency tree is reproducible and tamper-evident.

- **Make `/usr/local/lib/node_modules` read-only.** After the global install
  step, `chmod -R a-w /usr/local/lib/node_modules` prevents a process running
  as an unprivileged user from patching installed packages at runtime.

- **Drop `NPM_CONFIG_REGISTRY` after build.** If runtime containers do not
  need to install further npm packages, unset or override this env var in the
  consuming image to prevent accidental installs hitting the internal mirror
  from outside a controlled build environment.

- **Remove the npm cache.** Add `npm cache clean --force` at the end of the
  install step to reduce layer size and prevent cached tarballs from being
  exploited.

- **Restrict `/usr/local/bin/bun` to root ownership.** The current install
  uses `install -m 0755`, which is world-executable. `chmod o-w` (already the
  case) is correct; additionally consider `chown root:root` to prevent the
  binary being replaced by a process running as another user in the same
  group.

- **Audit `block-no-verify` placement.** Ensure the git hook that invokes
  `block-no-verify` is installed in a path that itself cannot be overridden by
  `core.hooksPath` — the tool guards against the override but the hook must
  fire first.
