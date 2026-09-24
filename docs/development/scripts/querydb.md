# querydb

A small bash wrapper that loads database connection settings from `.database` files and runs `sqlcmd` with them, logging everything it prints.

Back to the [development guide](../README.md).

## Purpose

`sqlcmd` is denied to the agent directly (`Bash(sqlcmd *)` is in the `permissions.deny` list of `claude-settings.json`, as are `cat`/`grep`/`find` of `*/.database*` and `Read`/`Edit` of `~/.database`), so the credentials in `.database` never appear on an agent-typed command line. `querydb` is the sanctioned route: it sources the settings files itself and invokes `sqlcmd` as its own subprocess. `ai/global/sql.examples.md` describes this route and the `.database` file format.

## Running it

```bash
querydb -Q "SELECT 1"
querydb -i script.sql
```

Every argument is passed straight through to `sqlcmd` after the connection options (`-S "$SERVER" -d "$DB" -U "$USER" -P "$PASSWORD" "$@"`). `querydb` has no options of its own and no `--help`. Test: "extra arguments are passed through to sqlcmd".

Inputs, both plain `KEY=value` shell files that are sourced (so they are executed as shell, not parsed):

- `$HOME/.database`, sourced first if it exists (read via `readlink -f`, so a symlinked file is canonicalised).
- The nearest `.database` found by walking up from `$PWD`, sourced second, so it overrides individual fields. It is skipped when it resolves to the same file as `$HOME/.database`, so the file is not sourced twice.

The four required fields are `SERVER`, `DB`, `USER` and `PASSWORD`. Typically the machine-specific `$HOME/.database` holds `SERVER`, `USER` and `PASSWORD`, and the repo's committed `.database` holds `DB`.

Environment variables read by the script itself:

- `HOME`, to find the global file.
- `XDG_RUNTIME_DIR`, then `TMPDIR`, then `/tmp`, in that order, to choose where the log file goes (`TMPBASE`).
- `TESTDB_LOGGING`, an internal recursion guard (see below). Do not set it by hand.

Output: everything the script and `sqlcmd` print, stdout and stderr merged, is streamed to the terminal and copied to `$TMPBASE/testdb-last.log`, which is overwritten on every run. The script prints `Using <file>` for the global file, `Using settings from <folder>` for a distinct repo-local file, and `Connecting to <server> (DB: <db>) as <user>` before calling `sqlcmd`. The password is not printed by the script.

Exit codes: `sqlcmd`'s own exit status once it has been launched (carried out through the `tee` pipe by `${PIPESTATUS[0]}`); 1 from `die` when `SERVER`, `DB`, `USER` or `PASSWORD` is empty (message `<NAME> not set (add it to $HOME/.database or a repo-local .database file)` plus `(full log: <path>)`).

## How it works

1. Log capture: unless `TESTDB_LOGGING` is set, the script re-executes itself (`TESTDB_LOGGING=1 "$0" "$@" 2>&1 | tee "$TESTDB_LOG"`) and exits with `${PIPESTATUS[0]}`, the inner run's status. This is why every line of output ends up in the log; the variable stops the inner run recursing.
2. `die` prints the message and the log path, then exits 1.
3. Settings: `SERVER`, `DB`, `USER` and `PASSWORD` are cleared, then `$HOME/.database` is sourced, then the nearest `.database` up the tree (loop `CP="${CP%/*}"` until empty), if it is a different file.
4. Validation: each of the four fields must be non-empty or `die`.
5. `sqlcmd -S "$SERVER" -d "$DB" -U "$USER" -P "$PASSWORD" "$@"` is the last command, so its status is the script's.

External tools: `bash` (the shebang is `#!/bin/bash`, and it uses `PIPESTATUS`), `tee`, `readlink`, `dirname` and `sqlcmd`. `USER` is deliberately shadowed (the comment and `# shellcheck disable=SC2034` explain it): it comes from the `.database` files, not from the login name.

Shipping: the Dockerfile in `containers/base/development-full/` does `COPY --chown=root:root --chmod=0755 scripts/querydb /usr/local/bin/querydb`, and the Stage 1 sanity loop only checks it is present and executable (there is no `--version`). It is on `claude-hooks/command-allowlist` and `Bash(querydb *)` is in `claude-settings.json` `permissions.allow`; `test/command-allowlist-parity.bats` keeps the two in step. `install-claude-hooks` does not install it on a host (it only installs `cfwf`), so on a host it has to be on `PATH` by other means. In the container, `lib/podman` mounts `$HOME/.database` read-only at `/home/developer/.database` when it exists, and warns when it does not.

## Tests

`test/querydb.bats` has six tests: the two `die` paths that are covered (`SERVER not set`, `PASSWORD not set`), loading `$HOME/.database`, a repo-local file overriding one field from a nested directory, argument pass-through, and the log file copy.

- `setup` calls `setup_isolated_env` (from `test/test_helper.bash`), which redirects `HOME`, the XDG variables and `PATH`, and unsets `XDG_RUNTIME_DIR`.
- `TMPDIR` is pointed at `${TEST_TMP}/tmp` so the re-exec's log never lands in the real `/tmp`.
- `sqlcmd` is faked with `make_stub sqlcmd 'echo "sqlcmd called with: $*"'`, a PATH stub that echoes its arguments, so assertions are on the exact argument string.
- `write_database_file` writes `.database` files; `run_script <dir>` (from the helper) runs the script with that working directory.

Run just this file:

```bash
bats test/querydb.bats
```

## Changing it safely

- Run `shellcheck containers/base/development-full/scripts/querydb` and keep it clean.
- Run `bats test/querydb.bats`.
- Mutation-check any new test: break the code (for example drop the `-P` argument or the `PIPESTATUS` exit) and confirm the new test fails, then restore it.
- Update `containers/base/development-full/README.md` (the `querydb` bullet under "Repo-local scripts") and `ai/global/sql.examples.md` if behaviour changes. The script has no help text to update.
- If the name changes or it is renamed, update `Dockerfile`, `claude-hooks/command-allowlist`, `claude-settings.json` and expect `test/command-allowlist-parity.bats` to tell you what is out of step.
- Add a changelog entry with `dotnet changelog -f CHANGELOG.md -a <Type> -m "<message>"`. Never edit `CHANGELOG.md` by hand.
- The pre-commit hooks run the whole bats suite, so commits and pushes take minutes. Run them in the background.

## Gotchas

- Untested paths: `DB not set` and `USER not set` have no test, and neither does the "repo-local file is the same file as `$HOME/.database`" skip. A change to either is not protected.
- `.database` files are sourced as shell, so anything in them runs. Keep them to `KEY=value` lines.
- The walk-up loop stops when the path becomes empty, so a `.database` in `/` is never found. It also picks the nearest file only; it does not merge several.
- The password goes on the `sqlcmd` command line (`-P`), so it is visible in the process list while the query runs.
- The log name is `testdb-last.log` (from the older `testdb` wrapper), it is shared between runs, and it holds whatever `sqlcmd` printed, including query results. Concurrent runs overwrite each other. `/tmp/**` is denied for `Read` in `claude-settings.json`, so when `TMPBASE` is `/tmp` the agent cannot read the log back with `Read`.
- stdout and stderr are merged, so a caller cannot separate them.
- A test environment with a `.database` in an ancestor directory of `TEST_TMP` would leak into "dies when no settings are available at all", because of the walk-up.
- GitHub API behaviour: not affected. `querydb` never talks to GitHub.
