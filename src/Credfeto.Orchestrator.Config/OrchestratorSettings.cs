using System.Diagnostics;

namespace Credfeto.Orchestrator.Config;

[DebuggerDisplay(
    "StateDirectory={StateDirectory}, WorkDirectory={WorkDirectory}, CiCheckTimeoutMinutes={CiCheckTimeoutMinutes}, UnknownMergeStateTimeoutMinutes={UnknownMergeStateTimeoutMinutes}"
)]
public sealed record OrchestratorSettings(
    string StateDirectory,
    string WorkDirectory,
    int CiCheckTimeoutMinutes,
    int UnknownMergeStateTimeoutMinutes
)
{
    // SESSION_BASE_DIR (lib/git set_repo_context): where an owner/repo's fingerprint and session files live
    public string SessionDirectory(string owner, string repository)
    {
        return this.StateDirectory + "/" + owner + "/" + repository;
    }
}
