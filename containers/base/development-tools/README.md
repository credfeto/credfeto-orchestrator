# development-tools

Base image: `debian:trixie-slim`

Built and pushed to `ghcr.io/<owner>/development-tools:latest` daily by
`.github/workflows/build-development-tools.yml`.

This image packages the full CI/CD and linting toolchain used by the
credfeto orchestrator. It intentionally contains no application source,
entrypoint scripts, or user workspace — those belong in a customisation
layer that `FROM`s this image.

## What it installs

This file lists where each tool comes from and how its download is verified,
not which version it is. Many of these tools follow upstream with no change to
this repository, so a version written here would go stale. For current
versions, see:

- **Pinned tools:** the `*_VERSION`, `*_SHA256_AMD64`/`*_SHA256_ARM64`, `*_REF`
  and `*_COMMIT` ARGs at the top of the Dockerfile.
- **What a build actually installed:** the `### Installed versions` section of
  the `build-development-tools.yml` run's job summary, read from
  `/opt/installed-versions.txt` in the built image.

### apt packages (from `debian:trixie-slim` + `contrib` component)

Installed from the Debian trixie archive, which apt verifies against the
Debian archive keyring. A `dist-upgrade` in the same layer re-runs on every
daily build, so these packages pick up Debian's updates without a change here.

| Package | Purpose |
| --- | --- |
| `bubblewrap` | Provides `bwrap`, which Claude Code's Linux Bash-tool sandbox needs to start inside the agent container |
| `ca-certificates` | Root CA bundle for TLS verification |
| `curl` | HTTP/HTTPS downloads |
| `dash` | Minimal POSIX shell |
| `fontconfig` | Font discovery and caching |
| `git` | Source control |
| `gnupg` | GPG key management and verification |
| `jq` | JSON processor |
| `libicu76` | ICU Unicode library, required by the .NET runtime |
| `libxml2-utils` | Provides `xmllint`, used by the pre-commit chain |
| `openssh-client` | `ssh` and `ssh-keygen` for remote operations |
| `parallel` | GNU parallel, for parallel task execution (for example `bats --jobs`) |
| `procps` | `ps`, `pkill` and `free`, needed by .NET benchmark tooling |
| `python3` | Python 3 runtime |
| `python3-pip` | Python package installer |
| `python3-venv` | Provides `ensurepip`/the `venv` module — without it `python3 -m venv` fails outright |
| `sqlite3` | SQLite CLI |
| `tini` | Minimal PID 1 / signal forwarder |
| `ttf-mscorefonts-installer` | Real Microsoft TrueType core fonts (Arial, Times New Roman, Courier New, etc.) from the `contrib` component, required by tools such as SixLabors.Fonts that match by internal family-name records |
| `unzip` | Archive extraction |

### apt packages from `trixie-backports`

Trixie's own versions of these lag the ones developer machines and
super-linter run, and the older versions report different findings. They are
installed with `apt-get install -t trixie-backports` from the Debian archive,
verified against the same keyring as above. Backports has apt pin priority
100, so only these packages (and any dependency the main list has not already
installed) come from it. The daily `dist-upgrade` picks up new backport
versions.

| Package | Purpose |
| --- | --- |
| `devscripts` | Provides `checkbashisms`, used by the shell-script lint chain |
| `shellcheck` | Shell script linter |

### Python linters (pip)

Installed from PyPI over HTTPS with `pip3 install --break-system-packages
--ignore-installed`. They are deliberately unpinned, and the layer is tied to
the same daily cache-bust as the apt `dist-upgrade`, so each daily build picks
up the latest releases. Nothing in this repository pins a version or checksum
for them.

`--ignore-installed` is needed because their dependency tree upgrades
`packaging`, which apt installed without the `RECORD` file pip needs to
uninstall it. The new copies land in `/usr/local`, which takes priority over
apt's `/usr/lib` at import time.

