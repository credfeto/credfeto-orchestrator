namespace Credfeto.Orchestrator.State;

// The lib/state path functions: each is the same printf, so a value is joined in as it is
public static class StatePaths
{
    // invocation_guard_file_path, infra_failure_guard_file_path, last_diagnostic_marker_file_path and the markers:
    // <SESSION_BASE_DIR>/<type>_<id>.<suffix>
    public static string ItemFile(string sessionDirectory, string itemType, string itemId, string suffix)
    {
        return sessionDirectory + "/" + itemType + "_" + itemId + "." + suffix;
    }

    // env_unblock_attempts_file_path: PR-only
    public static string EnvUnblockAttempts(string sessionDirectory, string itemId)
    {
        return ItemFile(
            sessionDirectory: sessionDirectory,
            itemType: "PullRequest",
            itemId: itemId,
            suffix: "env-unblocks"
        );
    }

    // precheck_cache_file_path
    public static string Precheck(string sessionDirectory, string key)
    {
        return sessionDirectory + "/" + key + ".precheck";
    }

    // owner_rate_limit_file
    public static string RateLimit(string stateDirectory, string owner)
    {
        return OwnerFile(stateDirectory: stateDirectory, owner: owner, name: "rate-limit");
    }

    // pull_duration_state_file_path
    public static string PullDurations(string stateDirectory, string owner)
    {
        return OwnerFile(stateDirectory: stateDirectory, owner: owner, name: "pull-durations");
    }

    private static string OwnerFile(string stateDirectory, string owner, string name)
    {
        return stateDirectory + "/" + owner + "/" + name;
    }
}
