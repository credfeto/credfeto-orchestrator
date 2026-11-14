using System.Diagnostics;

namespace Credfeto.Orchestrator.Commands.Tests;

// One read checked against a collection of test/fixtures/github-parity.json: the command that makes it, the case field
// that names the branch, the field holding what the shell version prints, and the MCP tool and argument it asks with
[DebuggerDisplay("Collection={Collection}, Read={Read}")]
public sealed record GitHubParityRead(
    string Collection,
    string Read,
    string NameField,
    string ExpectedField,
    string Tool,
    string NameArgument
);