| Package | Purpose |
| --- | --- |
| `ansible-lint` | Lint Ansible playbooks and roles (also brings in `ansible-core`, so the `ansible*` commands are on `PATH`) |
| `flake8` | Python style and error linter |
| `pre-commit` | Git hook framework |
| `pylint` | Python static analysis |
| `yamllint` | YAML linter |

### GitHub CLI (`gh`)

Installed from the official GitHub apt repository
(`https://cli.github.com/packages`), signed with the upstream keyring.
Traffic is routed through a local proxy (`github-api.markridgwell.com`) by
default via the `GH_HOST` and `GH_ENTERPRISE_TOKEN` environment variables so
the real GitHub PAT never enters the container.

### Upstream release binaries and source builds

| Tool | Source | Verification |
| --- | --- | --- |
| `hadolint` | GitHub release binary of `hadolint/hadolint` at the pinned `HADOLINT_VERSION` | `sha256sum -c` against the pinned `HADOLINT_SHA256_AMD64`/`HADOLINT_SHA256_ARM64` ARGs |
| `dotenv-linter` | GitHub release `.tar.gz` archive of `dotenv-linter/dotenv-linter` at the pinned `DOTENV_LINTER_VERSION` | `sha256sum -c` against the pinned `DOTENV_LINTER_SHA256_*` ARGs, before extraction |
| `sqlcmd` | GitHub release `.tar.bz2` archive of `microsoft/go-sqlcmd` at the pinned `SQLCMD_VERSION` | `sha256sum -c` against the pinned `SQLCMD_SHA256_*` ARGs, before extraction |
| `actionlint` | GitHub release `.tar.gz` archive of `rhysd/actionlint` at the pinned `ACTIONLINT_VERSION` | `sha256sum -c` against the pinned `ACTIONLINT_SHA256_*` ARGs, before extraction |
| `trufflehog` | GitHub release `.tar.gz` archive of `trufflesecurity/trufflehog` at the pinned `TRUFFLEHOG_VERSION` | `sha256sum -c` against the pinned `TRUFFLEHOG_SHA256_*` ARGs, before extraction |
| `trivy` | GitHub release `.tar.gz` archive of `aquasecurity/trivy` at the pinned `TRIVY_VERSION` | `sha256sum -c` against the pinned `TRIVY_SHA256_*` ARGs, before extraction |
| `shfmt` | Latest non-prerelease `mvdan/sh` release binary, deliberately unpinned. `.github/actions/resolve-shfmt-release` resolves it on every build and passes it in as the `SHFMT_VERSION` build-arg. | mvdan/sh publishes no checksum file, so `sha256sum -c` checks the binary against the SHA256 digest GitHub computed when the asset was uploaded, passed in as `SHFMT_SHA256_AMD64`/`SHFMT_SHA256_ARM64`. A missing or malformed digest fails the build. |
| `bats` | `bats-core/bats-core` cloned at the pinned `BATS_REF` tag and installed with its `install.sh` into `/usr/local`. The clone is removed afterwards. | bats-core publishes no release assets or checksums, so the build fails unless the clone's `HEAD` is the pinned `BATS_COMMIT` |
| `composite-action-lint` | Built from `COMPOSITE_ACTION_LINT_REF` (default `master`) of `bettermarks/composite-action-lint` in a throwaway Go builder stage, because no release binaries are published upstream. The binary lands in `/opt/composite-action-lint/` and is symlinked to `/usr/local/bin/composite-action-lint`. | None beyond the HTTPS clone. The commit it was built from is recorded in `/opt/composite-action-lint/.env`. |

### .NET SDK

Both the current LTS channel and the current STS channel are installed
side-by-side into `/usr/share/dotnet` using Microsoft's official
`dotnet-install.sh` script. This supports repositories that target multiple
TFMs simultaneously (e.g. `net9.0` + `net10.0`). `dotnet` is symlinked to
`/usr/bin/dotnet`.

The following .NET environment variables are set image-wide:

