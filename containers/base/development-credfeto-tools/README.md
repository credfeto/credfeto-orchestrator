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

`dotnet <name>` subcommand aliases (e.g. `dotnet-buildcheck`) are created via `ln -sf` so the
dotnet CLI can locate tools invoked through subcommand syntax.

## Cache-bust mechanism

`CREDFETO_FUNFAIR_TOOLS_CACHE_BUST` is resolved by `build-development-credfeto-tools.yml` via
the `.github/actions/nuget-latest-versions` composite action: it queries the NuGet flat-container
API for the latest published version of every package this image installs (`Credfeto.Changelog.Cmd`,
`Credfeto.DotNet.Code.Analysis.Overrides.Cmd`, `FunFair.BuildCheck`, `FunFair.BuildVersion`,
`Credfeto.DotNet.Repo.Formatter`) and hashes them together. The value only changes when one of
those packages actually ships a new release, so an unchanged run is a full build-cache hit
rather than a blind reinstall.

## Self-checks

The build-time sanity `RUN` step verifies everything this stage adds and fails the build (not
the container at runtime) if anything is missing:

- Each of the five .NET tools above is present in `dotnet tool list -g`.
- Each of the five `dotnet-*` subcommand aliases resolves on `PATH`.

`development-full`'s own build-time sanity check still probes the full inherited toolchain
end-to-end as an integration test — this stage's check exists to fail fast, at this layer,
instead of surfacing one image downstream.
