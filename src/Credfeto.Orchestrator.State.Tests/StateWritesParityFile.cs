using System.Diagnostics;

namespace Credfeto.Orchestrator.State.Tests;

// A file a case of test/fixtures/state-writes-parity.json starts with, under ORCHESTRATOR_STATE_DIR: a directory, a
// symbolic link to Link, a hard link to the case's file at HardLink, or a regular file holding Content; Mode (octal,
// empty for the umask's) is set once every file is made
[DebuggerDisplay("Path={Path}")]
public sealed record StateWritesParityFile(
    string Path,
    bool Directory,
    string? Link,
    string? HardLink,
    string Content,
    string Mode
);