| Variable | Value | Reason |
| --- | --- | --- |
| `DOTNET_ROOT` | `/usr/share/dotnet` | Tells the runtime where the SDK lives |
| `DOTNET_MULTILEVEL_LOOKUP` | `false` | Prevents the runtime searching outside `/usr/share/dotnet` |
| `DOTNET_NOLOGO` | `true` | Suppresses the version banner in CI output |
| `DOTNET_PRINT_TELEMETRY_MESSAGE` | `false` | Disables telemetry opt-in messages |
| `DOTNET_JitCollect64BitCounts` | `1` | Improves JIT throughput in short-lived CI processes |
| `DOTNET_ReadyToRun` | `0` | Disables R2R so the JIT can apply PGO optimisations |
| `DOTNET_TC_QuickJitForLoops` | `1` | Enables QuickJit for loop methods |
| `DOTNET_TC_CallCountingDelayMs` | `0` | Removes the call-counting delay |
| `DOTNET_TieredPGO` | `1` | Enables tiered Profile-Guided Optimisation |
| `MSBUILDTERMINALLOGGER` | `auto` | Uses the terminal logger when a TTY is detected |

## Users

A single unprivileged user `developer` is created with `useradd -m -s /bin/bash developer`. This gives the user:

- A home directory at `/home/developer`
- A login shell of `/bin/bash`

All tools are installed as `root` during the image build. Downstream images
and runtime consumers are expected to switch to the `developer` user for
workload execution. The `developer` home directory is referenced in two ways:

- `PATH` includes `/home/developer/.dotnet/tools` (set via `ENV`) so that
  `dotnet tool install -g` tools installed by the `developer` user are
  automatically on `PATH` for processes started by the container entrypoint.
- `/etc/profile.d/development-tools-paths.sh` re-augments `PATH` for login
  shells (e.g. those started by `bash --login`, `sshd` sessions, or some
  `pre-commit` invocations) that rebuild `PATH` from `/etc/login.defs` and
  would otherwise lose the `.dotnet/tools` entry.

## Locked-down paths

| Path | Permissions | Why tamper-resistant |
| --- | --- | --- |
| `/opt/composite-action-lint/` | `root:root`, directory `0755` | Owned by root; the `developer` user (and any other non-root process) cannot write into it. The binary and `.env` provenance file inside cannot be replaced or deleted without root. |
| `/opt/composite-action-lint/composite-action-lint` | `root:root`, `0755` | The binary itself is owned and write-protected by root. World-executable but not world-writable. |
| `/opt/composite-action-lint/.env` | `root:root` (inherited) | Records the exact `HEAD` SHA and upstream URL baked in at build time; a non-root process cannot alter the provenance record. |
| `/etc/profile.d/development-tools-paths.sh` | `root:root`, `0644` | Written and `chmod 644` by root; readable by all users for shell sourcing but writable only by root, preventing PATH injection via this file. |
| `/usr/local/bin/composite-action-lint` | symlink owned by root | The symlink target resolves to the root-owned binary above; a non-root user cannot retarget or remove the symlink. |

All other binaries under `/usr/local/bin/` (hadolint, dotenv-linter, sqlcmd,
actionlint, trufflehog, trivy, shfmt) are placed with `chmod 0755` and default
to `root:root` ownership, making them executable by all but writable only by
root. `bats` (with its support files under `/usr/local/libexec/bats-core/` and
`/usr/local/lib/bats-core/`) and the pip-installed linters are also installed
by root during the build, so they are root-owned too.

## Self-checks

The final `RUN` block in the Dockerfile is a build-time sanity check that
fails the image build (rather than allowing a broken image to be pushed)
if any of the following conditions are not met.

**Binary presence and `--version` probe.** Every required binary is checked
with `command -v` to confirm it is on `PATH`, then invoked with `--version`
to confirm it exits with status 0. The binaries checked are:

