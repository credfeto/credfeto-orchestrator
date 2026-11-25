using System.Diagnostics;
using Credfeto.Orchestrator.Jq;

namespace Credfeto.Orchestrator.Predicates;

// One {login, ts, kind, body} entry of pr_json_unaddressed_trusted_comments_text's jq program
[DebuggerDisplay("{Login} ({Kind}, {Timestamp})")]
internal sealed record UnaddressedComment(JqValue Login, JqValue Timestamp, JqValue Kind, JqValue Body);
