# development-tools

Base image: `debian:trixie-slim`

Built and pushed to `ghcr.io/<owner>/development-tools:latest` hourly by
`.github/workflows/build-development-tools.yml`.

This image packages the full CI/CD and linting toolchain used by the
credfeto orchestrator. It intentionally contains no application source,
entrypoint scripts, or user workspace — those belong in a customisation
layer that `FROM`s this image.

## What it installs

### apt packages (from `debian:trixie-slim` + `contrib` component)

| Package | Purpose |
| --- | --- |
| `ansible-lint` | Lint Ansible playbooks and roles |
| `bats` | Bash Automated Testing System |
| `ca-certificates` | Root CA bundle for TLS verification |
| `curl` | HTTP/HTTPS downloads |
| `dash` | Minimal POSIX shell |
| `devscripts` | Debian packaging helpers |
| `flake8` | Python style and error linter |
| `fontconfig` | Font discovery and caching |
| `git` | Source control |
| `gnupg` | GPG key management and verification |
| `libicu76` | ICU Unicode library, required by the .NET runtime |
| `libxml2-utils` | Provides `xmllint`, used by the pre-commit chain |
| `openssh-client` | `ssh` and `ssh-keygen` for remote operations |
| `pre-commit` | Git hook framework |
| `pylint` | Python static analysis |
| `python3` | Python 3 runtime |
| `python3-pip` | Python package installer |
| `shellcheck` | Shell script linter |
| `shfmt` | Shell script formatter |
| `sqlite3` | SQLite CLI |
| `tini` | Minimal PID 1 / signal forwarder |
| `ttf-mscorefonts-installer` | Real Microsoft TrueType core fonts (Arial, Times New Roman, Courier New, etc.) from the `contrib` component, required by tools such as SixLabors.Fonts that match by internal family-name records |
| `unzip` | Archive extraction |
| `yamllint` | YAML linter |

### GitHub CLI (`gh`)

Installed from the official GitHub apt repository
(`https://cli.github.com/packages`), signed with the upstream keyring.
Traffic is routed through a local proxy (`github-api.markridgwell.com`) by
default via the `GH_HOST` and `GH_ENTERPRISE_TOKEN` environment variables so
the real GitHub PAT never enters the container.

### Static binary linters

| Tool | Version ARG | Source |
| --- | --- | --- |
| `hadolint` | `HADOLINT_VERSION` (default `v2.14.0`) | GitHub releases (single static binary) |
| `dotenv-linter` | `DOTENV_LINTER_VERSION` (default `v4.0.0`) | GitHub releases (`.tar.gz` archive) |
| `sqlcmd` | `SQLCMD_VERSION` (default `v1.10.0`) | GitHub releases for `microsoft/go-sqlcmd` (`.tar.bz2` archive) |
| `actionlint` | `ACTIONLINT_VERSION` (default `latest`) | Official `download-actionlint.bash` installer script |
| `trufflehog` | `TRUFFLEHOG_VERSION` (unset = latest) | Official `install.sh` installer script |
| `trivy` | `TRIVY_VERSION` (default `0.72.0`) | GitHub releases for `aquasecurity/trivy` (`.tar.gz` archive) |
| `composite-action-lint` | built from `master` of `bettermarks/composite-action-lint` | Compiled in a throwaway `golang:1.24-bookworm` multi-stage builder; no release binaries are published upstream. The binary lands in `/opt/composite-action-lint/` and is symlinked to `/usr/local/bin/composite-action-lint`. |

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
actionlint, trufflehog, trivy) are placed with `chmod 0755` and default to
`root:root` ownership, making them executable by all but writable only by
root.

## Self-checks

The final `RUN` block in the Dockerfile is a build-time sanity check that
fails the image build (rather than allowing a broken image to be pushed)
if any of the following conditions are not met.

**Binary presence and `--version` probe.** Every required binary is checked
with `command -v` to confirm it is on `PATH`, then invoked with `--version`
to confirm it exits with status 0. The binaries checked are:

`git`, `gpg`, `curl`, `dotnet`, `shellcheck`, `shfmt`, `bats`, `sqlite3`,
`gh`, `hadolint`, `dotenv-linter`, `sqlcmd`, `actionlint`, `trufflehog`,
`trivy`, `composite-action-lint`, `python3`, `ansible-lint`, `flake8`, `pylint`,
`yamllint`, `pre-commit`, `xmllint`

**SSH client version.** `ssh -V` (not `--version`) is called separately
because the OpenSSH client uses a non-standard flag.

**HTTPS git clone.** A depth-1 clone of a sacrificial public repository
(`https://github.com/dnyw4l3n13/scratch.git`) is performed with
`GIT_CONFIG_SYSTEM=/dev/null` to bypass any system proxy or config
interference. A successful clone confirms that TLS certificate verification
works (the CA bundle is present), DNS resolves, and outbound HTTPS is
reachable from the build host. The cloned directory is removed immediately
afterwards.

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

- **Pin installer scripts by content hash.** The `download-actionlint.bash`,
  `trufflehog/install.sh`, and `dotnet-install.sh` scripts are fetched with
  `curl` at build time and executed directly. Pinning a `sha256` digest
  alongside the URL (and verifying with `sha256sum -c`) would prevent a
  supply-chain compromise from injecting malicious content into those scripts
  between the time they are written and the time the image is built.

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
