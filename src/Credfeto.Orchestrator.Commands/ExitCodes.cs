namespace Credfeto.Orchestrator.Commands;

public static class ExitCodes
{
    public const int Success = 0;

    // The command ran but could not produce a result, as when jq fails in the shell version
    public const int Failure = 1;

    public const int Usage = 2;

    // discovery priorities: the feed answered, but not with the expected JSON (fetch_all_priorities returns 2)
    public const int Unparseable = 3;

    // discovery github-incident: only a minor incident is open on a used component (github_incident_open returns 3)
    public const int MinorIncident = 3;

    // discovery github-incident: no incident is open on a used component (github_incident_open returns 1)
    public const int NoIncident = 4;

    // A predicate's answer is false, or the read found nothing
    public const int No = 3;

    // Stopped by SIGINT or SIGTERM
    public const int Cancelled = 130;
}
