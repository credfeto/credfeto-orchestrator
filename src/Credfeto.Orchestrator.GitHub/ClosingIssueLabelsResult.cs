using System.Collections.Generic;
using System.Diagnostics;

namespace Credfeto.Orchestrator.GitHub;

// The part of the cfwf MCP server's closing_issue_labels result the read uses; every other property is ignored
[DebuggerDisplay("Labels={Labels}")]
internal sealed record ClosingIssueLabelsResult(IReadOnlyList<string?>? Labels);