`git`, `gpg`, `curl`, `jq`, `dotnet`, `shellcheck`, `shfmt`, `bats`,
`sqlite3`, `gh`, `hadolint`, `dotenv-linter`, `sqlcmd`, `actionlint`,
`trufflehog`, `trivy`, `python3`, `ansible-lint`, `flake8`, `pylint`,
`yamllint`, `pre-commit`, `xmllint`, `bwrap`, `checkbashisms`

**shellcheck minimum version.** `shellcheck --version` must report at least
the minimum version the Dockerfile asserts, so a fall-back to trixie's older
shellcheck instead of the `trixie-backports` one fails the build.

**Tools resolve to their intended source.** `ansible-lint`, `flake8`,
`pre-commit`, `pylint`, `yamllint`, `shfmt` and `bats` must each resolve to
`/usr/local/bin`, so a Debian copy in `/usr/bin` can never be picked up in
place of the pip, mvdan/sh release or bats-core install.

**composite-action-lint.** Checked separately with `-h` (falling back to
`--help`) because it has no `--version` flag.

**SSH client version.** `ssh -V` (not `--version`) is called separately
because the OpenSSH client uses a non-standard flag.

**HTTPS git clone.** A depth-1 clone of a sacrificial public repository
(`https://github.com/dnyw4l3n13/scratch.git`) is performed with
`GIT_CONFIG_SYSTEM=/dev/null` to bypass any system proxy or config
interference. A successful clone confirms that TLS certificate verification
works (the CA bundle is present), DNS resolves, and outbound HTTPS is
reachable from the build host. The cloned directory is removed immediately
afterwards.

**`python3 -m venv` round-trip.** A throwaway virtual environment is created
in `/tmp`, its bundled `pip` is invoked with `--version` to confirm
`ensurepip` actually worked, and the venv is then removed. This is what
`python3-venv` exists to provide — without it, `python3 -m venv` fails
outright rather than producing a working environment (#1289).

SSH authentication and mount-dependent checks are intentionally deferred to
runtime startup scripts in the consuming image because SSH keys are not
available at image build time.

## Suggestions for further lock-down

- **Make static binaries immutable.** After installing each static binary in
  `/usr/local/bin`, set the immutable bit with `chattr +i` (requires
  `e2fsprogs` in the build and a writable ext4 layer). This prevents even
  root inside the running container from overwriting a binary without
  explicitly clearing the attribute first.

- **Use a read-only root filesystem at runtime.** Run downstream containers
  with `--read-only` and explicit `--tmpfs /tmp` and `--tmpfs
  /home/developer` mounts. This eliminates the entire class of attacks that
  depend on writing to the filesystem at runtime.

- **Drop all Linux capabilities.** Start containers with `--cap-drop ALL`
  and add back only the specific capabilities that tools actually need (in
  most linting workloads none are required). This prevents privilege
  escalation via `CAP_NET_ADMIN`, `CAP_SYS_PTRACE`, etc.

- **Pin installer scripts by content hash.** The `dotnet-install.sh` script is
  fetched with `curl` at build time and executed directly. Pinning a `sha256`
  digest alongside the URL (and verifying with `sha256sum -c`) would prevent a
  supply-chain compromise from injecting malicious content into that script
  between the time it is written and the time the image is built.

- **Restrict `GH_ENTERPRISE_TOKEN` scope.** The placeholder token currently
  has no intrinsic scope — its real power comes from whatever the upstream
  proxy exchanges it for. Add a short token lifetime (rotating frequently)
  and an allowlist of permitted GitHub API paths in the proxy to minimise the
  blast radius of a leaked token.

- **Add a `seccomp` profile.** Supply a custom `seccomp` profile that
  restricts the syscall surface to what linting and build tools actually use,
  blocking unusual calls such as `ptrace`, `mount`, `kexec_load`, and
  `reboot` that have no legitimate use in a CI linting container.

- **Remove `devscripts` if not needed.** The `devscripts` package pulls in a
  large set of Debian packaging tools that are unlikely to be required in a
  pure linting image. Removing it reduces the attack surface and image size.
