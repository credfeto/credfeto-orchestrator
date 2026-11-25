namespace Credfeto.Orchestrator.Commands;

public static class ExitCodes
{
    public const int Success = 0;

    // The command ran but could not produce a result, as when jq fails in the shell version
    public const int Failure = 1;

    public const int Usage = 2;

    // A predicate's answer is false, or the read found nothing
    public const int No = 3;

    // Stopped by SIGINT or SIGTERM
    public const int Cancelled = 130;
}
