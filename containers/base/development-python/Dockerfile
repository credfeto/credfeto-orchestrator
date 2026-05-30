# syntax=docker/dockerfile:1.7
# hadolint ignore=DL3007
FROM ghcr.io/credfeto/development-node:latest

# ---- Build-time arguments ----------------------------------------------------
# Trixie ships an old sqlfluff (3.3.1) — pinned-pip install gives us 4.x.
ARG SQLFLUFF_VERSION=4.1.0

# ---- Python tooling not available in apt -------------------------------------
# The development-tools base image installs yamllint / ansible-lint / flake8 /
# pylint / pre-commit as native apt packages. What remains on pip:
#   - uv, ruff           — Astral toolchain, too new for stable Debian.
#   - cfn-lint           — AWS CloudFormation linter, not in Debian.
#   - sqlfluff           — Trixie ships 3.3.1; we want the 4.x line. Pin via
#     SQLFLUFF_VERSION so rebuilds don't silently bump.
#   - pre-commit-hooks   — provides ~20 console_script bins (check-merge-
#     conflict, end-of-file-fixer, etc.) that the credfeto pre-commit config
#     calls as `language: system` entries. Without these the global pre-
#     commit hook fails with "Executable check-merge-conflict not found".
#
# pip's PEP 668 marker is acknowledged with --break-system-packages; the
# image is a sealed environment so global pip is fine and lands the
# binaries at /usr/local/bin.
#
# Split into two RUN steps because cfn-lint's dep tree (pydantic et al.)
# wants to upgrade typing_extensions, but the apt block in the base image
# pulled in python3-typing-extensions as a transitive dep of ansible-lint.
# pip can't uninstall packages that don't carry a RECORD file (which
# apt-managed ones don't), so the upgrade attempt fails with
# `error: uninstall-no-record-file`. `--ignore-installed` tells pip to skip
# the uninstall step entirely and drop fresh copies into
# /usr/local/lib/python3.X/dist-packages — that path has higher priority
# than apt's /usr/lib path, so the new versions win at import time.
# uv/ruff don't have this problem because they're standalone Rust binaries
# with no Python dep tree to reconcile.
# hadolint ignore=DL3013
RUN pip3 install --break-system-packages --no-cache-dir \
        uv \
        ruff \
        "sqlfluff==${SQLFLUFF_VERSION}" \
        pre-commit-hooks
# hadolint ignore=DL3013,DL3059
RUN pip3 install --break-system-packages --no-cache-dir --ignore-installed \
        cfn-lint

# ---- Build-time sanity check -------------------------------------------------
# Verifies all stage 1 (development-tools) + stage 2 (development-node) +
# stage 3 (development-python) binaries are present and callable.
#
# pre-commit-hooks console_script bins are tiny argparse entry points that
# don't support --version (just --help). Probe them by presence only using
# `command -v` — the credfeto pre-commit config exercises each one at runtime
# as a `language: system` entry.
# hadolint ignore=DL3001
RUN set -e; \
    echo "== stage 1 + stage 2 + stage 3 binary presence + version probe =="; \
    for cmd in git gpg curl dotnet shellcheck shfmt bats sqlite3 gh \
               hadolint dotenv-linter sqlcmd actionlint trufflehog \
               python3 ansible-lint flake8 pylint \
               yamllint pre-commit xmllint \
               node bun markdownlint-cli2 markdownlint stylelint eslint; do \
        if ! command -v "$cmd" >/dev/null 2>&1; then \
            echo "FATAL sanity: required binary '$cmd' is missing" >&2; exit 1; \
        fi; \
        if ! "$cmd" --version >/dev/null 2>&1; then \
            echo "FATAL sanity: '$cmd --version' did not exit 0" >&2; exit 1; \
        fi; \
    done; \
    echo "== composite-action-lint check (uses -h not --version) =="; \
    if ! command -v composite-action-lint >/dev/null 2>&1; then \
        echo "FATAL sanity: required binary 'composite-action-lint' is missing" >&2; exit 1; \
    fi; \
    composite-action-lint -h >/dev/null 2>&1 \
        || composite-action-lint --help >/dev/null 2>&1 \
        || { echo "FATAL sanity: composite-action-lint is not functional" >&2; exit 1; }; \
    echo "== ssh version check (uses -V not --version) =="; \
    if ! ssh -V >/dev/null 2>&1; then \
        echo "FATAL sanity: ssh -V did not exit 0" >&2; exit 1; \
    fi; \
    echo "== HTTPS clone (dnyw4l3n13/scratch — sacrificial sanity target) =="; \
    rm -rf /tmp/sanity-clone-python; \
    GIT_CONFIG_SYSTEM=/dev/null git clone --depth 1 \
        https://github.com/dnyw4l3n13/scratch.git /tmp/sanity-clone-python; \
    rm -rf /tmp/sanity-clone-python; \
    echo "== stage 2 tools (presence / non-standard version flags) =="; \
    claude --version >/dev/null 2>&1 || claude --help >/dev/null 2>&1; \
    if ! command -v block-no-verify >/dev/null 2>&1; then \
        echo "FATAL sanity: block-no-verify is not on PATH" >&2; exit 1; \
    fi; \
    echo "== stage 3 Python tool version probe =="; \
    uv --version; \
    ruff --version; \
    sqlfluff --version; \
    cfn-lint --version; \
    echo "== pre-commit-hooks bins presence check =="; \
    for cmd in check-merge-conflict check-case-conflict end-of-file-fixer \
               trailing-whitespace-fixer detect-private-key; do \
        if ! command -v "$cmd" >/dev/null 2>&1; then \
            echo "FATAL sanity: pre-commit-hooks bin '$cmd' is missing — run 'pip install pre-commit-hooks'" >&2; exit 1; \
        fi; \
    done; \
    echo "== all build-time checks passed =="
