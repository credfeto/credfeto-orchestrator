using System.Collections.Generic;
using System.Diagnostics;

namespace Credfeto.Orchestrator.GitHub;

// The part of the cfwf MCP server's branch_required_checks result the read uses; every other property is ignored
[DebuggerDisplay("Checks={Checks}")]
internal sealed record BranchRequiredChecksResult(IReadOnlyList<string?>? Checks);
