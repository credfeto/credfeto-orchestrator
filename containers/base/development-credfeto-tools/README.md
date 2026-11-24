# development-credfeto-tools

Base image: `ghcr.io/credfeto/development-dotnet-tools:latest`

This is stage 5 of the development base image chain:

```text
development-tools  →  development-node  →  development-python
    →  development-dotnet-tools  →  development-credfeto-tools
```

It adds the first-party `Credfeto.*`/`FunFair.*` .NET global tools this project actively ships,
on top of the stable third-party tools installed by `development-dotnet-tools` (stage 4).
`development-full` (stage 6) layers everything else — skills, hooks/settings, pre-commit, the
full verification tail — on top of this image.

## Why this image exists

Splitting the first-party tools into their own layer, separate from the third-party ones in
`development-dotnet-tools`, means a new release of an org-owned package (which the project
controls and may ship more often) never busts the third-party layer's cache, and vice versa —
each layer only rebuilds when a tool it actually installs ships a new version.

## What it installs

NuGet.Config, `NUGET_PACKAGES`, and `claude-code` are already baked in by
`development-dotnet-tools` (this image's base) — nothing to redo here.

### .NET global tools

Installed into the `developer` user's global tool path (`/home/developer/.dotnet/tools`) via
`su developer -c "dotnet tool install -g ..."`. Each tool gets its own layer to keep individual
blob sizes manageable and to avoid cascading cache invalidation.

| Package ID | Command(s) |
| --- | --- |
| `Credfeto.Changelog.Cmd` | `changelog`, `dotnet-changelog` |
| `Credfeto.DotNet.Code.Analysis.Overrides.Cmd` | `code-analysis`, `dotnet-code-analysis` |
| `FunFair.BuildCheck` | `buildcheck`, `dotnet-buildcheck` |
| `FunFair.BuildVersion` | `buildversion`, `dotnet-buildversion` |
| `Credfeto.DotNet.Repo.Formatter` | `cscleanup`, `dotnet-cscleanup` |
| `Credfeto.Build.Dotnet.Server` | `credfeto-build-dotnet` (the `build-dotnet` MCP server, which `development-full`'s `build-dotnet-mcp` wrapper starts from its global tool path, `/home/developer/.dotnet/tools/credfeto-build-dotnet`) |
| `Credfeto.Build.Node.Server` | `credfeto-build-node` (the `build-node` MCP server, which `development-full`'s `build-node-mcp` wrapper starts from its global tool path, `/home/developer/.dotnet/tools/credfeto-build-node`) |
| `Credfeto.ChangeLog.Mcp` | `changelog-mcp` (the `changelog` MCP server, which `development-full`'s `changelog-mcp` wrapper starts from its global tool path, `/home/developer/.dotnet/tools/changelog-mcp`) |
| `Credfeto.Git.Mcp` | `credfeto-git-mcp` (the `git` MCP server, which `development-full`'s `git-mcp` wrapper starts from its global tool path, `/home/developer/.dotnet/tools/credfeto-git-mcp`); installed at the version in the `CREDFETO_GIT_MCP_VERSION` ARG, see below |

`dotnet <name>` subcommand aliases (e.g. `dotnet-buildcheck`) are created via `ln -sf` so the
dotnet CLI can locate tools invoked through subcommand syntax.

## Pinned version

Every package above installs its latest stable release except `Credfeto.Git.Mcp`. It has only
pre-release builds so far, which `dotnet tool install` never picks without an explicit version, so
the Dockerfile's `CREDFETO_GIT_MCP_VERSION` ARG pins one. That ARG is the only place the version is
set: swap it for the first stable release (or remove the pin so the tool tracks the latest stable
release like the rest) before the change that introduced it is merged.

## Cache-bust mechanism

`CREDFETO_FUNFAIR_TOOLS_CACHE_BUST` is resolved by `build-development-credfeto-tools.yml` via
the `.github/actions/nuget-latest-versions` composite action: it queries the NuGet flat-container
API for the latest published version of every package this image installs (`Credfeto.Changelog.Cmd`,
`Credfeto.DotNet.Code.Analysis.Overrides.Cmd`, `FunFair.BuildCheck`, `FunFair.BuildVersion`,
`Credfeto.DotNet.Repo.Formatter`, `Credfeto.Build.Dotnet.Server`, `Credfeto.Build.Node.Server`, `Credfeto.ChangeLog.Mcp`, `Credfeto.Git.Mcp`) and hashes them together. The value only changes when one of
those packages actually ships a new release, so an unchanged run is a full build-cache hit
rather than a blind reinstall.

## Self-checks

The build-time sanity `RUN` step verifies everything this stage adds and fails the build (not
the container at runtime) if anything is missing:

- Each of the nine .NET tools above is present in `dotnet tool list -g`.
- `/home/developer/.dotnet/tools/credfeto-build-dotnet` is executable and `credfeto-build-dotnet` resolves on `PATH`.
- `/home/developer/.dotnet/tools/credfeto-build-node` is executable and `credfeto-build-node` resolves on `PATH`.
- `/home/developer/.dotnet/tools/changelog-mcp` is executable and `changelog-mcp` resolves on `PATH`.
- `/home/developer/.dotnet/tools/credfeto-git-mcp` is executable and `credfeto-git-mcp` resolves on `PATH`.
- Each of the five `dotnet-*` subcommand aliases resolves on `PATH`.

`development-full`'s own build-time sanity check still probes the full inherited toolchain
end-to-end as an integration test — this stage's check exists to fail fast, at this layer,
instead of surfacing one image downstream.
