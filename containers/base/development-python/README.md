# development-python

Base image: `ghcr.io/credfeto/development-node:latest`

This is stage 3 of the development base image chain:

```text
development-tools  →  development-node  →  development-python
```

It adds Python pip-based tooling that is either too new for Debian stable, not
packaged at all, or needs a version newer than what Debian ships.

## What it installs

All packages are installed with `pip3 install --break-system-packages
--no-cache-dir` so the binaries land in `/usr/local/bin`, which takes
precedence over the apt-managed `/usr/bin` equivalents.

| Package | Version | Reason pip, not apt |
| --- | --- | --- |
| `uv` | latest | Astral toolchain; not in Debian stable |
| `ruff` | latest | Astral toolchain; not in Debian stable |
| `sqlfluff` | `${SQLFLUFF_VERSION}` (default `4.1.0`) | Debian Trixie ships `3.3.1`; the `4.x` line is required |
| `pre-commit-hooks` | latest | Provides ~20 `console_script` entry points (`check-merge-conflict`, `end-of-file-fixer`, `trailing-whitespace-fixer`, `detect-private-key`, `check-case-conflict`, …) that the credfeto pre-commit config invokes as `language: system` entries |
| `cfn-lint` | latest | AWS CloudFormation linter; not packaged in Debian |

Note: the stage-1 `development-tools` image installs `yamllint`, `ansible-lint`,
`flake8`, `pylint`, and `pre-commit` as native apt packages. Those are not
reinstalled here.

### Why two separate RUN steps are needed

`cfn-lint` is installed in its own `RUN` step with `--ignore-installed`. Its
dependency tree (notably `pydantic` and related packages) wants to upgrade
`typing_extensions`. However, the apt block in `development-tools` pulled
`python3-typing-extensions` in as a transitive dependency of `ansible-lint`.
Packages installed by apt do not carry a `RECORD` file, so pip cannot uninstall
them (it exits with `error: uninstall-no-record-file`).

`--ignore-installed` tells pip to skip the uninstall step entirely and write
fresh copies into `/usr/local/lib/python3.X/dist-packages`. That path has
higher priority than apt's `/usr/lib` path, so the newer versions win at import
time.

`uv`, `ruff`, `sqlfluff`, and `pre-commit-hooks` do not have this problem: `uv`
and `ruff` are standalone Rust binaries with no Python dependency tree to
reconcile, and `sqlfluff` / `pre-commit-hooks` do not conflict with any
apt-managed package in the base image.

## Users

This stage adds no new users. It inherits the `developer` user (uid/gid chosen
by `useradd`) created in `development-tools` (stage 1). Runtime consumers
should switch to that user.

## Locked-down paths

This stage does not lock down any additional paths. The locked-down path
inherited from `development-node` (stage 2) is:

| Path | Mode | Set by |
| --- | --- | --- |
| `/etc/npmrc` | `0444` (root:root, read-only for all) | `development-node` |

No new immutable files or restricted directories are created in this stage.

## Self-checks

The build-time sanity `RUN` step verifies all binaries accumulated across all
three stages before the image layer is committed. It fails the build (not the
container at runtime) if any check fails.

**Stage 1 + 2 binary presence and `--version` probe** — every binary in the
list below must be on `PATH` and respond successfully to `--version`:

`git`, `gpg`, `curl`, `dotnet`, `shellcheck`, `shfmt`, `bats`, `sqlite3`,
`gh`, `hadolint`, `dotenv-linter`, `sqlcmd`, `actionlint`, `trufflehog`,
`composite-action-lint`, `python3`, `ansible-lint`, `flake8`, `pylint`,
`yamllint`, `pre-commit`, `xmllint`, `node`, `bun`, `markdownlint-cli2`,
`markdownlint`, `stylelint`, `eslint`

**`claude`** — probed with `--version` first; falls back to `--help` because
some releases do not support `--version`.

**`block-no-verify`** — presence-only check via `command -v`; no version flag.

**`ssh -V`** — SSH uses `-V` rather than `--version`; verified separately.

**HTTPS clone** — a `git clone --depth 1` of
`https://github.com/dnyw4l3n13/scratch.git` (a sacrificial public repo) is
performed and then deleted. This confirms the certificate chain, network
connectivity, and proxy configuration are all working at build time.

**Stage 3 pip tool version probes** — each of the pip-installed tools is called
to report its version:

```shell
uv --version
ruff --version
sqlfluff --version
cfn-lint --version
```

**`pre-commit-hooks` console_script presence** — the five most critical entry
points are probed with `command -v` (they do not support `--version` or
`--help`):

`check-merge-conflict`, `check-case-conflict`, `end-of-file-fixer`,
`trailing-whitespace-fixer`, `detect-private-key`

## Suggestions for further lock-down

- **Pin pip package versions.** `uv`, `ruff`, and `pre-commit-hooks` are
  installed without a version pin. Adding explicit version constraints (e.g.
  `uv==0.7.3`) makes builds fully reproducible and prevents silent regressions
  when upstream releases a breaking change.

- **Hash-verify pip downloads.** Use `pip install --require-hashes` with a
  generated `requirements.txt` (produced by `pip-compile --generate-hashes`)
  to detect supply-chain tampering. `uv pip sync --require-hashes` is the
  equivalent in the Astral toolchain.

- **Drop the pip installer after use.** The image carries a writable
  `pip3`/`pip` binary. If the `developer` user should not be able to install
  additional packages at runtime, remove or `chmod 0` the pip executables in
  a subsequent layer after all pip installs are complete.

- **Read-only `/usr/local/lib` at runtime.** Mount
  `/usr/local/lib/python3.X/dist-packages` read-only (or with `noexec`) in the
  container runtime spec so a compromised process cannot overwrite installed
  tooling.

- **Lock `cfn-lint` to a specific release.** `cfn-lint` is installed without a
  version pin. Pin it the same way `sqlfluff` is pinned via the
  `SQLFLUFF_VERSION` build argument, so it can be bumped deliberately rather
  than silently updated on the next image rebuild.

- **Scan pip packages for known CVEs.** Run `pip-audit` (or `trivy` with pip
  support) as a post-install step in CI to catch vulnerable transitive
  dependencies before they ship in the image.
