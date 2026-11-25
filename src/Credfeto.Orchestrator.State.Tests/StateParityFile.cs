using System.Diagnostics;

namespace Credfeto.Orchestrator.State.Tests;

// A state file a case starts with, under ORCHESTRATOR_STATE_DIR: a directory, a symbolic link to Link, or a regular
// file holding Content
[DebuggerDisplay("Path={Path}")]
public sealed record StateParityFile(string Path, bool Directory, string? Link, string Content);
