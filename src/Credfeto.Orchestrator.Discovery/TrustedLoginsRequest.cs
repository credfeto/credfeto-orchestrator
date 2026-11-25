using System.Diagnostics;

namespace Credfeto.Orchestrator.Discovery;

// get_trusted_logins' inputs: REPO_FULL, OWNER, WHITELISTED_USERS and PR_CREATOR_LOGIN
[DebuggerDisplay("{Repository}")]
public sealed record TrustedLoginsRequest(string Repository, string Owner, string Whitelist, string Creator);
