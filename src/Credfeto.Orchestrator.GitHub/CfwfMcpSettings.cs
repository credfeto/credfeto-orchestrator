using System;
using System.Diagnostics;

namespace Credfeto.Orchestrator.GitHub;

// Not a record: a record's generated ToString would print the token
[DebuggerDisplay("Endpoint={Endpoint}")]
public sealed class CfwfMcpSettings
{
    public CfwfMcpSettings(Uri endpoint, string token)
    {
        this.Endpoint = endpoint;
        this.Token = token;
    }

    public Uri Endpoint { get; }

    public string Token { get; }
}
