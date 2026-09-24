# Contributing to credfeto-orchestrator

Thanks for taking the time to contribute. This file says how to ask a question, report a bug,
suggest a change and send a fix. How the code is written, tested and changed is in the
[development guide](docs/development/README.md); read that before you change a script.

## Table of Contents

- [I have a question](#i-have-a-question)
- [Reporting bugs](#reporting-bugs)
- [Suggesting enhancements](#suggesting-enhancements)
- [Sending a change](#sending-a-change)
- [Legal notice](#legal-notice)

## I have a question

Search the existing [issues](https://github.com/credfeto/credfeto-orchestrator/issues) and the
[documentation](docs/) first: [architecture](docs/architecture.md), [oneshot](docs/oneshot.md)
and [the Workflow board](docs/workflow-board.md) explain what the orchestrator does. If that
does not answer it, open an issue with as much context as you can: what you ran, what you
expected, and what happened.

## Reporting bugs

Never report a security problem, a vulnerability or anything containing secrets in a public issue.
Follow [SECURITY.md](SECURITY.md) instead.

For anything else, first check that you are on the latest version and that the bug is not already
reported. Then open an issue that says:

- what you expected and what happened instead, with the exact command and its output;
- how to reproduce it, ideally the smallest case that still fails;
- the platform and versions that matter (operating system, `bash`, `gh`, `podman`, `jq`, the
  image tag if it happens in the agent container);
- for a Workflow board problem, the repository, the item number and the status you saw.

A maintainer will label it, try to reproduce it, and mark it `needs-repro` if they cannot.

## Suggesting enhancements

Open an issue that describes the current behaviour, the behaviour you want and why, and any
alternatives you tried. Check first that it has not been suggested and that it fits what this
project is for: an orchestrator that runs an AI agent one work item at a time, gated by a
human-approved plan.

## Sending a change

1. Read the [development guide](docs/development/README.md) and the guide for each script you
   will change, under [docs/development/scripts/](docs/development/scripts/).
2. Agree the change on an issue before writing code; a plan (files, approach, tests,
   assumptions) is posted there and work starts once it is approved.
3. Work on a branch, add tests with the change and mutation-check them, and update the guide,
   README and docs pages that describe the behaviour you changed.
4. Add a changelog entry with `dotnet changelog` (never edit `CHANGELOG.md` by hand).
5. Open a pull request that says what changed and why, and how you tested it. The pre-commit
   hooks run the whole test suite, so expect commits and pushes to take a few minutes.

## Legal notice

When contributing to this project, you must agree that you have authored 100% of the content,
that you have the necessary rights to the content and that the content you contribute may be
provided under the project license.
