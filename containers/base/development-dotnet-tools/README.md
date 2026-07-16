# development-dotnet-tools

Base image: `ghcr.io/credfeto/development-python:latest`

This is stage 4 of the development base image chain:

```text
development-tools  →  development-node  →  development-python  →  development-dotnet-tools
```

It adds `claude-code` and the stable, genuinely third-party (non-credfeto/funfair) .NET global
tools this project depends on. `development-credfeto-tools` (stage 5) layers the
`Credfeto.*`/`FunFair.*` first-party tools on top of this image, and `development-full`
(stage 6) layers everything else on top of that.

## Why this image exists

`development-full` used to bake every .NET global tool — third-party and first-party alike —
under a single blind daily cache-bust, positioned early enough in that Dockerfile to invalidate
everything downstream (skill clones, Claude Code hooks, the pre-commit orchestrator, and the
whole build-time verification tail) once a day regardless of whether anything actually changed.
Splitting the toolchain into its own image, cache-busted only when a tool it installs actually
publishes a new version, means a `development-full`-only change (hooks, skills, pre-commit) no
longer forces this layer to rebuild, and vice versa.

## What it installs

### NuGet.Config for FunFair feeds

A `NuGet.Config` is baked into the image at `/home/developer/.nuget/NuGet/NuGet.Config`. It
clears the default NuGet source and registers three FunFair-specific caching proxies:

- `Cache: api.nuget.org` — `https://api-nuget.markridgwell.com/v3/index.json`
- `Cache: FunFair` — `https://funfair-nuget.markridgwell.com/index.json`
- `Cache: FunFair (Prerelease)` — `https://funfair-prerelease-nuget.markridgwell.com/index.json`

The package restore cache is redirected to `/home/developer/.nuget-cache` (developer-owned) via
`NUGET_PACKAGES` so that `dotnet restore` and `dotnet tool install -g` remain writable without
touching the locked config subtree.

### claude-code

Installed via `apt-get` (the keyring and apt sources entry were added in `development-tools`).

### .NET global tools

Installed into the `developer` user's global tool path (`/home/developer/.dotnet/tools`) via
`su developer -c "dotnet tool install -g ..."`. Each tool gets its own layer to keep individual
blob sizes manageable and to avoid cascading cache invalidation.

| Package ID | Command(s) |
| --- | --- |
| `TSQLLint` | `tsqllint`, `dotnet-tsqllint` |
| `CWM.RoslynNavigator` | `cwm-roslyn-navigator`, `dotnet-cwm-roslyn-navigator` |
| `dotnet-ef` | `dotnet-ef` |
| `ilspycmd` | `ilspycmd`, `dotnet-ilspycmd` |
| `Microsoft.SqlPackage` | `sqlpackage`, `dotnet-sqlpackage` |
| `PowerShell` | `pwsh` |
| `dotnet-script` | `dotnet-script` |

`dotnet <name>` subcommand aliases (e.g. `dotnet-tsqllint`) are created via `ln -sf` so the
dotnet CLI can locate tools invoked through subcommand syntax.

### PSScriptAnalyzer

Installed via `Install-PSResource` for the `developer` user's PowerShell profile —
`check-setup` (in `development-full`) imports it to validate the `VALIDATE_POWERSHELL` hook.

## Cache-bust mechanism

`STABLE_TOOLS_CACHE_BUST` is resolved by `build-development-dotnet-tools.yml` via the
`.github/actions/nuget-latest-versions` composite action: it queries the NuGet flat-container
API for the latest published version of every package this image installs (`TSQLLint`,
`CWM.RoslynNavigator`, `dotnet-ef`, `ilspycmd`, `Microsoft.SqlPackage`, `PowerShell`,
`dotnet-script`) and hashes them together. The value only changes when one of those packages
actually ships a new release, so an unchanged day is a full build-cache hit rather than a blind
reinstall.

## Self-checks

The build-time sanity `RUN` step verifies everything this stage adds and fails the build (not
the container at runtime) if anything is missing:

- `claude` is present and responds to `--version`/`--help`.
- Each of the seven .NET tools above is present in `dotnet tool list -g`.
- `cwm-roslyn-navigator --help` exits `0`.
- The `PSScriptAnalyzer` PowerShell module imports successfully under `pwsh`.

`development-full`'s own build-time sanity check still probes the full inherited toolchain
end-to-end as an integration test — this stage's check exists to fail fast, at this layer,
instead of surfacing two images downstream.
