using System.Diagnostics;
using System.Net.Http;

namespace Credfeto.Orchestrator.GitHub.Tests;

[DebuggerDisplay("{Method}: {Body}")]
public sealed record RecordedRequest(HttpMethod Method, string? Authorization, string Body);
